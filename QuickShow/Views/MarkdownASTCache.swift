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
