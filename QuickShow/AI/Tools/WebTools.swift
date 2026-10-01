import AppKit
import Foundation
import Security
import CoreFoundation

// MARK: - 联网工具配置

/// web_search 的 Tavily Key 存取（Keychain，敏感信息不落 UserDefaults）+ 环境变量兜底
enum WebToolsConfig {
    static let tavilyKeychainAccount = "tavilyApiKey"

    /// 复用 AIChatService 同一 keychain service，仅 account 区分，隔离不同用途的条目
    private static let keychainService = "com.dzhang.quickshow.ai"

    /// 读取：Keychain → 兜底 ProcessInfo env "QUICKSHOW_TAVILY_API_KEY"（env 只读不写）
    static var tavilyAPIKey: String? {
        var query = baseKeychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let value = String(data: data, encoding: .utf8),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }

        // 环境变量兜底：仅内存读取，绝不写入钥匙串
        if let env = ProcessInfo.processInfo.environment["QUICKSHOW_TAVILY_API_KEY"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env
        }
        return nil
    }

    /// 写入 Keychain（空字符串则删除钥匙串条目）。
    /// 采用与 AIChatService 相同的「先删后建」策略：确保条目 ACL 始终与当前签名一致，
    /// 避免旧签名条目在读取时反复弹钥匙串密码。
    static func setTavilyAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(baseKeychainQuery() as CFDictionary)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var addQuery = baseKeychainQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func baseKeychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tavilyKeychainAccount
        ]
    }
}

// MARK: - web_search（Tavily）

