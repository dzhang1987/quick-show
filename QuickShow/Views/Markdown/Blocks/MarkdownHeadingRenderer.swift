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
        guard case let .heading(_, inlines) = block else { return .interactiveWidget }
        // H1 ~ H6 纯排版标题在无复杂内联（图片、注音）时可无缝并入连续 TextKit 文本流，
        // 保持与正文连贯框选复制。各级标题依靠字号、字重与段落留白塑造视觉层级。
        if !inlines.containsImage && !inlines.containsRuby {
            return .textFlowCompatible
        }
        return .interactiveWidget
    }

    func topSpacing(for block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat? {
        guard case let .heading(level, _) = block else { return nil }
        if let prev = previous, case .heading = prev {
            return 18 // 连续标题间距：保留从容呼吸感，彻底消除挤压踩踏
        }
        switch level {
        case 1: return 28 // 顶层大标题大呼吸
        case 2: return 24 // 二级章节
        case 3: return 20 // 三级常用小节（拉开与前文距离）
        case 4: return 16 // 四级要点
        case 5: return 14
        default: return 12
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
            case 1: return (20, .bold)
            case 2: return (17.5, .bold)
            case 3: return (15.5, .bold)
            case 4: return (14, .semibold)
            case 5: return (13.5, .semibold)
            default: return (13, .semibold)
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
        style.lineSpacing = level <= 2 ? 4 : 3
        if let next = nextBlock {
            if case .heading = next {
                // 连续标题：必须留足大标题间距（16~22pt），彻底消除挤压
                style.paragraphSpacing = level == 1 ? 22 : (level <= 3 ? 18 : 16)
            } else {
                // 亲密性原则：紧随正文/列表时贴近下文（7pt/6pt），与上方大留白形成清晰模块感
                style.paragraphSpacing = level == 1 ? 12 : (level <= 3 ? 7 : 6)
            }
        } else {
            style.paragraphSpacing = 0
        }
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
            headingText(size: 20, weight: .bold)
        case 2:
            headingText(size: 17.5, weight: .bold)
        case 3:
            headingText(size: 15.5, weight: .bold)
        case 4:
            headingText(size: 14, weight: .semibold)
        case 5:
            headingText(size: 13.5, weight: .semibold)
        default:
            headingText(size: 13, weight: .semibold)
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
