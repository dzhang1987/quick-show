import Combine
import SwiftUI

// MARK: - 视口高度环境值（首帧视口自适应分批）

/// 当前会话滚动视口高度（pt）。由 `SessionMessageList` 从其外层 GeometryReader 注入，
/// `AssistantMarkdownView` 读取以估算「首帧覆盖一屏」所需的初始块数（微信式秒开：
/// 首帧成本只与屏幕大小成正比，与会话体量无关）。默认 700（流式等无注入路径的合理常量）。
private struct ChatViewportHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 700
}

extension EnvironmentValues {
    var chatViewportHeight: CGFloat {
        get { self[ChatViewportHeightKey.self] }
        set { self[ChatViewportHeightKey.self] = newValue }
    }
}

// MARK: - Markdown AST 解析缓存（线程安全）

/// 块级 AST 解析缓存：`MarkdownParser.parse` 是无状态纯函数（同输入同输出），以 content 为
/// key 缓存 AST，命中直接复用。主线程渲染与后台公式预热线程都可能读写，故用 `lock` 保护；
/// 解析在锁外执行，仅在字典读写时持锁，避免长解析阻塞主线程。独立于 View 类型（非 MainActor），
/// 可安全地从后台队列调用。
enum MarkdownASTCache {
    private static var cache: [String: [MarkdownBlock]] = [:]
    /// LRU 次序（尾部=最近使用）：命中移到尾部，淘汰从头部。多会话来回切换时热条目不被误踢。
    private static var cacheOrder: [String] = []
    /// 条目数上限（256：>12 常驻会话 + 历史消息，大幅提升命中率）。
    private static let cacheEntryLimit = 256
    /// 内容总字符预算（4M：见报告内存量级，AST 文本与原文同量级）。
    private static let cacheCharBudget = 4_000_000
    /// 当前缓存内容的总字符数（预算淘汰用）。
    private static var cacheCharTotal = 0
    private static let lock = NSLock()

    /// 取 content 的块级 AST。
    /// - useCache == false：完全旁路缓存直接解析（不读不写），供流式中间态使用。
    /// - useCache == true：命中读缓存并刷新 LRU；未命中解析后写入，按条数/字符预算做 LRU 淘汰。
    static func blocks(for content: String, useCache: Bool) -> [MarkdownBlock] {
        guard useCache else { return MarkdownParser.parse(content) }
        lock.lock()
        if let cached = cache[content] {
            touchLocked(content)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let blocks = MarkdownParser.parse(content)

        lock.lock()
        if cache[content] != nil {
            touchLocked(content)   // 并发下已被他人写入：不重复计数
        } else {
            cache[content] = blocks
            cacheOrder.append(content)
            cacheCharTotal += content.count
            evictIfNeededLocked()
        }
        lock.unlock()
        return blocks
    }

    /// 锁内把 key 移到 LRU 尾部（最近使用）。
    private static func touchLocked(_ content: String) {
        guard let index = cacheOrder.firstIndex(of: content) else { return }
        cacheOrder.remove(at: index)
        cacheOrder.append(content)
    }

    private static func evictIfNeededLocked() {
        while cacheOrder.count > cacheEntryLimit || cacheCharTotal > cacheCharBudget {
            guard !cacheOrder.isEmpty else { break }
            let oldest = cacheOrder.removeFirst()
            if cache.removeValue(forKey: oldest) != nil {
                cacheCharTotal -= oldest.count
            }
        }
    }
}

// MARK: - 助手消息 Markdown 完整渲染

/// 助手落定消息：消费 MarkdownParser 的完整块级 AST。
/// 视觉层次原则（2026-10 排版专项，对标 DeepSeek / Claude Code 对话排版）：
/// - 无气泡：正文直接铺在玻璃材质上左对齐、无内边距，层级全靠字号/字重/留白表达
/// - 六级排版：h1 18 bold（附减弱底部分隔线）/ h2 16 / h3 14 / h4 13 / h5 12.5 / h6 12 semibold，均 contentPrimary；
///   正文与列表降两档（primary 0.80），与加粗档（contentPrimary semibold）肉眼可分
/// - 间距节奏：块间距不由 VStack 统一值承担，改为每块自带顶距——
///   标题前 26/20/16（与上文拉开成组），标题后 8（与紧随内容成组），内容块之间 16，首块无顶距
/// - 行高：正文/列表/代码 lineSpacing 6（13pt ≈ 1.7 倍）；列表项间 8、嵌套子项间 6
/// - 引号归一：成对 ASCII 直引号显示为「」（仅 text token，代码/链接不受影响）
struct AssistantMarkdownView: View, Equatable {
    let content: String
    /// 是否读写解析缓存。落定态（done/aborted）恒为 true；流式中间态（内容每 250ms 增长）
    /// 传 false 完全旁路缓存——否则每个中间态都成为新 key 写入并 FIFO 逐出落定消息的有用缓存。
    var useCache: Bool = true

    // MARK: - 解析缓存（落定态重渲染加速）

    // 实现迁至文件级 `MarkdownASTCache`（线程安全）：主线程渲染与后台预热共用同一缓存。
    private static func parsedBlocks(for content: String, useCache: Bool) -> [MarkdownBlock] {
        MarkdownASTCache.blocks(for: content, useCache: useCache)
    }

    /// 会话预热用：取 content 的块级 AST（命中缓存则复用，否则解析后写入）。
    /// `nonisolated`：允许后台预热线程调用（缓存自身线程安全）。
    nonisolated static func parsedBlocksForPrefetch(_ content: String) -> [MarkdownBlock] {
        MarkdownASTCache.blocks(for: content, useCache: true)
    }

    /// 脚注条目：定义 id 与行内内容。
    struct FootnoteEntry: Equatable {
        let id: String
        let inlines: [InlineToken]
    }

