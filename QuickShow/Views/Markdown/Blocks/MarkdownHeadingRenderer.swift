import SwiftUI
import AppKit

// MARK: - 标题渲染器与视图

final class MarkdownHeadingRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .heading = block { return true }
        return false
    }

    func capabilities(for block: MarkdownBlock) -> BlockCapabilities {
        guard case let .heading(level, inlines) = block else { return .interactiveWidget }
        // H2 ~ H6 纯排版标题在无复杂内联（图片、公式、注音）时可无缝并入连续 TextKit 文本流；
        // H1 带有质感底部分割线 Rectangle，作为独立 widget 渲染以保质感。
        if level >= 2 && !inlines.containsImage && !inlines.containsMath && !inlines.containsRuby {
            return .textFlowCompatible
        }
        return .interactiveWidget
    }

    func topSpacing(for block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat? {
        guard case let .heading(level, _) = block else { return nil }
        if let prev = previous, case .heading = prev {
            return Theme.Spacing.lg // 8: 标题后收紧成组
        }
        switch level {
        case 1: return Theme.Spacing.section + Theme.Spacing.lg // 26
        case 2: return Theme.Spacing.divider                    // 20
        case 3: return Theme.Spacing.card                       // 16
        case 4: return Theme.Spacing.xxxl                       // 14
        case 5: return Theme.Spacing.xxl                        // 12
        default: return Theme.Spacing.xl                        // 10
        }
    }

    func appendTextFlow(
        block: MarkdownBlock,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString,
        context: MarkdownRenderContext
    ) {
        guard case let .heading(level, inlines) = block else { return }
        let (size, weight): (CGFloat, NSFont.Weight) = {
            switch level {
            case 2: return (16, .semibold)
            case 3: return (14, .semibold)
            case 4: return (13, .semibold)
            case 5: return (12.5, .semibold)
            default: return (12, .semibold)
            }
        }()

        let font = MarkdownInlineNS.font(size: size, weight: weight)
        let render = MarkdownInlineNS.renderNS(
            inlines,
            baseFont: font,
            baseColor: .labelColor,
            baseSize: size
        )
        let headingPiece = NSMutableAttributedString(attributedString: render.attributed)

        let hasNext = nextBlock != nil
        if hasNext {
            headingPiece.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = hasNext ? 8 : 0
        headingPiece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: headingPiece.length))

        result.append(headingPiece)
    }

    func renderWidget(block: MarkdownBlock, context: MarkdownRenderContext) -> AnyView {
        guard case let .heading(level, inlines) = block else { return AnyView(EmptyView()) }
        return AnyView(MarkdownHeadingView(level: level, inlines: inlines))
    }
}

// MARK: - 独立标题视图（H1 独立排版及降级展示）

struct MarkdownHeadingView: View {
    let level: Int
    let inlines: [InlineToken]

    var body: some View {
        switch level {
        case 1:
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                headingText(size: 18, weight: .bold)
                Rectangle()
                    .fill(Theme.Colors.cardStroke)
                    .frame(height: Theme.Layout.dividerHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case 2:
            headingText(size: 16, weight: .semibold)
        case 3:
            headingText(size: 14, weight: .semibold)
        case 4:
            headingText(size: 13, weight: .semibold)
        case 5:
            headingText(size: 12.5, weight: .semibold)
        default:
            headingText(size: 12, weight: .semibold)
        }
    }

    private func headingText(size: CGFloat, weight: Font.Weight) -> some View {
        MarkdownInlineText(
            inlines: inlines,
            bodyColor: Theme.Colors.contentPrimary,
            baseSize: size,
            weight: weight,
            explicitColor: Theme.Colors.contentPrimary
        )
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
