// QoderProvider: Qoder 国际版原生协议 Provider 实现。
// 纯原生 Swift 实现 PAT 兑换 JobToken、UserInfo 缓存、自定义 Base64 重排与 COSY 请求头签名 (RSA PKCS1 + MD5 + AES-128-CBC)。

import Foundation
import os

final class QoderProvider: LLMProvider, @unchecked Sendable {
    let providerType: AIProviderType = .qoderNative

    private let logger = Logger(subsystem: "com.dzhang.quickshow.ai", category: "qoderProvider")

    // 内存凭据缓存 (PAT -> JobToken + UserInfo + 到期时间戳)
    private final class CredentialCache: @unchecked Sendable {
        struct Entry {
            let jobToken: String
            let userId: String
            let name: String
            let email: String
            let expiresAt: Date
        }
        private let lock = NSLock()
        private var cache: [String: Entry] = [:]

        func get(for pat: String) -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            if let entry = cache[pat], entry.expiresAt > Date() {
                return entry
            }
            return nil
        }

        func set(_ entry: Entry, for pat: String) {
            lock.lock()
            defer { lock.unlock() }
            cache[pat] = entry
        }
    }

    private let credentialCache = CredentialCache()

    init() {}

    func supportedAuthMethods(for provider: AIProvider) -> [any AIAuthMethod] {
        [
            DefaultAPIKeyAuthMethod(
                providerId: provider.id,
                displayName: "Personal Access Token",
                detailDescription: "手工配置 Qoder 访问令牌 (PAT)",
                placeholder: "输入 Personal Access Token",
                footerText: "令牌仅保存在本机受保护目录，绝不上云"
            ),
            QoderBiometricAuthMethod(),
            QoderDeviceFlowBrowserAuthMethod()
        ]
    }

    func stream(
        provider: AIProvider,
        model: AIModelSpec,
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions,
        apiKey: String
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let isLocal = provider.baseURL.contains("127.0.0.1") || provider.baseURL.contains("localhost")
        if isLocal {
            // 本地桥接模式直接委托 OpenAI 协议
            return OpenAIProvider().stream(provider: provider, model: model, messages: messages, options: options, apiKey: apiKey)
        }

        return AsyncThrowingStream<AIStreamEvent, Error> { continuation in
            let task = Task {
                do {
                    let cred = try await resolveCredentials(pat: apiKey)
                    let cleanModelId = model.id.replacingOccurrences(of: "qoder/", with: "")
                    let isReasoning = (options.thinkingLevel == .off) ? false : model.supportsThinking

                    var systemText = ""
                    let currentAgent = await MainActor.run {
                        AIAgentStore.shared.agent(for: options.agentId ?? "") ?? AIAgentStore.shared.activeAgent
                    }
                    let agentTools = await MainActor.run {
                        if options.disableTools { return [AITool]() }
                        return AIToolRegistry.shared.tools(for: currentAgent)
                    }

                    var toolsPayload: [[String: Any]] = []
                    for tool in agentTools {
                        toolsPayload.append([
                            "type": "function",
                            "function": [
                                "name": tool.name,
                                "description": tool.description,
                                "parameters": tool.parametersSchema
                            ]
                        ])
                    }

                    var userMessages: [[String: Any]] = []
                    var lastUserText = ""

                    for msg in messages {
                        if msg.role == "system" {
                            let text = msg.content?.extractedText ?? ""
                            if !text.isEmpty {
                                systemText += (systemText.isEmpty ? "" : "\n") + text
                            }
                        } else {
                            if msg.role == "user" {
                                if let text = msg.content?.extractedText, !text.isEmpty {
                                    lastUserText = text
                                }
                            }
                            if let encodedMsgData = try? JSONEncoder().encode(msg),
                               let dict = try? JSONSerialization.jsonObject(with: encodedMsgData) as? [String: Any] {
                                userMessages.append(dict)
                            } else {
                                let rawContent = msg.content?.extractedText ?? ""
                                userMessages.append([
                                    "role": msg.role,
                                    "content": rawContent
                                ])
                            }
                        }
                    }

                    if userMessages.isEmpty {
                        userMessages.append([
                            "role": "user",
                            "content": systemText.isEmpty ? "你好" : systemText
                        ])
                    }

                    let recordID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
                    let sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))

                    let requestBody: [String: Any] = [
                        "request_id": UUID().uuidString,
                        "request_set_id": recordID,
                        "chat_record_id": recordID,
                        "session_id": sessionID,
                        "stream": true,
                        "chat_task": "FREE_INPUT",
                        "is_reply": true,
                        "is_retry": false,
                        "source": 1,
                        "version": "3",
                        "session_type": "qodercli",
                        "agent_id": "agent_common",
                        "task_id": "common",
                        "code_language": "",
                        "chat_prompt": "",
                        "image_urls": NSNull(),
                        "aliyun_user_type": "",
                        "system": systemText.isEmpty ? "你是一个专业的人工智能助手。" : systemText,
                        "messages": userMessages,
                        "tools": toolsPayload,
                        "parameters": [
                            "max_tokens": 4096
                        ],
                        "chat_context": [
                            "chatPrompt": "",
                            "imageUrls": NSNull(),
                            "extra": [
                                "context": [],
                                "modelConfig": [
                                    "key": cleanModelId,
                                    "is_reasoning": isReasoning
                                ],
                                "originalContent": lastUserText
                            ],
                            "features": [],
                            "text": lastUserText
                        ],
                        "model_config": [
                            "key": cleanModelId,
                            "is_reasoning": isReasoning,
                            "max_output_tokens": 4096,
                            "source": "system"
                        ],
                        "business": [
                            "product": "cli",
                            "version": "1.0.0",
                            "type": "agent",
                            "stage": "start",
                            "id": UUID().uuidString,
                            "name": String(lastUserText.prefix(30)),
                            "begin_at": Int(Date().timeIntervalSince1970 * 1000)
                        ]
                    ]

                    let rawBodyData = try JSONSerialization.data(withJSONObject: requestBody)
                    let encodedBody = QoderNativeSigner.encodeBody(rawBodyData)

                    var base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if base.isEmpty { base = "https://api3.qoder.sh" }
                    while base.hasSuffix("/") { base.removeLast() }
                    guard let chatURL = URL(string: "\(base)/algo/api/v2/service/pro/sse/agent_chat_generation?FetchKeys=llm_model_result&AgentId=agent_common&Encode=1") else {
                        throw AIChatError.invalidBaseURL
                    }

                    let machineID = QoderNativeSigner.getStableMachineID()

                    let authHeaders = try QoderNativeSigner.buildAuthHeaders(
                        bodyData: encodedBody,
                        requestURL: chatURL,
                        jobToken: cred.jobToken,
                        userID: cred.userId,
                        name: cred.name,
                        email: cred.email,
                        machineID: machineID
                    )

                    var req = URLRequest(url: chatURL)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    req.setValue("opencode-qoder", forHTTPHeaderField: "User-Agent")
                    req.setValue(cleanModelId, forHTTPHeaderField: "X-Model-Key")
                    req.setValue("system", forHTTPHeaderField: "X-Model-Source")
                    for (k, v) in authHeaders {
                        req.setValue(v, forHTTPHeaderField: k)
                    }
                    req.httpBody = encodedBody

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
                        var errorDetail = "Qoder 网关响应异常 (HTTP \(status))"
                        if let _ = response as? HTTPURLResponse {
                            var rawErr = ""
                            for try await line in bytes.lines {
                                rawErr += line
                                if rawErr.count > 300 { break }
                            }
                            if !rawErr.isEmpty {
                                errorDetail = "\(errorDetail): \(rawErr)"
                            }
                        }
                        throw AIChatError.http(status: status, message: errorDetail)
                    }

                    let chatAccumulator = ChatToolCallAccumulator()

                    streaming: for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let dataStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !dataStr.isEmpty, dataStr != "[DONE]" else { break streaming }

                        guard let envData = dataStr.data(using: .utf8),
                              let env = try? JSONSerialization.jsonObject(with: envData) as? [String: Any] else {
                            continue
                        }

                        if let status = env["statusCodeValue"] as? Int, status != 200 {
                            let msg = env["body"] as? String ?? "Qoder 上游拒绝 (状态码 \(status))"
                            throw AIChatError.streamError(msg)
                        }

                        guard let bodyStr = env["body"] as? String, !bodyStr.isEmpty, bodyStr != "[DONE]" else {
                            continue
                        }

                        guard let chunkData = bodyStr.data(using: .utf8) else { continue }

                        if let streamChunk = try? JSONDecoder().decode(StreamChunk.self, from: chunkData) {
                            if let usage = streamChunk.usage, let promptTokens = usage.resolvedPromptTokens, promptTokens > 0 {
                                continuation.yield(.usage(promptTokens: promptTokens))
                            }
                            if let delta = streamChunk.choices.first?.delta {
                                if let reasoning = delta.resolvedReasoning, !reasoning.isEmpty {
                                    continuation.yield(.reasoning(reasoning))
                                }
                                if let text = delta.content, !text.isEmpty {
                                    continuation.yield(.text(text))
                                }
                                if let toolCalls = delta.toolCalls, !toolCalls.isEmpty {
                                    let newStarts = chatAccumulator.ingest(toolCalls)
                                    for item in newStarts {
                                        continuation.yield(.toolCallDispatched(id: item.id, name: item.name))
                                    }
                                }
                            }
                        } else if let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] {
                            if let errObj = chunk["error"] as? [String: Any],
                               let errMsg = errObj["message"] as? String {
                                throw AIChatError.streamError(errMsg)
                            }

                            if let usage = chunk["usage"] as? [String: Any],
                               let promptTokens = usage["prompt_tokens"] as? Int {
                                continuation.yield(.usage(promptTokens: promptTokens))
                            }

                            if let choices = chunk["choices"] as? [[String: Any]], let first = choices.first {
                                if let delta = first["delta"] as? [String: Any] {
                                    if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                                        continuation.yield(.reasoning(reasoning))
                                    }
                                    if let text = delta["content"] as? String, !text.isEmpty {
                                        continuation.yield(.text(text))
                                    }
                                }
                            }
                        }
                    }

                    if !chatAccumulator.isEmpty {
                        continuation.yield(.toolCalls(chatAccumulator.completed))
                        chatAccumulator.clear()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func fetchModels(provider: AIProvider, apiKey: String) async throws -> [String] {
        // 返回 Qoder 国际版官方支持的模型列表 (18个最新模型)
        [
            "qoder/auto",
            "qoder/ultimate",
            "qoder/fast",
            "qoder/performance",
            "qoder/efficient",
            "qoder/smodel",
            "qoder/cmodel",
            "qoder/qmodel_38max",
            "qoder/qfmodel",
            "qoder/qmodel_latest",
            "qoder/qmodel",
            "qoder/kmodel_latest",
            "qoder/kmodel",
            "qoder/gmodel",
            "qoder/gfmodel",
            "qoder/dmodel",
            "qoder/dfmodel",
            "qoder/mmodel"
        ]
    }

    func thinkingFields(for modelId: String, level: ThinkingLevel?) -> [String: Any] {
        [:]
    }

    // MARK: - 凭据换取与解析

    private func resolveCredentials(pat: String) async throws -> CredentialCache.Entry {
        if let cached = credentialCache.get(for: pat), cached.userId != "qoder-user" && !cached.userId.isEmpty {
            return cached
        }
        let jt = try await QoderNativeSigner.exchangeJobToken(pat: pat)
        let userInfo = await fetchUserInfo(jt: jt)

        let saved = await MainActor.run {
            AIProviderStore.shared.accountInfo(for: "qoder")
        }

        let resolvedUserId: String
        if !userInfo.id.isEmpty {
            resolvedUserId = userInfo.id
        } else if let savedUid = saved?.userId, !savedUid.isEmpty {
            resolvedUserId = savedUid
        } else {
            resolvedUserId = ""
        }

        guard !resolvedUserId.isEmpty && resolvedUserId != "qoder-user" else {
            throw AIChatError.http(status: 401, message: "未能获取有效的 Qoder 账号绑定 UID，请在设置中重新授权绑定 Qoder")
        }

        let resolvedName: String
        if !userInfo.name.isEmpty {
            resolvedName = userInfo.name
        } else if let savedName = saved?.displayName, !savedName.isEmpty {
            resolvedName = savedName
        } else {
            resolvedName = "QuickShow User"
        }

        let resolvedEmail: String
        if !userInfo.email.isEmpty {
            resolvedEmail = userInfo.email
        } else if let savedEmail = saved?.email, !savedEmail.isEmpty {
            resolvedEmail = savedEmail
        } else {
            resolvedEmail = "user@quickshow.app"
        }

        let entry = CredentialCache.Entry(
            jobToken: jt,
            userId: resolvedUserId,
            name: resolvedName,
            email: resolvedEmail,
            expiresAt: Date().addingTimeInterval(86400 - 300)
        )
        credentialCache.set(entry, for: pat)
        return entry
    }

    private func fetchUserInfo(jt: String) async -> (id: String, name: String, email: String, avatar: String) {
        let endpoints = [
            "https://openapi.qoder.sh/api/v1/userinfo",
            "https://openapi.qoder.com.cn/api/v1/userinfo"
        ]

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("Bearer \(jt)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("opencode-qoder", forHTTPHeaderField: "User-Agent")
            req.setValue(QoderNativeSigner.openAPICosyVersion, forHTTPHeaderField: "Cosy-Version")
            req.setValue(QoderNativeSigner.clientType, forHTTPHeaderField: "Cosy-ClientType")
            req.timeoutInterval = 6

            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    continue
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                let dataObj = json["data"] as? [String: Any]
                let id = json["id"] as? String ?? json["userId"] as? String ?? dataObj?["id"] as? String ?? ""
                let name = json["name"] as? String ?? json["username"] as? String ?? dataObj?["name"] as? String ?? ""
                let email = json["email"] as? String ?? dataObj?["email"] as? String ?? ""
                let avatar = json["avatar"] as? String ?? json["avatar_url"] as? String ?? dataObj?["avatar"] as? String ?? ""

                if !id.isEmpty {
                    // 同步持久化有效 UID 到 ProviderAccountInfo，供离线或后续降级使用
                    await MainActor.run {
                        var existing = AIProviderStore.shared.accountInfo(for: "qoder") ?? ProviderAccountInfo(
                            userId: id,
                            displayName: name.isEmpty ? "Qoder 用户" : name,
                            email: email,
                            avatarURL: avatar.isEmpty ? nil : avatar,
                            authMethod: "browser",
                            authorizedAt: Date(),
                            refreshToken: nil
                        )
                        existing.userId = id
                        if !name.isEmpty { existing.displayName = name }
                        if !email.isEmpty { existing.email = email }
                        if !avatar.isEmpty { existing.avatarURL = avatar }
                        AIProviderStore.shared.saveAccountInfo(existing, for: "qoder")
                    }

                    return (id, name, email, avatar)
                }
            } catch {
                logger.warning("请求 Qoder 用户信息端点 [\(endpoint)] 异常: \(error.localizedDescription)")
            }
        }

        // 网络端点均失败时，优先从 AIProviderStore 读取已持久化的真实 UID
        let saved = await MainActor.run {
            AIProviderStore.shared.accountInfo(for: "qoder")
        }
        if let saved = saved, let uid = saved.userId, !uid.isEmpty {
            return (
                id: uid,
                name: saved.displayName,
                email: saved.email,
                avatar: saved.avatarURL ?? ""
            )
        }

        // 尝试从本地 Qoder 应用配置读取真实 UID 作为脱机兜底
        let home = NSHomeDirectory()
        let appStatusPath = "\(home)/.qoder/.qoder-app-status.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: appStatusPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let name = json["name"] as? String ?? ""
            let email = json["email"] as? String ?? ""
            let avatar = json["avatar_url"] as? String ?? ""
            var uid = ""
            if let range = avatar.range(of: "/users/") {
                let sub = avatar[range.upperBound...]
                if let endRange = sub.range(of: "/") {
                    uid = String(sub[..<endRange.lowerBound])
                }
            }
            if !uid.isEmpty {
                return (id: uid, name: name, email: email, avatar: avatar)
            }
        }

        return ("", "", "", "")
    }
}
