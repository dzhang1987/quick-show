import SwiftUI

// MARK: - 代码块与 Mermaid 图表渲染器

final class MarkdownCodeBlockRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .codeBlock = block { return true }
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
        guard case let .codeBlock(language, code) = block else { return AnyView(EmptyView()) }
        if isMermaid(language) {
            return AnyView(MermaidBlockView(code: code))
        } else {
            return AnyView(CodeBlockView(language: language, code: code))
        }
    }

    private func isMermaid(_ language: String?) -> Bool {
        guard let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return lang == "mermaid"
    }
}
