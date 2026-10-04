import AppKit
import HighlightrKit

/// Markdown 代码块语法高亮服务。
///
/// 渲染层与 vendored Highlightr 之间唯一的桥接点：
/// - 深/浅外观各懒加载一个 Highlightr 实例（init 约 40–70ms，绝不在首帧/主线程触发）；
/// - 所有 highlight / setTheme 调用都收敛到一条专用串行队列，保护 Highlightr 内部可变状态；
/// - 高亮结果做背景剥离 + 字体统一后返回，方便 SwiftUI 自绘背景；
/// - 结果按 (language, code, darkMode) LRU 缓存，重复块零成本命中。
///
/// 无状态门面：全部为 `enum` 静态方法，唯一状态是进程级单例与缓存。
enum MarkdownHighlighter {

    // MARK: - 配置常量

    /// 深色底主题：前景色已为深底调优。
    private static let darkThemeName = "github-dark"

    /// 浅色底主题：atom-one-light。经实测筛选——GitHub light 主题 CSS 在 Highlightr
    /// 的解析管线下几乎不产出 token 颜色（多选择器共享声明不被识别），atom-one-light
    /// 兼容良好且 6 色分布均衡（紫关键字 / 绿字符串 / 红数字 / 灰注释），适配浅底。
    private static let lightThemeName = "atom-one-light"

    /// 缓存容量上限（双主题各自占位，容量上调以摊薄浅/深两套结果的挤占）。
    private static let cacheLimit = 96

    /// 代码等宽字号：对齐 `CodeBlockView` 现状（`Theme.Typography.mono(12.5)`，
    /// 常规字重）。`DesignTokens` 未提供 NSAttributedString 侧的 mono 令牌，
    /// 故此处显式对齐数值；若未来字体族/字号变动需同步该常量与 `Theme.Typography.mono`。
    private static let codeFontSize: CGFloat = 12.5

