import Foundation

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

// MARK: - 解析器（纯函数）

/// 块级 + 行内 Markdown 解析器，全部为无状态纯函数。
/// 渲染层可直接消费 `[MarkdownBlock]` AST。
enum MarkdownParser {

    // MARK: 块级

    /// 把 Markdown 文本解析为块级 AST。
    /// `references` 为上层（文档级）已收集的引用定义表，向所有嵌套块与行内解析贯穿；
    /// 本层预扫描会在合并后覆盖同名 key。
    static func parse(_ markdown: String, references: [String: LinkReference] = [:]) -> [MarkdownBlock] {
        guard !markdown.isEmpty else { return [] }
        let scan = scanLinkReferences(markdown.components(separatedBy: "\n"))
        let lines = scan.lines
        var referenceMap = references
        referenceMap.merge(scan.references) { _, new in new }
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(parseInlines(paragraph.joined(separator: "\n"), references: referenceMap)))
            paragraph.removeAll()
        }

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // 围栏代码块（``` 开始，``` 结束；未闭合时剩余整体按代码块）。
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let tag = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        index += 1
                        break
                    }
                    codeLines.append(candidate)
                    index += 1
                }
                blocks.append(.codeBlock(
                    language: tag.isEmpty ? nil : tag,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            // 块级数学公式（$$…$$ / \[…\]）：单行与跨行两种形态；必须放在围栏代码块之后。
            if let math = parseMathBlock(lines: lines, start: index) {
                flushParagraph()
                blocks.append(math.block)
                index = math.next
                continue
            }

            // 水平分隔线：整行由 ≥3 个 `-` / `*` / `_` 组成。
            // 与列表（需 `- ` 前缀+内容）、表格分隔行（必须含 `|`）、围栏代码块互斥，顺序无冲突。
            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.horizontalRule)
                index += 1
                continue
            }

            // 块级 HTML：行首 `<tag>` 外壳剥离后内部递归解析；无闭合则降级为普通段落。
            if let html = parseHTMLBlock(lines: lines, start: index, references: referenceMap) {
                flushParagraph()
                blocks.append(contentsOf: html.blocks)
                index = html.next
                continue
            }

            // 空行：段落分隔。
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // 标题（ATX，h1–h6）。
            if let heading = parseHeading(trimmed, references: referenceMap) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            // 引用块：连续以 > 开头的行。
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var content = String(candidate.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoted.append(content)
                    index += 1
                }
                blocks.append(.blockquote(parse(quoted.joined(separator: "\n"), references: referenceMap)))
                continue
            }

            // 表格：当前行含 | 且下一行是分隔行。
            if trimmed.contains("|"),
               index + 1 < lines.count,
               isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let result = parseTable(lines: lines, start: index, references: referenceMap)
                blocks.append(.table(result.table))
                index = result.next
                continue
            }

            // 脚注定义（`[^id]: 内容`，支持缩进续行）。
            if let footnote = parseFootnoteDefinition(lines: lines, start: index, references: referenceMap) {
                flushParagraph()
                blocks.append(footnote.block)
                index = footnote.next
                continue
            }

            // 列表。
            if isListLine(trimmed) {
                flushParagraph()
                let result = parseList(lines: lines, start: index, references: referenceMap)
                blocks.append(result.block)
                index = result.next
                continue
            }

            // 缩进代码块：连续 ≥4 空格（或 1 tab）且段落缓冲为空（不可打断段落）。
            if paragraph.isEmpty, indentation(of: raw) >= 4 {
                flushParagraph()
                var codeLines: [String] = []
                var cursor = index
                while cursor < lines.count {
                    let line = lines[cursor]
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        codeLines.append("")
                        cursor += 1
                        continue
                    }
                    if indentation(of: line) >= 4 || line.hasPrefix("\t") {
                        codeLines.append(dropIndent(line, 4))
                        cursor += 1
                    } else {
                        break
                    }
                }
                while let last = codeLines.last, last.isEmpty { codeLines.removeLast() }
                blocks.append(.codeBlock(language: nil, code: codeLines.joined(separator: "\n")))
                index = cursor
                continue
            }

            // Setext 标题：当前段落行（可含此前累积行）下一行为全 `=` → h1、全 `-` → h2。
            // 下一行若是列表行（如 `- `）则让位给列表解析。
            if index + 1 < lines.count {
                let nextTrimmed = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if !isListLine(nextTrimmed), let level = setextLevel(lines[index + 1]) {
                    let content = (paragraph + [raw]).joined(separator: "\n")
                    paragraph.removeAll()
                    blocks.append(.heading(level: level, inlines: parseInlines(content, references: referenceMap)))
                    index += 2
                    continue
                }
            }

            paragraph.append(raw)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: 行内

    /// 把行内 Markdown 文本解析为 token 数组。
    /// `references` 为引用式链接定义表（大小写不敏感 key），贯穿所有递归行内解析。
    static func parseInlines(_ text: String, references: [String: LinkReference] = [:]) -> [InlineToken] {
        guard !text.isEmpty else { return [] }
        let chars = Array(text)
        var tokens: [InlineToken] = []
        var buffer = ""
        var index = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            tokens.append(.text(buffer))
            buffer.removeAll()
        }

        while index < chars.count {
            let current = chars[index]

            // 行内数学 \(...\)：必须在反斜杠转义分支之前识别，否则 \( 会被当转义吃掉。
            if current == "\\", index + 1 < chars.count, chars[index + 1] == "(" {
                if let close = findClosingDelimiter(chars, from: index + 2, first: "\\", second: ")") {
                    let inner = String(chars[(index + 2)..<close])
                    if !inner.isEmpty {
                        flush()
                        tokens.append(.math(inner))
                        index = close + 2
                        continue
                    }
                }
            }

            // 反斜杠 + 换行 → 硬换行。
            if current == "\\", index + 1 < chars.count, chars[index + 1] == "\n" {
                flush()
                tokens.append(.lineBreak)
                index += 2
                continue
            }

            // 反斜杠转义。
            if current == "\\", index + 1 < chars.count {
                buffer.append(chars[index + 1])
                index += 2
                continue
            }

            // 行内代码（N 个反引号开启必须 N 个闭合；内部不解析）。
            if current == "`" {
                var backtickCount = 0
                while index + backtickCount < chars.count, chars[index + backtickCount] == "`" {
                    backtickCount += 1
                }
                if let close = findClosingBackticks(chars, from: index + backtickCount, count: backtickCount) {
                    var inner = String(chars[(index + backtickCount)..<close])
                    if inner.count >= 2, inner.hasPrefix(" "), inner.hasSuffix(" ") {
                        inner = String(inner.dropFirst().dropLast())
                    }
                    if !inner.isEmpty {
                        flush()
                        tokens.append(.code(inner))
                        index = close + backtickCount
                        continue
                    }
                    // 空内容按字面处理。
                    for _ in 0..<backtickCount { buffer.append("`") }
                    index += backtickCount
                    continue
                }
                for _ in 0..<backtickCount { buffer.append("`") }
                index += backtickCount
                continue
            }

            // 行内数学 $...$（在行内代码之后、粗体斜体之前；货币启发式保护见 parseInlineMath）。
            if current == "$", let math = parseInlineMath(chars, from: index) {
                flush()
                tokens.append(.math(math.content))
                index = math.next
                continue
            }

            // 硬换行：行尾 ≥2 空格 + 换行。
            if current == "\n" {
                var trailingSpaces = 0
                for character in buffer.reversed() {
                    if character == " " { trailingSpaces += 1 } else { break }
                }
                if trailingSpaces >= 2 {
                    while buffer.last == " " { buffer.removeLast() }
                    flush()
                    tokens.append(.lineBreak)
                    index += 1
                    continue
                }
            }

            // 图片：行内 ![alt](url "title")，或引用式 ![alt][label] / ![alt][] / ![alt]。
            if current == "!", index + 1 < chars.count, chars[index + 1] == "[" {
                if let image = parseLinkOrImage(chars, from: index + 1) {
                    flush()
                    tokens.append(.image(
                        alt: image.label,
                        url: image.url,
                        title: image.title
                    ))
                    index = image.next
                    continue
                }
                if let image = parseReferenceImage(chars, from: index + 1, references: references) {
                    flush()
                    tokens.append(.image(alt: image.alt, url: image.url, title: image.title))
                    index = image.next
                    continue
                }
            }

            // 脚注引用 [^id]（优先于链接，`[^` 不构成链接）。
            if current == "[", index + 1 < chars.count, chars[index + 1] == "^" {
                if let close = findClosing(chars, from: index + 2, marker: "]") {
                    let identifier = String(chars[(index + 2)..<close])
                    if !identifier.isEmpty {
                        flush()
                        tokens.append(.footnoteRef(identifier))
                        index = close + 1
                        continue
                    }
                }
            }

            // 链接：行内 [text](url "title")，或引用式 [text][label] / [text][] / 速记 [label]。
            if current == "[" {
                if let link = parseLinkOrImage(chars, from: index) {
                    flush()
                    tokens.append(.link(
                        text: parseInlines(link.label, references: references),
                        url: link.url,
                        title: link.title
                    ))
                    index = link.next
                    continue
                }
                if let reference = parseReferenceLink(chars, from: index, references: references) {
                    flush()
                    // 速记形式文本按字面输出；全形 / collapsed 形式文本递归解析。
                    let textTokens = reference.recursivelyParsedText
                        ? parseInlines(reference.text, references: references)
                        : [.text(reference.text)]
                    tokens.append(.link(text: textTokens, url: reference.url, title: reference.title))
                    index = reference.next
                    continue
                }
            }

            // 自动链接 <https://…> / <mailto:…>，以及行内 HTML 标签子集。
            if current == "<" {
                if let auto = parseAutolink(chars, from: index) {
                    flush()
                    tokens.append(auto.token)
                    index = auto.next
                    continue
                }
                if let html = parseInlineHTML(chars, from: index, references: references) {
                    flush()
                    tokens.append(contentsOf: html.tokens)
                    index = html.next
                    continue
                }
            }

            // 删除线 ~~text~~。
            if current == "~", index + 1 < chars.count, chars[index + 1] == "~",
               let close = findClosingDouble(chars, from: index + 2, marker: "~") {
                let inner = String(chars[(index + 2)..<close])
                if !inner.isEmpty {
                    flush()
                    tokens.append(.strikethrough(parseInlines(inner, references: references)))
                    index = close + 2
                    continue
                }
            }

            // 粗体 / 斜体（*/_ 双符号优先）。
            if current == "*" || current == "_" {
                let isDouble = index + 1 < chars.count && chars[index + 1] == current
                if isDouble, let close = findClosingDouble(chars, from: index + 2, marker: current) {
                    let inner = String(chars[(index + 2)..<close])
                    if !inner.isEmpty {
                        flush()
                        tokens.append(.bold(parseInlines(inner, references: references)))
                        index = close + 2
                        continue
                    }
                }
                if let close = findClosingSingle(chars, from: index + 1, marker: current) {
                    let inner = String(chars[(index + 1)..<close])
                    if !inner.isEmpty {
                        flush()
                        tokens.append(.italic(parseInlines(inner, references: references)))
                        index = close + 1
                        continue
                    }
                }
            }

            // HTML 实体解码（纯文本阶段的 &amp; / &#NNN; / &#xHH;）。
            if current == "&", let entity = parseEntity(chars, from: index) {
                buffer += entity.decoded
                index = entity.next
                continue
            }

            // 裸 URL（http:// / https:// / www.）。
            if current == "h" || current == "w", let bare = matchBareURL(chars, from: index) {
                flush()
                tokens.append(bare.token)
                index = bare.next
                continue
            }

            buffer.append(current)
            index += 1
        }
        flush()
        return tokens
    }

    // MARK: - 内部：块级数学

    /// 块级数学公式解析：支持 `$$` 跨行 / 单行 `$$…$$` 与 `\[` 跨行 / 单行 `\[…\]`。
    /// 跨行未闭合时，把剩余全部行收进公式（与围栏代码块同策略）。
    private static func parseMathBlock(lines: [String], start: Int) -> (block: MarkdownBlock, next: Int)? {
        let trimmed = lines[start].trimmingCharacters(in: .whitespaces)

        // \[ … \] 跨行
        if trimmed == "\\[" {
            return collectMathBody(lines: lines, start: start, closer: "\\]")
        }
        // \[ … \] 单行
        if trimmed.hasPrefix("\\["), trimmed.hasSuffix("\\]"), trimmed.count > 4 {
            let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            return (.mathBlock(latex: inner), start + 1)
        }

        // $$ … $$ 跨行
        if trimmed == "$$" {
            return collectMathBody(lines: lines, start: start, closer: "$$")
        }
        // $$ … $$ 单行
        if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
            let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            return (.mathBlock(latex: inner), start + 1)
        }

        return nil
    }

    /// 从 start 的下一行起收集到 closer 行；未闭合则把剩余全部收进。
    private static func collectMathBody(lines: [String], start: Int, closer: String) -> (block: MarkdownBlock, next: Int) {
        var body: [String] = []
        var index = start + 1
        while index < lines.count {
            let candidate = lines[index].trimmingCharacters(in: .whitespaces)
            if candidate == closer {
                return (.mathBlock(latex: normalizeMathBody(body)), index + 1)
            }
            body.append(lines[index])
            index += 1
        }
        return (.mathBlock(latex: normalizeMathBody(body)), index)
    }

    private static func normalizeMathBody(_ body: [String]) -> String {
        body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 内部：标题

    private static func parseHeading(_ trimmed: String, references: [String: LinkReference] = [:]) -> MarkdownBlock? {
        var level = 0
        for character in trimmed {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.hasPrefix(" ") else { return nil }
        return .heading(level: level, inlines: parseInlines(String(rest.dropFirst()), references: references))
    }

    /// Setext 下划线判定：整行（去首尾空白）全为 `=` → 1，全为 `-` → 2。
    private static func setextLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    // MARK: - 内部：列表

    /// 是否为列表行（无序 `- ` / `* ` / `+ `，或有序 `1. `）。
    private static func isListLine(_ trimmed: String) -> Bool {
        parseListMarker(trimmed) != nil
    }

    /// 解析列表标记：返回有序性、序号（无序为 nil）、标记宽度（含标记后空白）与首行内容。
    private static func parseListMarker(_ text: String) -> (ordered: Bool, number: Int?, markerWidth: Int, content: String)? {
        let chars = Array(text)
        guard let first = chars.first else { return nil }

        if first == "-" || first == "*" || first == "+" {
            guard chars.count >= 2, chars[1] == " " || chars[1] == "\t" else { return nil }
            var width = 1
            while width < chars.count, chars[width] == " " || chars[width] == "\t" { width += 1 }
            guard width < chars.count else { return nil }
            return (false, nil, width, String(chars[width...]))
        }

        guard first.isNumber else { return nil }
        var digits = 0
        while digits < chars.count, chars[digits].isNumber { digits += 1 }
        guard digits < chars.count, chars[digits] == "." else { return nil }
        var width = digits + 1
        guard width < chars.count, chars[width] == " " || chars[width] == "\t" else { return nil }
        while width < chars.count, chars[width] == " " || chars[width] == "\t" { width += 1 }
        guard width < chars.count else { return nil }
        guard let number = Int(String(chars[0..<digits])) else { return nil }
        return (true, number, width, String(chars[width...]))
    }

    /// 任务标记：`[ ]` / `[x]` / `[X]`（后可选空白），返回勾选状态与剩余内容。
    private static func parseTaskMarker(_ text: String) -> (checked: Bool, rest: String)? {
        let chars = Array(text)
        guard chars.count >= 3, chars[0] == "[", chars[2] == "]" else { return nil }
        let mark = chars[1]
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        var rest = String(chars[3...])
        if rest.hasPrefix(" ") || rest.hasPrefix("\t") { rest.removeFirst() }
        return (mark != " ", rest)
    }

    /// 列表解析：同级连续行成顶层项；缩进更深的行归入当前项，交由递归 `parse` 形成嵌套列表 / 多块内容。
    private static func parseList(lines: [String], start: Int, references: [String: LinkReference] = [:]) -> (block: MarkdownBlock, next: Int) {
        let baseIndent = indentation(of: lines[start])
        guard let firstMarker = parseListMarker(lines[start].trimmingCharacters(in: .whitespaces)) else {
            return (.unorderedList([]), start + 1)
        }
        let ordered = firstMarker.ordered

        var items: [MarkdownListItem] = []
        var index = start

        while index < lines.count {
            // 跳过条目间的空行：仅当后续仍为同级同类型列表行时继续。
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                var k = index
                while k < lines.count, lines[k].trimmingCharacters(in: .whitespaces).isEmpty { k += 1 }
                index = k
                guard k < lines.count else { break }
                let nextTrimmed = lines[k].trimmingCharacters(in: .whitespaces)
                if let marker = parseListMarker(nextTrimmed),
                   indentation(of: lines[k]) == baseIndent,
                   marker.ordered == ordered {
                    continue
                }
                break
            }

            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let marker = parseListMarker(trimmed),
                  indentation(of: raw) == baseIndent,
                  marker.ordered == ordered else { break }

            let contentIndent = baseIndent + marker.markerWidth
            var firstContent = marker.content
            var taskState: Bool? = nil
            if let task = parseTaskMarker(firstContent) {
                taskState = task.checked
                firstContent = task.rest
            }

            var contentLines: [String] = [firstContent]
            var cursor = index + 1
            while cursor < lines.count {
                let contRaw = lines[cursor]
                let contTrimmed = contRaw.trimmingCharacters(in: .whitespaces)
                if contTrimmed.isEmpty {
                    var k = cursor
                    while k < lines.count, lines[k].trimmingCharacters(in: .whitespaces).isEmpty { k += 1 }
                    guard k < lines.count else { break }
                    let nextIndent = indentation(of: lines[k])
                    let nextTrimmed = lines[k].trimmingCharacters(in: .whitespaces)
                    let continues = parseListMarker(nextTrimmed) != nil
                        ? nextIndent > baseIndent
                        : nextIndent >= contentIndent
                    if continues {
                        for _ in cursor..<k { contentLines.append("") }
                        cursor = k
                        continue
                    }
                    break
                }
                let indent = indentation(of: contRaw)
                if parseListMarker(contTrimmed) != nil, indent <= baseIndent { break }
                if indent >= contentIndent {
                    contentLines.append(dropIndent(contRaw, contentIndent))
                    cursor += 1
                } else if indent > baseIndent {
                    contentLines.append(dropIndent(contRaw, min(indent, contentIndent)))
                    cursor += 1
                } else {
                    break
                }
            }

            let itemBlocks = parse(contentLines.joined(separator: "\n"), references: references)
            items.append(MarkdownListItem(number: marker.number, taskState: taskState, blocks: itemBlocks))
            index = cursor
        }

        let block: MarkdownBlock = ordered ? .orderedList(items) : .unorderedList(items)
        return (block, index)
    }

    private static func indentation(of line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 }
            else if character == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    /// 去掉行首至多 columns 列的缩进（tab 记 4 列）。
    private static func dropIndent(_ line: String, _ columns: Int) -> String {
        var removed = 0
        var start = line.startIndex
        while removed < columns, start < line.endIndex {
            let character = line[start]
            if character == " " {
                removed += 1
                start = line.index(after: start)
            } else if character == "\t" {
                removed += 4
                start = line.index(after: start)
            } else {
                break
            }
        }
        return String(line[start...])
    }

    // MARK: - 内部：脚注定义

    /// 脚注定义：`[^id]: 内容`，合并后续 ≥4 空格（或 tab）缩进续行。
    private static func parseFootnoteDefinition(lines: [String], start: Int, references: [String: LinkReference] = [:]) -> (block: MarkdownBlock, next: Int)? {
        let trimmed = lines[start].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[^") else { return nil }
        guard let close = trimmed.firstIndex(of: "]") else { return nil }
        let afterClose = trimmed.index(after: close)
        guard afterClose < trimmed.endIndex, trimmed[afterClose] == ":" else { return nil }
        let idStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let identifier = String(trimmed[idStart..<close])
        guard !identifier.isEmpty else { return nil }

        var content = String(trimmed[trimmed.index(after: afterClose)...])
        if content.hasPrefix(" ") { content.removeFirst() }
        var parts: [String] = [content]

        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                var k = index
                while k < lines.count, lines[k].trimmingCharacters(in: .whitespaces).isEmpty { k += 1 }
                guard k < lines.count,
                      indentation(of: lines[k]) >= 4 || lines[k].hasPrefix("\t") else { break }
                for _ in index..<k { parts.append("") }
                index = k
                continue
            }
            if indentation(of: line) >= 4 || line.hasPrefix("\t") {
                parts.append(dropIndent(line, 4))
                index += 1
                continue
            }
            break
        }

        while let last = parts.last, last.isEmpty { parts.removeLast() }
        let body = parts.joined(separator: "\n")
        return (.footnoteDefinition(id: identifier, inlines: parseInlines(body, references: references)), index)
    }

    // MARK: - 内部：块级 HTML

    /// 常见块级标签集合（大小写不敏感）。
    private static let blockHTMLTags: Set<String> = [
        "div", "p", "section", "article", "details", "summary", "figure", "figcaption",
        "blockquote", "table", "thead", "tbody", "tfoot", "tr", "td", "th",
        "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6",
        "center", "header", "footer", "main", "nav", "aside", "pre", "form", "fieldset",
        "dl", "dt", "dd", "address", "video", "audio", "canvas"
    ]

    /// 块级 HTML：行首 `<tag …>` 到深度计数匹配的同名 `</tag>` 结束，剥离外壳后内部递归解析。
    /// `<hr>` / `<hr/>` 整行 → horizontalRule。无闭合或非块级标签返回 nil（降级为普通段落）。
    private static func parseHTMLBlock(lines: [String], start: Int, references: [String: LinkReference] = [:]) -> (blocks: [MarkdownBlock], next: Int)? {
        let trimmed = lines[start].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<") else { return nil }
        let chars = Array(trimmed)
        guard chars.count > 1, chars[1] != "/", chars[1] != "!", chars[1] != "?" else { return nil }

        var cursor = 1
        var name = ""
        while cursor < chars.count, chars[cursor].isLetter || chars[cursor].isNumber {
            name.append(chars[cursor])
            cursor += 1
        }
        guard !name.isEmpty else { return nil }
        let tag = name.lowercased()

        if tag == "hr" {
            return ([.horizontalRule], start + 1)
        }
        guard blockHTMLTags.contains(tag) else { return nil }
        guard let closeLine = findClosingHTMLTagLine(lines: lines, start: start, tag: tag) else { return nil }

        var innerLines: [String] = []
        if closeLine == start {
            let lineChars = Array(lines[start])
            if let gt = findCharacter(">", in: lineChars, from: 0) {
                let afterOpen = String(lineChars[(gt + 1)...])
                let closePattern = "</" + tag
                if let range = afterOpen.range(of: closePattern, options: .caseInsensitive) {
                    innerLines.append(String(afterOpen[afterOpen.startIndex..<range.lowerBound]))
                } else {
                    innerLines.append(afterOpen)
                }
            }
        } else {
            let lineChars = Array(lines[start])
            if let gt = findCharacter(">", in: lineChars, from: 0) {
                innerLines.append(String(lineChars[(gt + 1)...]))
            }
            if closeLine > start + 1 {
                innerLines.append(contentsOf: lines[(start + 1)..<closeLine])
            }
            let closeRaw = lines[closeLine]
            let closePattern = "</" + tag
            if let range = closeRaw.range(of: closePattern, options: .caseInsensitive) {
                innerLines.append(String(closeRaw[closeRaw.startIndex..<range.lowerBound]))
            }
        }

        let inner = innerLines.joined(separator: "\n")
        return (parse(inner, references: references), closeLine + 1)
    }

    /// 从 start 行起按同名标签深度计数，返回匹配闭合标签所在行；未闭合返回 nil。
    private static func findClosingHTMLTagLine(lines: [String], start: Int, tag: String) -> Int? {
        var depth = 0
        var index = start
        while index < lines.count {
            let (opens, closes) = countHTMLTag(lines[index], tag: tag)
            depth += opens - closes
            if depth <= 0, index >= start { return index }
            index += 1
        }
        return nil
    }

    /// 统计一行内某标签的开 / 闭次数（忽略自闭合）。
    private static func countHTMLTag(_ line: String, tag: String) -> (opens: Int, closes: Int) {
        let lower = Array(line.lowercased())
        let openPattern = Array("<" + tag)
        let closePattern = Array("</" + tag)
        var opens = 0
        var closes = 0
        var index = 0
        while index < lower.count {
            if lower[index] == "<" {
                if matches(lower, at: index, pattern: closePattern) {
                    closes += 1
                    index += closePattern.count
                    continue
                }
                if matches(lower, at: index, pattern: openPattern) {
                    let afterName = index + openPattern.count
                    if afterName >= lower.count || !(lower[afterName].isLetter || lower[afterName].isNumber) {
                        var gt = afterName
                        while gt < lower.count, lower[gt] != ">" { gt += 1 }
                        if gt < lower.count, gt > 0, lower[gt - 1] == "/" {
                            // 自闭合，不计深度
                        } else {
                            opens += 1
                        }
                        index = gt + 1
                        continue
                    }
                }
            }
            index += 1
        }
        return (opens, closes)
    }

    // MARK: - 内部：表格

    /// 水平分隔线（thematic break）：整行由 ≥3 个相同字符 `-` / `*` / `_` 组成且不含其他字符。
    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3, let first = trimmed.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    /// 表格分隔行：仅由 |、-、:、空格组成，且至少含一个 -。
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let allowed: Set<Character> = ["|", "-", ":", " "]
        return trimmed.allSatisfy { allowed.contains($0) }
    }

    /// 解析单列对齐：`:` 在左→left、在右→right、两端→center、无→nil。
    private static func parseAlignment(_ cell: String) -> MarkdownTableAlignment? {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let hasLeft = trimmed.hasPrefix(":")
        let hasRight = trimmed.hasSuffix(":")
        if hasLeft, hasRight { return .center }
        if hasLeft { return .left }
        if hasRight { return .right }
        return nil
    }

    private static func parseTable(lines: [String], start: Int, references: [String: LinkReference] = [:]) -> (table: MarkdownTable, next: Int) {
        let headerCells = splitTableCells(lines[start])
        let separatorCells = splitTableCells(lines[start + 1])
        var alignments: [MarkdownTableAlignment?] = separatorCells.map { parseAlignment($0) }
        while alignments.count < headerCells.count { alignments.append(nil) }
        if alignments.count > headerCells.count { alignments = Array(alignments.prefix(headerCells.count)) }

        var rows: [[[InlineToken]]] = []
        var index = start + 2 // 跳过表头与分隔行

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || !trimmed.contains("|") { break }
            rows.append(splitTableCells(lines[index]).map { parseInlines($0, references: references) })
            index += 1
        }

        let table = MarkdownTable(
            headers: headerCells.map { parseInlines($0, references: references) },
            rows: rows,
            alignments: alignments
        )
        return (table, index)
    }

    /// 拆分表格行单元格：去掉首尾竖线后按 | 切分并 trim。
    private static func splitTableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - 内部：行内辅助

    private static func findCharacter(_ character: Character, in chars: [Character], from: Int) -> Int? {
        var index = from
        while index < chars.count {
            if chars[index] == character { return index }
            index += 1
        }
        return nil
    }

    private static func findClosing(_ chars: [Character], from: Int, marker: Character) -> Int? {
        var index = from
        while index < chars.count {
            if chars[index] == marker { return index }
            index += 1
        }
        return nil
    }

    /// 查找双字符定界符序列（如 `\)`）的起始位置。
    private static func findClosingDelimiter(_ chars: [Character], from: Int, first: Character, second: Character) -> Int? {
        var index = from
        while index + 1 < chars.count {
            if chars[index] == first, chars[index + 1] == second { return index }
            index += 1
        }
        return nil
    }

    /// 查找恰好 count 个连续反引号的闭合序列起始位置。
    private static func findClosingBackticks(_ chars: [Character], from: Int, count: Int) -> Int? {
        var index = from
        while index < chars.count {
            if chars[index] == "`" {
                var run = 0
                while index + run < chars.count, chars[index + run] == "`" { run += 1 }
                if run == count { return index }
                index += run
            } else {
                index += 1
            }
        }
        return nil
    }

    /// 行内数学 `$...$` 识别 + 货币保护启发式。
    /// 开定界符：`$` 后必须紧跟非 `$`、非空白字符；
    /// 闭定界符：前一个字符不得为空白，后一个字符不得为数字，且不能是 `$$` 的开头。
    /// 不满足任一条件则返回 nil，交由调用方按普通字符处理（如「$5 和 $10」不会被误判）。
    private static func parseInlineMath(_ chars: [Character], from: Int) -> (content: String, next: Int)? {
        guard from + 1 < chars.count else { return nil }
        let next = chars[from + 1]
        guard next != "$", !next.isWhitespace else { return nil }

        var close = from + 1
        while close < chars.count {
            if chars[close] == "$" {
                let prev = chars[close - 1]
                let afterIsDigit = close + 1 < chars.count && chars[close + 1].isNumber
                let afterIsDollar = close + 1 < chars.count && chars[close + 1] == "$"
                if !prev.isWhitespace, !afterIsDigit, !afterIsDollar {
                    let content = String(chars[(from + 1)..<close])
                    if !content.isEmpty {
                        return (content, close + 1)
                    }
                }
            }
            close += 1
        }
        return nil
    }

    private static func findClosingDouble(_ chars: [Character], from: Int, marker: Character) -> Int? {
        var index = from
        while index + 1 < chars.count {
            if chars[index] == marker && chars[index + 1] == marker { return index }
            index += 1
        }
        return nil
    }

    /// 找单个标记（排除成对的双标记）。
    private static func findClosingSingle(_ chars: [Character], from: Int, marker: Character) -> Int? {
        var index = from
        while index < chars.count {
            if chars[index] == marker {
                let nextIsSame = index + 1 < chars.count && chars[index + 1] == marker
                let prevIsSame = index - 1 >= 0 && chars[index - 1] == marker
                if !nextIsSame && !prevIsSame { return index }
            }
            index += 1
        }
        return nil
    }

    /// 链接 / 图片共用解析：从 `[` 起解析 `label](url "title")`。
    /// 闭合 `]` 采用 bracket 配对计数（支持内层 `[...]` / `![...]` 嵌套），
    /// `(...)` 目标容忍括号平衡与字符串内括号。
    /// 返回标签原文、地址与可选标题，及结束位置。
    private static func parseLinkOrImage(_ chars: [Character], from: Int) -> (label: String, url: String, title: String?, next: Int)? {
        guard from < chars.count, chars[from] == "[" else { return nil }
        guard let closeBracket = findClosingBracket(chars, from: from + 1) else { return nil }
        guard closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(" else { return nil }

        var index = closeBracket + 2
        // CommonMark 允许 `(` 后出现空白 / 换行。
        while index < chars.count, chars[index].isWhitespace { index += 1 }

        var url = ""
        if index < chars.count, chars[index] == "<" {
            guard let angleClose = findCharacter(">", in: chars, from: index + 1) else { return nil }
            url = String(chars[(index + 1)..<angleClose])
            index = angleClose + 1
        } else if let destination = parseLinkDestination(chars, from: index) {
            url = destination.url
            index = destination.next
        } else {
            return nil
        }

        while index < chars.count, chars[index].isWhitespace { index += 1 }

        var title: String? = nil
        if index < chars.count, isTitleOpener(chars[index]) {
            guard let parsed = parseLinkTitle(chars, from: index) else { return nil }
            title = parsed.title
            index = parsed.next
            while index < chars.count, chars[index].isWhitespace { index += 1 }
        }

        guard index < chars.count, chars[index] == ")" else { return nil }
        let label = String(chars[(from + 1)..<closeBracket])
        guard !label.isEmpty, !url.isEmpty else { return nil }
        return (label, url, title, index + 1)
    }

    // MARK: - 内部：链接 / 引用定义

    /// 查找与起始 `[` 配对的闭合 `]`。扫描时跳过反斜杠转义，
    /// 并对内层 `[` / `]` 做配对计数，从而正确支持 `[![alt](img)](url)` 等嵌套结构。
    private static func findClosingBracket(_ chars: [Character], from: Int) -> Int? {
        var depth = 0
        var index = from
        while index < chars.count {
            let character = chars[index]
            if character == "\\", index + 1 < chars.count {
                index += 2
                continue
            }
            if character == "[" {
                depth += 1
            } else if character == "]" {
                if depth == 0 { return index }
                depth -= 1
            }
            index += 1
        }
        return nil
    }

    /// 解析链接目标（非 `<>` 形式）：容忍括号平衡（含嵌套），遇空白或未配对 `)` 结束。
    private static func parseLinkDestination(_ chars: [Character], from: Int) -> (url: String, next: Int)? {
        var depth = 0
        var result = ""
        var index = from
        while index < chars.count {
            let character = chars[index]
            if character == "\\", index + 1 < chars.count {
                result.append(chars[index + 1])
                index += 2
                continue
            }
            if character.isWhitespace { break }
            if character == "(" {
                depth += 1
            } else if character == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            result.append(character)
            index += 1
        }
        guard depth == 0, !result.isEmpty else { return nil }
        return (result, index)
    }

    /// 解析链接标题：`"…"` / `'…'` / `(…)` 三种形式，返回标题与结束位置。
    private static func parseLinkTitle(_ chars: [Character], from: Int) -> (title: String, next: Int)? {
        guard from < chars.count else { return nil }
        let opener = chars[from]
        let closer: Character
        switch opener {
        case "\"": closer = "\""
        case "'": closer = "'"
        case "(": closer = ")"
        default: return nil
        }
        var result = ""
        var index = from + 1
        while index < chars.count {
            let character = chars[index]
            if character == "\\", index + 1 < chars.count {
                result.append(chars[index + 1])
                index += 2
                continue
            }
            if character == closer { return (result, index + 1) }
            result.append(character)
            index += 1
        }
        return nil
    }

    private static func isTitleOpener(_ character: Character) -> Bool {
        character == "\"" || character == "'" || character == "("
    }

    /// 归一化引用 label：折叠内部连续空白为单空格、去首尾空白、大小写不敏感（统一小写）。
    /// 空 label 或以 `^` 开头（脚注定义）返回 nil。
    private static func normalizeReferenceLabel(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard !collapsed.hasPrefix("^") else { return nil }
        return collapsed.lowercased()
    }

    /// 预扫描整篇 Markdown：收集引用定义行并从行流中移除；跳过 fenced code block 区域。
    /// 返回过滤后的行与定义表（key 已归一化，重复定义后者覆盖前者）。
    private static func scanLinkReferences(_ lines: [String]) -> (lines: [String], references: [String: LinkReference]) {
        var filtered: [String] = []
        var references: [String: LinkReference] = [:]
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                filtered.append(line)
                continue
            }
            if !inFence, let definition = parseLinkReferenceDefinition(line) {
                references[definition.key] = definition.reference
                continue
            }
            filtered.append(line)
        }
        return (filtered, references)
    }

    /// 解析单行引用定义 `[label]: destination "title"`。
    /// 允许 ≤3 空格缩进；label 非空且不以 `^` 开头；destination 可 `<>` 包裹；
    /// title 可选（三种引号形式）；定义行后的多余内容视为非法，整体不作为定义。
    private static func parseLinkReferenceDefinition(_ line: String) -> (key: String, reference: LinkReference)? {
        guard indentation(of: line) <= 3 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let chars = Array(trimmed)
        guard chars.count > 2, chars[0] == "[" else { return nil }
        guard chars[1] != "^" else { return nil }
        guard let close = findClosing(chars, from: 1, marker: "]") else { return nil }
        guard close + 1 < chars.count, chars[close + 1] == ":" else { return nil }
        guard let key = normalizeReferenceLabel(String(chars[1..<close])) else { return nil }

        var index = close + 2
        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }

        var destination = ""
        if index < chars.count, chars[index] == "<" {
            guard let angleClose = findCharacter(">", in: chars, from: index + 1) else { return nil }
            destination = String(chars[(index + 1)..<angleClose])
            index = angleClose + 1
        } else if let parsed = parseLinkDestination(chars, from: index) {
            destination = parsed.url
            index = parsed.next
        } else {
            return nil
        }

        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }

        var title: String? = nil
        if index < chars.count, isTitleOpener(chars[index]) {
            guard let parsed = parseLinkTitle(chars, from: index) else { return nil }
            title = parsed.title
            index = parsed.next
            while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
        }

        // 定义行尾部不得残留内容。
        guard index >= chars.count else { return nil }
        return (key, LinkReference(destination: destination, title: title))
    }

    /// 行内引用式链接：`[text][label]`、`[text][]`（collapsed）、`[label]`（速记）。
    /// 返回链接文本原文、是否递归解析文本、url、title 与结束位置；未命中返回 nil。
    private static func parseReferenceLink(
        _ chars: [Character],
        from: Int,
        references: [String: LinkReference]
    ) -> (text: String, recursivelyParsedText: Bool, url: String, title: String?, next: Int)? {
        guard from < chars.count, chars[from] == "[" else { return nil }
        guard let close = findClosingBracket(chars, from: from + 1) else { return nil }
        let text = String(chars[(from + 1)..<close])
        guard !text.isEmpty else { return nil }

        let next = close + 1
        if next < chars.count, chars[next] == "[" {
            // 全形式 / collapsed：第二个 `[...]` 为 label；空 label 表示 collapsed（label = text）。
            guard let labelClose = findClosingBracket(chars, from: next + 1) else { return nil }
            let rawLabel = String(chars[(next + 1)..<labelClose])
            let lookupRaw = rawLabel.isEmpty ? text : rawLabel
            guard let key = normalizeReferenceLabel(lookupRaw),
                  let reference = references[key] else { return nil }
            return (text, true, reference.destination, reference.title, labelClose + 1)
        }

        // 速记形式：label 不含空白，直接查表；文本按字面输出。
        guard !text.contains(where: { $0.isWhitespace }) else { return nil }
        guard let key = normalizeReferenceLabel(text),
              let reference = references[key] else { return nil }
        return (text, false, reference.destination, reference.title, next)
    }

    /// 行内引用式图片：`![alt][label]`、`![alt][]`、`![alt]`。alt 始终为字面文本。
    private static func parseReferenceImage(
        _ chars: [Character],
        from: Int,
        references: [String: LinkReference]
    ) -> (alt: String, url: String, title: String?, next: Int)? {
        guard from < chars.count, chars[from] == "[" else { return nil }
        guard let close = findClosingBracket(chars, from: from + 1) else { return nil }
        let alt = String(chars[(from + 1)..<close])
        guard !alt.isEmpty else { return nil }

        var next = close + 1
        let lookupRaw: String
        if next < chars.count, chars[next] == "[" {
            guard let labelClose = findClosingBracket(chars, from: next + 1) else { return nil }
            let rawLabel = String(chars[(next + 1)..<labelClose])
            lookupRaw = rawLabel.isEmpty ? alt : rawLabel
            next = labelClose + 1
        } else {
            lookupRaw = alt
        }

        guard let key = normalizeReferenceLabel(lookupRaw),
              let reference = references[key] else { return nil }
        return (alt, reference.destination, reference.title, next)
    }

    // MARK: - 内部：自动链接与裸 URL

    /// `<https://…>` / `<mailto:…>` 自动链接。
    private static func parseAutolink(_ chars: [Character], from: Int) -> (token: InlineToken, next: Int)? {
        guard let gt = findCharacter(">", in: chars, from: from + 1) else { return nil }
        let inner = String(chars[(from + 1)..<gt])
        guard !inner.isEmpty else { return nil }
        guard inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") else { return nil }
        return (.link(text: [.text(decodeHTMLEntities(inner))], url: inner, title: nil), gt + 1)
    }

    /// 裸 URL：`http://` / `https://` / `www.` 开头的连续非空白词。
    /// 尾部 `.,!?)];:` 剥离，未配对的 `)` 剥离；`www.` 补全为 `https://`。
    private static func matchBareURL(_ chars: [Character], from: Int) -> (token: InlineToken, next: Int)? {
        // 起始边界：仅允许出现在行首或空白 / 常见标点之后。
        if from > 0 {
            let previous = chars[from - 1]
            let boundary: Set<Character> = [" ", "\t", "\n", "(", "[", "{", "\"", "'", "<", "|", "*", "_", "-", ">"]
            if !boundary.contains(previous) { return nil }
        }

        let prefix = String(chars[from..<min(from + 8, chars.count)])
        let isHTTP = prefix.hasPrefix("http://") || prefix.hasPrefix("https://")
        let isWWW = String(chars[from..<min(from + 4, chars.count)]) == "www."
        guard isHTTP || isWWW else { return nil }

        var end = from
        while end < chars.count, !chars[end].isWhitespace { end += 1 }
        guard end > from else { return nil }

        var token = String(chars[from..<end])
        let trailing: Set<Character> = [".", ",", "!", "?", ")", "]", ";", ":"]
        while let last = token.last, trailing.contains(last) { token.removeLast() }
        while token.last == ")" {
            let opens = token.filter { $0 == "(" }.count
            let closes = token.filter { $0 == ")" }.count
            if closes > opens { token.removeLast() } else { break }
        }
        guard !token.isEmpty else { return nil }

        let url = token.hasPrefix("www.") ? "https://" + token : token
        return (.link(text: [.text(token)], url: url, title: nil), from + token.count)
    }

    // MARK: - 内部：行内 HTML

    /// 行内 HTML 标签子集（大小写不敏感）：已知标签映射为对应 token；
    /// 未知标签剥离外壳后内部继续解析；`<br>` / `<br/>` → lineBreak；`<img>` / `<a>` 解析属性。
    private static func parseInlineHTML(_ chars: [Character], from: Int, references: [String: LinkReference] = [:]) -> (tokens: [InlineToken], next: Int)? {
        guard from + 1 < chars.count else { return nil }
        let afterChar = chars[from + 1]
        guard afterChar.isLetter || afterChar == "/" else { return nil }
        guard let gt = findCharacter(">", in: chars, from: from + 1) else { return nil }
        let innerString = String(chars[(from + 1)..<gt])
        guard !innerString.isEmpty else { return nil }

        if innerString.hasPrefix("/") {
            // 游离闭合标签：剥壳。
            return ([], gt + 1)
        }
        if innerString.hasPrefix("!") || innerString.hasPrefix("?") { return nil }

        let tagChars = Array(innerString)
        var cursor = 0
        while cursor < tagChars.count, tagChars[cursor] == " " { cursor += 1 }
        var name = ""
        while cursor < tagChars.count, tagChars[cursor].isLetter || tagChars[cursor].isNumber {
            name.append(tagChars[cursor])
            cursor += 1
        }
        guard !name.isEmpty else { return nil }
        let tag = name.lowercased()
        let attributes = parseAttributes(String(tagChars[cursor...]))
        let afterOpen = gt + 1

        // 空 / 自闭合标签。
        if tag == "br" { return ([.lineBreak], afterOpen) }
        if tag == "img" {
            let src = decodeHTMLEntities(attributes["src"] ?? "")
            let alt = decodeHTMLEntities(attributes["alt"] ?? "")
            let title = attributes["title"].map { decodeHTMLEntities($0) }
            guard !src.isEmpty else { return ([], afterOpen) }
            return ([.image(alt: alt, url: src, title: title)], afterOpen)
        }
        if innerString.hasSuffix("/") { return ([], afterOpen) }

        // 需要闭合标签的成对标签；找不到闭合则按字面处理。
        guard let closeStart = findClosingTag(chars, from: afterOpen, name: tag) else { return nil }
        guard let closeGt = findCharacter(">", in: chars, from: closeStart + 2 + tag.count) else { return nil }
        let content = String(chars[afterOpen..<closeStart])
        let next = closeGt + 1

        switch tag {
        case "b", "strong":
            return ([.bold(parseInlines(content, references: references))], next)
        case "i", "em":
            return ([.italic(parseInlines(content, references: references))], next)
        case "u":
            return ([.underline(parseInlines(content, references: references))], next)
        case "s", "del", "strike":
            return ([.strikethrough(parseInlines(content, references: references))], next)
        case "code", "kbd", "samp":
            return ([.code(content)], next)
        case "mark":
            return ([.highlight(parseInlines(content, references: references))], next)
        case "sub":
            return ([.subscript(parseInlines(content, references: references))], next)
        case "sup":
            return ([.superscript(parseInlines(content, references: references))], next)
        case "a":
            let href = decodeHTMLEntities(attributes["href"] ?? "")
            guard !href.isEmpty else { return ([], next) }
            let title = attributes["title"].map { decodeHTMLEntities($0) }
            return ([.link(text: parseInlines(content, references: references), url: href, title: title)], next)
        default:
            // 未知标签：剥外壳，内部内容继续行内解析。
            return (parseInlines(content, references: references), next)
        }
    }

    /// 查找 `</name>` 的起始位置（大小写不敏感，要求标签名后有边界）。
    private static func findClosingTag(_ chars: [Character], from: Int, name: String) -> Int? {
        let pattern = Array("</" + name.lowercased())
        var index = from
        while index < chars.count {
            if chars[index] == "<", matchesCaseInsensitive(chars, at: index, pattern: pattern) {
                let after = index + pattern.count
                if after >= chars.count || chars[after].isWhitespace || chars[after] == ">" {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    private static func matches(_ text: [Character], at index: Int, pattern: [Character]) -> Bool {
        guard index + pattern.count <= text.count else { return false }
        for offset in 0..<pattern.count where text[index + offset] != pattern[offset] { return false }
        return true
    }

    private static func matchesCaseInsensitive(_ text: [Character], at index: Int, pattern: [Character]) -> Bool {
        guard index + pattern.count <= text.count else { return false }
        for offset in 0..<pattern.count
        where String(text[index + offset]).lowercased() != String(pattern[offset]) {
            return false
        }
        return true
    }

    /// 容忍有无引号的属性解析，返回 key（小写）→ value。
    private static func parseAttributes(_ text: String) -> [String: String] {
        let chars = Array(text)
        var result: [String: String] = [:]
        var index = 0
        while index < chars.count {
            while index < chars.count, chars[index].isWhitespace { index += 1 }
            var key = ""
            while index < chars.count, chars[index] != "=", !chars[index].isWhitespace {
                key.append(chars[index])
                index += 1
            }
            while index < chars.count, chars[index].isWhitespace { index += 1 }
            if index < chars.count, chars[index] == "=" {
                index += 1
                while index < chars.count, chars[index].isWhitespace { index += 1 }
                var value = ""
                if index < chars.count, chars[index] == "\"" || chars[index] == "'" {
                    let quote = chars[index]
                    index += 1
                    while index < chars.count, chars[index] != quote {
                        value.append(chars[index])
                        index += 1
                    }
                    if index < chars.count { index += 1 }
                } else {
                    while index < chars.count, !chars[index].isWhitespace {
                        value.append(chars[index])
                        index += 1
                    }
                }
                if !key.isEmpty { result[key.lowercased()] = value }
            } else if !key.isEmpty {
                result[key.lowercased()] = ""
            }
        }
        return result
    }

    // MARK: - 内部：HTML 实体

    /// 常用命名实体表（≥40）。
    private static let htmlEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "prime": "′",
        "times": "×", "plusmn": "±", "darr": "↓", "uarr": "↑", "rarr": "→", "larr": "←",
        "harr": "↔", "ne": "≠", "le": "≤", "ge": "≥", "deg": "°", "middot": "·",
        "check": "✓", "cross": "✗", "star": "★", "hearts": "♥", "laquo": "«", "raquo": "»",
        "sect": "§", "para": "¶", "dagger": "†", "Dagger": "‡", "permil": "‰", "euro": "€",
        "pound": "£", "yen": "¥", "cent": "¢", "frac12": "½", "frac14": "¼", "frac34": "¾"
    ]

    /// 实体解码：命名 / 十进制 `&#NNN;` / 十六进制 `&#xHHHH;`。
    private static func parseEntity(_ chars: [Character], from: Int) -> (decoded: String, next: Int)? {
        guard from + 1 < chars.count, chars[from] == "&" else { return nil }
        var index = from + 1

        if chars[index] == "#" {
            index += 1
            guard index < chars.count else { return nil }
            var isHex = false
            if chars[index] == "x" || chars[index] == "X" {
                isHex = true
                index += 1
            }
            let hexDigits: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
                                             "a", "b", "c", "d", "e", "f", "A", "B", "C", "D", "E", "F"]
            var digits = ""
            while index < chars.count, isHex ? hexDigits.contains(chars[index]) : chars[index].isNumber {
                digits.append(chars[index])
                index += 1
            }
            guard !digits.isEmpty, index < chars.count, chars[index] == ";" else { return nil }
            guard let code = UInt32(digits, radix: isHex ? 16 : 10),
                  let scalar = UnicodeScalar(code) else { return nil }
            return (String(scalar), index + 1)
        }

        var name = ""
        while index < chars.count, chars[index].isLetter || chars[index].isNumber {
            name.append(chars[index])
            index += 1
        }
        guard !name.isEmpty, index < chars.count, chars[index] == ";" else { return nil }
        guard let value = htmlEntities[name] ?? htmlEntities[name.lowercased()] else { return nil }
        return (value, index + 1)
    }

    /// 对字符串中的 HTML 实体做解码（用于属性值）。
    private static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let chars = Array(text)
        var result = ""
        var index = 0
        while index < chars.count {
            if chars[index] == "&", let entity = parseEntity(chars, from: index) {
                result += entity.decoded
                index = entity.next
            } else {
                result.append(chars[index])
                index += 1
            }
        }
        return result
    }
}