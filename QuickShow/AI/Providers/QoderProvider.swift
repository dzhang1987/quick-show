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

                    var systemText = ""
                    var userMessages: [[String: Any]] = []
                    var lastUserText = ""

                    for msg in messages {
                        if msg.role == "system" {
                            if let plain = msg.content?.plainText {
                                systemText += (systemText.isEmpty ? "" : "\n") + plain
                            }
                        } else {
                            let role = msg.role
                            let content = msg.content?.plainText ?? ""
                            if role == "user" {
                                lastUserText = content
                            }
                            userMessages.append([
                                "role": role,
                                "content": content
                            ])
                        }
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
                        "tools": [],
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
                                    "is_reasoning": model.supportsThinking
                                ],
                                "originalContent": lastUserText
                            ],
                            "features": [],
                            "text": lastUserText
                        ],
                        "model_config": [
                            "key": cleanModelId,
                            "is_reasoning": model.supportsThinking,
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

                    let chatURL = URL(string: "https://api3.qoder.sh/algo/api/v2/service/pro/sse/agent_chat_generation?FetchKeys=llm_model_result&AgentId=agent_common&Encode=1")!
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
                        throw AIChatError.http(status: status, message: "Qoder 网关响应异常 (HTTP \(status))")
                    }

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

                        guard let chunkData = bodyStr.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
                            continue
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
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func fetchModels(provider: AIProvider, apiKey: String) async throws -> [String] {
        // 返回 Qoder 国际版官方支持的模型列表
        [
            "qoder/auto",
            "qoder/ultimate",
            "qoder/performance",
            "qoder/efficient",
            "qoder/lite",
            "qoder/qmodel",
            "qoder/qmodel_latest",
            "qoder/qmodel_preview",
            "qoder/dfmodel",
            "qoder/dmodel",
            "qoder/gm51model",
            "qoder/kmodel",
            "qoder/kmodel_latest",
            "qoder/mmodel"
        ]
    }

    func thinkingFields(for modelId: String, level: ThinkingLevel?) -> [String: Any] {
        [:]
    }

    // MARK: - 凭据换取与解析

    private func resolveCredentials(pat: String) async throws -> CredentialCache.Entry {
        if let cached = credentialCache.get(for: pat) {
            return cached
        }
        let jt = try await QoderNativeSigner.exchangeJobToken(pat: pat)
        let userInfo = try await fetchUserInfo(jt: jt)
        let entry = CredentialCache.Entry(
            jobToken: jt,
            userId: userInfo.id.isEmpty ? "qoder-user" : userInfo.id,
            name: userInfo.name,
            email: userInfo.email,
            expiresAt: Date().addingTimeInterval(86400 - 300)
        )
        credentialCache.set(entry, for: pat)
        return entry
    }

    private func fetchUserInfo(jt: String) async throws -> (id: String, name: String, email: String) {
        let url = URL(string: "https://openapi.qoder.sh/api/v1/userinfo")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(jt)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("opencode-qoder", forHTTPHeaderField: "User-Agent")
        req.setValue("1.0.1", forHTTPHeaderField: "Cosy-Version")
        req.setValue("5", forHTTPHeaderField: "Cosy-ClientType")

        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let id = json["id"] as? String ?? ""
        let name = json["name"] as? String ?? ""
        let email = json["email"] as? String ?? ""
        return (id, name, email)
    }
}
