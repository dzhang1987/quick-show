import SwiftUI
import AppKit

// MARK: - 混合排版渲染段（Display Segment）

/// 混合排版片段：将 Markdown AST 切分为连续排版文本流与独立交互岛屿。
/// - textFlow: 连续的标题、段落、列表项合并为一个 AttributedString，交由单个 Text 渲染，支持全篇自由连续划选与复制。
/// - widget: 代码块（带复制按钮与横滚）、表格、公式、图片段落等保留为独立 SwiftUI 组件。
enum MarkdownDisplaySegment: Identifiable, Equatable {
    case textFlow(id: String, content: AttributedString, topSpacing: CGFloat)
    case widget(id: String, block: MarkdownBlock, topSpacing: CGFloat)

    var id: String {
        switch self {
        case let .textFlow(id, _, _): return id
        case let .widget(id, _, _): return id
        }
    }

    var topSpacing: CGFloat {
        switch self {
        case let .textFlow(_, _, spacing): return spacing
        case let .widget(_, _, spacing): return spacing
        }
    }
}

// MARK: - 线性分段切分器

enum MarkdownBlockSegmenter {
    /// 判断某个块是否可以直接进入连续单文本流
    static func isTextFlowCompatible(_ block: MarkdownBlock) -> Bool {
        switch block {
        case let .heading(level, inlines):
            // H2 ~ H6 为纯排版标题；H1 带有底部分割线 Rectangle，作为独立 widget 渲染以保质感
            return level >= 2 && !inlines.containsImage && !inlines.containsMath
        case let .paragraph(inlines):
            // 普通段落无图片、无行内公式时直接进入文本流
            return !inlines.containsImage && !inlines.containsMath
        case let .orderedList(items), let .unorderedList(items):
            // 列表项全部为文本流兼容块时整体进入文本流
            return items.allSatisfy { isListItemTextFlowCompatible($0) }
        default:
            return false
        }
    }

    private static func isListItemTextFlowCompatible(_ item: MarkdownListItem) -> Bool {
        item.blocks.allSatisfy { block in
            switch block {
            case let .paragraph(inlines):
                return !inlines.containsImage && !inlines.containsMath
            case let .orderedList(subItems), let .unorderedList(subItems):
                return subItems.allSatisfy { isListItemTextFlowCompatible($0) }
            default:
                return false
            }
        }
    }

    /// 将 AST 块列表聚合为分段列表
    static func segment(_ blocks: [MarkdownBlock]) -> [MarkdownDisplaySegment] {
        var segments: [MarkdownDisplaySegment] = []
        var textBuffer: [MarkdownBlock] = []
        var counter = 0
        var lastFlushedBlock: MarkdownBlock? = nil

        func flushTextBuffer() {
            guard !textBuffer.isEmpty, let firstBlock = textBuffer.first else { return }
            let spacing = lastFlushedBlock != nil ? firstBlock.topSpacing(after: lastFlushedBlock!) : 0
            let attr = MarkdownTextFlowBuilder.build(from: textBuffer)
            segments.append(.textFlow(id: "flow_\(counter)", content: attr, topSpacing: spacing))
            counter += 1
            lastFlushedBlock = textBuffer.last
            textBuffer.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            if isTextFlowCompatible(block) {
                textBuffer.append(block)
            } else {
                flushTextBuffer()
                let spacing = lastFlushedBlock != nil ? block.topSpacing(after: lastFlushedBlock!) : 0
                segments.append(.widget(id: "widget_\(counter)", block: block, topSpacing: spacing))
                counter += 1
                lastFlushedBlock = block
            }
        }
        flushTextBuffer()
        return segments
    }
}

// MARK: - 文本流 AttributedString 生成器（精密对齐版）

enum MarkdownTextFlowBuilder {
    /// 将连续的普通文本块拼装为单个具备层次样式的 AttributedString
    static func build(from blocks: [MarkdownBlock]) -> AttributedString {
        var result = AttributedString()
        for (index, block) in blocks.enumerated() {
            let previous = index > 0 ? blocks[index - 1] : nil
            if let previous {
                let sep = separatorBetween(previous: previous, current: block)
                result.append(AttributedString(sep))
            }
            append(block: block, after: previous, into: &result)
        }
        return result
    }

    /// 根据前后块的语义类型决定块间换行留白：
    /// - 标题前拉开大间距（\n\n 空行成组锚点）
    /// - 标题后紧随正文收紧（单个 \n 紧凑成组）
    /// - 段落与段落、段落与列表、列表与段落之间保持独立段落空行（\n\n）
    private static func separatorBetween(previous: MarkdownBlock, current: MarkdownBlock) -> String {
        // 当前是标题：前置拉开成组大留白
        if case .heading = current {
            return "\n\n"
        }
        // 前一个是标题：后随内容自然收紧
        if case .heading = previous {
            return "\n"
        }
        // 普通块之间（段落与段落、段落与列表、列表与段落等）：必须保持清晰的双换行空行
        return "\n\n"
    }