    /// 把顶层 footnoteDefinition 从块流中抽出，其余块保持原顺序与相对位置。
    static func splitFootnotes(_ blocks: [MarkdownBlock]) -> (main: [MarkdownBlock], footnotes: [FootnoteEntry]) {
        var main: [MarkdownBlock] = []
        var footnotes: [FootnoteEntry] = []
        main.reserveCapacity(blocks.count)
        for block in blocks {
            if case let .footnoteDefinition(id, inlines) = block {
                footnotes.append(FootnoteEntry(id: id, inlines: inlines))
            } else {
                main.append(block)
            }
        }
        return (main, footnotes)
    }

    // MARK: - 单条消息内渐进渲染（首帧视口自适应）

    /// 保守的每块高度估计（pt）：正文段落 + 块间距的偏大值，用于「首帧覆盖一屏」估算。
    private static let estimatedBlockHeight: CGFloat = 72
    /// 初始块数下限（视口高度未知/极小时仍覆盖首屏顶部）。
    private static let minInitialBlocks = 8
    /// 初始块数上限（防超大视口一次构建过多）。
    private static let maxInitialBlocks = 16
    /// 后续每批块数（16ms 逐批：摊销更平滑）。
    private static let blockBatchSize = 12
    /// 已构建块数游标；-1 = 未种子化（首帧按视口高度算初始值）。消息身份变化时随视图重建重置。
    @State private var visibleBlockCount = -1

    /// 视口高度（由 `SessionMessageList` 注入）：首帧成本只与屏幕大小成正比，与会话体量无关。
    @Environment(\.chatViewportHeight) private var viewportHeight

    /// 手动实现 Equatable：分批游标是视图私有 @State（非渲染输入），
    /// 不参与相等判定，语义与新增 @State 前完全一致。
    static func == (lhs: AssistantMarkdownView, rhs: AssistantMarkdownView) -> Bool {
        lhs.content == rhs.content && lhs.useCache == rhs.useCache
    }

    /// 首帧初始块数：ceil(视口高度 / 每块估计高度)，夹在 [下限, 上限] 与总块数之间。
    private static func initialBlockCount(viewportHeight: CGFloat, total: Int) -> Int {
        let byViewport = Int((max(viewportHeight, 1) / estimatedBlockHeight).rounded(.up))
        return min(total, max(minInitialBlocks, min(byViewport, maxInitialBlocks)))
    }

    /// 当前有效可见块数（读取 live @State；未种子化时用首帧初始值）。供哨兵/task 实时读取。
    private func effectiveVisibleCount(seededInitial: Int, total: Int) -> Int {
        let base = visibleBlockCount < 0 ? seededInitial : visibleBlockCount
        return min(base, total)
    }

    var body: some View {
        let allBlocks = Self.parsedBlocks(for: content, useCache: useCache)
        // 脚注定义从正常块流中抽出（不在原位置渲染），聚合到文档末尾统一成脚注区。
        let split = Self.splitFootnotes(allBlocks)
        let blocks = split.main
        let footnotes = split.footnotes
        let seededInitial = Self.initialBlockCount(viewportHeight: viewportHeight, total: blocks.count)
        let visibleCount = effectiveVisibleCount(seededInitial: seededInitial, total: blocks.count)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.prefix(visibleCount).enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block)
                    .padding(.top, index == 0 ? 0 : block.topSpacing(after: blocks[index - 1]))
            }
            // 分批哨兵：零尺寸、无内容，出现后下一 runloop 再放一批。
            // 未被构建的块（含其内公式 attachment）此帧完全不参与测量/光栅化。
            //
            // ⚠️ `.id(visibleCount)` 是必需的：哨兵结构性身份不随前面 ForEach 变长而改变，
            // SwiftUI 视其为同一视图，`onAppear` 只在首次插入触发一次——那样分批会永久停摆。
            // 逐批改变 id 强制哨兵重建，使每批都能再次 onAppear，直到覆盖全部块。
            if visibleCount < blocks.count {
                Color.clear
                    .frame(width: 0, height: 0)
                    .id(visibleCount)
                    .onAppear {
                        DispatchQueue.main.async {
                            let current = effectiveVisibleCount(seededInitial: seededInitial, total: blocks.count)
                            visibleBlockCount = min(current + Self.blockBatchSize, blocks.count)
                        }
                    }
            }
            // 脚注区：所有 footnoteDefinition 聚合到文档末尾（细分隔线 + 小字号编号列表），
            // 待正文块全部分批落地后再显示，避免脚注抢在后续正文之前出现。
            if visibleCount >= blocks.count, !footnotes.isEmpty {
                MarkdownFootnoteSection(footnotes: footnotes)
                    .padding(.top, Theme.Spacing.divider)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 可靠分批推进兜底（容器必然被 realize，不受 LazyVStack 实现化粘滞影响）：
        // 与哨兵并存最多只是更快；增量基于 live 有效块数，不会回退。
        .task(id: visibleCount) {
            let current = effectiveVisibleCount(seededInitial: seededInitial, total: blocks.count)
            guard current < blocks.count else { return }
            try? await Task.sleep(nanoseconds: 16_000_000)
            let after = effectiveVisibleCount(seededInitial: seededInitial, total: blocks.count)
            guard !Task.isCancelled, after < blocks.count else { return }
            visibleBlockCount = min(after + Self.blockBatchSize, blocks.count)
        }
    }
}

// MARK: - 数学公式 latex 收集（会话预热用）

/// 遍历 Markdown 块级 AST 收集公式 latex：块级/行内分列，便于按各自展示模式预热缓存。
enum MathLatexCollector {
    struct Collected {
        var display: [String]
        var inline: [String]
    }

    /// 收集所有块级 + 行内公式 latex（去重、保持首次出现顺序）。
    static func collectMathLatex(blocks: [MarkdownBlock]) -> [String] {
        let collected = collect(blocks: blocks)
        var seen = Set<String>()
        return (collected.display + collected.inline).filter { seen.insert($0).inserted }
    }

