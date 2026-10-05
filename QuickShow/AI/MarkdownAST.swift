import Foundation

// 职责来源：MarkdownParser.swift 的 AST 类型定义区（行内 Token / 引用 / 列表项 / 表格 / 块级 AST）。

// MARK: - 行内 Token

/// 行内 Markdown 解析结果（粗体 / 斜体 / 行内代码 / 链接 / 数学公式 / 纯文本 等）。
indirect enum InlineToken: Equatable {
    case text(String)
    case bold([InlineToken])
    case italic([InlineToken])
    case code(String)
    /// 链接：`text` 为可继续解析的行内内容，`url` 为原始地址，`title` 为可选的引号标题。
    case link(text: [InlineToken], url: String, title: String?)
    /// 行内数学公式：已剥离定界符（$…$ / \(…\)）的纯 LaTeX 源串。
    case math(String)
    /// 删除线（`~~text~~` 或 `<s>/<del>/<strike>`）。
    case strikethrough([InlineToken])
    /// 下划线（`<u>`）。
    case underline([InlineToken])
    /// 高亮（`<mark>`）。
    case highlight([InlineToken])
    /// 下标（`<sub>`）。
    case `subscript`([InlineToken])
    /// 上标（`<sup>`）。
    case superscript([InlineToken])
    /// 图片：`alt` 为原始替代文本，`url` 为地址，`title` 为可选标题。
    case image(alt: String, url: String, title: String?)
    /// 硬换行（行尾 ≥2 空格或行尾反斜杠）。
    case lineBreak
    /// 脚注引用（`[^id]`）。
    case footnoteRef(String)
}

// MARK: - 引用式链接定义

/// 引用式链接 / 图片定义（CommonMark reference definition）：
/// 从 `[label]: destination "title"` 收集而来，供行内 `[text][label]` / `![alt][label]` / `[label]` 查表。
struct LinkReference: Equatable {
    /// 目标地址（已剥离 `<>` 包裹）。
    var destination: String
    /// 可选标题（`"…"` / `'…'` / `(…)`）。
    var title: String?
}

// MARK: - 列表项

/// 列表项：容器（orderedList / unorderedList）决定本级有序性；
/// 内容以块数组表达（段落、代码块，以及嵌套子列表块），支持任意层级递归。
struct MarkdownListItem: Equatable {
    /// 有序列表项序号（无序为 nil）。
    var number: Int?
    /// 任务列表状态：nil 表示非任务项；true 已勾选；false 未勾选。
    var taskState: Bool?
    /// 该列表项的块级内容；嵌套子列表以 `.orderedList` / `.unorderedList` 块形式出现。
    var blocks: [MarkdownBlock]
}

// MARK: - 表格

/// 表格列对齐方式。
enum MarkdownTableAlignment: Equatable {
    case left
    case center
    case right
}

/// 表格：表头单元格、数据行与列对齐；每个单元格为行内 token 数组。
struct MarkdownTable: Equatable {
    var headers: [[InlineToken]]
    var rows: [[[InlineToken]]]
    /// 每列对齐（nil 表示默认对齐），长度与 headers 对齐。
    var alignments: [MarkdownTableAlignment?]
}

// MARK: - 块级 AST

/// 块级 Markdown AST。blockquote / list item 递归包含块级节点，故为 indirect enum。
indirect enum MarkdownBlock: Equatable {
    case heading(level: Int, inlines: [InlineToken])
    case paragraph([InlineToken])
    case orderedList([MarkdownListItem])
    case unorderedList([MarkdownListItem])
    case blockquote([MarkdownBlock])
    case table(MarkdownTable)
    case codeBlock(language: String?, code: String)
    /// 块级数学公式：已剥离定界符（$$…$$ / \[…\]）的纯 LaTeX 源串。
    case mathBlock(latex: String)
    /// 水平分隔线（thematic break）：整行由 ≥3 个 `-` / `*` / `_` 组成。
    case horizontalRule
    /// 脚注定义（`[^id]: 内容`），位置保持在文档中出现处。
    case footnoteDefinition(id: String, inlines: [InlineToken])
}
