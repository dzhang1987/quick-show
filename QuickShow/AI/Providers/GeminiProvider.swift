// GeminiProvider: Google Gemini / Antigravity 原生协议 Provider 实现。
// 支持 Gemini 官方直连 API，提供多模态图文 payload 组装与 SSE 响应解析。

import Foundation

final class GeminiProvider: LLMProvider, @unchecked Sendable {
    let providerType: AIProviderType = .antigravityNative

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
            return OpenAIProvider().stream(provider: provider, model: model, messages: messages, options: options, apiKey: apiKey)
        }

        return AsyncThrowingStream<AIStreamEvent, Error> { continuation in
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
            "gemini-2.5-flash",
            "gemini-2.5-pro",
            "gemini-3.8-flash"
        ]
    }

    func thinkingFields(for modelId: String, level: ThinkingLevel?) -> [String: Any] {
        [:]
    }
}
