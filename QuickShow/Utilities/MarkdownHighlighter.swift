import AppKit
import HighlightrKit

// MARK: - 代码高亮主题变体（开闭原则设计）

/// 代码块语法高亮主题
public enum CodeHighlightTheme: String, CaseIterable, Identifiable {
    case atomOne = "atom-one"
    case tokyoNight = "tokyo-night"
    case github = "github"
    case nord = "nord"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .atomOne: return String(localized: "Atom One（均衡丰富）")
        case .tokyoNight: return String(localized: "Tokyo Night（暗夜霓虹）")
        case .github: return String(localized: "GitHub（经典极客）")
        case .nord: return String(localized: "Nord（北欧极简）")
        }
    }

    /// 深色模式 CSS 样式
    var darkCSS: String {
        switch self {
        case .atomOne:
            return CodeThemeCSS.atomOneDark
        case .tokyoNight:
            return CodeThemeCSS.tokyoNightDark
        case .github:
            return CodeThemeCSS.githubDark
        case .nord:
            return CodeThemeCSS.nordDark
        }
    }

    /// 浅色模式 CSS 样式
    var lightCSS: String {
        // atom-one-light 为 Highlightr 解析管线下兼容最佳且 6 色分布最均衡的浅底主题
        return CodeThemeCSS.atomOneLight
    }
}

// MARK: - 内置高亮主题样式表单一来源
enum CodeThemeCSS {
    static let atomOneDark = """
pre code.hljs{display:block;overflow-x:auto;padding:1em}code.hljs{padding:3px 5px}.hljs{color:#abb2bf;background:#282c34}.hljs-comment,.hljs-quote{color:#5c6370;font-style:italic}.hljs-doctag,.hljs-formula,.hljs-keyword{color:#c678dd}.hljs-deletion,.hljs-name,.hljs-section,.hljs-selector-tag,.hljs-subst{color:#e06c75}.hljs-literal{color:#56b6c2}.hljs-addition,.hljs-attribute,.hljs-meta .hljs-string,.hljs-regexp,.hljs-string{color:#98c379}.hljs-attr,.hljs-number,.hljs-selector-attr,.hljs-selector-class,.hljs-selector-pseudo,.hljs-template-variable,.hljs-type,.hljs-variable{color:#d19a66}.hljs-bullet,.hljs-link,.hljs-meta,.hljs-selector-id,.hljs-symbol,.hljs-title{color:#61aeee}.hljs-built_in,.hljs-class .hljs-title,.hljs-title.class_{color:#e6c07b}.hljs-emphasis{font-style:italic}.hljs-strong{font-weight:700}.hljs-link{text-decoration:underline}
"""

    static let tokyoNightDark = """
pre code.hljs{display:block;overflow-x:auto;padding:1em}code.hljs{padding:3px 5px}.hljs-comment,.hljs-meta{color:#565f89}.hljs-deletion,.hljs-doctag,.hljs-regexp,.hljs-selector-attr,.hljs-selector-class,.hljs-selector-id,.hljs-selector-pseudo,.hljs-tag,.hljs-template-tag,.hljs-variable.language_{color:#f7768e}.hljs-link,.hljs-literal,.hljs-number,.hljs-params,.hljs-template-variable,.hljs-type,.hljs-variable{color:#ff9e64}.hljs-attribute,.hljs-built_in{color:#e0af68}.hljs-keyword,.hljs-property,.hljs-subst,.hljs-title,.hljs-title.class_,.hljs-title.class_.inherited__,.hljs-title.function_{color:#7dcfff}.hljs-selector-tag{color:#73daca}.hljs-addition,.hljs-bullet,.hljs-quote,.hljs-string,.hljs-symbol{color:#9ece6a}.hljs-code,.hljs-formula,.hljs-section{color:#7aa2f7}.hljs-attr,.hljs-char.escape_,.hljs-keyword,.hljs-name,.hljs-operator{color:#bb9af7}.hljs-punctuation{color:#c0caf5}.hljs{background:#1a1b26;color:#9aa5ce}.hljs-emphasis{font-style:italic}.hljs-strong{font-weight:700}
"""