    private static func append(
        block: MarkdownBlock,
        after previous: MarkdownBlock?,
        into result: inout AttributedString
    ) {
        switch block {
        case let .heading(level, inlines):
            appendHeading(level: level, inlines: inlines, after: previous, into: &result)
        case let .paragraph(inlines):
            appendParagraph(inlines: inlines, after: previous, into: &result)
        case let .orderedList(items):
            appendList(items: items, ordered: true, depth: 0, after: previous, into: &result)
        case let .unorderedList(items):
            appendList(items: items, ordered: false, depth: 0, after: previous, into: &result)
        default:
            break
        }
    }

    // MARK: - 标题排版
    private static func appendHeading(
        level: Int,
        inlines: [InlineToken],
        after previous: MarkdownBlock?,
        into result: inout AttributedString
    ) {
        let (size, weight): (CGFloat, Font.Weight) = {
            switch level {
            case 2: return (16, .semibold)
            case 3: return (14, .semibold)
            case 4: return (13, .semibold)
            case 5: return (12.5, .semibold)
            default: return (12, .semibold)
            }
        }()

        var headingAttr = MarkdownInline.render(
            inlines,
            bodyColor: Theme.Colors.contentPrimary,
            size: size
        )
        headingAttr.font = Theme.Typography.text(size, weight)

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = Theme.Spacing.lg // 8: 标题后收紧成组
        if let previous {
            style.paragraphSpacingBefore = MarkdownBlock.heading(level: level, inlines: inlines).topSpacing(after: previous)
        }
        headingAttr.appKit.paragraphStyle = style
        result.append(headingAttr)
    }

    // MARK: - 段落排版
    private static func appendParagraph(
        inlines: [InlineToken],
        after previous: MarkdownBlock?,
        into result: inout AttributedString
    ) {
        var paraAttr = MarkdownInline.render(
            inlines,
            bodyColor: Color.primary.opacity(0.80),
            size: 13
        )

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        style.paragraphSpacing = Theme.Spacing.card // 16: 段落间距
        if let previous {
            style.paragraphSpacingBefore = MarkdownBlock.paragraph(inlines).topSpacing(after: previous)
        }
        paraAttr.appKit.paragraphStyle = style
        result.append(paraAttr)
    }

    // MARK: - 列表排版（NSTextTab 两列精密对齐）
    private static func appendList(
        items: [MarkdownListItem],
        ordered: Bool,
        depth: Int,
        after previous: MarkdownBlock?,
        into result: inout AttributedString
    ) {
        for (idx, item) in items.enumerated() {
            if idx > 0 {
                result.append(AttributedString("\n"))
            }
            appendListItem(item: item, ordered: ordered, depth: depth, isFirstInList: idx == 0, previousBlock: previous, into: &result)
        }
    }

    private static func appendListItem(
        item: MarkdownListItem,
        ordered: Bool,
        depth: Int,
        isFirstInList: Bool,
        previousBlock: MarkdownBlock?,
        into result: inout AttributedString
    ) {
        var itemPiece = AttributedString()

        // 1. 前导标号与制表符（\t 实现精准两列对齐，彻底告别单空格贴脸）
        let prefixText: String
        let prefixFont: Font
        if let state = item.taskState {
            prefixText = (state ? "✓" : "○") + "\t"
            prefixFont = Theme.Typography.text(12.5, .medium)
        } else if ordered {
            prefixText = "\(item.number ?? 1).\t"
            prefixFont = Theme.Typography.mono(12)
        } else {
            prefixText = (depth == 0 ? "•" : "◦") + "\t"
            prefixFont = Theme.Typography.text(13, .medium)
        }

        var prefixAttr = AttributedString(prefixText)
        prefixAttr.font = prefixFont
        prefixAttr.foregroundColor = Theme.Colors.contentTertiary
        itemPiece.append(prefixAttr)

        // 2. 正文内容
        let bodyOpacity: Double = item.taskState == true ? 0.55 : 0.80
        var subLists: [(items: [MarkdownListItem], ordered: Bool)] = []

        for block in item.blocks {
            switch block {
            case let .paragraph(inlines):
                let inlinesAttr = MarkdownInline.render(
                    inlines,
                    bodyColor: Color.primary.opacity(bodyOpacity),
                    size: 13
                )
                itemPiece.append(inlinesAttr)
            case let .orderedList(subItems):
                subLists.append((subItems, true))
            case let .unorderedList(subItems):
                subLists.append((subItems, false))
            default:
                break
            }
        }

        // 3. 悬挂缩进 + NSTextTab 精准两列对齐
        // 有序列表 14pt 标号 + 8pt 呼吸留白 = 24pt；无序列表圆点 + 8pt 留白 = 18pt
        let baseIndent: CGFloat = CGFloat(depth) * 22
        let hangingOffset: CGFloat = ordered ? 24 : 18
        let hangingIndent: CGFloat = baseIndent + hangingOffset

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        style.paragraphSpacing = Theme.Spacing.lg // 8: 列表项垂直间距
        style.firstLineHeadIndent = baseIndent
        style.headIndent = hangingIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: hangingIndent)]
        if isFirstInList, let previousBlock {
            style.paragraphSpacingBefore = MarkdownBlock.orderedList([]).topSpacing(after: previousBlock)
        }
        itemPiece.appKit.paragraphStyle = style
        result.append(itemPiece)

        // 4. 递归追加子列表
        for sub in subLists {
            result.append(AttributedString("\n"))
            appendList(items: sub.items, ordered: sub.ordered, depth: depth + 1, after: nil, into: &result)
        }
    }
}