/// 联网搜索：调用 Tavily Search API，返回直接答案与相关网页摘要
final class WebSearchTool: AITool {
    let name = "web_search"
    let description = "联网搜索互联网最新信息。输入查询语句，返回 Tavily 生成的直接答案与相关网页摘要列表（含标题、链接、正文片段）。"

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "搜索查询语句"],
                "max_results": [
                    "type": "integer",
                    "description": "返回结果数量，范围 1~10，默认 5",
                    "minimum": 1,
                    "maximum": 10
                ]
            ],
            "required": ["query"]
        ]
    }

    private static let endpoint = URL(string: "https://api.tavily.com/search")!
    private static let timeout: TimeInterval = 15

    func execute(arguments: [String: Any]) async throws -> String {
        let query = try requiredString(arguments, "query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ToolExecutionError("query 不能为空")
        }

        // max_results：缺省 5，钳制到 1~10
        var maxResults = 5
        if let raw = arguments["max_results"], !(raw is NSNull) {
            if let intValue = raw as? Int {
                maxResults = intValue
            } else if let number = raw as? NSNumber {
                maxResults = number.intValue
            } else if let string = raw as? String, let parsed = Int(string) {
                maxResults = parsed
            } else {
                throw ToolExecutionError("max_results 类型错误，应为整数")
            }
            maxResults = min(max(maxResults, 1), 10)
        }

        guard let apiKey = WebToolsConfig.tavilyAPIKey, !apiKey.isEmpty else {
            throw ToolExecutionError("未配置 Tavily API Key，请在设置 → AI 工具中填写")
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "query": query,
            "max_results": maxResults,
            "search_depth": "basic",
            "include_answer": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ToolExecutionError("搜索请求失败：\(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw ToolExecutionError("搜索请求响应异常")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.extractServerError(data) ?? "未知错误"
            throw ToolExecutionError("搜索失败（HTTP \(http.statusCode)）：\(detail)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolExecutionError("搜索响应解析失败")
        }

        // answer：Tavily 生成的直接答案，可能缺失
        let answer = (json["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        // results[]：title / url / content / score
        var results: [[String: Any]] = []
        if let list = json["results"] as? [[String: Any]] {
            for item in list.prefix(maxResults) {
                var entry: [String: Any] = [
                    "title": item["title"] as? String ?? "",
                    "url": item["url"] as? String ?? "",
                    "content": item["content"] as? String ?? ""
                ]
                if let score = item["score"] as? Double {
                    entry["score"] = score
                } else if let score = item["score"] as? NSNumber {
                    entry["score"] = score.doubleValue
                }
                results.append(entry)
            }
        }

        let answerValue: Any = (answer?.isEmpty == false) ? answer! : NSNull()
        return toolSuccessJSON(["answer": answerValue, "results": results])
    }

    /// 从非 2xx 响应体提取服务端错误说明
    private static func extractServerError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = json["detail"] as? String, !detail.isEmpty { return detail }
        if let error = json["error"] as? String, !error.isEmpty { return error }
        if let message = json["message"] as? String, !message.isEmpty { return message }
        return nil
    }
}

// MARK: - fetch_url

/// 抓取并阅读网页：仅支持 text/html 与 text/plain，HTML 手写提取为纯文本
final class FetchURLTool: AITool {
    let name = "fetch_url"
    let description = "抓取指定网页并读取其内容，将 HTML 转换为纯文本返回。仅支持 text/html 与 text/plain。"

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "要抓取的网页地址（仅 http/https）"]
            ],
            "required": ["url"]
        ]
    }

    /// 正文（提取后的纯文本）上限：64KB（UTF-8 字节）
    private static let maxContentBytes = 64 * 1024
    /// 原始 HTML 处理上限：避免超长页面拖垮解析（字符数）
    private static let maxRawCharacters = 1_000_000
    private static let maxRedirects = 5
    private static let timeout: TimeInterval = 20
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    func execute(arguments: [String: Any]) async throws -> String {
        let rawURL = try requiredString(arguments, "url").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ToolExecutionError("仅支持 http/https 的 URL：\(rawURL)")
        }

        // 独立会话 + 重定向计数器（上限 5 次）；会话持有 delegate，结束后失效释放
        let delegate = RedirectLimiter(maxRedirects: Self.maxRedirects)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ToolExecutionError("抓取网页失败：\(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw ToolExecutionError("抓取网页响应异常")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ToolExecutionError("抓取失败（HTTP \(http.statusCode)）")
        }

        // Content-Type 前缀匹配：仅接受 text/html 与 text/plain
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let isHTML = contentType.hasPrefix("text/html")
        let isPlain = contentType.hasPrefix("text/plain")
        guard isHTML || isPlain else {
            let shown = contentType.isEmpty ? "未知" : contentType
            throw ToolExecutionError("不支持的内容类型：\(shown)（仅支持 text/html 与 text/plain）")
        }

        let finalURL = http.url?.absoluteString ?? url.absoluteString
        let decoded = decodeText(data, contentType: contentType)

        var title: String?
        var content: String
        if isHTML {
            let working = decoded.count > Self.maxRawCharacters
                ? String(decoded.prefix(Self.maxRawCharacters))
                : decoded
            title = extractTitle(working)
            content = htmlToPlainText(working)
        } else {
            content = collapseWhitespace(decoded)
        }

        // 正文超 64KB 按 UTF-8 字节截断
        let truncatedResult = truncateToUTF8Bytes(content, maxBytes: Self.maxContentBytes)
        content = truncatedResult.text

        let titleValue: Any = title ?? NSNull()
        let payload: [String: Any] = [
            "url": finalURL,
            "title": titleValue,
            "content": content,
            "truncated": truncatedResult.truncated,
            "length": content.count
        ]
        return toolSuccessJSON(payload)
    }

    // MARK: 解码

    /// 按 Content-Type 声明的 charset 解码；缺省依次尝试 UTF-8 / ISO-8859-1
    private func decodeText(_ data: Data, contentType: String) -> String {
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
    private func htmlToPlainText(_ html: String) -> String {
        var working = replaceRegex("<!--.*?-->", in: html, with: " ")
        working = replaceRegex("<script\\b.*?</script>", in: working, with: " ")
        working = replaceRegex("<style\\b.*?</style>", in: working, with: " ")
        working = replaceRegex("<noscript\\b.*?</noscript>", in: working, with: " ")
        working = replaceRegex("<[^>]*>", in: working, with: " ")
        return collapseWhitespace(decodeHTMLEntities(working))
    }

    /// 提取 <title> 文本（去实体并折叠空白）
    private func extractTitle(_ html: String) -> String? {
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
    private func replaceRegex(_ pattern: String, in text: String, with template: String) -> String {
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
    private func decodeHTMLEntities(_ text: String) -> String {
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
    private func decodeNumericEntities(_ text: String) -> String {
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
    private func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按 UTF-8 字节数截断（中文等多字节字符不会被劈开）
    private func truncateToUTF8Bytes(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
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

// MARK: - 重定向限制器

/// 限制 URLSession 跟随重定向的次数（超过上限则停止跟随）
private final class RedirectLimiter: NSObject, URLSessionTaskDelegate {
    private let maxRedirects: Int
    private let lock = NSLock()
    private var count = 0

    init(maxRedirects: Int) {
        self.maxRedirects = maxRedirects
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let allowed = count < maxRedirects
        if allowed { count += 1 }
        lock.unlock()
        completionHandler(allowed ? request : nil)
    }
}