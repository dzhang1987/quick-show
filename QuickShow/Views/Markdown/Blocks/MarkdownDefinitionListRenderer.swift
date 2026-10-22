import SwiftUI
import AppKit

// MARK: - 定义列表（Definition List）渲染器

final class MarkdownDefinitionListRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .definitionList = block { return true }
        return false
    }

    func capabilities(for block: MarkdownBlock) -> BlockCapabilities {
        guard case let .definitionList(items) = block else { return .interactiveWidget }
        let allSimple = items.allSatisfy { item in
            !item.term.containsImage && !item.term.containsMath && !item.term.containsRuby &&
            item.definitions.allSatisfy { def in
                !def.containsImage && !def.containsMath && !def.containsRuby
            }
        }
        return allSimple ? .textFlowCompatible : .interactiveWidget
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
        guard case let .definitionList(items) = block else { return }
        let termFont = MarkdownInlineNS.font(size: 13, weight: .semibold)
        let defFont = MarkdownInlineNS.font(size: 13, weight: .regular)
        let defColor = MarkdownInlineNS.adaptiveLabel(opacity: 0.80)

        for (itemIndex, item) in items.enumerated() {
            let isLastItem = itemIndex == items.count - 1

            // 1. 术语（加粗）
            let termRender = MarkdownInlineNS.renderNS(
                item.term,
                baseFont: termFont,
                baseColor: .labelColor,
                baseSize: 13
            )
            let termPiece = NSMutableAttributedString(attributedString: termRender.attributed)
            termPiece.append(NSAttributedString(string: "\n", attributes: [.font: termFont, .foregroundColor: NSColor.labelColor]))
            let termStyle = NSMutableParagraphStyle()
            termStyle.lineSpacing = 3
            termStyle.paragraphSpacing = 4
            termPiece.addAttribute(.paragraphStyle, value: termStyle, range: NSRange(location: 0, length: termPiece.length))
            result.append(termPiece)

            // 2. 释义列表
            for (defIndex, def) in item.definitions.enumerated() {
                let isLastDef = defIndex == item.definitions.count - 1
                let defPiece = NSMutableAttributedString(
                    string: "•\t",
                    attributes: [
                        .font: MarkdownInlineNS.font(size: 12, weight: .medium),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                )
                let defRender = MarkdownInlineNS.renderNS(
                    def,
                    baseFont: defFont,
                    baseColor: defColor,
                    baseSize: 13
                )
                defPiece.append(defRender.attributed)
                defPiece.append(NSAttributedString(string: "\n", attributes: [.font: defFont, .foregroundColor: defColor]))

                let defStyle = NSMutableParagraphStyle()
                defStyle.lineSpacing = 4
                defStyle.firstLineHeadIndent = 16
                defStyle.headIndent = 26
                defStyle.tabStops = [NSTextTab(textAlignment: .left, location: 26)]
                if isLastDef {
                    defStyle.paragraphSpacing = isLastItem ? (nextBlock != nil ? 14 : 0) : 10
                } else {
                    defStyle.paragraphSpacing = 4
                }
                defPiece.addAttribute(.paragraphStyle, value: defStyle, range: NSRange(location: 0, length: defPiece.length))
                result.append(defPiece)
            }
        }
    }

    func renderWidget(block: MarkdownBlock, context: MarkdownRenderContext) -> AnyView {
        guard case let .definitionList(items) = block else { return AnyView(EmptyView()) }
        return AnyView(MarkdownDefinitionListView(items: items))
    }
}

// MARK: - 独立定义列表视图

struct MarkdownDefinitionListView: View {
    let items: [MarkdownDefinitionItem]

    init(items: [MarkdownDefinitionItem]) {
        self.items = items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    MarkdownInlineText(
                        inlines: item.term,
                        bodyColor: Theme.Colors.contentPrimary,
                        baseSize: 13,
                        weight: .semibold,
                        explicitColor: Theme.Colors.contentPrimary
                    )
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        ForEach(Array(item.definitions.enumerated()), id: \.offset) { _, def in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                                Text("•")
                                    .font(Theme.Typography.text(12, .semibold))
                                    .foregroundColor(Theme.Colors.contentTertiary)
                                MarkdownInlineText(inlines: def)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.leading, Theme.Spacing.xl)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
