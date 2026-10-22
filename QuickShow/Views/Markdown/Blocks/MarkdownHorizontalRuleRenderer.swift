import SwiftUI
import AppKit

// MARK: - 水平分隔线渲染器

final class MarkdownHorizontalRuleRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .horizontalRule = block { return true }
        return false
    }

    func capabilities(for block: MarkdownBlock) -> BlockCapabilities {
        .textFlowCompatible
    }

    func topSpacing(for block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat? {
        if let prev = previous, case .heading = prev { return Theme.Spacing.lg }
        return Theme.Spacing.card
    }

    func appendTextFlow(
        block: MarkdownBlock,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString,
        context: MarkdownRenderContext
    ) {
        // 使用零宽空格 + 换行符作为排版锚点，驱动 FlowLayoutManager 绘制水平居中细线，
        // 消除独立 Widget 岛屿阻断，实现前后正文的连贯划词拖选
        let piece = NSMutableAttributedString(
            string: "\u{200B}\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 4),
                .flowHorizontalRule: true
            ]
        )
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = nextBlock != nil ? 14 : 0
        style.lineSpacing = 10
        piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
        result.append(piece)
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
