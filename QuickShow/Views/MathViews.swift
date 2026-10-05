// 来源拆分：AIChatMathViews.swift — 公式视图层（InlineMathAttachment / MathBlockView / MathParagraphView / PendingInlineMath / InlineMathRender）。
import SwiftUI
import AppKit

// MARK: - 行内公式 Attachment

/// NSTextAttachment 构造：图片 + bounds（基线对齐）。
/// ⚠ 仅接受**已光栅化结果**——主线程绝不在此触发同步 render（缓存命中才可同步装 attachment）。
enum InlineMathAttachment {
    static func make(from raster: MathRasterizer.Rasterized) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = raster.image
        // y = -descent：把图片整体下压 descent 深度，使公式基线与整行文本基线重合
        attachment.bounds = CGRect(
            x: 0,
            y: -raster.descent,
            width: raster.size.width,
            height: raster.size.height
        )
        return attachment
    }
}

// MARK: - 块级公式视图

/// 块级公式：包 NSImageView，display 模式光栅化，等比缩放不下溢。
/// 失败降级由调用方处理（本视图 image 为 nil 时不显示内容）。
struct MathBlockView: NSViewRepresentable {
    let latex: String
    var fontSize: CGFloat = 14
    var color: Color = Color.primary

    /// 明暗翻转追踪：SwiftUI 环境变化才触发 updateNSView 重调（读 NSApp.effectiveAppearance
    /// 不被追踪，外观切换后旧位图会钉死），翻转后经缓存 key（含颜色分量）自动换新位图。
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        let nsColor = MathRasterizer.resolvedColor(color, appearance: MathRasterizer.appearance(for: colorScheme))
        let raster = MathRasterizer.rasterize(
            latex: latex, pointSize: fontSize, color: nsColor, isDisplay: true
        )
        view.image = raster?.image
    }
}

// MARK: - 含行内公式的段落视图

/// 含行内公式的段落：包 NSTextField（wrapsLabel），NSAttributedString 内嵌 NSTextAttachment。
/// 通过 sizeThatFits 把 proposed width 设为 preferredMaxLayoutWidth 后重新测量高度。
struct MathParagraphView: NSViewRepresentable {
    let inlines: [InlineToken]
    var baseSize: CGFloat = 13
    var weight: Font.Weight = .regular
    var color: Color = Color.primary.opacity(0.80)

    /// 明暗翻转追踪：同 MathBlockView，环境驱动 updateNSView 重调后重新取色光栅化；
    /// 原先读 field.effectiveAppearance 依赖视图已挂入窗口，且翻转不触发刷新。
    @Environment(\.colorScheme) private var colorScheme

    /// 测量缓存 + 行内公式两段式回填状态。
    final class Coordinator {
        var measuredWidth: CGFloat = -1
        var measuredHeight: CGFloat = 0
        /// 回填世代令牌：每次 updateNSView 自增；异步回调仅在世代未变时写回，
        /// 防止旧外观/旧内容的滞回结果覆盖新段落（防竞态）。
        var generation = 0
        /// 本段待回填公式计数：全部归零后一次性重建整段（避免 N 个公式触发 N 次重建）。
        var pendingRemaining = 0
        /// 回填写回目标字段（弱引用：视图销毁后回调自动失效）。
        weak var field: NSTextField?
        /// 本段内容 hash（updateNSView 时算一次）：全局高度缓存的 key 之一。
        var contentHash = 0
        /// 本段是否已「测量稳定」（无待回填公式：命中缓存或已知失败）：只有稳定测量才写入全局缓存，
        /// 避免用「占位文本高度」污染持久缓存。
        var measurementStable = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: NSAttributedString())
        field.isEditable = false
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.isBezeled = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.field = field
        // 世代推进：本次更新后，任何在途旧回调作废。
        coordinator.generation += 1
        let generation = coordinator.generation

        let nsColor = MathRasterizer.resolvedColor(color, appearance: MathRasterizer.appearance(for: colorScheme))
        let nsFont = MarkdownInlineNS.font(size: baseSize, weight: MarkdownInlineNS.nsWeight(weight))
        let renderResult = MarkdownInlineNS.renderNS(
            inlines,
            baseFont: nsFont,
            baseColor: nsColor,
            baseSize: baseSize
        )
        field.attributedStringValue = renderResult.attributed
        field.invalidateIntrinsicContentSize()
        // 内容/外观变化使旧测量失效：清缓存，下次 sizeThatFits 重新测量。
        coordinator.measuredWidth = -1
        // 全局高度缓存 key 的内容部分（updateNSView 时算一次；sizeThatFits 只补宽度/字号/字重）。
        coordinator.contentHash = MathLayoutCache.contentHash(inlines)
        // 诊断埋点（临时）：段落重建时刻 + pending 公式数——定位 doc 大塌缩的子视图来源。
        // 稳定性：本帧无待回填公式（全部命中缓存或已知失败）→ 测得的高度才写入全局缓存。
        coordinator.measurementStable = renderResult.pendingMath.isEmpty

