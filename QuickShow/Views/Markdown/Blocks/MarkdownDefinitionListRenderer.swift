import SwiftUI

// MARK: - 定义列表（Definition List）渲染器

final class MarkdownDefinitionListRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .definitionList = block { return true }
        return false
    }

    func capabilities(for block: MarkdownBlock) -> BlockCapabilities {
        .interactiveWidget
    }

    func topSpacing(for block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat? {
        if let prev = previous, case .heading = prev { return Theme.Spacing.lg }
        return Theme.Spacing.card
    }

    func renderWidget(block: MarkdownBlock, context: MarkdownRenderContext) -> AnyView {
        guard case let .definitionList(items) = block else { return AnyView(EmptyView()) }
        return AnyView(MarkdownDefinitionListView(items: items))
    }
}

// MARK: - 独立定义列表视图

struct MarkdownDefinitionListView: View {
    let items: [MarkdownDefinitionItem]

    init(items: [MarkdownDefinitionItem]) {
        self.items = items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    MarkdownInlineText(
                        inlines: item.term,
                        bodyColor: Theme.Colors.contentPrimary,
                        baseSize: 13,
                        weight: .semibold,
                        explicitColor: Theme.Colors.contentPrimary
                    )
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        ForEach(Array(item.definitions.enumerated()), id: \.offset) { _, def in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                                Text("•")
                                    .font(Theme.Typography.text(12, .semibold))
                                    .foregroundColor(Theme.Colors.contentTertiary)
                                MarkdownInlineText(inlines: def)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.leading, Theme.Spacing.xl)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
