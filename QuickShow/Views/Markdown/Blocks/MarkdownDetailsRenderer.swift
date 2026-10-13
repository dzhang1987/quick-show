import SwiftUI

// MARK: - 交互式折叠组件（<details> / <summary>）渲染器

final class MarkdownDetailsRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .details = block { return true }
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
        guard case let .details(summary, blocks, isOpen) = block else { return AnyView(EmptyView()) }
        return AnyView(MarkdownDetailsView(summary: summary, blocks: blocks, defaultOpen: isOpen))
    }
}

// MARK: - 独立 Details 视图

struct MarkdownDetailsView: View {
    let summary: [InlineToken]
    let blocks: [MarkdownBlock]
    let defaultOpen: Bool

    @State private var isExpanded: Bool

    init(summary: [InlineToken], blocks: [MarkdownBlock], defaultOpen: Bool) {
        self.summary = summary
        self.blocks = blocks
        self.defaultOpen = defaultOpen
        self._isExpanded = State(initialValue: defaultOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: Theme.Spacing.lg) {
                    Image(systemName: "chevron.right")
                        .font(Theme.Typography.text(11, .semibold))
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, alignment: .center)
                    MarkdownInlineText(
                        inlines: summary,
                        bodyColor: Theme.Colors.contentPrimary,
                        baseSize: 13,
                        weight: .semibold,
                        explicitColor: Theme.Colors.contentPrimary
                    )
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.lg)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, !blocks.isEmpty {
                Rectangle()
                    .fill(Theme.Colors.cardStroke)
                    .frame(height: Theme.Layout.dividerHeight)
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                        MarkdownBlockView(block: child)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(Theme.Colors.surfaceBadge)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
    }
}
