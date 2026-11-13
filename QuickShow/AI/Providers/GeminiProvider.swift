// GeminiProvider: Google Gemini / Antigravity 原生协议 Provider 实现。
// 支持 Gemini 官方直连 API，提供多模态图文 payload 组装与 SSE 响应解析。

import Foundation
import os

final class GeminiProvider: LLMProvider, @unchecked Sendable {
    let providerType: AIProviderType = .antigravityNative
    private static let logger = Logger(subsystem: "cn.chiproad.QuickShow", category: "GeminiProvider")

    init() {}

    func supportedAuthMethods(for provider: AIProvider) -> [any AIAuthMethod] {
        [
            DefaultAPIKeyAuthMethod(
                providerId: provider.id,
                displayName: "Gemini API Key",
                detailDescription: "直接输入 Google AI Studio API Key",
                placeholder: "AIzaSy...",
                footerText: "密钥仅保存在本机受保护目录，绝不上云"
            ),
            AntigravityBiometricAuthMethod(),
            AntigravityGooglePKCEMethod()
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
            return OpenAIProvider().stream(provider: provider, model: model, messages: messages, options: options, apiKey: apiKey)
        }

        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let isClassicStudioKey = cleanKey.hasPrefix("AIzaSy")

        // 1. 如果指定了经典的 AI Studio API Key (AIzaSy 开头)，走 Google AI Studio 端点
        if isClassicStudioKey {
            return streamViaAIStudio(provider: provider, model: model, messages: messages, options: options, apiKey: cleanKey)
        }

        // 2. 使用 Antigravity 官方云端网关原生 HTTP SSE 直连；失败直接返回，不降级到本地 Agent 进程。
        return AsyncThrowingStream<AIStreamEvent, Error> { continuation in
            let task = Task {
                do {
                    // 确保拿到新鲜有效的 Access Token（若过期则 0.3s 内自动刷新自愈）
                    guard let accessToken = await AntigravityCloudCodeAdapter.ensureFreshAccessToken(explicitKey: cleanKey) else {
                        throw AIChatError.network("未能获取到有效的 Antigravity 访问凭据，请重新授权")
                    }

                    let directStream = AntigravityCloudCodeAdapter.stream(
                        model: model,
                        messages: messages,
                        options: options,
                        initialToken: accessToken
                    )
                    for try await event in directStream {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    // 失败即显式返回：禁止降级到可自行执行宿主操作的 Agent CLI，避免绕过 AIToolExecutor。
                    Self.logger.error("[GeminiProvider] 原生直连异常: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamViaAIStudio(
        provider: AIProvider,
        model: AIModelSpec,
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions,
        apiKey: String
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream<AIStreamEvent, Error> { continuation in
            let task = Task {
                do {
                    let req = try AntigravityNativeAdapter.buildRequest(
                        baseURL: provider.baseURL,
                        model: model.id,
                        apiKey: apiKey,
                        messages: messages,
                        systemPrompt: nil,
                        stream: true
                    )

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
                        throw AIChatError.http(status: status, message: "Gemini API 返回 HTTP \(status)")
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !raw.isEmpty, raw != "[DONE]" else { break }

                        let (delta, usageTokens) = AntigravityNativeAdapter.parseChunk(jsonString: raw)
                        if let usage = usageTokens {
                            continuation.yield(.usage(promptTokens: usage))
                        }
                        if let delta {
                            continuation.yield(.text(delta))
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
        [
            "gemini-3.1-pro",
            "gemini-3.8-flash",
            "gemini-3.7-flash",
            "claude-opus-4-6",
            "claude-sonnet-4-6",
            "gpt-oss-120b"
        ]
    }

    func thinkingFields(for modelId: String, level: ThinkingLevel?) -> [String: Any] {
        guard let level else { return [:] }
        switch level {
        case .off: return ["effort": "low"]
        case .low: return ["effort": "low"]
        case .medium: return ["effort": "medium"]
        case .high: return ["effort": "high"]
        }
    }
}
