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

// MARK: - 助手消息 Markdown 完整渲染宿主

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

    init(content: String, useCache: Bool = true) {
        self.content = content
        self.useCache = useCache
    }

    // MARK: - 解析缓存（落定态重渲染加速）

    private static func parsedBlocks(for content: String, useCache: Bool) -> [MarkdownBlock] {
        MarkdownASTCache.blocks(for: content, useCache: useCache)
    }

    /// 会话预热用：取 content 的块级 AST（命中缓存则复用，否则解析后写入）。
    /// `nonisolated`：允许后台预热线程调用（缓存自身线程安全）。
    nonisolated static func parsedBlocksForPrefetch(_ content: String) -> [MarkdownBlock] {
        MarkdownASTCache.blocks(for: content, useCache: true)
    }

    /// 脚注条目别名（兼容性保障）
    typealias FootnoteEntry = MarkdownFootnoteEntry

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

    private static let estimatedBlockHeight: CGFloat = 72
    private static let minInitialBlocks = 8
    private static let maxInitialBlocks = 16
    private static let blockBatchSize = 12

    @State private var visibleBlockCount = -1
    @Environment(\.chatViewportHeight) private var viewportHeight

    static func == (lhs: AssistantMarkdownView, rhs: AssistantMarkdownView) -> Bool {
        lhs.content == rhs.content && lhs.useCache == rhs.useCache
    }

    private static func initialBlockCount(viewportHeight: CGFloat, total: Int) -> Int {
        let byViewport = Int((max(viewportHeight, 1) / estimatedBlockHeight).rounded(.up))
        return min(total, max(minInitialBlocks, min(byViewport, maxInitialBlocks)))
    }

    private func effectiveVisibleCount(seededInitial: Int, total: Int) -> Int {
        if useCache { return total }
        let base = visibleBlockCount < 0 ? seededInitial : visibleBlockCount
        return min(base, total)
    }

    private func advanceVisibleCount(to value: Int) {
        visibleBlockCount = value
    }

    var body: some View {
        let allBlocks = Self.parsedBlocks(for: content, useCache: useCache)
        let split = Self.splitFootnotes(allBlocks)
        let blocks = split.main
        let footnotes = split.footnotes
        let seededInitial = Self.initialBlockCount(viewportHeight: viewportHeight, total: blocks.count)
        let visibleCount = effectiveVisibleCount(seededInitial: seededInitial, total: blocks.count)
        let visibleBlocks = Array(blocks.prefix(visibleCount))
        let segments = MarkdownBlockSegmenter.segment(visibleBlocks)
        let _ = qsDebugLog("AssistantMarkdownView: contentLen=\(content.count) blocks=\(blocks.count) visible=\(visibleCount) segments=\(segments.count)")

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                switch segment {
                case let .textFlow(id, content, topSpacing):
                    NativeTextFlowView(attributedString: content)
                        .id(id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, index == 0 ? 0 : topSpacing)
                case let .widget(id, block, topSpacing):
                    MarkdownBlockView(block: block)
                        .id(id)
                        .padding(.top, index == 0 ? 0 : topSpacing)
                }
            }

            // 分批哨兵
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

            // 脚注区
            if visibleCount >= blocks.count, !footnotes.isEmpty {
                MarkdownFootnoteSection(footnotes: footnotes)
                    .padding(.top, Theme.Spacing.divider)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
