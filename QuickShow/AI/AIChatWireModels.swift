// 由 AIChatService.swift 拆出的 wire DTO 层：与 OpenAI Chat Completions / Responses 协议对应的请求与响应模型。

import Foundation

// MARK: - 请求/响应模型

/// 消息内容：纯文本（编码为字符串）或多模态片段数组（编码为数组）。
/// 对应 OpenAI Chat Completions 的 `content` 两种合法形态。
enum MessageContent: Codable {
    case text(String)
    case parts([ChatContentPart])

    /// 纯文本内容；多模态时返回 nil。
    var plainText: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let plain = try? container.decode(String.self) {
            self = .text(plain)
            return
        }
        self = .parts(try container.decode([ChatContentPart].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(value):
            try container.encode(value)
        case let .parts(value):
            try container.encode(value)
        }
    }
}

/// Chat Completions 多模态内容片段：文本或图片 data URI。
struct ChatContentPart: Codable {
    struct ImageURL: Codable {
        let url: String
    }

    let type: String          // "text" / "image_url"
    let text: String?
    let imageURL: ImageURL?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    static func textPart(_ value: String) -> ChatContentPart {
        ChatContentPart(type: "text", text: value, imageURL: nil)
    }

    static func imagePart(dataURI: String) -> ChatContentPart {
        ChatContentPart(type: "image_url", text: nil, imageURL: ImageURL(url: dataURI))
    }
}

/// 请求装配层的工具调用项（assistant 消息回传模型时使用）。
/// 对应 Chat Completions 的 `tool_calls[]` 元素；Responses 会映射为 function_call 项。
struct WireToolCall: Codable {
    let id: String
    let type: String
    let function: WireToolCallFunction

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.type = "function"
        self.function = WireToolCallFunction(name: name, arguments: arguments)
    }
}

/// WireToolCall 的 function 载荷。
struct WireToolCallFunction: Codable {
    let name: String
    let arguments: String
}

/// 发往 OpenAI 兼容端点的单条 wire 消息。
/// 支持三种形态：普通 role+content、assistant 携带 tool_calls（content 可为 null）、
/// role == "tool" 携带 tool_call_id 的工具结果。
/// 说明：这是请求装配层类型，与展示层 ChatMessage 语义分离。
struct ChatCompletionMessage: Codable {
    let role: String
    /// 普通消息恒非空；assistant 仅发起工具调用时可为 nil（编码为 null）。
    let content: MessageContent?
    /// assistant 回传的工具调用清单。
    let toolCalls: [WireToolCall]?
    /// role == "tool" 时对应的调用 id。
    let toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
        self.toolCalls = nil
        self.toolCallId = nil
    }

    init(role: String, content: MessageContent) {
        self.role = role
        self.content = content
        self.toolCalls = nil
        self.toolCallId = nil
    }

    /// 完整构造：assistant tool_calls 或 tool 结果使用。
    init(role: String, content: MessageContent?, toolCalls: [WireToolCall]?, toolCallId: String?) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    /// 构造一条工具结果消息（role == "tool"）。
    static func toolResult(callID: String, content: String) -> ChatCompletionMessage {
        ChatCompletionMessage(role: "tool", content: .text(content), toolCalls: nil, toolCallId: callID)
    }

    /// 自定义编码：content 为 nil 时显式写 null（assistant 仅含 tool_calls 的合法形态）；
    /// tool_calls / tool_call_id 仅在存在时输出。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let content {
            try container.encode(content, forKey: .content)
        } else {
            try container.encodeNil(forKey: .content)
        }
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
    }
}

/// Chat Completions 的工具声明。
struct ChatToolDefinition: Encodable {
    let type: String
    let function: ChatToolFunctionDefinition
}

struct ChatToolFunctionDefinition: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

/// Responses 的工具声明（扁平结构）。
struct ResponsesToolDefinition: Encodable {
    let type: String
    let name: String
    let description: String
    let parameters: JSONValue
}

/// 任意 JSON 值的 Encodable 包装：把工具参数 schema（[String: Any]）编码进请求体。
struct JSONValue: Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try Self.encode(value, into: &container)
    }

    private static func encode(_ value: Any, into container: inout SingleValueEncodingContainer) throws {
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { JSONValue($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { JSONValue($0) })
        case let number as NSNumber:
            try container.encode(number.doubleValue)
        case is NSNull:
            try container.encodeNil()
        default:
            // 兜底：非标准 JSON 值退化为字符串，避免整体请求体编码失败。
            try container.encode(String(describing: value))
        }
    }
}

