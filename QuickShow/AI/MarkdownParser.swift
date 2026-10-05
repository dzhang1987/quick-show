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

    /// 拆分表格行单元格：去掉首尾竖线后按 | 切分并 trim。
    private static func splitTableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

}
