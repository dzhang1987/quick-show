import Foundation
import CoreFoundation

/// fetch_url 的 HTML → 纯文本引擎：按 charset 解码、剥离标签、解码实体、折叠空白、按 UTF-8 字节截断。
/// 纯函数集合，无状态；供 FetchURLTool 复用。
enum HTMLTextExtractor {

    // MARK: 解码

    /// 按 Content-Type 声明的 charset 解码；缺省依次尝试 UTF-8 / ISO-8859-1
    static func decodeText(_ data: Data, contentType: String) -> String {
        if let range = contentType.range(of: "charset=") {
            let charset = contentType[range.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;\"'"))
            switch charset {
            case "utf-8", "utf8":
                if let text = String(data: data, encoding: .utf8) { return text }
            case "gbk", "gb2312", "gb18030":
                let encoding = CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
                if let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) { return text }
            case "big5":
                let encoding = CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.big5.rawValue)
                )
                if let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) { return text }
            case "iso-8859-1", "latin1":
                if let text = String(data: data, encoding: .isoLatin1) { return text }
            default:
                break
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: HTML 提取

    /// HTML → 纯文本：去注释 / script / style / noscript → 去标签 → 解实体 → 折叠空白
    static func htmlToPlainText(_ html: String) -> String {
        var working = replaceRegex("<!--.*?-->", in: html, with: " ")
        working = replaceRegex("<script\\b.*?</script>", in: working, with: " ")
        working = replaceRegex("<style\\b.*?</style>", in: working, with: " ")
        working = replaceRegex("<noscript\\b.*?</noscript>", in: working, with: " ")
        working = replaceRegex("<[^>]*>", in: working, with: " ")
        return collapseWhitespace(decodeHTMLEntities(working))
    }

    /// 提取 <title> 文本（去实体并折叠空白）
    static func extractTitle(_ html: String) -> String? {
        guard let openRange = html.range(of: "<title", options: .caseInsensitive),
              let openEnd = html[openRange.upperBound...].firstIndex(of: ">"),
              let closeRange = html[html.index(after: openEnd)...].range(of: "</title", options: .caseInsensitive) else {
            return nil
        }
        let raw = String(html[html.index(after: openEnd)..<closeRange.lowerBound])
        let cleaned = collapseWhitespace(decodeHTMLEntities(raw))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 正则替换（忽略大小写、跨行匹配）
    static func replaceRegex(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    // MARK: 实体与空白

    /// 解码常见 HTML 实体 + 通用数字实体（&#123; / &#x1F;）。&amp; 最后解码，避免二次转义。
    static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&hellip;", with: "…")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
        result = decodeNumericEntities(result)
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }

    /// 通用数字实体解码：支持十进制 &#65; 与十六进制 &#x41;
    static func decodeNumericEntities(_ text: String) -> String {
        let pattern = "&#(x?)([0-9a-fA-F]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastLocation = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: lastLocation, length: match.range.location - lastLocation))
            let hexFlag = ns.substring(with: match.range(at: 1))
            let digits = ns.substring(with: match.range(at: 2))
            let radix = hexFlag.isEmpty ? 10 : 16
            if let code = UInt32(digits, radix: radix), let scalar = UnicodeScalar(code) {
                result.unicodeScalars.append(scalar)
            } else {
                // 非法码点：保留原文
                result += ns.substring(with: match.range)
            }
            lastLocation = match.range.location + match.range.length
        }
        result += ns.substring(from: lastLocation)
        return result
    }

    /// 折叠连续空白为单个空格并去除首尾
    static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按 UTF-8 字节数截断（中文等多字节字符不会被劈开）
    static func truncateToUTF8Bytes(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maxBytes else { return (text, false) }
        var result = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > maxBytes { break }
            result.append(character)
            bytes += size
        }
        return (result, true)
    }
}