/// 动态顶层编码 key：用于把思考强度、stream_options 等非固定字段注入请求体顶层。
private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init(_ string: String) { self.stringValue = string }
    init?(intValue: Int) { nil }
}

/// Chat Completions 请求体。
/// `extra`：由适配层注入的顶层字段（enable_thinking / reasoning_effort / stream_options 等），
/// 使用自定义编码合并，避免为每个模型差异新增固定字段。
struct ChatCompletionRequestBody: Encodable {
    let model: String
    let messages: [ChatCompletionMessage]
    let stream: Bool
    /// 启用的工具；为空时由自定义编码省略该字段，保持旧行为。
    let tools: [ChatToolDefinition]?
    let extra: [String: Any]

    init(
        model: String,
        messages: [ChatCompletionMessage],
        stream: Bool,
        tools: [ChatToolDefinition]?,
        extra: [String: Any] = [:]
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.tools = tools
        self.extra = extra
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(model, forKey: DynamicCodingKey("model"))
        try container.encode(messages, forKey: DynamicCodingKey("messages"))
        try container.encode(stream, forKey: DynamicCodingKey("stream"))
        if let tools { try container.encode(tools, forKey: DynamicCodingKey("tools")) }
        for (key, value) in extra {
            try container.encode(JSONValue(value), forKey: DynamicCodingKey(key))
        }
    }
}

/// Responses 请求体：system prompt 走 instructions，对话历史走 input。
/// `extra`：同 Chat，注入适配层顶层字段。
struct ResponsesRequestBody: Encodable {
    let model: String
    /// 可选；nil 时省略该字段。
    let instructions: String?
    let input: [ResponsesInputItem]
    let stream: Bool
    let tools: [ResponsesToolDefinition]?
    let extra: [String: Any]

    init(
        model: String,
        instructions: String?,
        input: [ResponsesInputItem],
        stream: Bool,
        tools: [ResponsesToolDefinition]?,
        extra: [String: Any] = [:]
    ) {
        self.model = model
        self.instructions = instructions
        self.input = input
        self.stream = stream
        self.tools = tools
        self.extra = extra
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(model, forKey: DynamicCodingKey("model"))
        if let instructions { try container.encode(instructions, forKey: DynamicCodingKey("instructions")) }
        try container.encode(input, forKey: DynamicCodingKey("input"))
        try container.encode(stream, forKey: DynamicCodingKey("stream"))
        if let tools { try container.encode(tools, forKey: DynamicCodingKey("tools")) }
        for (key, value) in extra {
            try container.encode(JSONValue(value), forKey: DynamicCodingKey(key))
        }
    }
}

/// Responses 的 input 项：普通 message / function_call / function_call_output 三种变体。
/// 采用单结构 + 自定义编码，按类型只输出相关字段，避免 null 污染请求体。
struct ResponsesInputItem: Encodable {
    let role: String?
    let content: ResponsesContent?
    let type: String?
    let callId: String?
    let name: String?
    let arguments: String?
    let output: String?

    enum CodingKeys: String, CodingKey {
        case role, content, type, name, arguments, output
        case callId = "call_id"
    }

    static func message(role: String, content: ResponsesContent) -> ResponsesInputItem {
        ResponsesInputItem(role: role, content: content, type: nil, callId: nil, name: nil, arguments: nil, output: nil)
    }

    static func functionCall(callId: String, name: String, arguments: String) -> ResponsesInputItem {
        ResponsesInputItem(role: nil, content: nil, type: "function_call", callId: callId, name: name, arguments: arguments, output: nil)
    }

    static func functionCallOutput(callId: String, output: String) -> ResponsesInputItem {
        ResponsesInputItem(role: nil, content: nil, type: "function_call_output", callId: callId, name: nil, arguments: nil, output: output)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(callId, forKey: .callId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(arguments, forKey: .arguments)
        try container.encodeIfPresent(output, forKey: .output)
    }
}

/// Responses 的内容：纯文本编码为字符串，含图时编码为片段数组。
enum ResponsesContent: Encodable {
    case text(String)
    case parts([ResponsesContentPart])