    /// 仅块级公式 latex（display 模式预热用）。
    static func collectBlockMathLatex(blocks: [MarkdownBlock]) -> [String] {
        collect(blocks: blocks).display
    }

    /// 仅行内公式 latex（text 模式预热用）。
    static func collectInlineMathLatex(blocks: [MarkdownBlock]) -> [String] {
        collect(blocks: blocks).inline
    }

    /// 单次遍历：块级入 display、行内入 inline；各自去重保序。
    static func collect(blocks: [MarkdownBlock]) -> Collected {
        var display: [String] = []
        var inline: [String] = []
        var seenDisplay = Set<String>()
        var seenInline = Set<String>()

        func addDisplay(_ latex: String) {
            if seenDisplay.insert(latex).inserted { display.append(latex) }
        }
        func addInline(_ latex: String) {
            if seenInline.insert(latex).inserted { inline.append(latex) }
        }
        func walkInlineTokens(_ tokens: [InlineToken]) {
            for token in tokens {
                switch token {
                case let .math(latex): addInline(latex)
                case let .bold(inner), let .italic(inner),
                     let .strikethrough(inner), let .underline(inner),
                     let .highlight(inner), let .subscript(inner),
                     let .superscript(inner):
                    walkInlineTokens(inner)
                case let .link(text, _, _): walkInlineTokens(text)
                case .text, .code, .image, .lineBreak, .footnoteRef: break
                }
            }
        }
        /// 列表项内容已改为块数组，嵌套子列表以块形式出现，递归交给 walkBlocks。
        func walkItem(_ item: MarkdownListItem) {
            walkBlocks(item.blocks)
        }
        func walkBlocks(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case let .heading(_, inlines), let .paragraph(inlines):
                    walkInlineTokens(inlines)
                case let .mathBlock(latex):
                    addDisplay(latex)
                case let .orderedList(items), let .unorderedList(items):
                    items.forEach(walkItem)
                case let .blockquote(inner):
                    walkBlocks(inner)
                case let .table(table):
                    table.headers.forEach(walkInlineTokens)
                    for row in table.rows { row.forEach(walkInlineTokens) }
                case let .footnoteDefinition(_, inlines):
                    walkInlineTokens(inlines)
                case .codeBlock, .horizontalRule:
                    break
                }
            }
        }
        walkBlocks(blocks)
        return Collected(display: display, inline: inline)
    }
}

// MARK: - 块级公式异步视图

/// 块级公式异步视图：首帧立即渲染「圆角浅灰底 + 等宽 LaTeX 源码」占位，
/// 后台光栅化完成后淡入替换为公式位图。首帧零 SwiftMath 成本，根治长会话白屏。
struct AsyncMathBlockView: View {
    let latex: String
    var fontSize: CGFloat = 14
    var color: Color = Color.primary

    @Environment(\.colorScheme) private var colorScheme
    @State private var loaded = false
    /// 请求世代：外观变化重发请求时，旧回调不得覆盖新状态。
    @State private var generation = 0
    /// 占位高度：同 latex 曾被渲染过则取全局高度缓存，占位直接锁同高 → 消除回填高度跳变。
    @State private var placeholderHeight: CGFloat?

    /// 显式 init：首帧即从全局高度缓存种子化占位高度（若该 latex 曾被渲染过），
    /// 使占位高度与真实位图一致，彻底消除「占位→回填」的高度跳变。
    init(latex: String, fontSize: CGFloat = 14, color: Color = Color.primary) {
        self.latex = latex
        self.fontSize = fontSize
        self.color = color
        _placeholderHeight = State(initialValue: MathLayoutCache.blockHeight(latex: latex, pointSize: fontSize))
    }

    var body: some View {
        // ⚠️ 刻意不做 placeholder→位图的 opacity 过渡动画：单条超长消息内 83+ 个块级公式
        // 的异步回填会在多个 CA 事务里连续触发 opacity 过渡，与首帧建树/窗口级淡入竞态时
        // 会像历史白屏（CHANGELOG 冷启动白屏）一样把内容层卡在近零透明度。改为无动画瞬时替换，
        // 占位符本身已保证首帧有可读内容，替换不再产生任何动画事务。
        // 空/纯空白 LaTeX（`$$\n$$`、退化解析产物）不渲染任何卡片，避免留下无内容的
        // 圆角空白块虚增内容高度、扭曲贴底/恢复判定。
        Group {
            // 非空 LaTeX 才渲染；空/纯空白时 Group 为空（零尺寸），不留空白卡片。
            if !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Group {
                    if loaded {
                        MathBlockView(latex: latex, fontSize: fontSize, color: color)
                    } else {
                        placeholder
                    }
                }
                .padding(.vertical, Theme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear { requestRaster() }
        .onChange(of: colorScheme) { _ in
            loaded = false
            requestRaster()
        }
    }

    /// 占位符：圆角浅灰底 + 等宽小号 LaTeX 源码（首帧即有真实可读内容，非空白）。
    /// 高度封顶（lineLimit + maxHeight）：即便公式超长/畸形，占位也绝不变成长条空白卡片。
    private var placeholder: some View {
        Text(latex)
            .font(Theme.Typography.mono(11))
            .foregroundColor(Theme.Colors.contentTertiary)
            .lineLimit(6)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: 96, alignment: .top)
            .clipped()
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            // 已知真实高度则锁同高（nil 时按内容自适应）：消除占位→位图回填的高度跳变。
            .frame(minHeight: placeholderHeight, maxHeight: placeholderHeight, alignment: .top)
            .clipped()
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .fill(Theme.Colors.surfaceTrack)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
            )
    }

