import Foundation

// MARK: - 线性分段切分器（基于能力声明与智能列表流式拆分）

enum MarkdownBlockSegmenter {

    /// 判断某个块是否可以直接进入连续单文本流（由对应渲染器的能力声明决定）
    static func isTextFlowCompatible(_ block: MarkdownBlock) -> Bool {
        let renderer = MarkdownBlockRegistry.shared.renderer(for: block)
        return renderer.capabilities(for: block).contains(.textFlowCompatible)
    }

    /// 列表内部拆分产生的结构单元
    enum ListSplitElement {
        case listSlice(ordered: Bool, items: [MarkdownListItem])
        case widget(block: MarkdownBlock, indent: CGFloat)
    }

    /// 列表拆解器对象：避免在递归与闭包中触发 Swift 内存独占性冲突（Law of Exclusivity）
    private final class ListSplitter {
        let ordered: Bool
        let depth: Int
        var elements: [ListSplitElement] = []
        var currentItems: [MarkdownListItem] = []

        init(ordered: Bool, depth: Int = 0) {
            self.ordered = ordered
            self.depth = depth
        }

        func flushCurrentItems() {
            guard !currentItems.isEmpty else { return }
            elements.append(.listSlice(ordered: ordered, items: currentItems))
            currentItems.removeAll()
        }

        func split(items: [MarkdownListItem]) -> [ListSplitElement] {
            let baseIndent: CGFloat = CGFloat(depth) * 22 + (ordered ? 24 : 18)

            for item in items {
                let hasWidget = item.blocks.contains { !MarkdownBlockSegmenter.isTextFlowCompatible($0) }
                if !hasWidget {
                    currentItems.append(item)
                    continue
                }

                var preBlocks: [MarkdownBlock] = []

                for childBlock in item.blocks {
                    if MarkdownBlockSegmenter.isTextFlowCompatible(childBlock) {
                        preBlocks.append(childBlock)
                    } else if case let .orderedList(subItems) = childBlock {
                        let subSplitter = ListSplitter(ordered: true, depth: depth + 1)
                        let subSplits = subSplitter.split(items: subItems)
                        applySubSplits(subSplits, parentItem: item, preBlocks: &preBlocks)
                    } else if case let .unorderedList(subItems) = childBlock {
                        let subSplitter = ListSplitter(ordered: false, depth: depth + 1)
                        let subSplits = subSplitter.split(items: subItems)
                        applySubSplits(subSplits, parentItem: item, preBlocks: &preBlocks)
                    } else {
                        // childBlock 本身就是独立 Widget（代码块、表格等）
                        if !preBlocks.isEmpty {
                            let itemNum = currentItems.isEmpty ? item.number : nil
                            currentItems.append(MarkdownListItem(number: itemNum, taskState: item.taskState, blocks: preBlocks))
                            preBlocks.removeAll()
                        }
                        flushCurrentItems()
                        elements.append(.widget(block: childBlock, indent: baseIndent))
                    }
                }

                if !preBlocks.isEmpty {
                    let itemNum = currentItems.isEmpty ? item.number : nil
                    currentItems.append(MarkdownListItem(number: itemNum, taskState: nil, blocks: preBlocks))
                }
            }

            flushCurrentItems()
            return elements
        }

        private func applySubSplits(
            _ subSplits: [ListSplitElement],
            parentItem: MarkdownListItem,
            preBlocks: inout [MarkdownBlock]
        ) {
            for element in subSplits {
                switch element {
                case let .listSlice(subOrdered, subItems):
                    let subBlock: MarkdownBlock = subOrdered ? .orderedList(subItems) : .unorderedList(subItems)
                    preBlocks.append(subBlock)
                case let .widget(widgetBlock, widgetIndent):
                    if !preBlocks.isEmpty {
                        let parentNumber = currentItems.isEmpty ? parentItem.number : nil
                        currentItems.append(MarkdownListItem(number: parentNumber, taskState: parentItem.taskState, blocks: preBlocks))
                        preBlocks.removeAll()
                    }
                    flushCurrentItems()
                    elements.append(.widget(block: widgetBlock, indent: widgetIndent))
                }
            }
        }
    }

