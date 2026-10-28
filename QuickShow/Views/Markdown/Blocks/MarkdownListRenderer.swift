import SwiftUI
import AppKit

// MARK: - 任务列表复选框 Attachment

/// 继承自 NSTextAttachment，重写 isEqual 和 hash，具备值语义判等防线。
/// 确保在 TextKit 文本流中完美呈现高保真原生方形复选框（Checkbox），杜绝圆圈与单选混淆。
final class TaskCheckboxAttachment: NSTextAttachment {
    let checked: Bool
    let isDark: Bool
    let pointSize: CGFloat

    init(checked: Bool, isDark: Bool, pointSize: CGFloat = 12.5) {
        self.checked = checked
        self.isDark = isDark
        self.pointSize = pointSize
        super.init(data: nil, ofType: nil)

        let symbolName = checked ? "checkmark.square.fill" : "square"
        let baseConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: checked ? MarkdownInlineNS.accentColor : NSColor.tertiaryLabelColor)
        let config = baseConfig.applying(colorConfig)

        self.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: checked ? "已完成" : "未完成")?.withSymbolConfiguration(config)
        // 与 13pt 正文文本基线垂直居中微调（向下平移 2pt）
        self.bounds = CGRect(x: 0, y: -2.0, width: pointSize + 0.5, height: pointSize + 0.5)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TaskCheckboxAttachment else { return false }
        return checked == other.checked && isDark == other.isDark && abs(pointSize - other.pointSize) < 0.1
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(checked)
        hasher.combine(isDark)
        hasher.combine(Int(pointSize * 10))
        return hasher.finalize()
    }
}

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
        return item.blocks.allSatisfy { block in
            switch block {
            case let .paragraph(inlines):
                return !inlines.containsImage && !inlines.containsRuby
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
            appendList(items: items, ordered: true, depth: 0, parentPrefix: nil, hasNextListItem: false, nextBlock: nextBlock, into: result, context: context)
        case let .unorderedList(items):
            appendList(items: items, ordered: false, depth: 0, parentPrefix: nil, hasNextListItem: false, nextBlock: nextBlock, into: result, context: context)
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
        parentPrefix: String?,
        hasNextListItem: Bool,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString,
        context: MarkdownRenderContext
    ) {
        for (idx, item) in items.enumerated() {
            let isLastInCurrentList = (idx == items.count - 1)
            let itemHasNextListItem = !isLastInCurrentList || hasNextListItem
            let itemNextBlock = (isLastInCurrentList && !hasNextListItem) ? nextBlock : nil

            let numberLabel: String?
            let currentPrefixForChildren: String?
            if ordered {
                let currentNum = item.number ?? (idx + 1)
                if let parent = parentPrefix, !parent.isEmpty {
                    let cleanParent = parent.hasSuffix(".") ? String(parent.dropLast()) : parent
                    let fullLabel = "\(cleanParent).\(currentNum)"
                    numberLabel = fullLabel
                    currentPrefixForChildren = fullLabel
                } else {
                    numberLabel = "\(currentNum)."
                    currentPrefixForChildren = "\(currentNum)"
                }
            } else {
                numberLabel = nil
                currentPrefixForChildren = nil
            }

            appendListItem(
                item: item,
                ordered: ordered,
                depth: depth,
                numberLabel: numberLabel,
                currentPrefixForChildren: currentPrefixForChildren,
                hasNextListItem: itemHasNextListItem,
                nextBlock: itemNextBlock,
                into: result,
                context: context
            )
        }
    }

    private func appendListItem(
        item: MarkdownListItem,
        ordered: Bool,
        depth: Int,
        numberLabel: String?,
        currentPrefixForChildren: String?,
        hasNextListItem: Bool,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString,
        context: MarkdownRenderContext
    ) {
        let itemPiece = NSMutableAttributedString()

        // 1. 前导标号与制表符（\t 实现精准两列对齐）
        var baselineOffset: CGFloat = 0
        var labelWidth: CGFloat = 0

        if let state = item.taskState {
            let attachment = TaskCheckboxAttachment(checked: state, isDark: context.isDark, pointSize: 12.5)
            itemPiece.append(NSAttributedString(attachment: attachment))
            itemPiece.append(NSAttributedString(string: "\t", attributes: [.font: MarkdownInlineNS.font(size: 13, weight: .regular)]))
            labelWidth = 13.5
        } else if ordered {
            let label = numberLabel ?? "\(item.number ?? 1)."
            let prefixText = "\(label)\t"
            let prefixFont = MarkdownInlineNS.monoFont(size: 12)
            let prefixColor = NSColor.secondaryLabelColor
            let prefixAttrs: [NSAttributedString.Key: Any] = [
                .font: prefixFont,
                .foregroundColor: prefixColor,
            ]
            itemPiece.append(NSAttributedString(string: prefixText, attributes: prefixAttrs))
            labelWidth = ceil((label as NSString).size(withAttributes: [.font: prefixFont]).width)
        } else {
            let symbol: String
            let prefixFont: NSFont
            let prefixColor: NSColor
            switch depth {
            case 0:
                symbol = "•"
                prefixFont = MarkdownInlineNS.font(size: 13.5, weight: .semibold)
                prefixColor = MarkdownInlineNS.adaptiveLabel(opacity: 0.70)
                baselineOffset = 1.2
            case 1:
                symbol = "◦"
                prefixFont = MarkdownInlineNS.font(size: 10.5, weight: .regular)
                prefixColor = MarkdownInlineNS.adaptiveLabel(opacity: 0.55)
                baselineOffset = 1.2
            default:
                symbol = "–"
                prefixFont = MarkdownInlineNS.font(size: 11.0, weight: .medium)
                prefixColor = MarkdownInlineNS.adaptiveLabel(opacity: 0.45)
                baselineOffset = 1.0
            }
            let prefixText = "\(symbol)\t"
            var prefixAttrs: [NSAttributedString.Key: Any] = [
                .font: prefixFont,
                .foregroundColor: prefixColor,
            ]
            if baselineOffset != 0 {
                prefixAttrs[.baselineOffset] = baselineOffset
            }
            itemPiece.append(NSAttributedString(string: prefixText, attributes: prefixAttrs))
            labelWidth = ceil((symbol as NSString).size(withAttributes: [.font: prefixFont]).width)
        }

        // 2. 正文内容
        let bodyOpacity: CGFloat = item.taskState == true ? 0.55 : 0.82
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
        let baseIndent: CGFloat = CGFloat(depth) * 16
        let minGap: CGFloat = 8
        let defaultOffset: CGFloat = item.taskState != nil ? 18 : (ordered ? 22 : 18)
        let hangingOffset: CGFloat = max(defaultOffset, labelWidth + minGap)
        let hangingIndent: CGFloat = baseIndent + hangingOffset

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5.5
        style.firstLineHeadIndent = baseIndent
        style.headIndent = hangingIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: hangingIndent)]

        if !subLists.isEmpty {
            style.paragraphSpacing = 4
        } else if hasNextListItem {
            style.paragraphSpacing = 7.5 // 适度放宽间距，多行列表项具备呼吸感
        } else if let next = nextBlock {
            if case .heading = next {
                style.paragraphSpacing = 20
            } else {
                style.paragraphSpacing = 12
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
            let subParentPrefix: String? = (sub.ordered && ordered && item.taskState == nil) ? currentPrefixForChildren : nil
            appendList(
                items: sub.items,
                ordered: sub.ordered,
                depth: depth + 1,
                parentPrefix: subParentPrefix,
                hasNextListItem: subHasNextListItem,
                nextBlock: subNextBlock,
                into: result,
                context: context
            )
        }
    }
}

