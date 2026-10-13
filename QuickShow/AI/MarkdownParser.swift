import Foundation

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

            // 围栏代码块（≥3 个连续 ` 或 ~ 开始，≥开启长度的同字符整行结束；未闭合时剩余整体按代码块）。
            if let fence = parseFenceOpen(trimmed) {
                flushParagraph()
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                    if isFenceClose(candidate.trimmingCharacters(in: .whitespaces), char: fence.char, minCount: fence.count) {
                        index += 1
                        break
                    }
                    codeLines.append(candidate)
                    index += 1
                }
                blocks.append(.codeBlock(
                    language: fence.tag.isEmpty ? nil : fence.tag,
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

            // YAML Front Matter（`---` 开启 + 连续 `key: value` 行 + `---`/`...` 闭合）：
            // 优先于水平分隔线与 Setext H2，避免元数据块被底线 `---` 误判为二级标题。
            if trimmed == "---", let frontMatter = parseFrontMatter(lines: lines, start: index) {
                flushParagraph()
                blocks.append(frontMatter.block)
                index = frontMatter.next
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

            // 引用块 / GitHub 风格提示块（> [!NOTE|TIP|IMPORTANT|WARNING|CAUTION]）：连续以 > 开头的行。
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
                if let first = quoted.first, let header = parseAlertHeader(first) {
                    var bodyLines = Array(quoted.dropFirst())
                    if !header.trailingText.isEmpty {
                        bodyLines.insert(header.trailingText, at: 0)
                    }
                    let innerBlocks = parse(bodyLines.joined(separator: "\n"), references: referenceMap)
                    blocks.append(.alert(kind: header.kind, blocks: innerBlocks))
                } else {
                    blocks.append(.blockquote(parse(quoted.joined(separator: "\n"), references: referenceMap)))
                }
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

            // 定义列表（`Term` + 下一行 `: Definition`）。
            if paragraph.isEmpty,
               let defList = parseDefinitionList(lines: lines, start: index, references: referenceMap) {
                flushParagraph()
                blocks.append(defList.block)
                index = defList.next
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

    /// 拆分表格行单元格：去掉首尾竖线后按未转义且不在行内反引号内的 `|` 切分并 trim。
    /// 同时将表格层面的转义管道符 `\|` 还原为字面 `|`。
    private static func splitTableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }

        let chars = Array(text)
        var cells: [String] = []
        var current = ""
        var inBackticks = 0
        var index = 0

        while index < chars.count {
            let ch = chars[index]

            // 表格级转义管道符 \|（在 GFM 中即便位于反引号内也优先作为表格管道符转义处理）
            if ch == "\\", index + 1 < chars.count, chars[index + 1] == "|" {
                current.append("|")
                index += 2
                continue
            }

            // 其它反斜杠转义（在反引号外跳过下一个字符，保留给 parseInlines）
            if ch == "\\", inBackticks == 0, index + 1 < chars.count {
                current.append(ch)
                current.append(chars[index + 1])
                index += 2
                continue
            }

            // 跟踪反引号开合
            if ch == "`" {
                var run = 0
                while index + run < chars.count, chars[index + run] == "`" { run += 1 }
                if inBackticks == 0 {
                    inBackticks = run
                } else if inBackticks == run {
                    inBackticks = 0
                }
                for _ in 0..<run { current.append("`") }
                index += run
                continue
            }

            // 仅在反引号外部切分单元格
            if ch == "|", inBackticks == 0 {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current.removeAll(keepingCapacity: true)
                index += 1
                continue
            }

            current.append(ch)
            index += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - 内部：围栏代码块 / YAML Front Matter / 定义列表 / GitHub Alert

    /// 识别围栏代码块开启行：连续 ≥3 个 `` ` `` 或 `~`（反引号围栏的 info string 中不得再含反引号）。
    static func parseFenceOpen(_ trimmed: String) -> (char: Character, count: Int, tag: String)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var count = 0
        for ch in trimmed {
            if ch == first { count += 1 } else { break }
        }
        guard count >= 3 else { return nil }
        let tag = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        if first == "`", tag.contains("`") { return nil }
        return (first, count, tag)
    }

    /// 识别围栏代码块闭合行：整行仅由 ≥minCount 个 `char` 组成。
    static func isFenceClose(_ trimmed: String, char: Character, minCount: Int) -> Bool {
        guard trimmed.count >= minCount else { return false }
        return trimmed.allSatisfy { $0 == char }
    }

    /// 识别 YAML Front Matter（`---` 开启，内部为连续 `key: value` 行，以 `---` 或 `...` 闭合）。
    private static func parseFrontMatter(lines: [String], start: Int) -> (block: MarkdownBlock, next: Int)? {
        var cursor = start + 1
        var body: [String] = []
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                guard !body.isEmpty else { return nil }
                return (.codeBlock(language: "yaml", code: body.joined(separator: "\n")), cursor + 1)
            }
            if trimmed.isEmpty { return nil }
            // 要求每一行均为 YAML 键值（含 `:`）或注释（`#`）或列表项（`- `）
            let isYAMLRow = trimmed.contains(":") || trimmed.hasPrefix("#") || trimmed.hasPrefix("- ")
            guard isYAMLRow else { return nil }
            body.append(lines[cursor])
            cursor += 1
        }
        return nil
    }

    /// 识别定义列表行前缀（`: 内容`）。
    private static func parseDefinitionMarker(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix(":") else { return nil }
        let after = trimmed.dropFirst()
        guard let first = after.first, first == " " || first == "\t" else { return nil }
        return String(after.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// 解析定义列表：连续的 `Term` + 一至多行 `: Definition`。
    private static func parseDefinitionList(
        lines: [String],
        start: Int,
        references: [String: LinkReference]
    ) -> (block: MarkdownBlock, next: Int)? {
        guard start + 1 < lines.count else { return nil }
        let firstDefTrimmed = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard parseDefinitionMarker(firstDefTrimmed) != nil else { return nil }

        var items: [MarkdownDefinitionItem] = []
        var cursor = start

        while cursor < lines.count {
            // 跳过组间空行（仅当空行后紧跟新的 `Term` + `: Definition` 时继续合并）
            if lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
                var k = cursor
                while k < lines.count, lines[k].trimmingCharacters(in: .whitespaces).isEmpty { k += 1 }
                if k + 1 < lines.count,
                   !lines[k].trimmingCharacters(in: .whitespaces).isEmpty,
                   parseDefinitionMarker(lines[k + 1].trimmingCharacters(in: .whitespaces)) != nil {
                    cursor = k
                } else {
                    break
                }
            }

            guard cursor + 1 < lines.count else { break }
            let termLine = lines[cursor].trimmingCharacters(in: .whitespaces)
            let nextLine = lines[cursor + 1].trimmingCharacters(in: .whitespaces)
            guard !termLine.isEmpty, parseDefinitionMarker(nextLine) != nil else { break }

            let termTokens = parseInlines(termLine, references: references)
            cursor += 1

            var definitions: [[InlineToken]] = []
            while cursor < lines.count {
                let defTrimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
                guard let defContent = parseDefinitionMarker(defTrimmed) else { break }
                definitions.append(parseInlines(defContent, references: references))
                cursor += 1
            }

            if !definitions.isEmpty {
                items.append(MarkdownDefinitionItem(term: termTokens, definitions: definitions))
            }
        }

        guard !items.isEmpty else { return nil }
        return (.definitionList(items), cursor)
    }

    /// 识别引用块首行的 `[!NOTE]` / `[!TIP]` / `[!IMPORTANT]` / `[!WARNING]` / `[!CAUTION]`（大小写不敏感）。
    /// 返回提示块类型与首行标记后可能紧跟的同行文本。
    private static func parseAlertHeader(_ firstLine: String) -> (kind: MarkdownAlertKind, trailingText: String)? {
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), let closeIndex = trimmed.firstIndex(of: "]") else { return nil }
        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let rawKind = String(trimmed[startIndex..<closeIndex]).trimmingCharacters(in: .whitespaces).lowercased()
        guard let kind = MarkdownAlertKind(rawValue: rawKind) else { return nil }
        let trailing = String(trimmed[trimmed.index(after: closeIndex)...]).trimmingCharacters(in: .whitespaces)
        return (kind, trailing)
    }

}
