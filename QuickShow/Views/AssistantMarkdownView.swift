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
