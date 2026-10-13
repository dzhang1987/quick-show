import SwiftUI

// MARK: - 脚注条目模型

struct MarkdownFootnoteEntry: Equatable {
    let id: String
    let inlines: [InlineToken]

    init(id: String, inlines: [InlineToken]) {
        self.id = id
        self.inlines = inlines
    }
}

// MARK: - 脚注渲染器

final class MarkdownFootnoteRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .footnoteDefinition = block { return true }
        return false
    }

    func capabilities(for block: MarkdownBlock) -> BlockCapabilities {
        .interactiveWidget
    }

    func topSpacing(for block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat? {
        Theme.Spacing.card
    }

    func renderWidget(block: MarkdownBlock, context: MarkdownRenderContext) -> AnyView {
        // 顶层脚注定义由主宿主在文档末尾统一通过 MarkdownFootnoteSection 渲染；
        // 嵌套定义在此处跳过，不在原位置留下多余占位。
        AnyView(EmptyView())
    }
}

// MARK: - 文档末尾脚注聚合区

/// 文档末尾脚注区：细分隔线 + 小字号（11）编号列表（序号 + 定义内容行内渲染）。
struct MarkdownFootnoteSection: View {
    let footnotes: [MarkdownFootnoteEntry]

    init(footnotes: [MarkdownFootnoteEntry]) {
        self.footnotes = footnotes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Rectangle()
                .fill(Theme.Colors.cardStroke)
                .frame(height: Theme.Layout.dividerHeight)
            ForEach(Array(footnotes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                    Text(note.id)
                        .font(Theme.Typography.text(11, .semibold))
                        .foregroundColor(Theme.Colors.accent)
                        .frame(minWidth: 16, alignment: .trailing)
                    MarkdownInlineText(
                        inlines: note.inlines,
                        bodyColor: Theme.Colors.contentTertiary,
                        baseSize: 11
                    )
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
