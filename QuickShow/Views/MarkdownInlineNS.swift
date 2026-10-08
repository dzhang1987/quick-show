// 来源拆分：AIChatMathViews.swift — 行内 NSAttributedString 渲染层（MarkdownInlineNS / MarkdownInlineText 及共用私有扩展）。
import SwiftUI
import AppKit

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

    /// 行内代码底色：chatInlineCodeFill = Color.primary.opacity(0.10) 的 NSColor 近似。
    private static var codeBackground: NSColor {
        NSColor.labelColor.withAlphaComponent(0.10)
    }

    /// 高亮（`<mark>`）底色：半透明强调色（与 SwiftUI 路径同 accent 色系，0.15 降噪）。
    private static var highlightBackground: NSColor {
        accentColor.withAlphaComponent(0.15)
    }

    /// accent 的 NSColor 近似：优先取当前主题 accent 解析值，失败退回系统 linkColor。
    private static var accentColor: NSColor {
        MathRasterizer.resolvedColor(Theme.Colors.accent, appearance: NSApp.effectiveAppearance)
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
                let piece = NSAttributedString(
                    string: MarkdownInline.normalizeQuotes(value),
                    attributes: [.font: baseFont, .foregroundColor: baseColor]
                )
                result.append(piece)

            case let .code(value):
                let piece = NSAttributedString(
                    string: value,
                    attributes: [
                        .font: monoFont(size: 12.5),
                        .foregroundColor: baseColor,
                        .backgroundColor: codeBackground,
                    ]
                )
                result.append(piece)

            case let .bold(inner):
                // 加粗档提为 labelColor（contentPrimary），与 SwiftUI 版一致
                render(
                    into: result,
                    tokens: inner,
                    baseFont: font(size: baseSize, weight: .semibold),
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

            case .lineBreak:
                result.append(NSAttributedString(
                    string: "\n",
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
                // AppKit/NSTextField 路径不做异步图片：降级为链接样式文本（公式+图片同段罕见）。
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
                // 方案 A：主线程**只做锁内快速查询**，绝不触发同步 render。
                switch MathRasterizer.lookup(latex: latex, pointSize: baseSize, color: baseColor, isDisplay: false) {
                case let .hit(raster):
                    // 命中缓存：纯内存装 attachment（纳秒级，走既有基线对齐路径）。
                    result.append(NSAttributedString(attachment: InlineMathAttachment.make(from: raster)))
                case .failed:
                    // 已知解析失败：降级显示原始 LaTeX 文本，不再重复请求。
                    appendMathFallback(into: result, latex: latex, color: baseColor)
                case .miss:
                    // 未命中：先装等宽原始 LaTeX 占位（首帧可读、真实文本宽度、段落高度合理），
                    // 登记待回填；全部异步完成后用真实 attachment 重建整段。
                    appendMathFallback(into: result, latex: latex, color: baseColor)
                    pending.append(PendingInlineMath(latex: latex, pointSize: baseSize, color: baseColor))
                }
            }
        }
    }

    /// 行内公式占位/失败降级：等宽原始 LaTeX 文本（12pt），保证首帧非空白且尺寸近似。
    private static func appendMathFallback(into result: NSMutableAttributedString, latex: String, color: NSColor) {
        result.append(NSAttributedString(
            string: latex,
            attributes: [.font: monoFont(size: 12), .foregroundColor: color]
        ))
    }

    // MARK: 新 token 辅助

    /// 由现有字体派生指定字号的同族字体（保留字重 / 斜体等 trait）。
    private static func derivedFont(from font: NSFont, size: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    }

    /// 对 [start, result.length) 区间应用单一属性（区间为空则跳过）。
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

    /// 链接样式：accent 前景 + 下划线 + `.link` 属性（url 非法时仅保留视觉样式）。
    private static func applyLinkStyle(to result: NSMutableAttributedString, from start: Int, url: String) {
        let range = NSRange(location: start, length: result.length - start)
        guard range.length > 0 else { return }
        result.addAttribute(.foregroundColor, value: accentColor, range: range)
        result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        if let linkURL = URL(string: url) {
            result.addAttribute(.link, value: linkURL, range: range)
        }
    }

    /// 上下标：以派生小号字体递归渲染 inner，再对整段应用 baselineOffset。
    /// baseSize 一并传入小号值，保证嵌套 bold/italic/math 同步缩小。
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

// MARK: - SwiftUI 统一行内入口

/// 行内文本统一入口：
/// - 含顶层图片：按「文本段 / 图片项」交替拆段，文本段递归走下方双路径，图片项交给
///   `MarkdownImageView`，整体 `VStack(leading)` 顺序排列；
/// - 含公式（含嵌套在粗体/斜体/链接等内的公式）：NSTextField + NSTextAttachment 路径；
/// - 其余：原 SwiftUI AttributedString 路径。
struct MarkdownInlineText: View {
    let inlines: [InlineToken]
    var bodyColor: Color = Color.primary.opacity(0.80)
    var baseSize: CGFloat = 13
    var weight: Font.Weight = .regular
    var explicitColor: Color? = nil

    var body: some View {
        if inlines.containsImage {
            imageLayout
        } else if inlines.containsMath {
            MathParagraphView(
                inlines: inlines,
                baseSize: baseSize,
                weight: weight,
                color: explicitColor ?? bodyColor
            )
        } else {
            plainText
        }
    }

    /// 含顶层图片：交替拆段（纯结构操作，无 IO），文本段复用本视图递归渲染，
    /// 文本段与图片以 `VStack(leading)` 自然换行相邻。
    private var imageLayout: some View {
        let segments = inlines.imageSegments
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .text(tokens):
                    MarkdownInlineText(
                        inlines: tokens,
                        bodyColor: bodyColor,
                        baseSize: baseSize,
                        weight: weight,
                        explicitColor: explicitColor
                    )
                case let .image(alt, url, title, linkURL):
                    MarkdownImageView(alt: alt, url: url, title: title, linkURL: linkURL)
                }
            }
        }
    }

    /// 非公式路径：严格复刻各调用点原有的 Text + font(+foregroundColor) modifier 组合。
    @ViewBuilder
    private var plainText: some View {
        let base = Text(MarkdownInline.render(inlines, bodyColor: bodyColor))
            .font(Theme.Typography.text(baseSize, weight))
        if let explicitColor {
            base.foregroundColor(explicitColor)
        } else {
            base
        }
    }
}

