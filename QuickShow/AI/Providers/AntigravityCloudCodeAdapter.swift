// AntigravityCloudCodeAdapter: 原生 Swift 直连 Google Cloud Code PA (Antigravity 官方云端网关) SSE 通道。
// 彻底剥离 agy CLI 本地进程 5.5 秒冷启动开销，首字上屏降至 1~2 秒，原生直通服务端 candidate.parts.thought 结构化思考流。
// 基于系统钥匙串动态感知活跃凭据，遇到 HTTP 401 自动检测钥匙串更新并执行自愈重试。
// 针对 SSE 流式协议进行定制优化：历史上下文严格交替归一合并，杜绝 MALFORMED_FUNCTION_CALL；独立专用会话隔离管理。

import Foundation
import os

enum AntigravityCloudCodeAdapter {

    private static let logger = Logger(subsystem: "cn.chiproad.QuickShow", category: "AntigravityDirect")
    private static let endpoint = "https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse"

    /// 内存中缓存的最新有效 Token
    private static var activeAccessToken: String?

    /// 专用于 SSE 流式长连接的 URLSession
    private static let directSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    // MARK: - 凭据模型与读取

    struct TokenBundle {
        let accessToken: String
        let refreshToken: String?
        let expiryDate: Date?
    }

    /// 从本地凭据文件读取 (~/.gemini/jetski-standalone-oauth-token)
    static func fetchFileTokenBundle() -> TokenBundle? {
        let path = "\(NSHomeDirectory())/.gemini/jetski-standalone-oauth-token"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokenObj = json["token"] as? [String: Any],
              let accessToken = tokenObj["access_token"] as? String,
              !accessToken.isEmpty else {
            return nil
        }
        let refreshToken = tokenObj["refresh_token"] as? String
        var expiryDate: Date?
        if let expiryStr = tokenObj["expiry"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiryDate = formatter.date(from: expiryStr) ?? ISO8601DateFormatter().date(from: expiryStr)
        }
        return TokenBundle(accessToken: accessToken, refreshToken: refreshToken, expiryDate: expiryDate)
    }

    /// 从本地凭据文件读取 Access Token (~/.gemini/jetski-standalone-oauth-token)
    static func fetchFileToken() -> String? {
        fetchFileTokenBundle()?.accessToken
    }

    /// 统一解析可用的 Access Token (单一真源：优先 QuickShow 专属持久化密钥，内存活跃缓存协同，绝不主动刺探系统钥匙串)
    static func resolveAccessToken(explicitKey: String?) -> String? {
        // 0. 优先使用最近生效的内存 Token
        if let active = activeAccessToken, !active.isEmpty {
            return active
        }

        // 1. 优先使用 QuickShow 自身持久化保存的显式 Key (用户配置或 Touch ID 导入并已安全落盘至 keys/antigravity.key)
        let trimmed = explicitKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty && !trimmed.hasPrefix("AIzaSy") {
            let token: String
            if trimmed.hasPrefix("Bearer ") {
                token = String(trimmed.dropFirst(7))
            } else {
                token = trimmed
            }
            if !token.isEmpty {
                activeAccessToken = token
                return token
            }
        }

        // 2. 兜底读取本地独立凭据文件 (~/.gemini/jetski-standalone-oauth-token)
        if let fileToken = fetchFileToken() {
            activeAccessToken = fileToken
            return fileToken
        }

        return nil
    }

