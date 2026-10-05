// 职责来源：AIChatService.swift 的「内部实现（请求构造 / 请求体编码 / 工具声明 / Responses 映射 / 错误解析）」MARK 分区。

import Foundation

extension AIChatService {
    // MARK: 内部实现（请求构造 / 编码 / 错误解析）

    /// 拼接端点：Base URL 去尾部斜杠后追加协议路径。
    func endpointURL(path: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        return URL(string: base + path)
    }

    /// 按协议构造请求体：
    /// - chat：`{model, messages:[...], stream, tools?}`（system prompt 维持注入 messages[0]）
    /// - responses：`{model, instructions?, input:[...], stream, tools?}`（system 转 instructions）
    /// `includeTools` 为 false 或无启用工具时不携带 tools 字段（保持旧行为）。
    /// `thinkingFields`：适配层注入的顶层思考字段；Chat Completions 流式额外注入
    /// `stream_options.include_usage = true` 以在末片获取 usage。
    /// `maxTokens`：输出上限；按协议映射为 `max_tokens`（Chat）/`max_output_tokens`（Responses）。
    func encodeRequestBody(
        proto: APIProtocol,
        model: String,
        messages: [ChatCompletionMessage],
        stream: Bool,
        includeTools: Bool,
        thinkingFields: [String: Any] = [:],
        maxTokens: Int? = nil
    ) throws -> Data {
        // 启用的工具声明：为空时返回 nil，自定义编码省略该字段。
        let chatTools = includeTools ? chatToolDefinitions() : nil
        let responsesTools = includeTools ? responsesToolDefinitions() : nil

        var extra = thinkingFields
        if proto == .chatCompletions && stream {
            extra["stream_options"] = ["include_usage": true] as [String: Any]
        }
        if let maxTokens {
            extra[proto == .responses ? "max_output_tokens" : "max_tokens"] = maxTokens
        }

        guard proto == .responses else {
            return try JSONEncoder().encode(
                ChatCompletionRequestBody(model: model, messages: messages, stream: stream, tools: chatTools, extra: extra)
            )
        }

        // Responses 只支持单个 instructions：合并全部 system 消息（systemPrompt + 压缩摘要等），
        // 避免除首条外的 system（如摘要）被 responsesInput 跳过而丢失。
        let systemTexts = messages
            .filter { $0.role == "system" }
            .compactMap { $0.content?.plainText?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var instructions: String? = systemTexts.isEmpty ? nil : systemTexts.joined(separator: "\n\n")
        if instructions == nil {
            let fallback = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty { instructions = fallback }
        }

        // 对话历史（非 system）映射为 input：普通消息、assistant function_call、工具结果三类。
        let input = responsesInput(from: messages)

        return try JSONEncoder().encode(
            ResponsesRequestBody(model: model, instructions: instructions, input: input, stream: stream, tools: responsesTools, extra: extra)
        )
    }

    /// 基于启用的工具构造 Chat Completions 工具声明；无工具返回 nil。
    private func chatToolDefinitions() -> [ChatToolDefinition]? {
        let tools = AIToolRegistry.shared.enabledTools()
        guard !tools.isEmpty else { return nil }
        return tools.map { tool in
            ChatToolDefinition(
                type: "function",
                function: ChatToolFunctionDefinition(
                    name: tool.name,
                    description: tool.description,
                    parameters: JSONValue(tool.parametersSchema)
                )
            )
        }
    }

    /// 基于启用的工具构造 Responses 工具声明；无工具返回 nil。
    private func responsesToolDefinitions() -> [ResponsesToolDefinition]? {
        let tools = AIToolRegistry.shared.enabledTools()
        guard !tools.isEmpty else { return nil }
        return tools.map { tool in
            ResponsesToolDefinition(
                type: "function",
                name: tool.name,
                description: tool.description,
                parameters: JSONValue(tool.parametersSchema)
            )
        }
    }

    /// 把 wire 消息数组映射为 Responses input 项：
    /// - system：跳过（走 instructions）
    /// - tool：function_call_output（call_id + output 文本）
    /// - assistant：有文本则输出 assistant message，其 tool_calls 逐条输出 function_call 项
    /// - 其他：普通 role + content 消息
    private func responsesInput(from messages: [ChatCompletionMessage]) -> [ResponsesInputItem] {
        var items: [ResponsesInputItem] = []
        for message in messages {
            switch message.role {
            case "system":
                continue
            case "tool":
                items.append(.functionCallOutput(
                    callId: message.toolCallId ?? "",
                    output: message.content?.plainText ?? ""
                ))
            case "assistant":
                if let content = message.content, let text = content.plainText, !text.isEmpty {
                    items.append(.message(role: "assistant", content: ResponsesContent(from: content)))
                }
                for call in message.toolCalls ?? [] {
                    items.append(.functionCall(
                        callId: call.id,
                        name: call.function.name,
                        arguments: call.function.arguments
                    ))
                }
            default:
                if let content = message.content {
                    items.append(.message(role: message.role, content: ResponsesContent(from: content)))
                }
            }
        }
        return items
    }

    /// 从错误 body 中提取 `error.message`，失败则回退为原始文本前缀。
    func extractErrorMessage(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data),
           let message = envelope.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        return String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }
}