// MARK: - 图片拆段单元

/// 图片拆段后的显示单元：文本段（继续行内渲染）或图片项（交给 `MarkdownImageView`）。
/// `linkURL` 非 nil 表示该图片来自链接内嵌（`[![alt](img)](link)`），成功态可点击打开。
private enum InlineDisplaySegment {
    case text([InlineToken])
    case image(alt: String, url: String, title: String?, linkURL: String?)
}

// MARK: - 公式 / 图片检测（递归）

private extension Array where Element == InlineToken {
    /// 是否含公式 token（递归粗体/斜体/链接/删除线/下划线/高亮/上下标内部）。
    var containsMath: Bool { contains { $0.containsMath } }

    /// 是否含**顶层**图片 token（不递归进入链接内层）。
    var containsTopLevelImage: Bool {
        contains { if case .image = $0 { return true } else { return false } }
    }

    /// 是否触发图片拆段：顶层 `.image`，或顶层 `.link` 的 text 顶层含 `.image`
    /// （即 `[![alt](img)](link)`）。仅处理「一层 link 包 image」，不再深入嵌套以避免无限递归。
    var containsImage: Bool {
        contains { token in
            switch token {
            case .image:
                return true
            case let .link(text, _, _):
                return text.containsTopLevelImage
            default:
                return false
            }
        }
    }

    /// 仅按顶层 `.image` 拆段（老逻辑），供链接内层拆解复用。
    /// 顺序保持，连续文本归一段，图片各自成项，空文本段丢弃。
    var topLevelImageSegments: [InlineDisplaySegment] {
        var segments: [InlineDisplaySegment] = []
        var buffer: [InlineToken] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            segments.append(.text(buffer))
            buffer.removeAll()
        }
        for token in self {
            if case let .image(alt, url, title) = token {
                flush()
                segments.append(.image(alt: alt, url: url, title: title, linkURL: nil))
            } else {
                buffer.append(token)
            }
        }
        flush()
        return segments
    }

    /// 把顶层 token 序列拆为交替的文本段与图片项：顺序保持，连续文本归一段，
    /// 图片各自成项，空文本段丢弃。
    /// 升级：顶层 `.link` 的 text 顶层含 `.image` 时，递归拆解其内层——image 提升为图片项并
    /// 携带 linkURL，非图片 token 归并到相邻文本段（不保留链接样式，可接受）。
    var imageSegments: [InlineDisplaySegment] {
        var segments: [InlineDisplaySegment] = []
        var buffer: [InlineToken] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            segments.append(.text(buffer))
            buffer.removeAll()
        }
        for token in self {
            switch token {
            case let .image(alt, url, title):
                flush()
                segments.append(.image(alt: alt, url: url, title: title, linkURL: nil))
            case let .link(text, linkURL, _) where text.containsTopLevelImage:
                for inner in text.topLevelImageSegments {
                    switch inner {
                    case let .image(alt, url, title, _):
                        flush()
                        segments.append(.image(alt: alt, url: url, title: title, linkURL: linkURL))
                    case let .text(tokens):
                        buffer.append(contentsOf: tokens)
                    }
                }
            default:
                buffer.append(token)
            }
        }
        flush()
        return segments
    }
}

private extension InlineToken {
    var containsMath: Bool {
        switch self {
        case .math:
            return true
        case let .bold(inner), let .italic(inner),
             let .strikethrough(inner), let .underline(inner), let .highlight(inner),
             let .superscript(inner):
            return inner.containsMath
        case let .`subscript`(inner):
            return inner.containsMath
        case let .link(text, _, _):
            return text.containsMath
        case .text, .code, .image, .lineBreak, .footnoteRef:
            return false
        }
    }
}