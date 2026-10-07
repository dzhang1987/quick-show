import Foundation

// MARK: - Markdown AST 解析缓存（线程安全）

/// 块级 AST 解析缓存：`MarkdownParser.parse` 是无状态纯函数（同输入同输出），以 content 为
/// key 缓存 AST，命中直接复用。主线程渲染与后台公式预热线程都可能读写，故用 `lock` 保护；
/// 解析在锁外执行，仅在字典读写时持锁，避免长解析阻塞主线程。独立于 View 类型（非 MainActor），
/// 可安全地从后台队列调用。
enum MarkdownASTCache {
    private static var cache: [String: [MarkdownBlock]] = [:]
    /// LRU 次序（尾部=最近使用）：命中移到尾部，淘汰从头部。多会话来回切换时热条目不被误踢。
    private static var cacheOrder: [String] = []
    /// 条目数上限（256：>12 常驻会话 + 历史消息，大幅提升命中率）。
    private static let cacheEntryLimit = 256
    /// 内容总字符预算（4M：见报告内存量级，AST 文本与原文同量级）。
    private static let cacheCharBudget = 4_000_000
    /// 当前缓存内容的总字符数（预算淘汰用）。
    private static var cacheCharTotal = 0
    private static let lock = NSLock()

    /// 取 content 的块级 AST。
    /// - useCache == false：完全旁路缓存直接解析（不读不写），供流式中间态使用。
    /// - useCache == true：命中读缓存并刷新 LRU；未命中解析后写入，按条数/字符预算做 LRU 淘汰。
    static func blocks(for content: String, useCache: Bool) -> [MarkdownBlock] {
        guard useCache else { return MarkdownParser.parse(content) }
        lock.lock()
        if let cached = cache[content] {
            touchLocked(content)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let blocks = MarkdownParser.parse(content)

        lock.lock()
        if cache[content] != nil {
            touchLocked(content)   // 并发下已被他人写入：不重复计数
        } else {
            cache[content] = blocks
            cacheOrder.append(content)
            cacheCharTotal += content.count
            evictIfNeededLocked()
        }
        lock.unlock()
        return blocks
    }

    /// 锁内把 key 移到 LRU 尾部（最近使用）。
    private static func touchLocked(_ content: String) {
        guard let index = cacheOrder.firstIndex(of: content) else { return }
        cacheOrder.remove(at: index)
        cacheOrder.append(content)
    }

    private static func evictIfNeededLocked() {
        while cacheOrder.count > cacheEntryLimit || cacheCharTotal > cacheCharBudget {
            guard !cacheOrder.isEmpty else { break }
            let oldest = cacheOrder.removeFirst()
            if cache.removeValue(forKey: oldest) != nil {
                cacheCharTotal -= oldest.count
            }
        }
    }
}

// MARK: - Markdown 渲染进度缓存（主线程专用，无锁）

/// 单条助手消息的**已渲染块数**进度缓存：key 与 `MarkdownASTCache` 同空间（消息 content 字符串），
/// 值为 `[String: Int]`（content → 已构建块数）。
///
/// 存在意义：`ChatVirtualRow` 的「实渲染 ↔ 等高占位」切换（窗口外切占位）会**销毁**
/// `AssistantMarkdownView` 的 `@State visibleBlockCount`——长消息每次滚回视口都从
/// `settledInitialBlocks`(40) 重新起步，再以 16ms/批推进；大会话滚动时行不断进出窗口，
/// 批次风暴可持续数十秒（行高逐批变化又触发全列表重估）。本缓存让重挂载的消息直接
/// 恢复到既有渲染进度，从根上消除「重挂载塌回首批」的批次风暴。
///
/// 线程约定：**仅主线程读写**（调用点全部是 `AssistantMarkdownView` 的 body / 批次推进）。
/// AST 缓存因后台公式预热线程读写才用 `NSLock`；本缓存不参与预热，刻意保持无锁。
/// 淘汰策略与 `MarkdownASTCache` 完全一致：条目数上限 + 内容字符预算的 LRU
/// （命中移到尾部，淘汰从头部；多会话来回时热条目不被误踢）。
enum MarkdownRenderProgressCache {
    private static var cache: [String: Int] = [:]
    /// LRU 次序（尾部=最近使用）。
    private static var cacheOrder: [String] = []
    /// 条目数上限（与 AST 缓存对齐：256）。
    private static let cacheEntryLimit = 256
    /// 内容总字符预算（与 AST 缓存对齐：4M）。
    private static let cacheCharBudget = 4_000_000
    /// 当前缓存内容的总字符数（预算淘汰用）。
    private static var cacheCharTotal = 0

    /// 取 content 的已渲染块数；无进度返回 nil。命中刷新 LRU。
    static func progress(for content: String) -> Int? {
        guard let value = cache[content] else { return nil }
        touch(content)
        return value
    }

    /// 记录 content 的已渲染块数。**单调不减**：仅在新值更大时写入（分批推进只会前进），
    /// 合法值（>0）才入缓存，避免流式/空内容污染。
    static func record(_ count: Int, for content: String) {
        guard count > 0 else { return }
        if let existing = cache[content] {
            guard count > existing else {
                touch(content)
                return
            }
            cache[content] = count
            touch(content)
        } else {
            cache[content] = count
            cacheOrder.append(content)
            cacheCharTotal += content.count
            evictIfNeeded()
        }
    }

    /// 把 key 移到 LRU 尾部（最近使用）。
    private static func touch(_ content: String) {
        guard let index = cacheOrder.firstIndex(of: content) else { return }
        cacheOrder.remove(at: index)
        cacheOrder.append(content)
    }

    private static func evictIfNeeded() {
        while cacheOrder.count > cacheEntryLimit || cacheCharTotal > cacheCharBudget {
            guard !cacheOrder.isEmpty else { break }
            let oldest = cacheOrder.removeFirst()
            if cache.removeValue(forKey: oldest) != nil {
                cacheCharTotal -= oldest.count
            }
        }
    }
}
