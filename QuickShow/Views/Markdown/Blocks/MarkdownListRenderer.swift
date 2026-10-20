import SwiftUI
import AppKit

// MARK: - 列表渲染器

final class MarkdownListRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        switch block {
        case .orderedList, .unorderedList: return true
        default: return false
        }
    }

    func capabilities(for block: MarkdownBlock) -> BlockCapabilities {
        switch block {
        case let .orderedList(items), let .unorderedList(items):
            if items.allSatisfy({ isListItemTextFlowCompatible($0) }) {
                return .textFlowCompatible
            }
            return .interactiveWidget
        default:
            return .interactiveWidget
        }
    }

    private func isListItemTextFlowCompatible(_ item: MarkdownListItem) -> Bool {
        var paragraphCount = 0
        return item.blocks.allSatisfy { block in
            switch block {
            case let .paragraph(inlines):
                paragraphCount += 1
                return paragraphCount <= 1 && !inlines.containsImage && !inlines.containsMath && !inlines.containsRuby
            case let .orderedList(subItems), let .unorderedList(subItems):
                return subItems.allSatisfy { isListItemTextFlowCompatible($0) }
            default:
                return false
            }
        }
    }

    func topSpacing(for block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat? {
        if let prev = previous, case .heading = prev {
            return Theme.Spacing.lg
        }
        return Theme.Spacing.card
    }

    func appendTextFlow(
        block: MarkdownBlock,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString,
        context: MarkdownRenderContext
    ) {
        let startIndex = result.length
        switch block {
        case let .orderedList(items):
            appendList(items: items, ordered: true, depth: 0, hasNextListItem: false, nextBlock: nextBlock, into: result)
        case let .unorderedList(items):
            appendList(items: items, ordered: false, depth: 0, hasNextListItem: false, nextBlock: nextBlock, into: result)
        default:
            break
        }
        // 当整个列表块为连续文本流最后一块（nextBlock == nil）时，收敛末尾多余换行符，避免底部多出一行空白
        if nextBlock == nil, result.length > startIndex, result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
    }

    func renderWidget(block: MarkdownBlock, context: MarkdownRenderContext) -> AnyView {
        switch block {
        case let .orderedList(items):
            return AnyView(MarkdownListView(items: items, ordered: true))
        case let .unorderedList(items):
            return AnyView(MarkdownListView(items: items, ordered: false))
        default:
            return AnyView(EmptyView())
        }
    }

    // MARK: - TextKit 精密列表排版拼装

    private func appendList(
        items: [MarkdownListItem],
        ordered: Bool,
        depth: Int,
        hasNextListItem: Bool,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString
    ) {
        for (idx, item) in items.enumerated() {
            let isLastInCurrentList = (idx == items.count - 1)
            let itemHasNextListItem = !isLastInCurrentList || hasNextListItem
            let itemNextBlock = (isLastInCurrentList && !hasNextListItem) ? nextBlock : nil
            appendListItem(
                item: item,
                ordered: ordered,
                depth: depth,
                hasNextListItem: itemHasNextListItem,
                nextBlock: itemNextBlock,
                into: result
            )
        }
    }

    private func appendListItem(
        item: MarkdownListItem,
        ordered: Bool,
        depth: Int,
        hasNextListItem: Bool,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString
    ) {
        let itemPiece = NSMutableAttributedString()

        // 1. 前导标号与制表符（\t 实现精准两列对齐）
        let prefixText: String
        let prefixFont: NSFont
        let prefixColor: NSColor
        var baselineOffset: CGFloat = 0

        if let state = item.taskState {
            prefixText = (state ? "✓" : "○") + "\t"
            prefixFont = MarkdownInlineNS.font(size: 12.5, weight: .medium)
            prefixColor = state ? MarkdownInlineNS.accentColor : NSColor.tertiaryLabelColor
        } else if ordered {
            prefixText = "\(item.number ?? 1).\t"
            prefixFont = MarkdownInlineNS.monoFont(size: 12)
            prefixColor = NSColor.secondaryLabelColor
        } else {
            prefixText = (depth == 0 ? "•" : "◦") + "\t"
            prefixFont = MarkdownInlineNS.font(size: 12, weight: .medium)
            prefixColor = NSColor.secondaryLabelColor
            if depth == 0 && item.taskState == nil {
                baselineOffset = 0.5
            }
        }

        var prefixAttrs: [NSAttributedString.Key: Any] = [
            .font: prefixFont,
            .foregroundColor: prefixColor,
        ]
        if baselineOffset != 0 {
            prefixAttrs[.baselineOffset] = baselineOffset
        }
        itemPiece.append(NSAttributedString(string: prefixText, attributes: prefixAttrs))

        // 2. 正文内容
        let bodyOpacity: CGFloat = item.taskState == true ? 0.55 : 0.80
        var subLists: [(items: [MarkdownListItem], ordered: Bool)] = []

        let bodyFont = MarkdownInlineNS.font(size: 13, weight: .regular)
        let bodyColor = MarkdownInlineNS.adaptiveLabel(opacity: bodyOpacity)

        for block in item.blocks {
            switch block {
            case let .paragraph(inlines):
                let bodyRender = MarkdownInlineNS.renderNS(
                    inlines,
                    baseFont: bodyFont,
                    baseColor: bodyColor,
                    baseSize: 13
                )
                itemPiece.append(bodyRender.attributed)
            case let .orderedList(subItems):
                subLists.append((subItems, true))
            case let .unorderedList(subItems):
                subLists.append((subItems, false))
            default:
                break
            }
        }

        // 每个列表条目自身在 TextKit 中均为独立段落，末尾始终保留换行符隔离
        itemPiece.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))

        // 3. 悬挂缩进 + NSTextTab 精准两列对齐
        let baseIndent: CGFloat = CGFloat(depth) * 22
        let hangingOffset: CGFloat = item.taskState != nil ? 20 : (ordered ? 24 : 18)
        let hangingIndent: CGFloat = baseIndent + hangingOffset

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        style.firstLineHeadIndent = baseIndent
        style.headIndent = hangingIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: hangingIndent)]

        if !subLists.isEmpty {
            style.paragraphSpacing = 8
        } else if hasNextListItem {
            style.paragraphSpacing = 14
        } else if let next = nextBlock {
            if case .heading = next {
                style.paragraphSpacing = 22
            } else {
                style.paragraphSpacing = 16
            }
        } else {
            style.paragraphSpacing = 0
        }

        itemPiece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: itemPiece.length))
        result.append(itemPiece)

        // 4. 递归追加子列表
        for (sIdx, sub) in subLists.enumerated() {
            let isLastSub = sIdx == subLists.count - 1
            let subHasNextListItem = !isLastSub || hasNextListItem
            let subNextBlock = (isLastSub && !hasNextListItem) ? nextBlock : nil
            appendList(
                items: sub.items,
                ordered: sub.ordered,
                depth: depth + 1,
                hasNextListItem: subHasNextListItem,
                nextBlock: subNextBlock,
                into: result
            )
        }
    }
}