        // 两段式（方案 A）：命中缓存的公式已同步装 attachment；未命中者在上面写成等宽
        // 占位文本，此处批量发起异步光栅化，全部完成后**只重建一次**整段（避免 N 次重建）。
        let pending = renderResult.pendingMath
        guard !pending.isEmpty else { return }
        coordinator.pendingRemaining = pending.count

        // 捕获本次世代下的取色/字体与内容，供回填重建使用（外观变化会再次进入并推进世代）。
        let tokens = inlines
        let size = baseSize
        let rebuildFlush: () -> Void = {
            let rebuilt = MarkdownInlineNS.renderNS(
                tokens,
                baseFont: nsFont,
                baseColor: nsColor,
                baseSize: size
            )
            // ⚠ 无任何 opacity/动画过渡：直接替换，避免 CA 事务竞态把内容层卡在近零透明度。
            coordinator.field?.attributedStringValue = rebuilt.attributed
            coordinator.field?.invalidateIntrinsicContentSize()
            // 位图回填改变内容尺寸：清测量缓存，驱动 sizeThatFits 重新测量高度。
            coordinator.measuredWidth = -1
            // 回填后本段所有公式均已缓存/已知失败 → 后续测量为稳定测量，可写入全局高度缓存。
            coordinator.measurementStable = true
        }

        for item in pending {
            MathRasterizer.rasterizeAsync(
                latex: item.latex,
                pointSize: item.pointSize,
                color: item.color,
                isDisplay: false
            ) { _ in
                // 统一延迟到下一 runloop：命中缓存/已知失败时的同步回调会在发起循环内触发，
                // 若立即重建会重入；延迟后所有回调在发起循环结束后统一结算。
                DispatchQueue.main.async {
                    guard generation == coordinator.generation else { return }
                    coordinator.pendingRemaining -= 1
                    guard coordinator.pendingRemaining <= 0 else { return }
                    rebuildFlush()
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        // 无宽度建议时交回系统；有宽度则钉死换行宽度后重新测量高度。
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        // 内容已就绪（updateNSView 已写入 attributedString）且宽度未变时，复用上次测量结果，
        // 避免同一测量周期内重复强制 layout。
        // ⚠️ guarded by attributedStringValue.length > 0：sizeThatFits 可能早于首次 updateNSView
        // 被调用（此时为占位空串），若把这种空测量的极小高度写入缓存，段落会被钉死塌陷为不可见。
        let hasContent = nsView.attributedStringValue.length > 0
        if hasContent, context.coordinator.measuredWidth == width {
            return CGSize(width: width, height: context.coordinator.measuredHeight)
        }
        // 全局持久高度缓存：跨实例/跨 LRU 重建命中即免测量（首帧成本只与屏幕成正比的关键）。
        // key 含内容 hash + 宽度桶 + 外观 + 字号 + 字重；内容变则键变，天然自洽。
        let globalKey = MathLayoutCache.ParagraphKey(
            contentHash: context.coordinator.contentHash,
            widthBucket: Int(width.rounded()),
            isDark: colorScheme == .dark,
            pointSizeMilli: Int((baseSize * 1000).rounded()),
            weightRaw: Self.weightRaw(weight)
        )
        if hasContent, let cachedHeight = MathLayoutCache.paragraphHeight(for: globalKey) {
            nsView.preferredMaxLayoutWidth = width
            context.coordinator.measuredWidth = width
            context.coordinator.measuredHeight = cachedHeight
            return CGSize(width: width, height: cachedHeight)
        }
        nsView.preferredMaxLayoutWidth = width
        nsView.invalidateIntrinsicContentSize()
        nsView.layoutSubtreeIfNeeded()
        let height = max(nsView.fittingSize.height, nsView.intrinsicContentSize.height)
        if hasContent {
            context.coordinator.measuredWidth = width
            context.coordinator.measuredHeight = height
            // 仅稳定测量（无待回填公式）写入全局缓存，避免占位文本高度污染持久缓存。
            if context.coordinator.measurementStable {
                MathLayoutCache.storeParagraphHeight(height, for: globalKey)
            } else {
                // 诊断埋点（临时）：占位测量（pending 段落）——大塌缩的直接形态。
            }
        }
        return CGSize(width: width, height: height)
    }

    /// `Font.Weight` → 稳定整数（全局缓存 key 用）。
    private static func weightRaw(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight: return 1
        case .thin: return 2
        case .light: return 3
        case .regular: return 4
        case .medium: return 5
        case .semibold: return 6
        case .bold: return 7
        case .heavy: return 8
        case .black: return 9
        default: return 4
        }
    }
}

// MARK: - NSAttributedString 行内渲染（镜像 MarkdownInline.render 语义）

/// 单条待异步光栅化的行内公式（段落构建时收集，用于两段式回填）。
struct PendingInlineMath {
    let latex: String
    let pointSize: CGFloat
    let color: NSColor
}

/// 行内渲染结果：attributed 已含「命中位图 attachment 或未命中占位」，
/// pendingMath 为本段需要后台光栅化的公式清单（全部完成后重建一次整段）。
struct InlineMathRender {
    let attributed: NSAttributedString
    let pendingMath: [PendingInlineMath]
}
