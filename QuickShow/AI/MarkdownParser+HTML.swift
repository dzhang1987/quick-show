import Foundation

// 职责来源：MarkdownParser.swift 的块级 HTML、行内 HTML 与 HTML 实体区。

extension MarkdownParser {

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
    static func parseHTMLBlock(lines: [String], start: Int, references: [String: LinkReference] = [:]) -> (blocks: [MarkdownBlock], next: Int)? {
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

    // MARK: - 内部：行内 HTML

    /// 行内 HTML 标签子集（大小写不敏感）：已知标签映射为对应 token；
    /// 未知标签剥离外壳后内部继续解析；`<br>` / `<br/>` → lineBreak；`<img>` / `<a>` 解析属性。
    static func parseInlineHTML(_ chars: [Character], from: Int, references: [String: LinkReference] = [:]) -> (tokens: [InlineToken], next: Int)? {
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
    static func parseEntity(_ chars: [Character], from: Int) -> (decoded: String, next: Int)? {
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
    static func decodeHTMLEntities(_ text: String) -> String {
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
