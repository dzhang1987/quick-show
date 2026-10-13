import SwiftUI

// MARK: - 水平分隔线渲染器

final class MarkdownHorizontalRuleRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .horizontalRule = block { return true }
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
        AnyView(
            Rectangle()
                .fill(Theme.Colors.cardStroke)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Theme.Layout.dividerHeight)
        )
    }
}
