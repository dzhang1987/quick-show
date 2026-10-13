import Combine
import SwiftUI

// 由 AIChatMarkdownView.swift 拆出：SwiftUI 行内 token 渲染（MarkdownInline）。

// MARK: - 行内渲染

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
                // 2026-10 重设计：底色 0.06→0.10（比面板亮一档，旧值在玻璃上近乎隐形），
                // 字色 0.80→主文字色，字重 medium——行内代码 chip 对比度与可读性提升，一眼可辨
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
                // 半透明强调色高亮（alpha 0.15，2026-10 重设计自 0.18 收敛降噪；
                // 与 AppKit 路径 MarkdownInlineNS 对齐）
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
                // 镜像 AppKit 路径 MarkdownInlineNS：上标小字号 -2、baseline +3。
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

            case let .link(label, url, _):
                // title 无视觉变化，忽略。
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
                // 防御性兜底：正常情况下含图片段落会在 MarkdownInlineText 层被拆段，
                // 不会进入此处；以纯文本渲染 alt 保险。
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
                // SwiftUI AttributedString 无法内嵌图片；含公式的路径统一改走 MarkdownInlineNS。
                // 此处仅作兜底：以等宽文本显示原始 LaTeX（正常渲染不会触达）。
                var piece = AttributedString(value)
                piece.font = Theme.Typography.mono(12)
                piece.foregroundColor = bodyColor
                result.append(piece)
            }
        }
    }

    /// 成对 ASCII 直引号归一为中文引号「」（未配对的单个 " 保留原样）。
    /// 仅供显示层调用（text token 与流式纯文本），绝不触碰行内代码/代码块/链接 URL；
    /// 不改原始文本，复制/重发内容不受影响。
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
                    result.append("「")   // 存在后续配对：开引号
                    isOpen = true
                } else if isOpen {
                    result.append("」")   // 处于开引状态：合引号
                    isOpen = false
                } else {
                    result.append(first)  // 未配对的单个 "，原样保留
                }
            } else {
                result.append(first)
            }
            remaining = after
        }
        return result
    }
}
