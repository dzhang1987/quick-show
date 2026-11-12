import SwiftUI

// MARK: - 静态极光·氛围光团（光与纸 · 2026-11）
//
// 用户决策（2026-11 CPU 治理）：极光定格为静态氛围光晕，不做动效。
// 背景（三轮 A/B 实测铁证）：TimelineView 任何调度（.animation / .periodic 皆然）都会让
// 整窗 NSHostingView 的 display cycle 按屏幕刷新率空转——minimumInterval 只节流内容重绘，
// 节流不了更新循环（可见态 22~32% CPU，逐帧全窗布局 + AttributeGraph 更新）。
// 静态化后零更新源、零成本。若未来恢复动效，正确路径是 CAGradientLayer 层树 + 显式低频
// Timer（与 SwiftUI 视图图解耦），勿回 TimelineView。
//
// 视觉：3 团 distinct 光斑（主色×2 + 副色×1），位置/半径/亮度取 wander 曲线 t=0 的确定帧，
// 构图跨重启稳定；三段 stop 软膝径向渐变自羽化（不做整窗 blur）。
// 对比度纪律：光团峰值不透明度克制（auroraBlobPeakOpacity），纵向偏顶部（auroraVerticalBias），
// 下方正文小字仍落在确定纸面，不进入对比度预算。
// 色彩 / 半径 / 软膝全部走 DesignTokens，本视图不硬编码。

struct ChatAuroraView: View {
    var body: some View {
        // t=0：wander 曲线的确定采样点，静态构图（无时间线、无时钟、无遮挡门控——静止即零成本）
        Canvas { ctx, size in
            drawBlobs(ctx: &ctx, size: size, t: 0)
        }
        .allowsHitTesting(false)
    }

    /// 绘制三团光斑。
    private func drawBlobs(ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let shortSide = min(size.width, size.height)
        let baseRadius = shortSide * Theme.Colors.auroraBlobRadiusRatio
        let verticalBound = size.height * Theme.Colors.auroraVerticalBias

        // 三团：主色 / 副色 / 主色（异 seed → 独立 wander 采样，交叠出色彩层次）
        let blobs: [(hue: Color, seed: Double, scale: CGFloat)] = [
            (Theme.Colors.auroraBlobPrimary, 1.7, 1.0),
            (Theme.Colors.auroraBlobSecondary, 4.3, 0.85),
            (Theme.Colors.auroraBlobPrimary, 8.9, 0.65)
        ]

        for blob in blobs {
            // 位置：横向全幅游走采样，纵向偏顶部
            let x = size.width * 0.5 + wave(t, blob.seed, 0.11, 0.07, 0.043) * size.width * 0.45
            let y = verticalBound * 0.5 + wave(t, blob.seed + 9.1, 0.09, 0.06, 0.037) * verticalBound * 0.5
            // 半径呼吸采样（0.7~1.3 倍基础半径）
            let radius = baseRadius * blob.scale * (1.0 + 0.3 * wave(t, blob.seed + 3.3, 0.09, 0.05, 0.031))
            // 亮度呼吸采样（0.5~1.0 倍峰值）
            let opacity = Theme.Colors.auroraBlobPeakOpacity * (0.75 + 0.25 * wave(t, blob.seed + 5.7, 0.13, 0.08, 0.047))

            let center = CGPoint(x: x, y: y)
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            // 三段 stop 软膝渐变：中段保留部分亮度、边缘归零，自羽化替代整窗 blur
            let shading = GraphicsContext.Shading.radialGradient(
                Gradient(stops: [
                    .init(color: blob.hue.opacity(opacity), location: 0),
                    .init(
                        color: blob.hue.opacity(opacity * Theme.Colors.auroraBlobKneeOpacityRatio),
                        location: Theme.Colors.auroraBlobKneeLocation
                    ),
                    .init(color: blob.hue.opacity(0), location: 1)
                ]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
            ctx.fill(Path(ellipseIn: rect), with: shading)
        }
    }

    /// 不可通约频率正弦叠加 → 有机、不显周期的 wander 曲线（值域约 -1...1）。
    private func wave(_ t: Double, _ seed: Double, _ f1: Double, _ f2: Double, _ f3: Double) -> CGFloat {
        CGFloat((sin(t * f1 + seed) + sin(t * f2 + seed * 2.7) + sin(t * f3 + seed * 1.3)) / 3.0)
    }
}
