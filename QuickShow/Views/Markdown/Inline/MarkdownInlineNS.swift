import SwiftUI
import AppKit
import CoreText

/// 行内 token → NSAttributedString（供含公式的段落使用）。
/// 语义严格对齐 SwiftUI 版 MarkdownInline.render：
/// text→引号归一 + baseColor/baseFont；code→等宽 + surfaceTrack 底；
/// bold→semibold + labelColor；italic→斜体；link→accent + 下划线（title 忽略）；
/// strikethrough→strikethroughStyle；underline→underlineStyle；
/// highlight→accent 半透明 backgroundColor；subscript/superscript→小号字体 + baselineOffset；
/// lineBreak→换行；footnoteRef→小号 accent 上标；image→链接样式「[图片: alt]」降级；
/// math→缓存命中装 NSTextAttachment / 未命中装等宽占位并登记异步回填。
enum MarkdownInlineNS {

    /// SwiftUI Font.Weight → AppKit NSFont.Weight。
    static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    /// 正文字体（SF Pro）。
    static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// 等宽字体（SF Mono），对应 Theme.Typography.mono。
    static func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// 动态适配外观的文本前景色（带透明度）：解决 NSColor.labelColor.withAlphaComponent 在 AppKit 下固化为固定 sRGB 丢失外观感知的问题
    static func adaptiveLabel(opacity: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor.white.withAlphaComponent(opacity)
                : NSColor.black.withAlphaComponent(opacity)
        }
    }

    /// 行内代码底色：chatInlineCodeFill = Color.primary.opacity(0.10) 的 NSColor 近似。
    private static var codeBackground: NSColor {
        adaptiveLabel(opacity: 0.10)
    }

    /// 键盘按键（`<kbd>`）底色：比行内代码深半档以突显键帽感。
    private static var kbdBackground: NSColor {
        adaptiveLabel(opacity: 0.14)
    }

    /// 高亮（`<mark>`）底色：半透明强调色（与 SwiftUI 路径同 accent 色系，0.15 降噪）。
    private static var highlightBackground: NSColor {
        NSColor(name: nil) { appearance in
            MathRasterizer.resolvedColor(Theme.Colors.accent, appearance: appearance).withAlphaComponent(0.15)
        }
    }

    /// accent 的 NSColor 近似：优先取当前主题 accent 解析值，失败退回系统 linkColor。
    static var accentColor: NSColor {
        NSColor(name: nil) { appearance in
            MathRasterizer.resolvedColor(Theme.Colors.accent, appearance: appearance)
        }
    }

    static func renderNS(
        _ tokens: [InlineToken],
        baseFont: NSFont,
        baseColor: NSColor,
        baseSize: CGFloat
    ) -> InlineMathRender {
        let result = NSMutableAttributedString()
        var pending: [PendingInlineMath] = []
        render(
            into: result,
            tokens: tokens,
            baseFont: baseFont,
            baseColor: baseColor,
            baseSize: baseSize,
            pending: &pending
        )
        return InlineMathRender(attributed: result, pendingMath: pending)
    }

    private static func render(
        into result: NSMutableAttributedString,
        tokens: [InlineToken],
        baseFont: NSFont,
        baseColor: NSColor,
        baseSize: CGFloat,
        pending: inout [PendingInlineMath]
    ) {
        for token in tokens {
            switch token {
            case let .text(value):
                // 段内软换行转为 Unicode 行分隔符（\u{2028}），确保在 TextKit 中折行不断段：
                // 既不提前触发 paragraphSpacing，又能在列表项内保持 headIndent 悬挂缩进对齐。
                let normalized = MarkdownInline.normalizeQuotes(value)
                    .replacingOccurrences(of: "\n", with: "\u{2028}")
                let piece = NSAttributedString(
                    string: normalized,
                    attributes: [.font: baseFont, .foregroundColor: baseColor]
                )
                result.append(piece)

            case let .code(value):
                let piece = NSAttributedString(
                    string: value,
                    attributes: [
                        .font: monoFont(size: 12.5, weight: .medium),
                        .foregroundColor: NSColor.labelColor,
                        .backgroundColor: codeBackground,
                    ]
                )
                result.append(piece)

            case let .kbd(value):
                let piece = NSAttributedString(
                    string: "\u{2009}\(value)\u{2009}",
                    attributes: [
                        .font: monoFont(size: max(baseSize - 1, 9), weight: .semibold),
                        .foregroundColor: NSColor.labelColor,
                        .backgroundColor: kbdBackground,
                    ]
                )
                result.append(piece)

            case let .bold(inner):
                var boldFont = font(size: baseSize, weight: .semibold)
                if baseFont.fontDescriptor.symbolicTraits.contains(.italic) {
                    boldFont = NSFontManager.shared.convert(boldFont, toHaveTrait: .italicFontMask)
                }
                render(
                    into: result,
                    tokens: inner,
                    baseFont: boldFont,
                    baseColor: .labelColor,
                    baseSize: baseSize,
                    pending: &pending
                )

            case let .italic(inner):
                let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                render(
                    into: result,
                    tokens: inner,
                    baseFont: italicFont,
                    baseColor: baseColor,
                    baseSize: baseSize,
                    pending: &pending
                )

            case let .link(label, url, _):
                let start = result.length
                render(
                    into: result,
                    tokens: label,
                    baseFont: baseFont,
                    baseColor: baseColor,
                    baseSize: baseSize,
                    pending: &pending
                )
                applyLinkStyle(to: result, from: start, url: url)

            case let .strikethrough(inner):
                let start = result.length
                render(
                    into: result,
                    tokens: inner,
                    baseFont: baseFont,
                    baseColor: baseColor,
                    baseSize: baseSize,
                    pending: &pending
                )
                applyAttribute(
                    to: result, from: start,
                    key: .strikethroughStyle, value: NSUnderlineStyle.single.rawValue
                )

            case let .underline(inner):
                let start = result.length
                render(
                    into: result,
                    tokens: inner,
                    baseFont: baseFont,
                    baseColor: baseColor,
                    baseSize: baseSize,
                    pending: &pending
                )
                applyAttribute(
                    to: result, from: start,
                    key: .underlineStyle, value: NSUnderlineStyle.single.rawValue
                )

            case let .highlight(inner):
                let start = result.length
                render(
                    into: result,
                    tokens: inner,
                    baseFont: baseFont,
                    baseColor: baseColor,
                    baseSize: baseSize,
                    pending: &pending
                )
                applyAttribute(to: result, from: start, key: .backgroundColor, value: highlightBackground)

            case let .`subscript`(inner):
                renderScript(
                    into: result, tokens: inner,
                    baseFont: baseFont, baseColor: baseColor, baseSize: baseSize,
                    sizeDelta: -2, baselineOffset: -3, pending: &pending
                )

            case let .superscript(inner):
                renderScript(
                    into: result, tokens: inner,
                    baseFont: baseFont, baseColor: baseColor, baseSize: baseSize,
                    sizeDelta: -2, baselineOffset: 3, pending: &pending
                )

            case let .ruby(base, ruby, position):
                let start = result.length
                render(
                    into: result,
                    tokens: base,
                    baseFont: baseFont,
                    baseColor: baseColor,
                    baseSize: baseSize,
                    pending: &pending
                )
                let len = result.length - start
                guard len > 0, !ruby.isEmpty else { break }

                let ctPos: CTRubyPosition
                switch position {
                case .over: ctPos = .before
                case .right: ctPos = .interCharacter
                case .under: ctPos = .after
                }
                let annotation = CTRubyAnnotationCreateWithAttributes(
                    .center,
                    .none,
                    ctPos,
                    ruby as CFString,
                    [:] as CFDictionary
                )
                result.addAttribute(
                    kCTRubyAnnotationAttributeName as NSAttributedString.Key,
                    value: annotation,
                    range: NSRange(location: start, length: len)
                )

            case .lineBreak:
                result.append(NSAttributedString(
                    string: "\u{2028}",
                    attributes: [.font: baseFont, .foregroundColor: baseColor]
                ))

            case let .footnoteRef(id):
                result.append(NSAttributedString(
                    string: id,
                    attributes: [
                        .font: derivedFont(from: baseFont, size: max(baseSize - 3, 1)),
                        .foregroundColor: accentColor,
                        .baselineOffset: CGFloat(4),
                    ]
                ))

            case let .image(alt, url, _):
                let label = alt.isEmpty ? String(localized: "[图片]") : String(localized: "[图片: \(alt)]")
                let piece = NSMutableAttributedString(
                    string: label,
                    attributes: [
                        .font: baseFont,
                        .foregroundColor: accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]
                )
                if let linkURL = URL(string: url) {
                    piece.addAttribute(
                        .link, value: linkURL,
                        range: NSRange(location: 0, length: piece.length)
                    )
                }
                result.append(piece)

            case let .math(latex):
                switch MathRasterizer.lookup(latex: latex, pointSize: baseSize, color: baseColor, isDisplay: false) {
                case let .hit(raster):
                    result.append(NSAttributedString(attachment: InlineMathAttachment.make(from: raster)))
                case .failed:
                    appendMathFallback(into: result, latex: latex, color: baseColor)
                case .miss:
                    appendMathFallback(into: result, latex: latex, color: baseColor)
                    pending.append(PendingInlineMath(latex: latex, pointSize: baseSize, color: baseColor))
                }
            }
        }
    }

    private static func appendMathFallback(into result: NSMutableAttributedString, latex: String, color: NSColor) {
        result.append(NSAttributedString(
            string: latex,
            attributes: [.font: monoFont(size: 12), .foregroundColor: color]
        ))
    }

    private static func derivedFont(from font: NSFont, size: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    }

    private static func applyAttribute(
        to result: NSMutableAttributedString,
        from start: Int,
        key: NSAttributedString.Key,
        value: Any
    ) {
        let range = NSRange(location: start, length: result.length - start)
        guard range.length > 0 else { return }
        result.addAttribute(key, value: value, range: range)
    }

    private static func applyLinkStyle(to result: NSMutableAttributedString, from start: Int, url: String) {
        let range = NSRange(location: start, length: result.length - start)
        guard range.length > 0 else { return }
        result.addAttribute(.foregroundColor, value: accentColor, range: range)
        result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        if let linkURL = URL(string: url) {
            result.addAttribute(.link, value: linkURL, range: range)
        }
    }

    private static func renderScript(
        into result: NSMutableAttributedString,
        tokens: [InlineToken],
        baseFont: NSFont,
        baseColor: NSColor,
        baseSize: CGFloat,
        sizeDelta: CGFloat,
        baselineOffset: CGFloat,
        pending: inout [PendingInlineMath]
    ) {
        let start = result.length
        let scriptSize = max(baseSize + sizeDelta, 1)
        render(
            into: result,
            tokens: tokens,
            baseFont: derivedFont(from: baseFont, size: scriptSize),
            baseColor: baseColor,
            baseSize: scriptSize,
            pending: &pending
        )
        applyAttribute(to: result, from: start, key: .baselineOffset, value: baselineOffset)
    }
}