    /// 将可能嵌套 Widget（代码块、表格等）的列表按时序拆解为纯文本列表片段与独立 Widget 序列
    static func splitList(ordered: Bool, items: [MarkdownListItem], depth: Int = 0) -> [ListSplitElement] {
        let splitter = ListSplitter(ordered: ordered, depth: depth)
        return splitter.split(items: items)
    }

    /// 将 AST 块列表聚合为分段列表
    static func segment(_ blocks: [MarkdownBlock]) -> [MarkdownDisplaySegment] {
        var segments: [MarkdownDisplaySegment] = []
        var textBuffer: [MarkdownBlock] = []
        var counter = 0
        var lastFlushedBlock: MarkdownBlock? = nil

        func flushTextBuffer() {
            guard !textBuffer.isEmpty, let firstBlock = textBuffer.first else { return }
            let spacing = lastFlushedBlock != nil
                ? MarkdownBlockRegistry.shared.topSpacing(for: firstBlock, after: lastFlushedBlock!)
                : 0
            let attr = MarkdownTextFlowBuilder.build(from: textBuffer)
            segments.append(.textFlow(id: "flow_\(counter)", content: attr, topSpacing: spacing))
            counter += 1
            lastFlushedBlock = textBuffer.last
            textBuffer.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            if isTextFlowCompatible(block) {
                textBuffer.append(block)
            } else if case let .orderedList(items) = block {
                // 有序列表内部嵌套 Widget：流式拆解为文本切片与独立组件，打破连坐降级
                let splitElements = splitList(ordered: true, items: items)
                for element in splitElements {
                    switch element {
                    case let .listSlice(ordered, sliceItems):
                        let sliceBlock: MarkdownBlock = ordered ? .orderedList(sliceItems) : .unorderedList(sliceItems)
                        textBuffer.append(sliceBlock)
                    case let .widget(wBlock, indent):
                        flushTextBuffer()
                        let spacing = lastFlushedBlock != nil
                            ? MarkdownBlockRegistry.shared.topSpacing(for: wBlock, after: lastFlushedBlock!)
                            : 8
                        segments.append(.widget(id: "widget_\(counter)", block: wBlock, topSpacing: spacing, leadingIndent: indent))
                        counter += 1
                        lastFlushedBlock = wBlock
                    }
                }
            } else if case let .unorderedList(items) = block {
                // 无序列表内部嵌套 Widget：流式拆解为文本切片与独立组件，打破连坐降级
                let splitElements = splitList(ordered: false, items: items)
                for element in splitElements {
                    switch element {
                    case let .listSlice(ordered, sliceItems):
                        let sliceBlock: MarkdownBlock = ordered ? .orderedList(sliceItems) : .unorderedList(sliceItems)
                        textBuffer.append(sliceBlock)
                    case let .widget(wBlock, indent):
                        flushTextBuffer()
                        let spacing = lastFlushedBlock != nil
                            ? MarkdownBlockRegistry.shared.topSpacing(for: wBlock, after: lastFlushedBlock!)
                            : 8
                        segments.append(.widget(id: "widget_\(counter)", block: wBlock, topSpacing: spacing, leadingIndent: indent))
                        counter += 1
                        lastFlushedBlock = wBlock
                    }
                }
            } else {
                flushTextBuffer()
                let spacing = lastFlushedBlock != nil
                    ? MarkdownBlockRegistry.shared.topSpacing(for: block, after: lastFlushedBlock!)
                    : 0
                segments.append(.widget(id: "widget_\(counter)", block: block, topSpacing: spacing))
                counter += 1
                lastFlushedBlock = block
            }
        }
        flushTextBuffer()
        return segments
    }
}