    private func requestRaster() {
        generation += 1
        let token = generation
        // 占位高度兜底：init 已种子化；此处再查一次覆盖「init 后缓存才被填充」的窗口。
        if placeholderHeight == nil {
            placeholderHeight = MathLayoutCache.blockHeight(latex: latex, pointSize: fontSize)
        }
        let nsColor = MathRasterizer.resolvedColor(
            color,
            appearance: MathRasterizer.appearance(for: colorScheme)
        )
        MathRasterizer.rasterizeAsync(
            latex: latex,
            pointSize: fontSize,
            color: nsColor,
            isDisplay: true
        ) { raster in
            // 光栅化失败（raster == nil）保持占位符 = 原始 LaTeX 降级显示。
            guard let raster, token == generation else { return }
            // 记录真实高度（供下次重建的占位锁定，消除回填跳变；尺寸与颜色无关）。
            MathLayoutCache.storeBlockHeight(raster.size.height, latex: latex, pointSize: fontSize)
            loaded = true
        }
    }
}

private extension MarkdownBlock {
    /// 块顶距：间距节奏的唯一来源。
    /// 标题前大幅拉开（h1 26 / h2 20 / h3 16）形成成组锚点；
    /// 标题后收紧为 8（after 为标题时），让标题与紧随内容成组；
    /// 其余内容块（段落/列表/引用/表格/代码块）之间统一 16。
    func topSpacing(after previous: MarkdownBlock) -> CGFloat {
        if case .heading = previous { return Theme.Spacing.lg }      // 8：标题后收紧成组
        switch self {
        case let .heading(level, _):
            // 标题前间距随层级递减成组锚点：26 / 20 / 16 / 14 / 12 / 10
            switch level {
            case 1: return Theme.Spacing.section + Theme.Spacing.lg  // 26：一级标题成组锚点
            case 2: return Theme.Spacing.divider                     // 20
            case 3: return Theme.Spacing.card                        // 16
            case 4: return Theme.Spacing.xxxl                        // 14
            case 5: return Theme.Spacing.xxl                         // 12
            default: return Theme.Spacing.xl                         // 10：h6
            }
        default:
            return Theme.Spacing.card                                // 16：段落/列表/引用/表格/代码块
        }
    }
}

// MARK: - 单个块

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, inlines):
            headingView(level: level, inlines: inlines)

        case let .paragraph(inlines):
            MarkdownInlineText(inlines: inlines)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .mathBlock(latex):
            mathBlockView(latex)

        case .horizontalRule:
            // 水平分隔线：通栏细线，视觉语言对齐 h1 底部分隔线
            Rectangle()
                .fill(Theme.Colors.cardStroke)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Theme.Layout.dividerHeight)

        case let .orderedList(items):
            MarkdownListView(items: items, ordered: true)

        case let .unorderedList(items):
            MarkdownListView(items: items, ordered: false)

        case let .blockquote(inner):
            MarkdownBlockquoteView(blocks: inner)

        case let .table(table):
            MarkdownTableView(table: table)

        case let .codeBlock(language, code):
            CodeBlockView(language: language, code: code)

        case let .footnoteDefinition(_, _):
            // 顶层脚注定义已由 AssistantMarkdownView 抽出到文档末尾统一渲染；
            // 嵌套（如引用块内）定义在此跳过，不在原位置留下占位。
            EmptyView()
        }
    }

    /// 标题：h1 18 bold + 减弱底部分隔线；h2 16 / h3 14 / h4 13 / h5 12.5 / h6 12 semibold；均 contentPrimary。
    /// h4 与正文同号（13）：靠 semibold + contentPrimary 与正文（regular / primary 0.80）区分，对齐 GitHub 语义。
    @ViewBuilder
    private func headingView(level: Int, inlines: [InlineToken]) -> some View {
        switch level {
        case 1:
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                headingText(inlines: inlines, size: 18, weight: .bold)
                Rectangle()
                    .fill(Theme.Colors.cardStroke)
                    .frame(height: Theme.Layout.dividerHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case 2:
            headingText(inlines: inlines, size: 16, weight: .semibold)
        case 3:
            headingText(inlines: inlines, size: 14, weight: .semibold)
        case 4:
            headingText(inlines: inlines, size: 13, weight: .semibold)
        case 5:
            headingText(inlines: inlines, size: 12.5, weight: .semibold)
        default:
            headingText(inlines: inlines, size: 12, weight: .semibold)
        }
    }

    /// 统一标题排版：contentPrimary + 显式字号字重、行距 2、自适应高度。
    private func headingText(inlines: [InlineToken], size: CGFloat, weight: Font.Weight) -> some View {
        MarkdownInlineText(
            inlines: inlines,
            bodyColor: Theme.Colors.contentPrimary,
            baseSize: size,
            weight: weight,
            explicitColor: Theme.Colors.contentPrimary
        )
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 块级公式：异步视图（首帧占位 + 后台光栅化淡入），居中展示（display 模式 14pt）。
    private func mathBlockView(_ latex: String) -> some View {
        AsyncMathBlockView(latex: latex, fontSize: 14, color: Theme.Colors.contentPrimary)
    }
}

// MARK: - 列表

private struct MarkdownListView: View {
    let items: [MarkdownListItem]
    /// 本级有序性：由容器块（orderedList / unorderedList）决定。
    let ordered: Bool
    /// 嵌套深度：0 为顶层，用于切换无序圆点样式（• / ◦）。
    var depth: Int = 0

    var body: some View {
        // 列表项间 8：大间距节奏，提升扫读性（对标 CC 列表呼吸感）
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                MarkdownListItemRow(item: item, ordered: ordered, depth: depth)
            }
        }
    }
}

private struct MarkdownListItemRow: View {
    let item: MarkdownListItem
    let ordered: Bool
    var depth: Int = 0

