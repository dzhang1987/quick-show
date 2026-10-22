import Foundation

// MARK: - 线性分段切分器（基于能力声明）

enum MarkdownBlockSegmenter {

    // MARK: - 分段结果 LRU 缓存（消除每帧重复解析与富文本分配）
    private static var segmentCache: [String: [MarkdownDisplaySegment]] = [:]
    private static var segmentCacheOrder: [String] = []
    private static let segmentCacheLimit = 256
    private static let cacheLock = NSLock()

    /// 判断某个块是否可以直接进入连续单文本流（由对应渲染器的能力声明决定）
    static func isTextFlowCompatible(_ block: MarkdownBlock) -> Bool {
        let renderer = MarkdownBlockRegistry.shared.renderer(for: block)
        return renderer.capabilities(for: block).contains(.textFlowCompatible)
    }

    /// 将 AST 块列表聚合为分段列表：
    /// 遵循开闭原则与块原子性契约，兼容单文本流（TextKit）的连续块合流渲染；
    /// 包含 Widget（如独立组件、含数学公式或嵌套代码块的复杂列表等）的块整体优雅降级为独立组件视图，
    /// 坚决避免因局部拆解破坏列表语义完整性与序号自增连续性。
    static func segment(_ blocks: [MarkdownBlock], cacheKey: String? = nil) -> [MarkdownDisplaySegment] {
        if let key = cacheKey {
            cacheLock.lock()
            if let cached = segmentCache[key] {
                if let idx = segmentCacheOrder.firstIndex(of: key) {
                    segmentCacheOrder.remove(at: idx)
                    segmentCacheOrder.append(key)
                }
                cacheLock.unlock()
                return cached
            }
            cacheLock.unlock()
        }

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

        if let key = cacheKey {
            cacheLock.lock()
            if segmentCache[key] == nil {
                segmentCache[key] = segments
                segmentCacheOrder.append(key)
                if segmentCacheOrder.count > segmentCacheLimit {
                    let oldest = segmentCacheOrder.removeFirst()
                    segmentCache.removeValue(forKey: oldest)
                }
            }
            cacheLock.unlock()
        }

        return segments
    }
}

