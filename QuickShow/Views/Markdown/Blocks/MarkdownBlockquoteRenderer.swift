import SwiftUI

// MARK: - 引用块渲染器

final class MarkdownBlockquoteRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .blockquote = block { return true }
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
        guard case let .blockquote(blocks) = block else { return AnyView(EmptyView()) }
        return AnyView(MarkdownBlockquoteView(blocks: blocks))
    }
}

// MARK: - 独立引用块视图

struct MarkdownBlockquoteView: View {
    let blocks: [MarkdownBlock]

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                MarkdownBlockView(block: child)
            }
        }
        .foregroundColor(Theme.Colors.contentSecondaryStrong)
        .padding(.leading, Theme.Spacing.xl + 3)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.Colors.accent.opacity(0.80), Theme.Colors.accent.opacity(0.50)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 3)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .fill(Theme.Colors.surfaceBadge)
        )
    }
}
