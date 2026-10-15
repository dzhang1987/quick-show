// AntigravityCloudCodeAdapter: 原生 Swift 直连 Google Cloud Code PA (Antigravity 官方云端网关) SSE 通道。
// 彻底剥离 agy CLI 本地进程 5.5 秒冷启动开销，首字上屏降至 1~2 秒，原生直通服务端 candidate.parts.thought 结构化思考流。
// 基于 Google OAuth 自动刷新机制与钥匙串协同：遇 Token 过期或 HTTP 401 自动使用 refresh_token 秒级刷新自愈。
// 针对 SSE 流式协议进行定制优化：历史上下文严格交替归一合并，杜绝 MALFORMED_FUNCTION_CALL；独立专用会话隔离管理。

import Foundation
import os

enum AntigravityCloudCodeAdapter {

    private static let logger = Logger(subsystem: "cn.chiproad.QuickShow", category: "AntigravityDirect")
    private static let endpoint = "https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse"

    // MARK: - Google OAuth 与云端网关常量配置
    static let oauthTokenEndpoint = "https://oauth2.googleapis.com/token"
    static let oauthClientId = "PLACEHOLDER_OAUTH_CLIENT_ID"
    static let oauthClientSecret = "PLACEHOLDER_OAUTH_CLIENT_SECRET"
    private static let loadCodeAssistEndpoint = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let fallbackProjectId = "aicode-consumers"
    private static let userAgent = "antigravity/2.0.6 darwin/arm64"

    private static let lock = NSLock()
    /// 内存中缓存的最新有效 Token
    private static var activeAccessToken: String?
    /// Token 过期时间
    private static var tokenExpiryDate: Date?
    /// 活跃的 refresh_token
    private static var activeRefreshToken: String?
    /// 缓存的 Project ID
    private static var cachedProjectId: String?

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