// MARK: - 独立 SwiftUI 列表视图

struct MarkdownListView: View {
    let items: [MarkdownListItem]
    let ordered: Bool
    var depth: Int = 0

    init(items: [MarkdownListItem], ordered: Bool, depth: Int = 0) {
        self.items = items
        self.ordered = ordered
        self.depth = depth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                MarkdownListItemRow(item: item, ordered: ordered, depth: depth)
            }
        }
    }
}

struct MarkdownListItemRow: View {
    let item: MarkdownListItem
    let ordered: Bool
    var depth: Int = 0

    private static let nestedIndent: CGFloat = 22

    init(item: MarkdownListItem, ordered: Bool, depth: Int = 0) {
        self.item = item
        self.ordered = ordered
        self.depth = depth
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
            marker
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                    itemBlock(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(item.taskState == true ? 0.55 : 1)
        }
    }

    @ViewBuilder
    private var marker: some View {
        if let state = item.taskState {
            Image(systemName: state ? "checkmark.circle.fill" : "circle")
                .font(Theme.Typography.text(12.5, .medium))
                .foregroundColor(state ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                .frame(minWidth: 14, alignment: .trailing)
        } else if ordered {
            Text("\(item.number ?? 1).")
                .font(Theme.Typography.mono(12))
                .foregroundColor(Theme.Colors.contentTertiary)
                .frame(minWidth: 14, alignment: .trailing)
        } else {
            Text(depth == 0 ? "•" : "◦")
                .font(Theme.Typography.text(13, .medium))
                .foregroundColor(Theme.Colors.contentTertiary)
                .frame(minWidth: 14, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func itemBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .orderedList(items):
            MarkdownListView(items: items, ordered: true, depth: depth + 1)
                .padding(.leading, Self.nestedIndent)
        case let .unorderedList(items):
            MarkdownListView(items: items, ordered: false, depth: depth + 1)
                .padding(.leading, Self.nestedIndent)
        default:
            MarkdownBlockView(block: block)
        }
    }
}