    /// 从 Chat Completions 内容映射：文本 → input_text/output_text 由片段构造方决定。
    init(from content: MessageContent) {
        switch content {
        case let .text(value):
            self = .text(value)
        case let .parts(chatParts):
            self = .parts(chatParts.map { part in
                switch part.type {
                case "image_url":
                    return ResponsesContentPart(
                        type: "input_image",
                        text: nil,
                        imageURL: part.imageURL?.url
                    )
                default:
                    return ResponsesContentPart(type: "input_text", text: part.text, imageURL: nil)
                }
            })
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(value):
            try container.encode(value)
        case let .parts(value):
            try container.encode(value)
        }
    }
}

/// Responses 的 input 内容片段：input_text / output_text / input_image。
/// 注意：Responses 的 `input_image` 的 image_url 直接是字符串（非对象）。
struct ResponsesContentPart: Encodable {
    let type: String
    let text: String?
    let imageURL: String?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }
}

/// 服务端 token 用量：Chat Completions 用 prompt_tokens，Responses 用 input_tokens，
/// 统一归一为 prompt token（上下文水位真源）。
struct TokenUsage: Decodable {
    let promptTokens: Int?
    let inputTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case inputTokens = "input_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }

    /// 归一为 prompt token：优先 prompt_tokens（Chat），回退 input_tokens（Responses）。
    var resolvedPromptTokens: Int? { promptTokens ?? inputTokens }
}

/// Chat Completions 的 SSE 增量分片：choices[0].delta 的 content 或 tool_calls 分片。
struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let toolCalls: [DeltaToolCall]?
            /// DeepSeek 风格思考增量字段。
            let reasoningContent: String?
            /// 部分 OpenAI 兼容端点的思考增量字段。
            let reasoning: String?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
                case reasoningContent = "reasoning_content"
                case reasoning
            }

            /// 两种字段名统一到同一累积通道：优先 reasoning_content，回退 reasoning。
            var resolvedReasoning: String? {
                reasoningContent ?? reasoning
            }
        }
        let delta: Delta?
    }
    let choices: [Choice]
    /// 顶层 usage：`stream_options.include_usage` 时末片携带（此时 choices 为空数组）。
    let usage: TokenUsage?
}

/// Chat Completions 的 tool_calls 分片：name/id/type 通常首片给出，arguments 逐片累积。
struct DeltaToolCall: Decodable {
    struct DeltaFunction: Decodable {
        let name: String?
        let arguments: String?
    }
    let index: Int?
    let id: String?
    let type: String?
    let function: DeltaFunction?
}

/// Chat Completions tool_calls 分片累积器：按 index 归并 name 与 arguments。
/// 全程在 MainActor 上使用，无并发访问。
final class ChatToolCallAccumulator {
    private struct Partial {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    private var byIndex: [Int: Partial] = [:]

    func ingest(_ deltas: [DeltaToolCall]) {
        for delta in deltas {
            let index = delta.index ?? 0
            var partial = byIndex[index] ?? Partial()
            if let id = delta.id, !id.isEmpty { partial.id = id }
            if let name = delta.function?.name, !name.isEmpty {
                // name 一般整块到达；若端点分片则拼接，保证不丢内容。
                partial.name = (partial.name ?? "") + name
            }
            if let args = delta.function?.arguments { partial.arguments += args }
            byIndex[index] = partial
        }
    }

    var isEmpty: Bool { byIndex.isEmpty }

    func clear() { byIndex.removeAll() }

    /// 按 index 顺序产出完整调用；name 缺失的分片跳过。
    var completed: [CompletedToolCall] {
        byIndex.keys.sorted().compactMap { index in
            guard let partial = byIndex[index], let name = partial.name, !name.isEmpty else { return nil }
            return CompletedToolCall(
                id: partial.id ?? UUID().uuidString,
                name: name,
                arguments: partial.arguments
            )
        }
    }
}

/// Responses 的 SSE 事件：按顶层 type 分流，字段宽松可选（缺失即忽略该事件）。
struct ResponsesEvent: Decodable {
    struct ErrorBody: Decodable {
        let message: String?
    }

    struct ResponseBody: Decodable {
        let error: ErrorBody?
        /// response.completed 的 usage（input_tokens → prompt token）。
        let usage: TokenUsage?
    }

    /// output_item 载荷：type == "function_call" 时携带 call_id/name/arguments。
    struct OutputItem: Decodable {
        let type: String?
        let id: String?
        let callId: String?
        let name: String?
        let arguments: String?