// MARK: - 独立 SwiftUI 列表视图

struct MarkdownListView: View {
    let items: [MarkdownListItem]
    let ordered: Bool
    var depth: Int = 0
    var parentPrefix: String? = nil

    init(items: [MarkdownListItem], ordered: Bool, depth: Int = 0, parentPrefix: String? = nil) {
        self.items = items
        self.ordered = ordered
        self.depth = depth
        self.parentPrefix = parentPrefix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                let currentNum = item.number ?? (idx + 1)
                let numberLabel: String? = {
                    guard ordered else { return nil }
                    if let parent = parentPrefix, !parent.isEmpty {
                        let cleanParent = parent.hasSuffix(".") ? String(parent.dropLast()) : parent
                        return "\(cleanParent).\(currentNum)"
                    } else {
                        return "\(currentNum)."
                    }
                }()
                let childPrefix: String? = {
                    guard ordered else { return nil }
                    if let parent = parentPrefix, !parent.isEmpty {
                        let cleanParent = parent.hasSuffix(".") ? String(parent.dropLast()) : parent
                        return "\(cleanParent).\(currentNum)"
                    } else {
                        return "\(currentNum)"
                    }
                }()

                MarkdownListItemRow(
                    item: item,
                    ordered: ordered,
                    depth: depth,
                    numberLabel: numberLabel,
                    childPrefix: childPrefix
                )
            }
        }
    }
}

struct MarkdownListItemRow: View {
    let item: MarkdownListItem
    let ordered: Bool
    var depth: Int = 0
    var numberLabel: String? = nil
    var childPrefix: String? = nil

    private static let nestedIndent: CGFloat = 16

    init(
        item: MarkdownListItem,
        ordered: Bool,
        depth: Int = 0,
        numberLabel: String? = nil,
        childPrefix: String? = nil
    ) {
        self.item = item
        self.ordered = ordered
        self.depth = depth
        self.numberLabel = numberLabel
        self.childPrefix = childPrefix
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
            Image(systemName: state ? "checkmark.square.fill" : "square")
                .font(Theme.Typography.text(12.5, .medium))
                .foregroundColor(state ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                .frame(minWidth: 14, alignment: .trailing)
        } else if ordered {
            Text(numberLabel ?? "\(item.number ?? 1).")
                .font(Theme.Typography.mono(12))
                .foregroundColor(Theme.Colors.contentTertiary)
                .frame(minWidth: 14, alignment: .trailing)
        } else {
            let (symbol, fontSize, fontWeight, opacity): (String, CGFloat, Font.Weight, Double) = {
                switch depth {
                case 0: return ("•", 13.5, .semibold, 0.70)
                case 1: return ("◦", 10.5, .regular, 0.55)
                default: return ("–", 11.0, .medium, 0.45)
                }
            }()
            Text(symbol)
                .font(Theme.Typography.text(fontSize, fontWeight))
                .foregroundColor(Theme.Colors.contentPrimary.opacity(opacity))
                .frame(minWidth: 14, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func itemBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .orderedList(items):
            MarkdownListView(
                items: items,
                ordered: true,
                depth: depth + 1,
                parentPrefix: (ordered && item.taskState == nil) ? childPrefix : nil
            )
            .padding(.leading, Self.nestedIndent)
        case let .unorderedList(items):
            MarkdownListView(
                items: items,
                ordered: false,
                depth: depth + 1
            )
            .padding(.leading, Self.nestedIndent)
        default:
            MarkdownBlockView(block: block)
        }
    }
}