    static let githubDark = """
pre code.hljs{display:block;overflow-x:auto;padding:1em}code.hljs{padding:3px 5px}.hljs{color:#c9d1d9;background:#0d1117}.hljs-doctag,.hljs-keyword,.hljs-meta .hljs-keyword,.hljs-template-tag,.hljs-template-variable,.hljs-type,.hljs-variable.language_{color:#ff7b72}.hljs-title,.hljs-title.class_,.hljs-title.class_.inherited__,.hljs-title.function_{color:#d2a8ff}.hljs-attr,.hljs-attribute,.hljs-literal,.hljs-meta,.hljs-number,.hljs-operator,.hljs-selector-attr,.hljs-selector-class,.hljs-selector-id,.hljs-variable{color:#79c0ff}.hljs-meta .hljs-string,.hljs-regexp,.hljs-string{color:#a5d6ff}.hljs-built_in,.hljs-symbol{color:#ffa657}.hljs-code,.hljs-comment,.hljs-formula{color:#8b949e}.hljs-name,.hljs-quote,.hljs-selector-pseudo,.hljs-selector-tag{color:#7ee787}.hljs-subst{color:#c9d1d9}.hljs-section{color:#1f6feb;font-weight:700}.hljs-bullet{color:#f2cc60}.hljs-emphasis{color:#c9d1d9;font-style:italic}.hljs-strong{color:#c9d1d9;font-weight:700}.hljs-addition{color:#aff5b4;background-color:#033a16}.hljs-deletion{color:#ffdcd7;background-color:#67060c}
"""

    static let nordDark = """
pre code.hljs{display:block;overflow-x:auto;padding:1em}code.hljs{padding:3px 5px}.hljs{background:#2e3440}.hljs,.hljs-subst{color:#d8dee9}.hljs-selector-tag{color:#81a1c1}.hljs-selector-id{color:#8fbcbb;font-weight:700}.hljs-selector-attr,.hljs-selector-class{color:#8fbcbb}.hljs-property,.hljs-selector-pseudo{color:#88c0d0}.hljs-addition{background-color:rgba(163,190,140,.5)}.hljs-deletion{background-color:rgba(191,97,106,.5)}.hljs-built_in,.hljs-class,.hljs-type{color:#8fbcbb}.hljs-function,.hljs-function>.hljs-title,.hljs-title.hljs-function{color:#88c0d0}.hljs-keyword,.hljs-literal,.hljs-symbol{color:#81a1c1}.hljs-number{color:#b48ead}.hljs-regexp{color:#ebcb8b}.hljs-string{color:#a3be8c}.hljs-title{color:#8fbcbb}.hljs-params{color:#d8dee9}.hljs-bullet{color:#81a1c1}.hljs-code{color:#8fbcbb}.hljs-emphasis{font-style:italic}.hljs-formula{color:#8fbcbb}.hljs-strong{font-weight:700}.hljs-link:hover{text-decoration:underline}.hljs-comment,.hljs-quote{color:#4c566a}.hljs-doctag{color:#8fbcbb}.hljs-meta,.hljs-meta .hljs-keyword{color:#5e81ac}.hljs-meta .hljs-string{color:#a3be8c}.hljs-attr{color:#8fbcbb}.hljs-attribute{color:#d8dee9}.hljs-name{color:#81a1c1}.hljs-section{color:#88c0d0}.hljs-tag{color:#81a1c1}.hljs-template-variable,.hljs-variable{color:#d8dee9}.hljs-template-tag{color:#5e81ac}
"""

    static let atomOneLight = """
pre code.hljs{display:block;overflow-x:auto;padding:1em}code.hljs{padding:3px 5px}.hljs{color:#383a42;background:#fafafa}.hljs-comment,.hljs-quote{color:#a0a1a7;font-style:italic}.hljs-doctag,.hljs-formula,.hljs-keyword{color:#a626a4}.hljs-deletion,.hljs-name,.hljs-section,.hljs-selector-tag,.hljs-subst{color:#e45649}.hljs-literal{color:#0184bb}.hljs-addition,.hljs-attribute,.hljs-meta .hljs-string,.hljs-regexp,.hljs-string{color:#50a14f}.hljs-attr,.hljs-number,.hljs-selector-attr,.hljs-selector-class,.hljs-selector-pseudo,.hljs-template-variable,.hljs-type,.hljs-variable{color:#986801}.hljs-bullet,.hljs-link,.hljs-meta,.hljs-selector-id,.hljs-symbol,.hljs-title{color:#4078f2}.hljs-built_in,.hljs-class .hljs-title,.hljs-title.class_{color:#c18401}.hljs-emphasis{font-style:italic}.hljs-strong{font-weight:700}.hljs-link{text-decoration:underline}
"""
}

