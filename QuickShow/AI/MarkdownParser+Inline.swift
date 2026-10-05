import Foundation

// 职责来源：MarkdownParser.swift 的行内主解析区与行内辅助函数区。

extension MarkdownParser {

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

    // MARK: - 内部：行内辅助

    static func findCharacter(_ character: Character, in chars: [Character], from: Int) -> Int? {
        var index = from
        while index < chars.count {
            if chars[index] == character { return index }
            index += 1
        }
        return nil
    }

    static func findClosing(_ chars: [Character], from: Int, marker: Character) -> Int? {
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
}