    /// 嵌套子列表缩进：对齐到父项文本起点（标记列 14 + 间距 8）。
    private static let nestedIndent: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
            marker
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                    itemBlock(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 已勾选任务：内容整体弱化一档（AttributedString 显式前景色无法被外层
            // foregroundColor 覆盖，故用 opacity 做颜色弱化）。
            .opacity(item.taskState == true ? 0.55 : 1)
        }
    }

    /// 行首标记列：任务勾选框 / 有序序号 / 无序圆点（等宽右对齐保持多行对齐）。
    @ViewBuilder
    private var marker: some View {
        if let state = item.taskState {
            Image(systemName: state ? "checkmark.circle.fill" : "circle")
                .font(Theme.Typography.text(12.5, .medium))
                .foregroundColor(state ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                .frame(minWidth: 14, alignment: .trailing)
        } else if ordered {
            Text("\(item.number ?? 1).")
                .font(Theme.Typography.mono(12))
                .foregroundColor(Theme.Colors.contentTertiary)
                .frame(minWidth: 14, alignment: .trailing)
        } else {
            Text(depth == 0 ? "•" : "◦")
                .font(Theme.Typography.text(13, .medium))
                .foregroundColor(Theme.Colors.contentTertiary)
                .frame(minWidth: 14, alignment: .trailing)
        }
    }

    /// 列表项块内容：嵌套子列表缩进一级并携带深度递归；其余块沿用统一块渲染。
    @ViewBuilder
    private func itemBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .orderedList(items):
            MarkdownListView(items: items, ordered: true, depth: depth + 1)
                .padding(.leading, Self.nestedIndent)
        case let .unorderedList(items):
            MarkdownListView(items: items, ordered: false, depth: depth + 1)
                .padding(.leading, Self.nestedIndent)
        default:
            MarkdownBlockView(block: block)
        }
    }
}

// MARK: - 引用块

private struct MarkdownBlockquoteView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            // 左竖线：弱化强调色，克制不抢戏
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Theme.Colors.accent.opacity(0.55))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                    MarkdownBlockView(block: child)
                }
            }
            // 引用内容整体弱化一档，与竖线共同传达「引述」语义
            .foregroundColor(Theme.Colors.contentSecondaryStrong)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .fill(Theme.Colors.surfaceBadge)
        )
    }
}

// MARK: - 表格

/// 表格：表头行底色 + 表头下实线 + 数据行斑马纹 + 提亮描边卡片。
/// 用 VStack 行结构（而非 Grid）以便整行铺底色；列等宽，列间距 16。
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 表头：加粗 + 整行底色；每列按 alignments 设置对齐
            HStack(spacing: Theme.Spacing.card) {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { column, header in
                    MarkdownInlineText(
                        inlines: header,
                        bodyColor: Theme.Colors.contentPrimary,
                        baseSize: 12.5,
                        weight: .semibold,
                        explicitColor: Theme.Colors.contentPrimary
                    )
                    .multilineTextAlignment(textAlignment(at: column))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: frameAlignment(at: column))
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .background(Theme.Colors.chatTableHeader)

            // 表头下实线（提亮档，确保在斑马纹前清晰可辨）
            Rectangle()
                .fill(Theme.Colors.chatStrokeStrong)
                .frame(height: Theme.Layout.dividerHeight)

            // 数据行：偶数行斑马纹
            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: Theme.Spacing.card) {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        MarkdownInlineText(
                            inlines: cell,
                            bodyColor: Theme.Colors.contentPrimary,
                            baseSize: 12.5,
                            explicitColor: Theme.Colors.contentPrimary
                        )
                        .multilineTextAlignment(textAlignment(at: column))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: frameAlignment(at: column))
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.md)
                .background(rowIndex % 2 == 1 ? Theme.Colors.chatTableRowAlternate : Color.clear)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
    }

    /// 列对齐 → SwiftUI Frame Alignment（越界回退 leading）。
    private func frameAlignment(at column: Int) -> Alignment {
        switch alignment(at: column) {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }

    /// 列对齐 → 多行文本对齐。
    private func textAlignment(at column: Int) -> TextAlignment {
        switch alignment(at: column) {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }

    private func alignment(at column: Int) -> MarkdownTableAlignment? {
        guard column >= 0, column < table.alignments.count else { return nil }
        return table.alignments[column]
    }
}

// MARK: - 代码块

/// 围栏代码块：语言标签 + 等宽内容；hover 右上角渐显复制钮（成功变对勾轻反馈）。
/// 语法高亮：首帧立即纯色等宽渲染，同时后台计算高亮 AttributedString，完成后替换
/// （失败/不支持语言保持纯色）。高亮计算全程异步，绝不阻塞流式渲染。
struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.lg) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(Theme.Typography.mono(10, .semibold))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
                Spacer(minLength: 0)
                // 布局稳定化：按钮常驻布局（header 行高度恒定），hover 仅切换透明度，
                // 不触发布局变化。
                // 显隐由 hovered 单独驱动；copied 仅是复制成功的瞬时内容反馈
                // （鼠标离开时按钮随 hovered 隐去，不会残留悬空的第二按钮）。
                Button(action: copyCode) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(Theme.Typography.text(9.5, .medium))
                        Text(copied ? "已复制" : "复制")
                            .font(Theme.Typography.text(9.5, .medium))
                    }
                    .foregroundColor(copied ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                            .fill(Theme.Colors.surfaceButton)
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
                .accessibilityHidden(!hovered)
            }
            .frame(minHeight: 14)

            // 高亮状态与渲染内聚于子视图（见 CodeBlockText）：hover 变化引起的
            // 父 body 重算会被 SwiftUI 子视图值 diff 短路，大段高亮文本永不重建。
            CodeBlockText(code: code, language: language)
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(Theme.Colors.surfaceTrack)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
    }

    private func copyCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        copied = true
        // 轻反馈：对勾短暂停留后复位
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

