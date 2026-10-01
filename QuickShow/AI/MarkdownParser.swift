import Foundation

// MARK: - 行内 Token

/// 行内 Markdown 解析结果（粗体 / 斜体 / 行内代码 / 链接 / 纯文本）。
indirect enum InlineToken: Equatable {
    case text(String)
    case bold([InlineToken])
    case italic([InlineToken])
    case code(String)
    case link(text: [InlineToken], url: String)
}

// MARK: - 列表项

/// 列表项：支持无序 / 有序，以及一层嵌套子项。
struct MarkdownListItem: Equatable {
    var ordered: Bool
    /// 有序列表序号（无序为 nil）。
    var number: Int?
    var inlines: [InlineToken]
    /// 一层嵌套的子项。
    var children: [MarkdownListItem]
}

// MARK: - 表格

/// 表格：表头单元格与数据行；每个单元格为行内 token 数组。
struct MarkdownTable: Equatable {
    var headers: [[InlineToken]]
    var rows: [[[InlineToken]]]
}

// MARK: - 块级 AST

/// 块级 Markdown AST。blockquote 递归包含块级节点，故为 indirect enum。
indirect enum MarkdownBlock: Equatable {
    case heading(level: Int, inlines: [InlineToken])
    case paragraph([InlineToken])
    case orderedList([MarkdownListItem])
    case unorderedList([MarkdownListItem])
    case blockquote([MarkdownBlock])
    case table(MarkdownTable)
    case codeBlock(language: String?, code: String)
}

// MARK: - 解析器（纯函数）

/// 块级 + 行内 Markdown 解析器，全部为无状态纯函数。
/// Wave 2 的渲染层可直接消费 `[MarkdownBlock]` AST。
enum MarkdownParser {

    // MARK: 块级