    /// 同步回写本地独立凭据文件 (~/.gemini/jetski-standalone-oauth-token)，让系统内其它协同工具同步受益
    static func updateLocalJetskiTokenFile(accessToken: String, expiresIn: Double) {
        let path = "\(NSHomeDirectory())/.gemini/jetski-standalone-oauth-token"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokenObj = json["token"] as? [String: Any] else {
            return
        }
        tokenObj["access_token"] = accessToken
        let expiryDate = Date().addingTimeInterval(expiresIn)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        tokenObj["expiry"] = formatter.string(from: expiryDate)
        json["token"] = tokenObj
        if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? updatedData.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// 使用 refresh_token 向 Google OAuth 端点刷新最新的 access_token
    @discardableResult
    static func refreshAccessToken(force: Bool = false) async -> String? {
        lock.lock()
        // 若未强制刷新，且当前 Token 距离过期超过 60 秒，直接复用
        if !force, let token = activeAccessToken, let expiry = tokenExpiryDate, expiry > Date().addingTimeInterval(60) {
            lock.unlock()
            return token
        }
        let existingRefreshToken = activeRefreshToken
        lock.unlock()

        // 尝试从多渠道提取可用的 refresh_token
        var rToken: String? = existingRefreshToken
        if rToken == nil || rToken?.isEmpty == true {
            rToken = fetchFileTokenBundle()?.refreshToken
        }
        if rToken == nil || rToken?.isEmpty == true {
            let saved = await MainActor.run { AIProviderStore.shared.accountInfo(for: "antigravity") }
            rToken = saved?.refreshToken
        }

        guard let validRefreshToken = rToken, !validRefreshToken.isEmpty else {
            logger.warning("[AntigravityDirect] 未找到可用的 refresh_token，无法执行自动刷新")
            return nil
        }

        guard let url = URL(string: oauthTokenEndpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "client_id": oauthClientId,
            "client_secret": oauthClientSecret,
            "grant_type": "refresh_token",
            "refresh_token": validRefreshToken
        ]
        let bodyString = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String, !newAccessToken.isEmpty else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.error("[AntigravityDirect] OAuth Token 刷新失败，HTTP: \(status)")
                return nil
            }

            let expiresIn = (json["expires_in"] as? Double) ?? 3600
            let newExpiry = Date().addingTimeInterval(expiresIn - 60)

            lock.lock()
            activeAccessToken = newAccessToken
            tokenExpiryDate = newExpiry
            activeRefreshToken = validRefreshToken
            lock.unlock()

            logger.info("[AntigravityDirect] OAuth Token 自动刷新成功，有效时长: \(expiresIn)s")

            // 安全回写本地凭据与持久化存储
            updateLocalJetskiTokenFile(accessToken: newAccessToken, expiresIn: expiresIn)
            await MainActor.run {
                AIProviderStore.shared.setAPIKey(newAccessToken, for: "antigravity")
                if var account = AIProviderStore.shared.accountInfo(for: "antigravity") {
                    account.refreshToken = validRefreshToken
                    AIProviderStore.shared.saveAccountInfo(account, for: "antigravity")
                }
            }

            return newAccessToken
        } catch {
            logger.error("[AntigravityDirect] 刷新 OAuth Token 网络异常: \(error.localizedDescription)")
            return nil
        }
    }

    /// 确保返回一个最新有效的 Access Token（若无有效 Token 或已过期，自动执行刷新自愈）
    static func ensureFreshAccessToken(explicitKey: String?) async -> String? {
        let trimmed = explicitKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty && !trimmed.hasPrefix("AIzaSy") {
            let token = trimmed.hasPrefix("Bearer ") ? String(trimmed.dropFirst(7)) : trimmed
            lock.lock()
            if let active = activeAccessToken, active == token, let expiry = tokenExpiryDate, expiry > Date().addingTimeInterval(60) {
                lock.unlock()
                return active
            }
            lock.unlock()
        }

        if let bundle = fetchFileTokenBundle() {
            lock.lock()
            if let exp = bundle.expiryDate, exp > Date().addingTimeInterval(60) {
                activeAccessToken = bundle.accessToken
                tokenExpiryDate = exp
                activeRefreshToken = bundle.refreshToken
                lock.unlock()
                return bundle.accessToken
            }
            if let r = bundle.refreshToken {
                activeRefreshToken = r
            }
            lock.unlock()
        }

        lock.lock()
        if let active = activeAccessToken, let expiry = tokenExpiryDate, expiry > Date().addingTimeInterval(60) {
            lock.unlock()
            return active
        }
        lock.unlock()

        // 执行秒级自动刷新
        return await refreshAccessToken()
    }

    /// 统一同步解析 Access Token（保底回退或显式 Key）
    static func resolveAccessToken(explicitKey: String?) -> String? {
        lock.lock()
        if let active = activeAccessToken, !active.isEmpty {
            lock.unlock()
            return active
        }
        lock.unlock()

        let trimmed = explicitKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty && !trimmed.hasPrefix("AIzaSy") {
            let token = trimmed.hasPrefix("Bearer ") ? String(trimmed.dropFirst(7)) : trimmed
            if !token.isEmpty {
                lock.lock()
                activeAccessToken = token
                lock.unlock()
                return token
            }
        }

        if let fileToken = fetchFileToken() {
            lock.lock()
            activeAccessToken = fileToken
            lock.unlock()
            return fileToken
        }

        return nil
    }

    /// 动态解析当前 Google Cloud Project ID
    static func resolveProjectId(token: String) async -> String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["GOOGLE_CLOUD_PROJECT"], !p.isEmpty { return p }
        if let p = env["GOOGLE_CLOUD_PROJECT_ID"], !p.isEmpty { return p }

        lock.lock()
        if let cached = cachedProjectId, !cached.isEmpty {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let url = URL(string: loadCodeAssistEndpoint) else { return fallbackProjectId }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = "{}".data(using: .utf8)
        req.timeoutInterval = 5

        if let (data, response) = try? await URLSession.shared.data(for: req),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let proj = json["cloudaicompanionProject"] as? String, !proj.isEmpty {
            lock.lock()
            cachedProjectId = proj
            lock.unlock()
            logger.info("[AntigravityDirect] 动态解析 Cloud Code Project 成功: \(proj)")
            return proj
        }

        return fallbackProjectId
    }

    // MARK: - 模型与思考强度映射

    /// 映射为 Antigravity 官方服务端受支持的模型 ID
    static func resolveModelId(_ id: String, effort: ThinkingLevel?) -> String {
        let clean = id.replacingOccurrences(of: "antigravity/", with: "")
        switch clean {
        case "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.8-flash-tiered",
             "gemini-3.8-flash-high", "gemini-3.8-flash-medium", "gemini-3.8-flash-low":
            return "gemini-3.8-flash-tiered"
        case "gemini-3-flash", "gemini-3-flash-agent":
            return "gemini-3-flash"
        case "gemini-3.1-pro", "gemini-2.5-pro", "gemini-pro", "gemini-pro-agent":
            return "gemini-3.8-flash-tiered"
        case "claude-opus", "claude-opus-4-6", "claude-opus-4-6-thinking":
            return "claude-opus-4-6-thinking"
        case "claude-sonnet", "claude-sonnet-4-6":
            return "claude-sonnet-4-6"
        case "gpt-oss-120b", "gpt-oss-120b-medium":
            return "gpt-oss-120b-medium"
        default:
            return clean
        }
    }

    private static func shouldEnableThinking(for modelId: String, level: ThinkingLevel?) -> Bool {
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
                    var currentToken = initialToken
                    let projectId = await resolveProjectId(token: currentToken)

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

                    // 自愈机制：如果遇到 401 Unauthorized，调用 OAuth 端点强制刷新并重试一次
                    if http.statusCode == 401 {
                        logger.warning("[AntigravityDirect] 收到 HTTP 401，立即执行 Token 自动刷新自愈...")
                        if let freshToken = await refreshAccessToken(force: true) {
                            currentToken = freshToken
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
                                logger.info("[AntigravityDirect] 自愈重试完成，HTTP 状态码: \(http.statusCode)")
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
