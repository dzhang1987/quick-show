import AppKit
import SwiftUI

// MARK: - WCAG 对比度（可读性的唯一裁决点）
//
// 为什么需要这一层：文字可读性只由「前景色 × 真实合成底色」决定。当底色是浮动的
// （窗口玻璃实时采样壁纸、主题自带底色被剥离、半透明层叠加），任何写死的色值都无法
// 保证可读——同一个 #50a14f 在近白纸面上有 3.4:1，压到深灰底上只剩 1.4:1。
//
// 本类型把三件事收敛为单一来源，供设计令牌（底色）与代码高亮（前景色）共用：
// 1. sRGB 相对亮度与 WCAG 2.1 对比度公式（杜绝散落的 0.2126/0.7152 魔法系数）；
// 2. 半透明前景在给定底色上的合成（求「实际看到的颜色」）；
// 3. 以最小感知位移把前景色校正到对比度下限（亮底压暗 / 暗底提亮，二分逼近）。
//
// 纯度约束：不持有状态、不依赖 App 单例、不触碰主线程——可在任意队列（含高亮渲染
// 后台队列）安全调用，也可被单元测试直接断言。
struct ContrastColor: Equatable {
    /// sRGB 通道（0...1）
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 从任意 NSColor 取 sRGB 分量（色彩空间不一（calibrated/display P3）时先转 sRGB；
    /// 取不到 sRGB 表示即视为不可度量，交由调用方保持原色）。
    init?(srgb color: NSColor) {
        guard let converted = color.usingColorSpace(.sRGB) else { return nil }
        self.init(
            Double(converted.redComponent),
            Double(converted.greenComponent),
            Double(converted.blueComponent)
        )
    }

    /// 从 `#RRGGBB` / `RRGGBB` 解析（令牌与审计脚本共用同一语法）。
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    static let black = ContrastColor(0, 0, 0)
    static let white = ContrastColor(1, 1, 1)

    // MARK: 输出

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }

    var hex: String {
        let channels = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }

    // MARK: WCAG 2.1

    /// WCAG 相对亮度（sRGB → 线性化 → 0.2126R+0.7152G+0.0722B）
    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// 与另一色的对比度（1…21，1 表示完全不可辨）
    func contrastRatio(to other: ContrastColor) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    // MARK: 合成与校正

    /// 半透明前景在底色上的实际观感（alpha = 该前景自身不透明度）
    func blended(over background: ContrastColor, alpha: Double) -> ContrastColor {
        let clamped = min(max(alpha, 0), 1)
        return ContrastColor(
            red * clamped + background.red * (1 - clamped),
            green * clamped + background.green * (1 - clamped),
            blue * clamped + background.blue * (1 - clamped)
        )
    }

    /// 朝目标极做线性混合（amount 0 = 自身，1 = 目标极）
    func mixed(toward target: ContrastColor, amount: Double) -> ContrastColor {
        let clamped = min(max(amount, 0), 1)
        return ContrastColor(
            red + (target.red - red) * clamped,
            green + (target.green - green) * clamped,
            blue + (target.blue - blue) * clamped
        )
    }

    /// 把当前色校正到「与底色对比度 ≥ minimumContrast」。
    ///
    /// 策略：保持色相，朝黑或白做最小幅度线性混合。两个极分别二分求最小混合量，
    /// 取感知位移（以亮度差度量）更小的一侧——中性灰底上只有一侧能达标时自动选那条路。
    /// 已达标则原样返回（零改动是默认行为，不破坏主题本身的观感）。
    func adjusted(minimumContrast minimum: Double, against background: ContrastColor) -> ContrastColor {
        guard minimum > 1, contrastRatio(to: background) < minimum else { return self }

        let options = [ContrastColor.black, ContrastColor.white].compactMap { pole in
            solvingContrast(toward: pole, minimumContrast: minimum, against: background)
        }
        guard !options.isEmpty else {
            return background.relativeLuminance > 0.18 ? .black : .white
        }
        return options.min { lhs, rhs in
            abs(lhs.relativeLuminance - relativeLuminance) < abs(rhs.relativeLuminance - relativeLuminance)
        } ?? self
    }

    /// 朝 `pole` 二分出「刚好达标」的最小混合量；全程不达标返回 nil。
    private func solvingContrast(
        toward pole: ContrastColor,
        minimumContrast minimum: Double,
        against background: ContrastColor
    ) -> ContrastColor? {
        let extreme = mixed(toward: pole, amount: 1)
        guard extreme.contrastRatio(to: background) >= minimum else { return nil }

        var low = 0.0    // 已知不达标
        var high = 1.0   // 已知达标
        for _ in 0..<16 {
            let mid = (low + high) / 2
            if mixed(toward: pole, amount: mid).contrastRatio(to: background) >= minimum {
                high = mid
            } else {
                low = mid
            }
        }
        return mixed(toward: pole, amount: high)
    }
}
