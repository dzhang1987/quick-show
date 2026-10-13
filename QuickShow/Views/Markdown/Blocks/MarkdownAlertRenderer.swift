import SwiftUI

// MARK: - GitHub 风格提示卡片（Alerts）渲染器

final class MarkdownAlertRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .alert = block { return true }
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
        guard case let .alert(kind, blocks) = block else { return AnyView(EmptyView()) }
        return AnyView(MarkdownAlertView(kind: kind, blocks: blocks))
    }
}

// MARK: - 独立 Alert 视图

struct MarkdownAlertView: View {
    let kind: MarkdownAlertKind
    let blocks: [MarkdownBlock]

    init(kind: MarkdownAlertKind, blocks: [MarkdownBlock]) {
        self.kind = kind
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: iconName)
                    .font(Theme.Typography.text(12.5, .semibold))
                Text(title)
                    .font(Theme.Typography.text(12.5, .semibold))
            }
            .foregroundColor(tintColor)

            if !blocks.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                        MarkdownBlockView(block: child)
                    }
                }
            }
        }
        .padding(.leading, Theme.Spacing.xl + 3)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tintColor.opacity(0.85))
                .frame(width: 3)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .fill(tintColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .stroke(tintColor.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var title: String {
        switch kind {
        case .note: return "Note"
        case .tip: return "Tip"
        case .important: return "Important"
        case .warning: return "Warning"
        case .caution: return "Caution"
        }
    }

    private var iconName: String {
        switch kind {
        case .note: return "info.circle.fill"
        case .tip: return "lightbulb.fill"
        case .important: return "exclamationmark.bubble.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .caution: return "exclamationmark.octagon.fill"
        }
    }

    private var tintColor: Color {
        switch kind {
        case .note: return Color(nsColor: .systemBlue)
        case .tip: return Color(nsColor: .systemGreen)
        case .important: return Color(nsColor: .systemPurple)
        case .warning: return Color(nsColor: .systemOrange)
        case .caution: return Color(nsColor: .systemRed)
        }
    }
}
