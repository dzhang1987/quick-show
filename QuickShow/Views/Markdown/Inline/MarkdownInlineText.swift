import SwiftUI

// MARK: - SwiftUI 统一行内入口

/// 行内文本统一入口：
/// - 含顶层图片：按「文本段 / 图片项」交替拆段，文本段递归走下方双路径，图片项交给
///   `MarkdownImageView`，整体 `VStack(leading)` 顺序排列；
/// - 含公式（含嵌套在粗体/斜体/链接等内的公式）：NSTextField + NSTextAttachment 路径（MathParagraphView）；
/// - 含东亚注音：RubyParagraphView；
/// - 其余：原 SwiftUI AttributedString 路径。
struct MarkdownInlineText: View {
    let inlines: [InlineToken]
    var bodyColor: Color = Color.primary.opacity(0.80)
    var baseSize: CGFloat = 13
    var weight: Font.Weight = .regular
    var explicitColor: Color? = nil

    init(
        inlines: [InlineToken],
        bodyColor: Color = Color.primary.opacity(0.80),
        baseSize: CGFloat = 13,
        weight: Font.Weight = .regular,
        explicitColor: Color? = nil
    ) {
        self.inlines = inlines
        self.bodyColor = bodyColor
        self.baseSize = baseSize
        self.weight = weight
        self.explicitColor = explicitColor
    }

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
        } else if inlines.containsRuby {
            RubyParagraphView(
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
        let base = Text(MarkdownInline.render(inlines, bodyColor: bodyColor, size: baseSize, baseWeight: weight))
        if let explicitColor {
            base.foregroundColor(explicitColor)
        } else {
            base
        }
    }
}
