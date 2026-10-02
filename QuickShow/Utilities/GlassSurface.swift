import AppKit
import SwiftUI

// MARK: - 功能层玻璃面（Liquid Glass）
//
// HIG Materials 原则：Liquid Glass 只用于**功能层**（toolbar / 输入条 / 状态栏 / 按钮等浮动控件面），
// 内容层（消息列表 / 正文 / 表单）必须用标准材质；整窗包 NSGlassEffectView 是官方点名的错误用法
// （观感像磨砂塑料）。本 Modifier 让功能面在 macOS 26+ 用官方 .glassEffect，
// 13~25 退化为 ultraThinMaterial + 0.5pt 描边——两个版本分层语义一致
//（材质内容底 + 描边功能面），不会出现「26+ 是玻璃、<26 是实色块」的割裂。
//
// 使用纪律：
// - 只在功能面（可交互控件面）使用；绝不在 glass 上叠 glass。
// - .glassEffect 必须位于 padding/background 等改变外观的 modifier 之后（官方要求）。
// - 多个相邻 glass 面（间距小于一个视觉组）需包 GlassEffectContainer(spacing:) 统一采样；
//   当前各功能面彼此不相邻（中间隔内容区），故未使用容器。
struct GlassSurface<S: Shape>: ViewModifier {
    /// 功能面形状（圆角取 Theme 令牌）。
    let shape: S
    /// <26 退化路径的功能面描边色。
    var strokeColor: Color = Theme.Colors.chatStrokeStrong

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // 官方 Liquid Glass：材质/高光/阴影由系统提供，随 effectiveAppearance 自适应明暗
            content.glassEffect(.regular, in: shape)
        } else {
            // 13~25 退化：内容层同款超薄材质 + 0.5pt 描边，保持与 26+ 一致的功能面层级
            content
                .background(shape.fill(.ultraThinMaterial))
                .overlay(shape.stroke(strokeColor, lineWidth: 0.5))
        }
    }
}

extension View {
    /// 把当前视图标记为功能层玻璃面（26+ Liquid Glass / <26 材质 + 描边）。
    func glassSurface<S: Shape>(_ shape: S) -> some View {
        modifier(GlassSurface(shape: shape))
    }
}

// MARK: - 运行时系统能力开关
//
// 整窗 Liquid Glass（NSGlassEffectView）实验开关：SDK ≥ 26 编译、运行时按版本分支。
// SwiftUI 视图层（AIChatView 等）用它决定「内容层透玻璃」还是「降级铺材质」，
// 与 AppKit 窗口层（AIWindowManager）的装载分支保持同一判断源。
enum OSFeatures {
    /// macOS 26+：AppKit Liquid Glass 可用，整窗走真玻璃。
    static let liquidGlass: Bool = {
        if #available(macOS 26.0, *) { return true }
        return false
    }()
}

// MARK: - 整窗玻璃窗体的内容层背景
//
// 与窗口层 NSGlassEffectView 配套：26+ 内容层透明（透出真玻璃，内容「印」在玻璃上，
// 系统 Spotlight 语义）；<26 降级路径铺 ultraThinMaterial 保持观感接近。
// 主面板 / AI 窗共用，避免两处 if/else 漂移。
struct LiquidPanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            if OSFeatures.liquidGlass {
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                    .fill(.clear)
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
    }
}

extension View {
    /// 整窗玻璃窗体的内容层背景（26+ 透明透玻璃 / <26 降级铺材质）。
    func liquidPanelBackground() -> some View {
        modifier(LiquidPanelBackground())
    }
}

// MARK: - 无边框窗口 contentView 统一圆角裁剪
//
// 两个窗口（主面板 / AI 窗）共用同一套：整窗 NSGlassEffectView 已移除，
// hostingView 直接作为 contentView，由 AppKit 根图层施加连续曲率圆角裁剪。
// 26+ 与 13~25 走同一路径，不再分子分支（明暗翻转交由材质/语义色同源驱动）。
enum PanelHostingConfigurator {
    static func configure(_ hostingView: NSView, cornerRadius: CGFloat) {
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    }
}