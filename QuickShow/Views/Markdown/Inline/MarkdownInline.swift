import Combine
import SwiftUI

// MARK: - 行内 SwiftUI 渲染器

/// 行内 token → AttributedString（粗体 / 斜体 / 行内代码 / 可点击链接 / 纯文本）。
/// 供段落、标题、列表项、表格单元格、引用块共用。
enum MarkdownInline {
    /// 正文基准字号。
    static let baseSize: CGFloat = 13

    /// bodyColor：纯文本/行内代码的颜色——正文与列表降两档（primary 0.80），
    /// 与加粗档（contentPrimary 纯白/纯黑）肉眼可分区分开；标题、表格等调用处显式传 contentPrimary。
    /// 加粗递归时把基色提为 contentPrimary（而非事后整段覆盖），嵌套链接的 accent 得以保留。
    /// - size：当前行内基准字号（递归时上下标会下调；外部默认正文 13）。
    /// - baseWeight：段落/标题的基础字重（默认 regular，标题可传 semibold/bold）。
    static func render(
        _ tokens: [InlineToken],
        bodyColor: Color = Color.primary.opacity(0.80),
        size: CGFloat = baseSize,
        baseWeight: Font.Weight = .regular
    ) -> AttributedString {
        var result = AttributedString()
        append(
            tokens,
            into: &result,
            bodyColor: bodyColor,
            size: size,
            baseWeight: baseWeight,
            isBold: false,
            isItalic: false
        )
        return result
    }

    private static func resolveFont(
        size: CGFloat,
        baseWeight: Font.Weight,
        isBold: Bool,
        isItalic: Bool
    ) -> Font {
        let weight: Font.Weight = isBold ? (baseWeight == .bold ? .bold : .semibold) : baseWeight
        let base = Theme.Typography.text(size, weight)
        return isItalic ? base.italic() : base
    }

