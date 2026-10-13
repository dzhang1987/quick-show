import Foundation

// MARK: - 线性分段切分器（基于能力声明）

enum MarkdownBlockSegmenter {

    /// 判断某个块是否可以直接进入连续单文本流（由对应渲染器的能力声明决定）
    static func isTextFlowCompatible(_ block: MarkdownBlock) -> Bool {
        let renderer = MarkdownBlockRegistry.shared.renderer(for: block)
        return renderer.capabilities(for: block).contains(.textFlowCompatible)
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