/// Markdown 代码块语法高亮服务。
///
/// 渲染层与 vendored Highlightr 之间唯一的桥接点：
/// - 深/浅外观各懒加载一个 Highlightr 实例（init 约 40–70ms，绝不在首帧/主线程触发）；
/// - 所有 highlight / setTheme 调用都收敛到一条专用串行队列，保护 Highlightr 内部可变状态；
/// - 高亮结果做背景剥离 + 字体统一后返回，方便 SwiftUI 自绘背景；
/// - 结果按 (language, code, darkMode, theme) LRU 缓存，重复块零成本命中。
enum MarkdownHighlighter {

    // MARK: - 配置与主题

    /// 当前激活的代码高亮主题（由 AppState 持久化驱动，切换时自动清空缓存并重载实例）
    static var currentTheme: CodeHighlightTheme = .atomOne {
        didSet {
            guard oldValue != currentTheme else { return }
            queue.sync {
                cache.removeAll()
                cacheOrder.removeAll()
                darkHighlighter = nil
                lightHighlighter = nil
                darkHighlighterInitialized = false
                lightHighlighterInitialized = false
            }
        }
    }

    /// 缓存容量上限（双主题各自占位，容量上调以摊薄浅/深两套结果的挤占）。
    private static let cacheLimit = 96

    /// 代码等宽字号：对齐 `CodeBlockView` 现状（`Theme.Typography.mono(12.5)`，
    /// 常规字重）。`DesignTokens` 未提供 NSAttributedString 侧的 mono 令牌，
    /// 故此处显式对齐数值；若未来字体族/字号变动需同步该常量与 `Theme.Typography.mono`。
    private static let codeFontSize: CGFloat = 12.5

    /// 统一后的代码字体（SF Mono，常规字重）。
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)

    /// 主题 bold token 使用的字重（语法 bold 为 font-weight:600 → semibold）。
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
    static func normalizeLanguage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if plainTextLanguages.contains(normalized) { return nil }
        return languageAliases[normalized] ?? normalized
    }

    // MARK: - 内部状态（仅在 `queue` 上访问）

    /// 专用串行队列：承载 Highlightr 实例创建、主题设置、highlight 与缓存读写。
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

    /// 缓存键：语言 + 原始代码 + 外观维度 + 高亮主题。
    private struct CacheKey: Hashable {
        let language: String
        let code: String
        let darkMode: Bool
        let theme: CodeHighlightTheme
    }

    // MARK: - 公开 API

    /// 同步高亮：调用方必须在后台线程调用。
    static func highlight(
        _ code: String,
        language: String?,
        darkMode: Bool,
        theme: CodeHighlightTheme? = nil
    ) -> NSAttributedString? {
        let normalized = normalizeLanguage(language)
        let resolvedLanguage: String?
        let cacheLanguage: String

        if let normalized {
            resolvedLanguage = normalized
            cacheLanguage = normalized
        } else if language == nil {
            resolvedLanguage = nil
            cacheLanguage = "auto"
        } else {
            return nil
        }

        let targetTheme = theme ?? currentTheme
        let key = CacheKey(language: cacheLanguage, code: code, darkMode: darkMode, theme: targetTheme)

        return queue.sync {
            if targetTheme != currentTheme {
                currentTheme = targetTheme
            }

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
    static func highlightSwiftUI(
        _ code: String,
        language: String?,
        darkMode: Bool,
        theme: CodeHighlightTheme? = nil
    ) -> AttributedString? {
        guard let attributed = highlight(code, language: language, darkMode: darkMode, theme: theme) else { return nil }
        return AttributedString(attributed)
    }

    // MARK: - Highlightr 生命周期

    private static func highlighterInstance(darkMode: Bool) -> Highlightr? {
        if darkMode {
            if darkHighlighterInitialized { return darkHighlighter }
            darkHighlighterInitialized = true

            guard let instance = Highlightr() else { return nil }
            instance.setTheme(css: currentTheme.darkCSS)
            darkHighlighter = instance
            return instance
        } else {
            if lightHighlighterInitialized { return lightHighlighter }
            lightHighlighterInitialized = true

            guard let instance = Highlightr() else { return nil }
            instance.setTheme(css: currentTheme.lightCSS)
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