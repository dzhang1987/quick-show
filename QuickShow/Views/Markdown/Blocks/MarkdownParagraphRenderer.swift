import SwiftUI
import AppKit

// MARK: - 段落渲染器

final class MarkdownParagraphRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .paragraph = block { return true }
        return false
    }

    func capabilities(for block: MarkdownBlock) -> BlockCapabilities {
        guard case let .paragraph(inlines) = block else { return .interactiveWidget }
        if !inlines.containsImage && !inlines.containsMath && !inlines.containsRuby {
            return .textFlowCompatible
        }
        return .interactiveWidget
    }

    func topSpacing(for block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat? {
        if let prev = previous, case .heading = prev {
            return Theme.Spacing.lg // 8: 紧随标题
        }
        return Theme.Spacing.card // 16: 段落间距
    }

    func appendTextFlow(
        block: MarkdownBlock,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString,
        context: MarkdownRenderContext
    ) {
        guard case let .paragraph(inlines) = block else { return }
        let baseFont = MarkdownInlineNS.font(size: 13, weight: .regular)
        let baseColor = MarkdownInlineNS.adaptiveLabel(opacity: 0.80)
        let render = MarkdownInlineNS.renderNS(
            inlines,
            baseFont: baseFont,
            baseColor: baseColor,
            baseSize: 13
        )
        let paraPiece = NSMutableAttributedString(attributedString: render.attributed)

        let hasNext = nextBlock != nil
        if hasNext {
            paraPiece.append(NSAttributedString(string: "\n", attributes: [.font: baseFont, .foregroundColor: baseColor]))
        }

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        if let next = nextBlock {
            if case .heading = next {
                style.paragraphSpacing = 18
            } else {
                style.paragraphSpacing = 12
            }
        } else {
            style.paragraphSpacing = 0
        }
        paraPiece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paraPiece.length))

        result.append(paraPiece)
    }

    func renderWidget(block: MarkdownBlock, context: MarkdownRenderContext) -> AnyView {
        guard case let .paragraph(inlines) = block else { return AnyView(EmptyView()) }
        return AnyView(
            MarkdownInlineText(inlines: inlines)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        )
    }
}