    /// 解析当前 Google Cloud Project ID
    static func resolveProjectId() -> String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["GOOGLE_CLOUD_PROJECT"], !p.isEmpty { return p }
        if let p = env["GOOGLE_CLOUD_PROJECT_ID"], !p.isEmpty { return p }
        return "363803525110"
    }

    // MARK: - 模型与思考强度映射

    /// 映射为 Antigravity 官方服务端受支持的模型 ID
    static func resolveModelId(_ id: String, effort: ThinkingLevel?) -> String {
        let clean = id.replacingOccurrences(of: "antigravity/", with: "")
        switch clean {
        case "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash":
            switch effort {
            case .high: return "gemini-3.6-flash-high"
            case .medium: return "gemini-3.6-flash-medium"
            case .low, .off: return "gemini-3.6-flash-low"
            case nil: return "gemini-3.6-flash-high"
            }
        case "gemini-3.1-pro", "gemini-2.5-pro":
            switch effort {
            case .low, .off: return "gemini-3.1-pro-low"
            default: return "gemini-pro-agent" // gemini-3.1-pro-high 会报 400 INVALID_ARGUMENT，pro 模型统一映射为 gemini-pro-agent
            }
        case "claude-opus", "claude-opus-4-6":
            return "claude-opus-4-6-thinking"
        case "claude-sonnet", "claude-sonnet-4-6":
            return "claude-sonnet-4-6"
        case "gpt-oss-120b":
            return "gpt-oss-120b-medium"
        default:
            return clean
        }
    }

    private static func shouldEnableThinking(for modelId: String, level: ThinkingLevel?) -> Bool {
        // 只要用户未显式关闭思考（.off），所有 Antigravity 模型默认开启服务端原生深度思考链
        if level == .off { return false }
        return true
    }

    // MARK: - 请求构造与流式直连

    static func buildRequest(
        modelId: String,
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions,
        token: String,
        projectId: String
    ) throws -> URLRequest {
        guard let url = URL(string: endpoint) else {
            throw AIChatError.network("无效的 Antigravity 直连端点: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("antigravity/2.0.6 darwin/arm64", forHTTPHeaderField: "User-Agent")

        var normalizedContents: [[String: Any]] = []
        var systemParts: [[String: Any]] = []

        for msg in messages {
            if msg.role == "system" {
                if let txt = msg.content?.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), !txt.isEmpty {
                    systemParts.append(["text": txt])
                }
                continue
            }

            let role = (msg.role == "assistant") ? "model" : "user"
            var parts: [[String: Any]] = []

            if let content = msg.content {
                switch content {
                case .text(let txt):
                    let trimmed = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { parts.append(["text": trimmed]) }
                case .parts(let partList):
                    for p in partList {
                        if let text = p.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                            parts.append(["text": text])
                        } else if let imageURL = p.imageURL {
                            let rawB64 = imageURL.url
                                .replacingOccurrences(of: "data:image/jpeg;base64,", with: "")
                                .replacingOccurrences(of: "data:image/png;base64,", with: "")
                            parts.append([
                                "inline_data": [
                                    "mime_type": "image/jpeg",
                                    "data": rawB64
                                ]
                            ])
                        }
                    }
                }
            }

            // 过滤空消息（例如截断残留或异常助手空轮次）
            guard !parts.isEmpty else { continue }

            // 关键合规修复：Gemini 要求 role 严格交替 (user -> model -> user -> model)。
            // 若历史消息存在连续相同角色（例如连续两次 user 提问或空轮次被忽略后形成的同角色），直接将其 parts 合并为一个 turn，彻底消除 MALFORMED_FUNCTION_CALL 截断
            if let last = normalizedContents.last, (last["role"] as? String) == role {
                var mergedParts = last["parts"] as? [[String: Any]] ?? []
                mergedParts.append(contentsOf: parts)
                normalizedContents[normalizedContents.count - 1]["parts"] = mergedParts
            } else {
                normalizedContents.append(["role": role, "parts": parts])
            }
        }

        // 确保首轮必须由 user 发起
        while let first = normalizedContents.first, (first["role"] as? String) != "user" {
            normalizedContents.removeFirst()
        }

        var requestObj: [String: Any] = ["contents": normalizedContents]
        if !systemParts.isEmpty {
            requestObj["system_instruction"] = ["parts": systemParts]
        }

        if shouldEnableThinking(for: modelId, level: options.thinkingLevel) {
            requestObj["generationConfig"] = [
                "thinkingConfig": [
                    "includeThoughts": true
                ]
            ]
        }

        let rootJSON: [String: Any] = [
            "project": projectId,
            "model": modelId,
            "request": requestObj
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: rootJSON)
        return request
    }

    /// 发起原生 HTTP SSE 直连流式生成（含 HTTP 401 自动检测钥匙串更新重试机制）
    static func stream(
        model: AIModelSpec,
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions,
        initialToken: String
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream<AIStreamEvent, Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let resolvedModel = resolveModelId(model.id, effort: options.thinkingLevel)
                    let projectId = resolveProjectId()
                    var currentToken = initialToken

                    logger.info("[AntigravityDirect] 发起原生直连请求: model=\(resolvedModel), project=\(projectId)")

                    var req = try buildRequest(
                        modelId: resolvedModel,
                        messages: messages,
                        options: options,
                        token: currentToken,
                        projectId: projectId
                    )

                    var (bytes, response) = try await directSession.bytes(for: req)
                    guard var http = response as? HTTPURLResponse else {
                        throw AIChatError.network("Antigravity 直连未收到 HTTP 响应")
                    }

                    // 自愈机制：如果遇到 401 Unauthorized，尝试检测本地独立凭据是否已刷新并重试一次
                    if http.statusCode == 401 {
                        logger.warning("[AntigravityDirect] 收到 HTTP 401，尝试检测本地凭据文件是否已更新...")
                        if let freshToken = fetchFileToken(), freshToken != currentToken {
                            currentToken = freshToken
                            activeAccessToken = freshToken
                            req = try buildRequest(
                                modelId: resolvedModel,
                                messages: messages,
                                options: options,
                                token: currentToken,
                                projectId: projectId
                            )
                            let (retryBytes, retryResponse) = try await directSession.bytes(for: req)
                            if let retryHttp = retryResponse as? HTTPURLResponse {
                                bytes = retryBytes
                                http = retryHttp
                                logger.info("[AntigravityDirect] 重试完成，HTTP 状态码: \(http.statusCode)")
                            }
                        }
                    }

                    guard (200..<300).contains(http.statusCode) else {
                        throw AIChatError.http(status: http.statusCode, message: "Antigravity 直连网关返回 HTTP \(http.statusCode)")
                    }

                    var hasReceivedFirstChunk = false

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmedLine.hasPrefix("data:") else { continue }

                        let rawJSON = trimmedLine.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        // 遇到 [DONE] 正常退出流
                        if rawJSON == "[DONE]" { break }
                        // 空行继续等待，绝不误杀退出
                        guard !rawJSON.isEmpty else { continue }

                        guard let data = rawJSON.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let resp = json["response"] as? [String: Any] else {
                            continue
                        }

                        // Usage 统计
                        if let usage = resp["usageMetadata"] as? [String: Any],
                           let inputTokens = usage["promptTokenCount"] as? Int {
                            continuation.yield(.usage(promptTokens: inputTokens))
                        }

                        // Candidates 分发 (含服务端原生结构化思考流与正文流)
                        if let candidates = resp["candidates"] as? [[String: Any]],
                           let firstCandidate = candidates.first,
                           let content = firstCandidate["content"] as? [String: Any],
                           let parts = content["parts"] as? [[String: Any]] {
                            for part in parts {
                                let isThought = part["thought"] as? Bool ?? false
                                if let text = part["text"] as? String, !text.isEmpty {
                                    if !hasReceivedFirstChunk {
                                        hasReceivedFirstChunk = true
                                        logger.info("[AntigravityDirect] 收到首个直连数据块 (isThought: \(isThought))")
                                    }
                                    if isThought {
                                        continuation.yield(.reasoning(text))
                                    } else {
                                        continuation.yield(.text(text))
                                    }
                                }
                            }
                        }
                    }

                    logger.info("[AntigravityDirect] 直连流顺利完成")
                    continuation.finish()
                } catch {
                    logger.error("[AntigravityDirect] 直连任务异常: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
