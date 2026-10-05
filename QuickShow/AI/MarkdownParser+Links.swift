import Foundation

// 职责来源：MarkdownParser.swift 的链接 / 引用定义、自动链接与裸 URL 区。

extension MarkdownParser {

    // MARK: - 内部：链接 / 引用定义

    /// 查找与起始 `[` 配对的闭合 `]`。扫描时跳过反斜杠转义，
    /// 并对内层 `[` / `]` 做配对计数，从而正确支持 `[![alt](img)](url)` 等嵌套结构。
    static func findClosingBracket(_ chars: [Character], from: Int) -> Int? {
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
    static func parseLinkDestination(_ chars: [Character], from: Int) -> (url: String, next: Int)? {
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
    static func parseLinkTitle(_ chars: [Character], from: Int) -> (title: String, next: Int)? {
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

    static func isTitleOpener(_ character: Character) -> Bool {
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
    static func scanLinkReferences(_ lines: [String]) -> (lines: [String], references: [String: LinkReference]) {
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
    static func parseReferenceLink(
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
    static func parseReferenceImage(
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
    static func parseAutolink(_ chars: [Character], from: Int) -> (token: InlineToken, next: Int)? {
        guard let gt = findCharacter(">", in: chars, from: from + 1) else { return nil }
        let inner = String(chars[(from + 1)..<gt])
        guard !inner.isEmpty else { return nil }
        guard inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") else { return nil }
        return (.link(text: [.text(decodeHTMLEntities(inner))], url: inner, title: nil), gt + 1)
    }

    /// 裸 URL：`http://` / `https://` / `www.` 开头的连续非空白词。
    /// 尾部 `.,!?)];:` 剥离，未配对的 `)` 剥离；`www.` 补全为 `https://`。
    static func matchBareURL(_ chars: [Character], from: Int) -> (token: InlineToken, next: Int)? {
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
}