        enum CodingKeys: String, CodingKey {
            case type, id, name, arguments
            case callId = "call_id"
        }
    }

    let type: String?
    let delta: String?      // response.output_text.delta / function_call_arguments.delta 的增量
    let message: String?    // 顶层错误信息（type == "error" 时）
    let error: ErrorBody?
    let response: ResponseBody?
    let item: OutputItem?   // response.output_item.added / done 的 item
    let itemId: String?     // response.function_call_arguments.* 的 item_id
    let outputIndex: Int?   // 无 item_id 时按 output_index 归并
    let arguments: String?  // response.function_call_arguments.done 的完整参数
    /// 部分端点在独立事件顶层携带的 usage。
    let usage: TokenUsage?

    enum CodingKeys: String, CodingKey {
        case type, delta, message, error, response, item, arguments, usage
        case itemId = "item_id"
        case outputIndex = "output_index"
    }

    /// 依次尝试顶层 message / error.message / response.error.message，返回可读错误信息。
    var resolvedErrorMessage: String {
        for candidate in [message, error?.message, response?.error?.message] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return "流式响应异常中断。"
    }
}

/// Responses function_call 累积器：按 item_id（缺失时回退 output_index）归并 call_id/name/arguments。
/// 全程在 MainActor 上使用，无并发访问。
final class ResponsesToolCallAccumulator {
    private struct Partial {
        var callId: String?
        var name: String?
        var arguments: String = ""
    }

    private var byKey: [String: Partial] = [:]
    private var order: [String] = []

    private func ensure(_ key: String) -> Partial {
        if let existing = byKey[key] { return existing }
        order.append(key)
        return Partial()
    }

    /// 登记/更新一个 function_call 项（added / done / arguments.done 共用）。
    func register(key: String, callID: String?, name: String?, arguments: String?) {
        var partial = ensure(key)
        if let callID, !callID.isEmpty { partial.callId = callID }
        if let name, !name.isEmpty { partial.name = name }
        if let arguments, !arguments.isEmpty { partial.arguments = arguments }
        byKey[key] = partial
    }

    func appendArguments(key: String, delta: String) {
        var partial = ensure(key)
        partial.arguments += delta
        byKey[key] = partial
    }

    var isEmpty: Bool { byKey.isEmpty }

    func clear() {
        byKey.removeAll()
        order.removeAll()
    }

    /// 按出现顺序产出完整调用；name/callId 缺失的项跳过（无法回传结果）。
    var completed: [CompletedToolCall] {
        order.compactMap { key in
            guard let partial = byKey[key], let name = partial.name, !name.isEmpty else { return nil }
            return CompletedToolCall(
                id: partial.callId ?? key,
                name: name,
                arguments: partial.arguments
            )
        }
    }
}

/// 非 2xx 时的错误信封：`{"error":{"message":"..."}}`。
struct APIErrorEnvelope: Decodable {
    struct APIErrorBody: Decodable {
        let message: String?
    }
    let error: APIErrorBody?
}

/// GET /models 响应：OpenAI 格式 `{"data":[{"id":"..."}]}`。
struct ModelListResponse: Decodable {
    struct Item: Decodable {
        let id: String?
    }
    let data: [Item]?
}

/// Chat Completions 非流式响应：取 choices[0].message.content 与 tool_calls。
struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let toolCalls: [ResponseToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }
        let message: Message?
    }
    let choices: [Choice]?
    /// 非流式 usage（prompt_tokens）。
    let usage: TokenUsage?
}

/// 非流式响应中的工具调用项（Chat Completions）。
struct ResponseToolCall: Decodable {
    struct Function: Decodable {
        let name: String?
        let arguments: String?
    }
    let id: String?
    let function: Function?
}

/// Responses 非流式响应：拼接 output[].content[] 中 type == output_text 的文本，
/// 并解析 output[] 中 type == "function_call" 的工具调用项。
struct ResponsesResponse: Decodable {
    struct Output: Decodable {
        struct Content: Decodable {
            let type: String?
            let text: String?
        }
        let type: String?
        let callId: String?
        let name: String?
        let arguments: String?
        let content: [Content]?

        enum CodingKeys: String, CodingKey {
            case type, name, arguments, content
            case callId = "call_id"
        }
    }
    let output: [Output]?
    /// 非流式 usage（input_tokens）。
    let usage: TokenUsage?
}