    /// 把 Markdown 文本解析为块级 AST。
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        guard !markdown.isEmpty else { return [] }
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(parseInlines(paragraph.joined(separator: "\n"))))
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

            // 空行：段落分隔。
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // 标题。
            if let heading = parseHeading(trimmed) {
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
                blocks.append(.blockquote(parse(quoted.joined(separator: "\n"))))
                continue
            }

            // 表格：当前行含 | 且下一行是分隔行。
            if trimmed.contains("|"),
               index + 1 < lines.count,
               isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let result = parseTable(lines: lines, start: index)
                blocks.append(.table(result.table))
                index = result.next
                continue
            }

            // 列表。
            if isListLine(trimmed) {
                flushParagraph()
                let result = parseList(lines: lines, start: index)
                blocks.append(result.block)
                index = result.next
                continue
            }

            paragraph.append(raw)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: 行内

    /// 把行内 Markdown 文本解析为 token 数组（粗体 / 斜体 / 行内代码 / 链接 / 纯文本）。
    static func parseInlines(_ text: String) -> [InlineToken] {
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

            // 反斜杠转义。
            if current == "\\", index + 1 < chars.count {
                buffer.append(chars[index + 1])
                index += 2
                continue
            }

            // 行内代码（最高优先级，内部不再解析）。
            if current == "`", let close = findClosing(chars, from: index + 1, marker: "`") {
                flush()
                tokens.append(.code(String(chars[(index + 1)..<close])))
                index = close + 1
                continue
            }

            // 链接 [text](url)。
            if current == "[", let link = parseLink(chars, from: index) {
                flush()
                tokens.append(.link(text: parseInlines(link.label), url: link.url))
                index = link.next
                continue
            }

            // 粗体 / 斜体（*/_ 双符号优先）。
            if current == "*" || current == "_" {
                let isDouble = index + 1 < chars.count && chars[index + 1] == current
                if isDouble, let close = findClosingDouble(chars, from: index + 2, marker: current) {
                    let inner = String(chars[(index + 2)..<close])
                    if !inner.isEmpty {
                        flush()
                        tokens.append(.bold(parseInlines(inner)))
                        index = close + 2
                        continue
                    }
                }
                if let close = findClosingSingle(chars, from: index + 1, marker: current) {
                    let inner = String(chars[(index + 1)..<close])
                    if !inner.isEmpty {
                        flush()
                        tokens.append(.italic(parseInlines(inner)))
                        index = close + 1
                        continue
                    }
                }
            }

            buffer.append(current)
            index += 1
        }
        flush()
        return tokens
    }

    // MARK: - 内部：标题

    private static func parseHeading(_ trimmed: String) -> MarkdownBlock? {
        var level = 0
        for character in trimmed {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...3).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.hasPrefix(" ") else { return nil }
        return .heading(level: level, inlines: parseInlines(String(rest.dropFirst())))
    }

    // MARK: - 内部：列表

    /// 是否为列表行（无序 `- ` / `* ` / `+ `，或有序 `1. `）。
    private static func isListLine(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return true
        }
        return parseOrderedMarker(trimmed) != nil
    }

    private static func parseOrderedMarker(_ text: String) -> (number: Int, content: String)? {
        guard let range = text.range(of: #"^(\d+)\.\s+"#, options: .regularExpression) else { return nil }
        let prefix = text[range]
        let numberPart = prefix.prefix { $0.isNumber }
        guard let number = Int(numberPart) else { return nil }
        return (number, String(text[range.upperBound...]))
    }

    private static func makeListItem(from trimmed: String) -> MarkdownListItem {
        if let marker = parseOrderedMarker(trimmed) {
            return MarkdownListItem(
                ordered: true,
                number: marker.number,
                inlines: parseInlines(marker.content),
                children: []
            )
        }
        let content = String(trimmed.dropFirst(2))
        return MarkdownListItem(ordered: false, number: nil, inlines: parseInlines(content), children: [])
    }

    /// 列表解析：同级连续行成顶层项；缩进 ≥ 基准 +2 的行作为上一层项的子项（仅一层）。
    private static func parseList(lines: [String], start: Int) -> (block: MarkdownBlock, next: Int) {
        let baseIndent = indentation(of: lines[start])
        let firstTrimmed = lines[start].trimmingCharacters(in: .whitespaces)
        let ordered = parseOrderedMarker(firstTrimmed) != nil

        var items: [MarkdownListItem] = []
        var index = start

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || !isListLine(trimmed) { break }

            let indent = indentation(of: raw)
            if indent >= baseIndent + 2, !items.isEmpty {
                items[items.count - 1].children.append(makeListItem(from: trimmed))
            } else {
                items.append(makeListItem(from: trimmed))
            }
            index += 1
        }

        let block: MarkdownBlock = ordered ? .orderedList(items) : .unorderedList(items)
        return (block, index)
    }

    private static func indentation(of line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else { break }
        }
        return count
    }

    // MARK: - 内部：表格

    /// 表格分隔行：仅由 |、-、:、空格组成，且至少含一个 -。
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let allowed: Set<Character> = ["|", "-", ":", " "]
        return trimmed.allSatisfy { allowed.contains($0) }
    }

    private static func parseTable(lines: [String], start: Int) -> (table: MarkdownTable, next: Int) {
        let headerCells = splitTableCells(lines[start])
        var rows: [[[InlineToken]]] = []
        var index = start + 2 // 跳过表头与分隔行

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || !trimmed.contains("|") { break }
            rows.append(splitTableCells(lines[index]).map { parseInlines($0) })
            index += 1
        }

        let table = MarkdownTable(headers: headerCells.map { parseInlines($0) }, rows: rows)
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

    private static func findClosing(_ chars: [Character], from: Int, marker: Character) -> Int? {
        var index = from
        while index < chars.count {
            if chars[index] == marker { return index }
            index += 1
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

    private static func parseLink(_ chars: [Character], from: Int) -> (label: String, url: String, next: Int)? {
        guard let closeBracket = findClosing(chars, from: from + 1, marker: "]") else { return nil }
        guard closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(" else { return nil }
        guard let closeParen = findClosing(chars, from: closeBracket + 2, marker: ")") else { return nil }
        let label = String(chars[(from + 1)..<closeBracket])
        let url = String(chars[(closeBracket + 2)..<closeParen])
        guard !label.isEmpty, !url.isEmpty else { return nil }
        return (label, url, closeParen + 1)
    }
}