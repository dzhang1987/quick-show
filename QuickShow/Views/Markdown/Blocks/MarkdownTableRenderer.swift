import SwiftUI

// MARK: - 表格渲染器

final class MarkdownTableRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .table = block { return true }
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
        guard case let .table(table) = block else { return AnyView(EmptyView()) }
        return AnyView(MarkdownTableView(table: table))
    }
}
