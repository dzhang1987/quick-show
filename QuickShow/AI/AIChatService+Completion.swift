// 职责来源：AIChatService.swift 的「模型列表 / 非流式补全」MARK 分区。

import Foundation

extension AIChatService {
    // MARK: 模型列表 / 非流式补全

    /// 拉取端点模型列表：GET `{baseURL}/models`，解析 OpenAI 格式 `data[].id`。
    /// 错误统一抛出中文化的 AIChatError，由设置表单行内提示。
    func fetchModels() async throws -> [String] {
        guard let url = endpointURL(path: "/models") else { throw AIChatError.invalidBaseURL }
        guard let key = apiKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIChatError.missingAPIKey
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIChatError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIChatError.http(status: http.statusCode, message: extractErrorMessage(from: body))
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

    /// 非流式补全（用于 LLM 标题摘要 / 上下文压缩等后台轻量请求），返回纯文本。
    /// `options`：会话级模型与思考档位（nil 回落全局默认 / 模型默认）；压缩场景可传 .off 关闭思考。
    /// `maxTokens`：可选输出上限。
    func complete(
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions = AIChatRequestOptions(),
        maxTokens: Int? = nil
    ) async throws -> String {
        let proto = apiProtocol
        let path = proto == .responses ? "/responses" : "/chat/completions"
        guard let url = endpointURL(path: path) else { throw AIChatError.invalidBaseURL }
        guard let key = apiKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIChatError.missingAPIKey
        }
        // 模型解析优先级与流式一致：会话绑定模型（请求传入且非空）→ 全局 selectedModel。
        let requestedModel = options.modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel: String
        if let requestedModel, !requestedModel.isEmpty {
            resolvedModel = requestedModel
        } else {
            resolvedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !resolvedModel.isEmpty else { throw AIChatError.missingModel }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // 非流式补全用于标题摘要 / 上下文压缩等轻量后台请求：不带工具，避免误触发工具调用。
        let thinkingFields = AIModelAdapter.thinkingFields(for: resolvedModel, level: options.thinkingLevel)
        request.httpBody = try encodeRequestBody(
            proto: proto,
            model: resolvedModel,
            messages: messages,
            stream: false,
            includeTools: false,
            thinkingFields: thinkingFields,
            maxTokens: maxTokens
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIChatError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIChatError.http(status: http.statusCode, message: extractErrorMessage(from: body))
        }
        // 非流式路径同样解析 tool_calls（当前调用方只取文本，解析能力保持一致）。
        return try extractCompletion(proto: proto, data: data).text
    }

    /// 从非流式响应中提取文本与工具调用（两种协议）。
    /// 文本为空但存在工具调用时不视为错误；两者均空才抛 invalidResponse。
    private func extractCompletion(proto: APIProtocol, data: Data) throws -> (text: String, toolCalls: [CompletedToolCall]) {
        if proto == .responses {
            guard let decoded = try? JSONDecoder().decode(ResponsesResponse.self, from: data) else {
                throw AIChatError.invalidResponse
            }
            let outputs: [ResponsesResponse.Output] = decoded.output ?? []
            var pieces: [String] = []
            var calls: [CompletedToolCall] = []
            for output in outputs {
                if output.type == "function_call" {
                    let name = output.name ?? ""
                    if !name.isEmpty {
                        calls.append(CompletedToolCall(
                            id: output.callId ?? UUID().uuidString,
                            name: name,
                            arguments: output.arguments ?? ""
                        ))
                    }
                    continue
                }
                let contents: [ResponsesResponse.Output.Content] = output.content ?? []
                for content in contents {
                    if content.type == "output_text" || content.type == nil {
                        if let piece = content.text { pieces.append(piece) }
                    }
                }
            }
            let text = pieces.joined()
            guard !text.isEmpty || !calls.isEmpty else { throw AIChatError.invalidResponse }
            return (text, calls)
        }
        guard let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) else {
            throw AIChatError.invalidResponse
        }
        let message = decoded.choices?.first?.message
        let text = message?.content ?? ""
        let calls = (message?.toolCalls ?? []).compactMap { raw -> CompletedToolCall? in
            guard let name = raw.function?.name, !name.isEmpty else { return nil }
            return CompletedToolCall(
                id: raw.id ?? UUID().uuidString,
                name: name,
                arguments: raw.function?.arguments ?? ""
            )
        }
        guard !text.isEmpty || !calls.isEmpty else { throw AIChatError.invalidResponse }
        return (text, calls)
    }
}