/// 代码内容子视图：高亮状态（`highlighted`）与高亮渲染、高亮 task 全部内聚于此。
///
/// 状态半径原则：hover（复制按钮显隐）是 CodeBlockView 的状态，其变化触发父 body
/// 重算；本视图作为参数化子视图，参数（code/language）不变时 SwiftUI 值 diff 会
/// 短路父重算——本视图 body 不重跑，`Text(highlighted)`（大段 AttributedString，
/// 构造需解析 runs，成本高一个数量级）永不重建。滚动中 hover 进出风暴的重算成本
/// 由此被压缩到 header 一行（语言标签 + 小按钮）。
private struct CodeBlockText: View {
    let code: String
    let language: String?

    @Environment(\.colorScheme) private var colorScheme
    /// 后台高亮结果；nil = 尚未完成 / 不可用 / 降级纯色。
    @State private var highlighted: AttributedString?

    var body: some View {
        // 高亮版优先、否则降级为纯色等宽文本（现状行为）。
        // 代码块内不转 Markdown，纯等宽显示。
        // 长行不折行：横向滚动承载超长行——折行会破坏缩进结构、复制粘贴混入换行符。
        // 嵌套滚动安全：底层 NSScrollView 不消费垂直滚轮 delta（沿 responder chain 上传
        // 外层垂直滚动，滚轮鼠标体验与现状一致），仅消费水平 delta（shift+滚轮/双指横滑）；
        // 内容短于视口时贴 scroll origin（leading），与旧 frame(alignment: .leading) 等价。
        // fixedSize(horizontal: true)：水平按固有宽度布局（ScrollView 提议无限宽，双保险防
        // 折行）；vertical: false 服从容器高度（= 内容固有行高，无循环依赖）。
        ScrollView(.horizontal, showsIndicators: true) {
            Group {
                if let highlighted {
                    Text(highlighted)
                } else {
                    Text(code)
                        .font(Theme.Typography.mono(12.5))
                        .foregroundColor(Theme.Colors.contentPrimary)
                }
            }
            .lineSpacing(6)
            .fixedSize(horizontal: true, vertical: false)
        }
        .task(id: HighlightTask(code: code, language: language, darkMode: colorScheme == .dark)) {
            // 首帧保持纯色等宽（highlighted == nil）；后台计算高亮后替换。
            highlighted = nil
            let code = self.code
            let language = self.language
            let result = await Task.detached(priority: .utility) {
                MarkdownHighlighter.highlightSwiftUI(code, language: language, darkMode: colorScheme == .dark)
            }.value
            guard !Task.isCancelled else { return }
            highlighted = result
        }
    }

    /// 高亮 task 键：内容 / 语言 / 外观任一变化即重高亮（外观切换换主题，
    /// 流式期间 code 增长重算）。
    private struct HighlightTask: Equatable {
        let code: String
        let language: String?
        let darkMode: Bool
    }
}

// MARK: - 脚注区

