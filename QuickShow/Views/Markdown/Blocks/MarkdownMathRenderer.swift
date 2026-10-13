import SwiftUI

// MARK: - 块级数学公式渲染器

final class MarkdownMathRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .mathBlock = block { return true }
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
        guard case let .mathBlock(latex) = block else { return AnyView(EmptyView()) }
        return AnyView(
            AsyncMathBlockView(latex: latex, fontSize: 14, color: Theme.Colors.contentPrimary)
        )
    }
}
