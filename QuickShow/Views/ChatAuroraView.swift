import SwiftUI

// MARK: - 动态极光·游走光团（光与纸 · 2026-11）
//
// 用户诉求：不是线性 wash，而是「一团光在背景游走，光晕本身随机变化」。
// 实现：Canvas + TimelineView 驱动 3 团 distinct 光斑（主色×2 + 副色×1），
// 每团的位置 / 半径 / 亮度各自用「不可通约频率正弦叠加」做有机 wander 与随机呼吸，
// 组合后不显周期、不机械；光团交叠处色彩自然流动（mesh 感）。
//
// 性能：30fps 上限；Canvas 每帧仅重绘 3 个径向渐变 + 一次模糊滤镜，GPU 友好。
// 无障碍：尊重系统「减弱动态」——paused 时静止渲染。
// 对比度纪律：光团峰值不透明度克制（auroraBlobPeakOpacity），纵向游走偏顶部
// （auroraVerticalBias），下方正文小字仍落在确定纸面，不进入对比度预算。
//
// 色彩 / 半径 / 模糊 / 速度全部走 DesignTokens，本视图不硬编码。

struct ChatAuroraView: View {
    let windowWidth: CGFloat
    let windowHeight: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(minimumInterval: Theme.Motion.auroraFrameInterval, paused: reduceMotion)
        ) { context in
            let t = context.date.timeIntervalSinceReferenceDate * Theme.Motion.auroraTimeScale
            Canvas { ctx, size in
                drawBlobs(ctx: &ctx, size: size, t: t)
            }
        }
        .allowsHitTesting(false)
    }

    /// 绘制三团游走光斑。
    private func drawBlobs(ctx: inout GraphicsContext, size: CGSize, t: Double) {
        // 柔化 glow 边缘（一次滤镜作用于后续所有光团）
        ctx.addFilter(.blur(radius: Theme.Colors.auroraBlobBlur))

        let shortSide = min(size.width, size.height)
        let baseRadius = shortSide * Theme.Colors.auroraBlobRadiusRatio
        let verticalBound = size.height * Theme.Colors.auroraVerticalBias

        // 三团：主色 / 副色 / 主色（异 seed → 独立 wander，交叠出色彩流动）
        let blobs: [(hue: Color, seed: Double, scale: CGFloat)] = [
            (Theme.Colors.auroraBlobPrimary, 1.7, 1.0),
            (Theme.Colors.auroraBlobSecondary, 4.3, 0.85),
            (Theme.Colors.auroraBlobPrimary, 8.9, 0.65)
        ]

        for blob in blobs {
            // 位置：横向全幅游走，纵向偏顶部游走
            let x = size.width * 0.5 + wave(t, blob.seed, 0.11, 0.07, 0.043) * size.width * 0.45
            let y = verticalBound * 0.5 + wave(t, blob.seed + 9.1, 0.09, 0.06, 0.037) * verticalBound * 0.5
            // 半径随机呼吸（0.7~1.3 倍基础半径）
            let radius = baseRadius * blob.scale * (1.0 + 0.3 * wave(t, blob.seed + 3.3, 0.09, 0.05, 0.031))
            // 亮度随机呼吸（0.5~1.0 倍峰值）
            let opacity = Theme.Colors.auroraBlobPeakOpacity * (0.75 + 0.25 * wave(t, blob.seed + 5.7, 0.13, 0.08, 0.047))

            let center = CGPoint(x: x, y: y)
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            let shading = GraphicsContext.Shading.radialGradient(
                Gradient(colors: [blob.hue.opacity(opacity), blob.hue.opacity(0)]),
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