    /// 统一后的代码字体（SF Mono，常规字重）。
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)

    /// 主题 bold token 使用的字重（github-dark 语法 bold 为 font-weight:600 → semibold）。
    private static let codeFontBold = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .semibold)

    // MARK: - 语言别名归一化

    /// 已知语言短名/别名 → highlight.js 规范语言名。
    private static let languageAliases: [String: String] = [
        "objective-c": "objectivec",
        "objc": "objectivec",
        "py": "python",
        "python3": "python",
        "js": "javascript",
        "ts": "typescript",
        "sh": "bash",
        "zsh": "bash",
        "shell": "bash",
        "yml": "yaml",
        "rb": "ruby",
        "rs": "rust",
        "golang": "go",
        "kt": "kotlin",
        "cs": "csharp",
        "c#": "csharp",
        "c++": "cpp",
        "md": "markdown",
    ]

    /// 纯文本语言标记：显式声明「不做语法高亮、走纯色降级」。
    private static let plainTextLanguages: Set<String> = [
        "text", "txt", "plain", "plaintext",
    ]

    /// 语言别名归一化（objective-c→objectivec、py→python 等）。
    ///
    /// 规则：trim + 小写归一后查表；纯文本标记（text/txt/plain/plainText）与空串返回 nil
    /// （调用方据此纯色降级）；未知语言原样返回（Highlightr 内部会 fallback 到自动检测）。
    static func normalizeLanguage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if plainTextLanguages.contains(normalized) { return nil }
        return languageAliases[normalized] ?? normalized
    }

    // MARK: - 内部状态（仅在 `queue` 上访问）

    /// 专用串行队列：承载 Highlightr 实例创建、主题设置、highlight 与缓存读写。
    /// 串行化同时充当 Highlightr 可变状态的同步保护与缓存互斥。
    private static let queue = DispatchQueue(
        label: "cn.chiproad.quickshow.markdown-highlighter",
        qos: .userInitiated
    )

    /// 深色主题的懒加载实例；nil 表示创建失败。
    private static var darkHighlighter: Highlightr?

    /// 浅色主题的懒加载实例；nil 表示创建失败。
    private static var lightHighlighter: Highlightr?

    /// 是否已尝试过创建深色实例（失败后不重复付出 ~70ms 创建成本）。
    private static var darkHighlighterInitialized = false

    /// 是否已尝试过创建浅色实例（失败后不重复付出 ~70ms 创建成本）。
    private static var lightHighlighterInitialized = false

    /// 结果缓存：key → 处理后不可变富文本。
    private static var cache: [CacheKey: NSAttributedString] = [:]

    /// LRU 顺序：最旧在前，最新在末尾。
    private static var cacheOrder: [CacheKey] = []

    /// 缓存键：语言（归一化名或 "auto"）+ 原始代码 + 外观维度。
    private struct CacheKey: Hashable {
        let language: String
        let code: String
        let darkMode: Bool
    }

    // MARK: - 公开 API

    /// 同步高亮：调用方必须在后台线程调用。
    ///
    /// - Parameter darkMode: 当前外观；true 走 github-dark，false 走 github。
    /// - 返回 nil 表示不可用/失败（实例未就绪、纯文本语言、高亮失败），调用方降级纯色。
    static func highlight(_ code: String, language: String?, darkMode: Bool) -> NSAttributedString? {
        // 归一化：显式纯文本 / 空串 → 纯色降级；nil 输入 → 自动检测。
        let normalized = normalizeLanguage(language)
        let resolvedLanguage: String?
        let cacheLanguage: String

        if let normalized {
            resolvedLanguage = normalized
            cacheLanguage = normalized
        } else if language == nil {
            // 未提供语言信息：交给 Highlightr 自动检测。
            resolvedLanguage = nil
            cacheLanguage = "auto"
        } else {
            // 显式纯文本标记或空串：不做高亮，调用方纯色显示。
            return nil
        }

        let key = CacheKey(language: cacheLanguage, code: code, darkMode: darkMode)

        return queue.sync {
            if let cached = cache[key] {
                touch(key)
                return cached
            }

            guard let highlighter = highlighterInstance(darkMode: darkMode) else { return nil }
            guard let raw = highlighter.highlight(code, as: resolvedLanguage, fastRender: true) else {
                return nil
            }

            let processed = postProcess(raw)
            store(processed, for: key)
            return processed
        }
    }

    /// SwiftUI 便捷：转换 AttributedString；nil 同样降级。
    static func highlightSwiftUI(_ code: String, language: String?, darkMode: Bool) -> AttributedString? {
        guard let attributed = highlight(code, language: language, darkMode: darkMode) else { return nil }
        return AttributedString(attributed)
    }

    // MARK: - Highlightr 生命周期

    /// 在 `queue` 上按外观懒加载对应主题的 Highlightr 实例。创建失败返回 nil（不抛错）。
    ///
    /// 深/浅各持一个实例，主题在创建时一次性设定，此后互不切换：避免 `setTheme`
    /// 反复重解析主题，也彻底排除主题与 `highlight` 之间的状态竞争。
    private static func highlighterInstance(darkMode: Bool) -> Highlightr? {
        if darkMode {
            if darkHighlighterInitialized { return darkHighlighter }
            darkHighlighterInitialized = true

            guard let instance = Highlightr() else { return nil }
            instance.setTheme(to: darkThemeName)
            darkHighlighter = instance
            return instance
        } else {
            if lightHighlighterInitialized { return lightHighlighter }
            lightHighlighterInitialized = true

            guard let instance = Highlightr() else { return nil }
            instance.setTheme(to: lightThemeName)
            lightHighlighter = instance
            return instance
        }
    }

    // MARK: - 后处理

    /// 剥离 token 级背景块并统一字体；前景色保持主题输出（github-dark 已适配深底）。
    ///
    /// 字体统一时按原有 run 的 traits 映射：保留主题对 bold token（函数名/标题类）的
    /// 字重层级，仅统一字体族与字号，避免高亮观感被抹平。
    private static func postProcess(_ raw: NSAttributedString) -> NSAttributedString {
        guard raw.length > 0 else { return raw }

        let result = NSMutableAttributedString(attributedString: raw)
        let fullRange = NSRange(location: 0, length: result.length)
        result.removeAttribute(.backgroundColor, range: fullRange)

        raw.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let isBold = (value as? NSFont)?
                .fontDescriptor
                .symbolicTraits
                .contains(.bold) ?? false
            result.addAttribute(.font, value: isBold ? codeFontBold : codeFont, range: range)
        }
        return result
    }

    // MARK: - LRU 缓存（仅在 `queue` 上访问）

    private static func touch(_ key: CacheKey) {
        guard let index = cacheOrder.firstIndex(of: key) else { return }
        cacheOrder.remove(at: index)
        cacheOrder.append(key)
    }

    private static func store(_ value: NSAttributedString, for key: CacheKey) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = value

        while cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }
}