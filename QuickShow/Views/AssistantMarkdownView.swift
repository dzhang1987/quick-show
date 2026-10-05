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
    /// 已构建块数游标；-1 = 未种子化（首帧按视口高度算初始值，或从进度缓存恢复）。
    /// 消息身份变化时随视图重建重置——但 LazyVStack **滚动中的反实例化**也会静默重置
    /// 本游标（长消息塌回首批 → document 高度骤减 → 视口被 clamp 拽走），恢复见
    /// MarkdownRenderProgressCache。
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

    /// 当前有效可见块数。**落定态（useCache=true）一律全量渲染**——滚动稳定优先于
    /// 渲染速度（用户决策）：渐进渲染的逐批高度增长（16ms/批）会让 doc 高度持续
    /// 震荡，视口在上方时 LazyVStack 的偏移补偿不可靠 → 「上滚跳消息」；流式中间态
    /// （useCache=false）保持游标渐进（流式增量渲染性能不受影响，内容持续增长时
    /// 视口在底部跟随，高度增长不破坏阅读位置）。LazyVStack 惰性实例化保证挂载/
    /// 切会话只构建视口附近几条消息——全量渲染的成本仅作用于视口附近长消息
    /// （每条 ~50-150ms 一次性布局）。
    private func effectiveVisibleCount(seededInitial: Int, total: Int) -> Int {
        if useCache { return total }
        let base = visibleBlockCount < 0 ? seededInitial : visibleBlockCount
        return min(base, total)
    }

    /// 游标推进落点（仅流式中间态使用：落定态 effective 恒为全量，哨兵/task 短路）。
    private func advanceVisibleCount(to value: Int) {
        visibleBlockCount = value
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
                            advanceVisibleCount(to: min(current + Self.blockBatchSize, blocks.count))
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
            advanceVisibleCount(to: min(after + Self.blockBatchSize, blocks.count))
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