/// 文档末尾脚注区：细分隔线 + 小字号（11）编号列表（序号 + 定义内容行内渲染）。
/// 由 `AssistantMarkdownView` 聚合顶层 footnoteDefinition 后统一渲染。
private struct MarkdownFootnoteSection: View {
    let footnotes: [AssistantMarkdownView.FootnoteEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Rectangle()
                .fill(Theme.Colors.cardStroke)
                .frame(height: Theme.Layout.dividerHeight)
            ForEach(Array(footnotes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                    Text(note.id)
                        .font(Theme.Typography.text(11, .semibold))
                        .foregroundColor(Theme.Colors.accent)
                        .frame(minWidth: 16, alignment: .trailing)
                    MarkdownInlineText(
                        inlines: note.inlines,
                        bodyColor: Theme.Colors.contentTertiary,
                        baseSize: 11
                    )
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 图片

/// 图片内存缓存（按地址键，避免滚动/重渲染反复下载与解码）。
/// `NSCache` 自身线程安全，可跨后台解码任务读写。
private enum MarkdownImageCache {
    static let cache = NSCache<NSURL, NSImage>()

    static func key(for url: String) -> NSURL? {
        if let parsed = URL(string: url), parsed.scheme != nil {
            return parsed as NSURL
        }
        let expanded = (url as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return URL(fileURLWithPath: expanded) as NSURL
    }
}

/// 远程 / 本地 / data URI 图片视图：异步加载 + 内存缓存，绝不阻塞流式渲染。
/// 三态：加载中（等高占位 + ProgressView）/ 失败（弱化块 + alt + url）/ 成功（等比缩放 + 圆角 + 描边）。
/// 对外契约：`MarkdownImageView(alt:url:title:linkURL:)`（`linkURL` 默认 nil，被 MarkdownInlineText 拆段路径引用）。
/// 当图片来自 `[![alt](img)](link)` 这类链接内嵌图片时，`linkURL` 非 nil：成功态图片可点击打开链接。
struct MarkdownImageView: View {
    let alt: String
    let url: String
    let title: String?
    /// 外层链接地址（链接内嵌图片）；nil = 普通图片，不可点击。
    let linkURL: String?

    /// 显式 init：保证 `alt:url:title:` 旧调用与 `alt:url:title:linkURL:` 新调用都可用。
    init(alt: String, url: String, title: String?, linkURL: String? = nil) {
        self.alt = alt
        self.url = url
        self.title = title
        self.linkURL = linkURL
    }

    private enum LoadState {
        case loading
        case success(NSImage)
        case failure
    }

    @State private var state: LoadState = .loading
    /// 成功态是否处于 hover（可点击时用于手型光标与轻微提亮）。
    @State private var hovering = false
    /// 手型光标是否已 push（保证与 pop 严格配对，避免光标栈失衡）。
    @State private var cursorPushed = false

    var body: some View {
        Group {
            switch state {
            case .loading:
                loadingView
            case let .success(image):
                successView(image)
            case .failure:
                failureView
            }
        }
        .task(id: url) { await load() }
        .onDisappear {
            // 视图消失时兜底弹出手型光标，避免离开后光标残留。
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
    }

    /// 可点击链接 URL；`linkURL` 为 nil 或无法构造 URL 时为 nil（图片退化为不可点击）。
    private var clickableURL: URL? {
        guard let linkURL, let url = URL(string: linkURL) else { return nil }
        return url
    }

    // MARK: 三态视图

    /// 加载中：低饱和等高占位块（高度 120）+ 居中 ProgressView。
    private var loadingView: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
            .fill(Theme.Colors.surfaceTrack)
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .overlay(ProgressView().controlSize(.small))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
            )
    }

    /// 成功：按原始宽高比、容器宽自适应（限制向上采样）、圆角 insetCard、轻描边。
    /// 链接内嵌图片（linkURL 有效）时可点击打开，hover 手型光标 + 轻微提亮。
    private func successView(_ image: NSImage) -> some View {
        let clickable = clickableURL != nil
        return Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            // 先钉住不超过原始像素宽（向上采样限制）；圆角/描边跟随图片本身。
            .frame(maxWidth: max(image.size.width, 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
            )
            // 命中区 = 图片本身（避免外层满宽 frame 把透明区也纳入点击/hover）。
            .contentShape(Rectangle())
            .brightness(clickable && hovering ? 0.05 : 0)
            .onTapGesture {
                guard let target = clickableURL else { return }
                NSWorkspace.shared.open(target)
            }
            .onHover { isHovering in
                handleHover(isHovering, clickable: clickable)
            }
            // 再在容器内左对齐铺排（图片窄时不拉伸容器视觉）。
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// hover 状态与手型光标维护：仅在可点击时 push/pop，且 push 与 pop 严格配对。
    private func handleHover(_ isHovering: Bool, clickable: Bool) {
        hovering = isHovering
        guard clickable else {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
            return
        }
        if isHovering, !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        } else if !isHovering, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    /// 失败：弱化色圆角块内显示 alt 文本 + url 小字链接。
    private var failureView: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(alt.isEmpty ? "图片无法加载" : alt)
                .font(Theme.Typography.text(12))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
                .fixedSize(horizontal: false, vertical: true)
            if let linkURL = URL(string: url),
               let scheme = linkURL.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                Link(destination: linkURL) {
                    Text(url)
                        .font(Theme.Typography.text(10))
                        .foregroundColor(Theme.Colors.accent)
                }
            } else {
                Text(url)
                    .font(Theme.Typography.text(10))
                    .foregroundColor(Theme.Colors.contentTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(Theme.Colors.surfaceTrack)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
    }

    // MARK: 加载

    /// 仅做状态编排（网络/解码均已异步外移），故固定在主 actor 上执行，@State 写入安全。
    @MainActor
    private func load() async {
        state = .loading
        guard let key = MarkdownImageCache.key(for: url) else {
            state = .failure
            return
        }
        if let cached = MarkdownImageCache.cache.object(forKey: key) {
            state = .success(cached)
            return
        }

        let decoded: NSImage?
        if let parsed = URL(string: url),
           let scheme = parsed.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            decoded = await Self.loadRemote(parsed)
        } else {
            let raw = url
            decoded = await Task.detached(priority: .utility) {
                Self.decodeLocalOrData(raw)
            }.value
        }

        guard !Task.isCancelled else { return }
        if let decoded {
            MarkdownImageCache.cache.setObject(decoded, forKey: key)
            state = .success(decoded)
        } else {
            state = .failure
        }
    }

    /// 远程图片：URLSession 异步取数据，解码放到后台线程。
    private static func loadRemote(_ url: URL) async -> NSImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                return nil
            }
            return await Task.detached(priority: .utility) { NSImage(data: data) }.value
        } catch {
            return nil
        }
    }

    /// 本地绝对路径（支持 ~ 展开 / file://）与 `data:` URI 解码；已在后台线程调用。
    private static func decodeLocalOrData(_ raw: String) -> NSImage? {
        if raw.hasPrefix("data:") {
            return decodeDataURI(raw)
        }
        if raw.hasPrefix("file://"), let fileURL = URL(string: raw) {
            return NSImage(contentsOf: fileURL)
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        return NSImage(contentsOfFile: expanded)
    }

    /// `data:image/...;base64,<payload>` 解码。
    private static func decodeDataURI(_ uri: String) -> NSImage? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.startIndex..<comma].lowercased()
        guard header.contains(";base64") else { return nil }
        let payload = String(uri[uri.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
        return NSImage(data: data)
    }
}

// MARK: - 行内渲染

/// 行内 token → AttributedString（粗体 / 斜体 / 行内代码 / 可点击链接 / 纯文本）。
/// 供段落、标题、列表项、表格单元格、引用块共用。
enum MarkdownInline {
    /// 正文基准字号。
    static let baseSize: CGFloat = 13

    /// 需要在「统一基础字体」之后回填样式的运行区间（上下标 / 脚注引用等新 token：
    /// 字号必须晚于 `result.font` 整体赋值，否则会被基础字体覆盖）。
    private struct StyledRun {
        let range: Range<AttributedString.Index>
        let font: Font
        var baselineOffset: CGFloat?
        var color: Color?
    }

    /// bodyColor：纯文本/行内代码的颜色——正文与列表降两档（primary 0.80），
    /// 与加粗档（contentPrimary 纯白/纯黑）肉眼可分区分开；标题、表格等调用处显式传 contentPrimary。
    /// 加粗递归时把基色提为 contentPrimary（而非事后整段覆盖），嵌套链接的 accent 得以保留。
    /// - size：当前行内基准字号（递归时上下标会下调；外部默认正文 13）。
    static func render(
        _ tokens: [InlineToken],
        bodyColor: Color = Color.primary.opacity(0.80),
        size: CGFloat = baseSize
    ) -> AttributedString {
        var result = AttributedString()
        var styledRuns: [StyledRun] = []
        append(tokens, into: &result, styledRuns: &styledRuns, bodyColor: bodyColor, size: size)

        // 统一基础字体（行内覆盖（代码/加粗等）已在上面设定，这里只设默认值）
        result.font = Theme.Typography.text(size)
        // 上下标 / 脚注引用字号回填（必须晚于基础字体赋值才能生效）。
        for styled in styledRuns {
            result[styled.range].font = styled.font
            if let baseline = styled.baselineOffset {
                result[styled.range].baselineOffset = baseline
            }
            if let color = styled.color {
                result[styled.range].foregroundColor = color
            }
        }
        return result
    }

    /// 递归构建：所有 token 直接追加进共享 result，新 token 的字体样式登记为 StyledRun，
    /// 待整段基础字体设置完毕后统一回填。语义与 AppKit 路径 `MarkdownInlineNS` 镜像。
    private static func append(
        _ tokens: [InlineToken],
        into result: inout AttributedString,
        styledRuns: inout [StyledRun],
        bodyColor: Color,
        size: CGFloat
    ) {
        for token in tokens {
            switch token {
            case let .text(value):
                var piece = AttributedString(normalizeQuotes(value))
                piece.foregroundColor = bodyColor
                result.append(piece)

            case let .code(value):
                var piece = AttributedString(value)
                piece.font = Theme.Typography.mono(12.5)
                piece.foregroundColor = bodyColor
                piece.backgroundColor = Theme.Colors.surfaceTrack
                result.append(piece)

            case let .bold(inner):
                append(inner, into: &result, styledRuns: &styledRuns,
                       bodyColor: Theme.Colors.contentPrimary, size: size)

            case let .italic(inner):
                append(inner, into: &result, styledRuns: &styledRuns, bodyColor: bodyColor, size: size)

            case let .strikethrough(inner):
                let start = result.endIndex
                append(inner, into: &result, styledRuns: &styledRuns, bodyColor: bodyColor, size: size)
                result[start..<result.endIndex].strikethroughStyle = .single

            case let .underline(inner):
                let start = result.endIndex
                append(inner, into: &result, styledRuns: &styledRuns, bodyColor: bodyColor, size: size)
                result[start..<result.endIndex].underlineStyle = .single

            case let .highlight(inner):
                let start = result.endIndex
                append(inner, into: &result, styledRuns: &styledRuns, bodyColor: bodyColor, size: size)
                // 半透明强调色高亮（alpha 0.18 与 AppKit 路径 MarkdownInlineNS 对齐）。
                result[start..<result.endIndex].backgroundColor = Theme.Colors.accent.opacity(0.18)

            case let .subscript(inner):
                let subSize = max(size - 2, 9)
                let start = result.endIndex
                append(inner, into: &result, styledRuns: &styledRuns, bodyColor: bodyColor, size: subSize)
                styledRuns.append(StyledRun(
                    range: start..<result.endIndex,
                    font: Theme.Typography.text(subSize),
                    baselineOffset: -3,
                    color: nil
                ))

            case let .superscript(inner):
                // 镜像 AppKit 路径 MarkdownInlineNS：上标小字号 -2、baseline +3。
                let superSize = max(size - 2, 9)
                let start = result.endIndex
                append(inner, into: &result, styledRuns: &styledRuns, bodyColor: bodyColor, size: superSize)
                styledRuns.append(StyledRun(
                    range: start..<result.endIndex,
                    font: Theme.Typography.text(superSize),
                    baselineOffset: 3,
                    color: nil
                ))

            case let .link(label, url, _):
                // title 无视觉变化，忽略。
                let start = result.endIndex
                append(label, into: &result, styledRuns: &styledRuns, bodyColor: bodyColor, size: size)
                let range = start..<result.endIndex
                result[range].foregroundColor = Theme.Colors.accent
                result[range].underlineStyle = .single
                if let linkURL = URL(string: url) {
                    result[range].link = linkURL
                }

            case let .image(alt, _, _):
                // 防御性兜底：正常情况下含图片段落会在 MarkdownInlineText 层被拆段，
                // 不会进入此处；以纯文本渲染 alt 保险。
                var piece = AttributedString(alt)
                piece.foregroundColor = bodyColor
                result.append(piece)

            case .lineBreak:
                result.append(AttributedString("\n"))

            case let .footnoteRef(identifier):
                let refSize = max(size - 3, 9)
                let start = result.endIndex
                result.append(AttributedString(identifier))
                styledRuns.append(StyledRun(
                    range: start..<result.endIndex,
                    font: Theme.Typography.text(refSize),
                    baselineOffset: 4,
                    color: Theme.Colors.accent
                ))

            case let .math(value):
                // SwiftUI AttributedString 无法内嵌图片；含公式的路径统一改走 MarkdownInlineNS。
                // 此处仅作兜底：以等宽文本显示原始 LaTeX（正常渲染不会触达）。
                var piece = AttributedString(value)
                piece.font = Theme.Typography.mono(12)
                piece.foregroundColor = bodyColor
                result.append(piece)
            }
        }
    }

    /// 成对 ASCII 直引号归一为中文引号「」（未配对的单个 " 保留原样）。
    /// 仅供显示层调用（text token 与流式纯文本），绝不触碰行内代码/代码块/链接 URL；
    /// 不改原始文本，复制/重发内容不受影响。
    static func normalizeQuotes(_ text: String) -> String {
        guard text.contains("\"") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var isOpen = false
        var remaining = text[...]
        while let first = remaining.first {
            let after = remaining.dropFirst()
            if first == "\"" {
                if !isOpen, after.contains("\"") {
                    result.append("「")   // 存在后续配对：开引号
                    isOpen = true
                } else if isOpen {
                    result.append("」")   // 处于开引状态：合引号
                    isOpen = false
                } else {
                    result.append(first)  // 未配对的单个 "，原样保留
                }
            } else {
                result.append(first)
            }
            remaining = after
        }
        return result
    }
}
