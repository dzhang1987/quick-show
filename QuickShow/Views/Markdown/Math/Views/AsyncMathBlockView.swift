import SwiftUI

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
