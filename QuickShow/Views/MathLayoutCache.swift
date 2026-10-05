// 来源拆分：AIChatMathViews.swift — 段落/公式高度持久缓存（MathLayoutCache）。
import SwiftUI
import AppKit
import SwiftMath

// MARK: - 段落/公式高度持久缓存（跨重建查表，首帧免测量）

/// 全局测量缓存（独立枚举、非 MainActor、NSLock 保护，锁内只做字典操作）：
/// 1. 段落高度：跨 LRU 逐出重建复用，消除 `NSTextField.layoutSubtreeIfNeeded` 的重复测量
///    （这是历史「重挂载首帧最大成本」）。
/// 2. 块级公式高度：供 `AsyncMathBlockView` 占位直接锁定真实高度，消除占位→位图回填的高度跳变。
/// 键含内容 hash / 宽度桶 / 外观 / 字号 / 字重，内容变则键变，天然自洽。
enum MathLayoutCache {
    struct ParagraphKey: Hashable {
        var contentHash: Int
        /// 宽度取整（1pt 精度）。
        var widthBucket: Int
        var isDark: Bool
        var pointSizeMilli: Int
        var weightRaw: Int
    }

    struct BlockKey: Hashable {
        var latexHash: Int
        var pointSizeMilli: Int
        // 不含颜色：公式位图尺寸与颜色无关（只由数学原子布局决定）。
    }

    private static var paragraphCache: [ParagraphKey: CGFloat] = [:]
    private static var paragraphOrder: [ParagraphKey] = []
    private static var blockCache: [BlockKey: CGFloat] = [:]
    private static var blockOrder: [BlockKey] = []
    /// 各自 LRU 上限（高度是小数值，内存可忽略；条数上限防哈希表无限增长）。
    private static let limit = 4096
    private static let lock = NSLock()

    // MARK: 段落高度

    static func paragraphHeight(for key: ParagraphKey) -> CGFloat? {
        lock.lock(); defer { lock.unlock() }
        guard let height = paragraphCache[key] else { return nil }
        if let index = paragraphOrder.firstIndex(of: key) {
            paragraphOrder.remove(at: index)
            paragraphOrder.append(key)
        }
        return height
    }

    static func storeParagraphHeight(_ height: CGFloat, for key: ParagraphKey) {
        lock.lock(); defer { lock.unlock() }
        if paragraphCache[key] == nil { paragraphOrder.append(key) }
        paragraphCache[key] = height
        while paragraphOrder.count > limit {
            let oldest = paragraphOrder.removeFirst()
            paragraphCache.removeValue(forKey: oldest)
        }
    }

    // MARK: 块级公式高度

    static func blockHeight(latex: String, pointSize: CGFloat) -> CGFloat? {
        lock.lock(); defer { lock.unlock() }
        let key = blockKey(latex: latex, pointSize: pointSize)
        guard let height = blockCache[key] else { return nil }
        if let index = blockOrder.firstIndex(of: key) {
            blockOrder.remove(at: index)
            blockOrder.append(key)
        }
        return height
    }

    static func storeBlockHeight(_ height: CGFloat, latex: String, pointSize: CGFloat) {
        lock.lock(); defer { lock.unlock() }
        let key = blockKey(latex: latex, pointSize: pointSize)
        if blockCache[key] == nil { blockOrder.append(key) }
        blockCache[key] = height
        while blockOrder.count > limit {
            let oldest = blockOrder.removeFirst()
            blockCache.removeValue(forKey: oldest)
        }
    }

    private static func blockKey(latex: String, pointSize: CGFloat) -> BlockKey {
        BlockKey(
            latexHash: hashString(latex),
            pointSizeMilli: Int((pointSize * 1000).rounded())
        )
    }

    // MARK: 内容 hash（段落 token 序列）

    /// 段落 token 序列的稳定 hash（进程内稳定即可：缓存为进程内缓存）。
    static func contentHash(_ tokens: [InlineToken]) -> Int {
        var hasher = Hasher()
        hashTokens(tokens, into: &hasher)
        return hasher.finalize()
    }

    private static func hashTokens(_ tokens: [InlineToken], into hasher: inout Hasher) {
        for token in tokens {
            switch token {
            case let .text(value): hasher.combine(1); hasher.combine(value)
            case let .code(value): hasher.combine(2); hasher.combine(value)
            case let .bold(inner): hasher.combine(3); hashTokens(inner, into: &hasher)
            case let .italic(inner): hasher.combine(4); hashTokens(inner, into: &hasher)
            case let .link(text, url, title):
                hasher.combine(5); hashTokens(text, into: &hasher)
                hasher.combine(url); hasher.combine(title)
            case let .math(value): hasher.combine(6); hasher.combine(value)
            case let .strikethrough(inner): hasher.combine(7); hashTokens(inner, into: &hasher)
            case let .underline(inner): hasher.combine(8); hashTokens(inner, into: &hasher)
            case let .highlight(inner): hasher.combine(9); hashTokens(inner, into: &hasher)
            case let .`subscript`(inner): hasher.combine(10); hashTokens(inner, into: &hasher)
            case let .superscript(inner): hasher.combine(11); hashTokens(inner, into: &hasher)
            case let .image(alt, url, title):
                hasher.combine(12); hasher.combine(alt); hasher.combine(url); hasher.combine(title)
            case .lineBreak: hasher.combine(13)
            case let .footnoteRef(id): hasher.combine(14); hasher.combine(id)
            }
        }
    }

    private static func hashString(_ value: String) -> Int {
        var hasher = Hasher()
        hasher.combine(value)
        return hasher.finalize()
    }
}
