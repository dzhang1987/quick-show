import Foundation

// 说明：各工具除协议层 snake_case name 外，另提供中文 displayName 与 category，
// 仅供设置页/卡片展示；发给模型的 name/schema 与执行链路完全不变。

// MARK: - web_search（Tavily）

/// 联网搜索：调用 Tavily Search API，返回直接答案与相关网页摘要
final class WebSearchTool: AITool {
    let name = "web_search"
    let displayName = "网页搜索"
    let category: ToolCategory = .web
    /// 纯读联网搜索，无共享可变状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
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
    let displayName = "抓取网页"
    let category: ToolCategory = .web
    /// 纯读网页抓取，无共享可变状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
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
        let decoded = HTMLTextExtractor.decodeText(data, contentType: contentType)

        var title: String?
        var content: String
        if isHTML {
            let working = decoded.count > Self.maxRawCharacters
                ? String(decoded.prefix(Self.maxRawCharacters))
                : decoded
            title = HTMLTextExtractor.extractTitle(working)
            content = HTMLTextExtractor.htmlToPlainText(working)
        } else {
            content = HTMLTextExtractor.collapseWhitespace(decoded)
        }

        // 正文超 64KB 按 UTF-8 字节截断
        let truncatedResult = HTMLTextExtractor.truncateToUTF8Bytes(content, maxBytes: Self.maxContentBytes)
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
