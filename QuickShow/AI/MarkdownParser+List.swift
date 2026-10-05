import Foundation

// 职责来源：MarkdownParser.swift 的列表解析区与脚注定义区。

extension MarkdownParser {

    // MARK: - 内部：列表

    /// 是否为列表行（无序 `- ` / `* ` / `+ `，或有序 `1. `）。
    static func isListLine(_ trimmed: String) -> Bool {
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
    static func parseList(lines: [String], start: Int, references: [String: LinkReference] = [:]) -> (block: MarkdownBlock, next: Int) {
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

    static func indentation(of line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 }
            else if character == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    /// 去掉行首至多 columns 列的缩进（tab 记 4 列）。
    static func dropIndent(_ line: String, _ columns: Int) -> String {
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
    static func parseFootnoteDefinition(lines: [String], start: Int, references: [String: LinkReference] = [:]) -> (block: MarkdownBlock, next: Int)? {
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
}
