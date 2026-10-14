// OpenAIProvider: OpenAI 协议 Provider 实现。
// 适配 OpenAI 官方、阿里云百炼 (DashScope)、Ollama、vLLM 以及所有 OpenAI 兼容端点。

import Foundation

final class OpenAIProvider: LLMProvider, @unchecked Sendable {
    let providerType: AIProviderType = .openAICompatible

    init() {}

    func stream(
        provider: AIProvider,
        model: AIModelSpec,
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions,
        apiKey: String
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream<AIStreamEvent, Error> { continuation in
            let task = Task {
                do {
                    let proto: APIProtocol = (provider.apiProtocol == .responses) ? .responses : .chatCompletions
                    var base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    while base.hasSuffix("/") { base.removeLast() }

                    let path = (proto == .responses) ? "/responses" : "/chat/completions"
                    guard let url = URL(string: base + path) else {
                        throw AIChatError.invalidBaseURL
                    }

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !apiKey.isEmpty {
                        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }

                    let thinkingFields = self.thinkingFields(for: model.id, level: options.thinkingLevel)
                    let bodyData = try await MainActor.run {
                        let agent = AIAgentStore.shared.agent(for: options.agentId ?? "") ?? AIAgentStore.shared.activeAgent
                        return try AIChatService.shared.encodeRequestBody(
                            proto: proto,
                            model: model.id,
                            messages: messages,
                            stream: true,
                            includeTools: true,
                            agent: agent,
                            thinkingFields: thinkingFields
                        )
                    }
                    req.httpBody = bodyData

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
                        throw AIChatError.http(status: status, message: "")
                    }

                    let chatAccumulator = ChatToolCallAccumulator()
                    let responsesAccumulator = ResponsesToolCallAccumulator()

                    streaming: for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty else { continue }

                        guard let data = payload.data(using: .utf8) else { continue }

                        if proto == .responses {
                            guard let event = try? JSONDecoder().decode(ResponsesEvent.self, from: data) else {
                                continue
                            }
                            if let usage = event.usage ?? event.response?.usage,
                               let prompt = usage.resolvedPromptTokens {
                                continuation.yield(.usage(promptTokens: prompt))
                            }
                            switch event.type {
                            case "response.output_text.delta":
                                guard let delta = event.delta, !delta.isEmpty else { continue }
                                continuation.yield(.text(delta))
                            case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
                                guard let delta = event.delta, !delta.isEmpty else { continue }
                                continuation.yield(.reasoning(delta))
                            case "response.output_item.added", "response.output_item.done":
                                guard let item = event.item, item.type == "function_call" else { continue }
                                let key = item.id ?? "index-\(event.outputIndex ?? 0)"
                                if let newly = responsesAccumulator.register(
                                    key: key,
                                    callID: item.callId,
                                    name: item.name,
                                    arguments: item.arguments
                                ) {
                                    continuation.yield(.toolCallDispatched(id: newly.id, name: newly.name))
                                }
                            case "response.function_call_arguments.delta":
                                guard let delta = event.delta, !delta.isEmpty else { continue }
                                let key = event.itemId ?? "index-\(event.outputIndex ?? 0)"
                                responsesAccumulator.appendArguments(key: key, delta: delta)
                            case "response.function_call_arguments.done":
                                guard let itemID = event.itemId else { continue }
                                if let newly = responsesAccumulator.register(
                                    key: itemID,
                                    callID: nil,
                                    name: nil,
                                    arguments: event.arguments
                                ) {
                                    continuation.yield(.toolCallDispatched(id: newly.id, name: newly.name))
                                }
                            case "response.completed":
                                if !responsesAccumulator.isEmpty {
                                    continuation.yield(.toolCalls(responsesAccumulator.completed))
                                    responsesAccumulator.clear()
                                }
                                break streaming
                            case "response.failed", "response.error", "error":
                                throw AIChatError.streamError(event.resolvedErrorMessage)
                            default:
                                continue
                            }
                        } else {
                            // Chat Completions
                            if payload == "[DONE]" {
                                if !chatAccumulator.isEmpty {
                                    continuation.yield(.toolCalls(chatAccumulator.completed))
                                    chatAccumulator.clear()
                                }
                                break streaming
                            }
                            guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
                                continue
                            }
                            if let usage = chunk.usage, let prompt = usage.resolvedPromptTokens, prompt > 0 {
                                continuation.yield(.usage(promptTokens: prompt))
                            }
                            guard let delta = chunk.choices.first?.delta else { continue }

                            if let content = delta.content, !content.isEmpty {
                                continuation.yield(.text(content))
                            }
                            if let reasoning = delta.resolvedReasoning, !reasoning.isEmpty {
                                continuation.yield(.reasoning(reasoning))
                            }
                            if let toolCalls = delta.toolCalls, !toolCalls.isEmpty {
                                let newStarts = chatAccumulator.ingest(toolCalls)
                                for item in newStarts {
                                    continuation.yield(.toolCallDispatched(id: item.id, name: item.name))
                                }
                            }
                        }
                    }

                    // 流自然结束补发
                    if proto == .responses {
                        if !responsesAccumulator.isEmpty {
                            continuation.yield(.toolCalls(responsesAccumulator.completed))
                            responsesAccumulator.clear()
                        }
                    } else if !chatAccumulator.isEmpty {
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
        var base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/models") else { throw AIChatError.invalidBaseURL }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIChatError.http(status: status, message: body)
        }

        guard let decoded = try? JSONDecoder().decode(ModelListResponse.self, from: data) else {
            throw AIChatError.invalidResponse
        }
        let ids = (decoded.data ?? [])
            .compactMap { $0.id?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw AIChatError.invalidResponse }
        return ids
    }

    func thinkingFields(for modelId: String, level: ThinkingLevel?) -> [String: Any] {
        guard let level else { return [:] }
        switch level {
        case .off:
            return modelId.hasPrefix("glm-5.3") ? [:] : ["enable_thinking": false]
        case .low, .medium, .high:
            if modelId.hasPrefix("glm-5.3") {
                switch level {
                case .low: return ["reasoning_effort": "low"]
                case .medium: return ["reasoning_effort": "high"]
                case .high: return ["reasoning_effort": "max"]
                case .off: return [:]
                }
            }
            return ["reasoning_effort": level.rawValue]
        }
    }
}
