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
    /// A5：落定态（useCache=true）首批块数——不再一次性同步渲染全部块，
    /// 避免超长助手消息在首帧/重挂载时一次性布局数千块。约覆盖 1~2 屏。
    private static let settledInitialBlocks = 40
    /// A5：落定态后续每批块数（比流式批更大，尽快补齐全文）。
    private static let settledBatchSize = 24
    /// 重挂载恢复时的目标批数：进度缓存命中（= 曾被渲染过）的消息，剩余块同 runloop
    /// 分 2~3 个大步长批次连续补齐，不再走 16ms/批的渐进等待，避免单帧卡顿。
    private static let recoveryBatchCount = 3
    /// 恢复态首批种子上限：命中进度也**不一次性付清**——先建至多 64 块，余量再分批推进，
    /// 避免超长消息（数百块）回窗单事务全量建树造成布局风暴。
    private static let recoverySeedCap = 64
    /// 恢复态单批块数上限：每 runloop 推进不超过此值（单帧建树成本有界），连续推进不 sleep 16ms。
    private static let recoveryBatchCap = 64
    /// 已构建块数游标；-1 = 未种子化（首帧按视口高度算初始值，或从进度缓存恢复）。
    /// 消息身份变化时随视图重建重置；`ChatVirtualRow` 的实渲染↔等高占位切换（窗口外）
    /// 亦会销毁本游标——恢复由 `MarkdownRenderProgressCache` 承担：种子化时若命中既有
    /// 进度，直接渲染到 `min(progress, total)`，不回到首批重新渐进。
    @State private var visibleBlockCount = -1
    /// 本次实例是否正从渲染进度缓存恢复：命中缓存的消息批次推进走「同 runloop 大批」
    /// （不 sleep 16ms），真正首见的消息保留 16ms 渐进。仅在 `visibleBlockCount < 0`
    /// （尚未种子化）时判定并置位一次，是视图私有 @State，不参与 Equatable。
    @State private var isRecoveringFromProgress = false

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

    /// 当前有效可见块数（流式与落定均渐进，避免一次性同步渲染全部块）。
    /// A5：落定态（useCache=true）首批至少 settledInitialBlocks（~40），随后 batchSize 逐批补齐；
    /// 流式中间态（useCache=false）沿用视口自适应的较小首批（流式增量渲染更敏感）。
    /// 游标 `visibleBlockCount` 为 -1 时：
    /// - 先尝试从 `MarkdownRenderProgressCache` 恢复——但**限量播种** `min(progress, 64, total)`，
    ///   余量交同 runloop 大批补齐（不回到首批重新渐进，也不单事务全量建树）；
    /// - 无进度（真正首见）才按首批种子化，走 16ms 渐进。
    private func effectiveVisibleCount(seededInitial: Int, total: Int) -> Int {
        if visibleBlockCount >= 0 {
            return min(visibleBlockCount, total)
        }
        if useCache, let progress = MarkdownRenderProgressCache.progress(for: content), progress > 0 {
            return min(min(progress, Self.recoverySeedCap), total)
        }
        let firstBatch: Int
        if useCache {
            firstBatch = min(total, max(seededInitial, Self.settledInitialBlocks))
        } else {
            firstBatch = seededInitial
        }
        return min(firstBatch, total)
    }

    /// 当前批大小（落定态更大批，尽快补齐；流式态小批更平滑）。
    private var batchSize: Int {
        useCache ? Self.settledBatchSize : Self.blockBatchSize
    }

    /// 种子化时判定「是否从既有渲染进度恢复」：仅在尚未种子化（游标 -1）且进度缓存命中时
    /// 置位一次。命中后剩余块走同 runloop 大批补齐（见 `stepSize`），与真正首见的 16ms 渐进区分。
    private func markRecoveringFromProgressIfNeeded() {
        guard !isRecoveringFromProgress, visibleBlockCount < 0,
              useCache, (MarkdownRenderProgressCache.progress(for: content) ?? 0) > 0 else { return }
        isRecoveringFromProgress = true
    }

    /// 单次推进步长：恢复态用「剩余 / N」的大步长（同 runloop 连续补齐，不 sleep 16ms），
    /// 但单批硬上限 `recoveryBatchCap`（64）——单帧建树成本有界，余量下一 runloop 继续；
    /// 首见态保持既有小批（落定 24 / 流式 12）。
    private func stepSize(from current: Int, total: Int) -> Int {
        guard isRecoveringFromProgress else { return batchSize }
        let remaining = total - current
        let byRecovery = Int((Double(remaining) / Double(Self.recoveryBatchCount)).rounded(.up))
        return min(Self.recoveryBatchCap, max(Self.settledBatchSize, byRecovery))
    }

    /// 游标推进落点（落定态与流式态共用：哨兵/task 逐批推进可见块数）。
    /// 落定态回写渲染进度缓存（递增、单调），供行重挂载时恢复；流式态（useCache=false）
    /// 内容高频增长，写缓存只会污染 key 空间，故不写。
    private func advanceVisibleCount(to value: Int) {
        visibleBlockCount = value
        if useCache {
            MarkdownRenderProgressCache.record(value, for: content)
        }
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
                            markRecoveringFromProgressIfNeeded()
                            let current = effectiveVisibleCount(seededInitial: seededInitial, total: blocks.count)
                            advanceVisibleCount(to: min(current + stepSize(from: current, total: blocks.count), blocks.count))
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
        // - 首见消息：sleep 16ms 后推进一小批（渐进渲染，保持原有观感）。
        // - 进度缓存恢复的消息：不等待，直接以「剩余/N」大步长推进，2~3 批到位（防批次风暴）。
        .task(id: visibleCount) {
            markRecoveringFromProgressIfNeeded()
            let current = effectiveVisibleCount(seededInitial: seededInitial, total: blocks.count)
            guard current < blocks.count else { return }
            if isRecoveringFromProgress {
                advanceVisibleCount(to: min(current + stepSize(from: current, total: blocks.count), blocks.count))
                return
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
            let after = effectiveVisibleCount(seededInitial: seededInitial, total: blocks.count)
            guard !Task.isCancelled, after < blocks.count else { return }
            advanceVisibleCount(to: min(after + batchSize, blocks.count))
        }
    }
}