    /// 递归构建：每个叶子 token 按当前上下文（size / baseWeight / isBold / isItalic）直接写入精确字体，
    /// 避免整段覆盖抹平 `.code` / `.bold` / `.italic` 样式。语义与 AppKit 路径 `MarkdownInlineNS` 镜像。
    private static func append(
        _ tokens: [InlineToken],
        into result: inout AttributedString,
        bodyColor: Color,
        size: CGFloat,
        baseWeight: Font.Weight,
        isBold: Bool,
        isItalic: Bool
    ) {
        for token in tokens {
            switch token {
            case let .text(value):
                var piece = AttributedString(normalizeQuotes(value))
                piece.font = resolveFont(size: size, baseWeight: baseWeight, isBold: isBold, isItalic: isItalic)
                piece.foregroundColor = bodyColor
                result.append(piece)

            case let .code(value):
                var piece = AttributedString(value)
                piece.font = Theme.Typography.mono(max(size - 0.5, 9), .medium)
                piece.foregroundColor = Theme.Colors.contentPrimary
                piece.backgroundColor = Theme.Colors.chatInlineCodeFill
                result.append(piece)

            case let .kbd(value):
                var piece = AttributedString("\u{2009}\(value)\u{2009}")
                piece.font = Theme.Typography.mono(max(size - 1, 9), .semibold)
                piece.foregroundColor = Theme.Colors.contentPrimary
                piece.backgroundColor = Theme.Colors.badgeFill
                result.append(piece)

            case let .bold(inner):
                append(
                    inner,
                    into: &result,
                    bodyColor: Theme.Colors.contentPrimary,
                    size: size,
                    baseWeight: baseWeight,
                    isBold: true,
                    isItalic: isItalic
                )

            case let .italic(inner):
                append(
                    inner,
                    into: &result,
                    bodyColor: bodyColor,
                    size: size,
                    baseWeight: baseWeight,
                    isBold: isBold,
                    isItalic: true
                )

            case let .strikethrough(inner):
                let start = result.endIndex
                append(
                    inner,
                    into: &result,
                    bodyColor: bodyColor,
                    size: size,
                    baseWeight: baseWeight,
                    isBold: isBold,
                    isItalic: isItalic
                )
                result[start..<result.endIndex].strikethroughStyle = .single

            case let .underline(inner):
                let start = result.endIndex
                append(
                    inner,
                    into: &result,
                    bodyColor: bodyColor,
                    size: size,
                    baseWeight: baseWeight,
                    isBold: isBold,
                    isItalic: isItalic
                )
                result[start..<result.endIndex].underlineStyle = .single

            case let .highlight(inner):
                let start = result.endIndex
                append(
                    inner,
                    into: &result,
                    bodyColor: bodyColor,
                    size: size,
                    baseWeight: baseWeight,
                    isBold: isBold,
                    isItalic: isItalic
                )
                result[start..<result.endIndex].backgroundColor = Theme.Colors.accent.opacity(0.15)

            case let .subscript(inner):
                let subSize = max(size - 2, 9)
                let start = result.endIndex
                append(
                    inner,
                    into: &result,
                    bodyColor: bodyColor,
                    size: subSize,
                    baseWeight: baseWeight,
                    isBold: isBold,
                    isItalic: isItalic
                )
                result[start..<result.endIndex].baselineOffset = -3

            case let .superscript(inner):
                let superSize = max(size - 2, 9)
                let start = result.endIndex
                append(
                    inner,
                    into: &result,
                    bodyColor: bodyColor,
                    size: superSize,
                    baseWeight: baseWeight,
                    isBold: isBold,
                    isItalic: isItalic
                )
                result[start..<result.endIndex].baselineOffset = 3

            case let .ruby(base, ruby, position):
                append(
                    base,
                    into: &result,
                    bodyColor: bodyColor,
                    size: size,
                    baseWeight: baseWeight,
                    isBold: isBold,
                    isItalic: isItalic
                )
                let rtSize = max(size * 0.58, 8)
                switch position {
                case .over:
                    var rt = AttributedString("(\(ruby))")
                    rt.font = resolveFont(size: rtSize, baseWeight: baseWeight, isBold: isBold, isItalic: isItalic)
                    rt.foregroundColor = bodyColor.opacity(0.85)
                    rt.baselineOffset = 3
                    result.append(rt)
                case .right:
                    var rt = AttributedString(" \(ruby)")
                    rt.font = resolveFont(size: rtSize, baseWeight: baseWeight, isBold: isBold, isItalic: isItalic)
                    rt.foregroundColor = bodyColor.opacity(0.85)
                    result.append(rt)
                case .under:
                    var rt = AttributedString("(\(ruby))")
                    rt.font = resolveFont(size: rtSize, baseWeight: baseWeight, isBold: isBold, isItalic: isItalic)
                    rt.foregroundColor = bodyColor.opacity(0.85)
                    rt.baselineOffset = -3
                    result.append(rt)
                }

            case let .link(label, url, _):
                let start = result.endIndex
                append(
                    label,
                    into: &result,
                    bodyColor: bodyColor,
                    size: size,
                    baseWeight: baseWeight,
                    isBold: isBold,
                    isItalic: isItalic
                )
                let range = start..<result.endIndex
                result[range].foregroundColor = Theme.Colors.accent
                result[range].underlineStyle = .single
                if let linkURL = URL(string: url) {
                    result[range].link = linkURL
                }

            case let .image(alt, _, _):
                var piece = AttributedString(alt)
                piece.font = resolveFont(size: size, baseWeight: baseWeight, isBold: isBold, isItalic: isItalic)
                piece.foregroundColor = bodyColor
                result.append(piece)

            case .lineBreak:
                result.append(AttributedString("\n"))

            case let .footnoteRef(identifier):
                let refSize = max(size - 3, 9)
                var piece = AttributedString(identifier)
                piece.font = Theme.Typography.text(refSize, .medium)
                piece.baselineOffset = 4
                piece.foregroundColor = Theme.Colors.accent
                result.append(piece)

            case let .math(value):
                var piece = AttributedString(value)
                piece.font = Theme.Typography.mono(12)
                piece.foregroundColor = bodyColor
                result.append(piece)
            }
        }
    }

    /// 成对 ASCII 直引号归一为中文引号「」（未配对的单个 " 保留原样）。
    static func normalizeQuotes(_ text: String) -> String {
        guard text.contains("\"") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var isOpen = false
        var remaining = text[...]
        while let first = remaining.first {
            let after = remaining.dropFirst()
            if first == "\"" {
                if !isOpen, after.contains("\"") {
                    result.append("「")
                    isOpen = true
                } else if isOpen {
                    result.append("」")
                    isOpen = false
                } else {
                    result.append(first)
                }
            } else {
                result.append(first)
            }
            remaining = after
        }
        return result
    }
}
