import Foundation
import Security
import os

// MARK: - 服务层错误

/// AI 服务层错误：统一映射为用户可读中文提示，由 State 层呈现到对话流。
enum AIChatError: LocalizedError {
    case invalidBaseURL
    case missingAPIKey
    case missingModel
    case invalidResponse
    case http(status: Int, message: String)
    case timeout
    case network(String)
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Base URL 无效，请在设置中检查 AI 服务地址。"
        case .missingAPIKey:
            return "尚未配置 API Key，请在设置中填写。"
        case .missingModel:
            return "尚未配置模型名称（Model），请在设置中填写。"
        case .invalidResponse:
            return "服务端返回了无法识别的响应。"
        case let .http(status, message):
            return AIChatError.humanReadableHTTP(status: status, message: message)
        case .timeout:
            return "等待首个响应超时（120 秒），请检查网络或稍后重试。"
        case let .network(message):
            return "网络错误：\(message)"
        case let .streamError(message):
            // Responses 等协议在流内以事件形式报错，此处直接呈现服务端可读信息。
            return message.isEmpty ? "流式响应异常中断。" : message
        }
    }

    /// HTTP 状态码 → 用户可读中文提示（401/403/404/429/5xx 等）。
    private static func humanReadableHTTP(status: Int, message: String) -> String {
        let suffix = message.isEmpty ? "" : "（\(message)）"
        switch status {
        case 401:
            return "API Key 无效或已过期（401），请在设置中重新填写。\(suffix)"
        case 403:
            return "无权访问该模型或接口（403）。\(suffix)"
        case 404:
            return "接口地址不存在（404），请检查 Base URL 是否正确。\(suffix)"
        case 408:
            return "服务端请求超时（408），请稍后重试。\(suffix)"
        case 429:
            return "请求过于频繁或额度不足（429），请稍后再试。\(suffix)"
        case 500...599:
            return "服务端错误（\(status)），请稍后重试。\(suffix)"
        default:
            return "请求失败（\(status)）。\(suffix)"
        }
    }
}

// MARK: - API 协议

/// AI 服务协议类型：chat = Chat Completions（经典），responses = OpenAI Responses。
/// 供设置层选择；持久化到 UserDefaults 键 `ai.apiProtocol`。
enum APIProtocol: String, CaseIterable {
    case chatCompletions = "chat"
    case responses = "responses"
}

// MARK: - 流式事件

/// 一轮流式响应中收集到的一次完整工具调用（分片累积后的结果）。
struct CompletedToolCall: Equatable {
    /// 工具调用 id（Chat Completions 的 `id` / Responses 的 `call_id`）。
    let id: String
    let name: String
    /// 完整参数 JSON 字符串。
    let arguments: String
}

/// 流式事件：文本增量（打字机）或一次完整的工具调用集合。
/// 文本事件保持与旧 `AsyncStream<String>` 完全一致的行为；工具调用在流结束（[DONE] /
/// response.completed / 自然关闭）时一次性产出，避免中途回合。
enum AIStreamEvent {
    case text(String)
    case toolCalls([CompletedToolCall])
}

// MARK: - 模型列表项

/// 模型列表中的一项：显示名 + 请求体 model 标识。
/// 列表首项即默认模型；持久化到 UserDefaults 键 `ai.modelList`（JSON）。
struct AIModel: Identifiable, Codable, Equatable {
    var id: UUID
    /// 展示名（可读即可，允许与 modelId 相同）。
    var name: String
    /// 请求体中的 model 字段值。
    var modelId: String

    init(id: UUID = UUID(), name: String, modelId: String) {
        self.id = id
        self.name = name
        self.modelId = modelId
    }
}

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
private struct ChatToolDefinition: Encodable {
    let type: String
    let function: ChatToolFunctionDefinition
}

private struct ChatToolFunctionDefinition: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

/// Responses 的工具声明（扁平结构）。
private struct ResponsesToolDefinition: Encodable {
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

/// Chat Completions 请求体。
private struct ChatCompletionRequestBody: Encodable {
    let model: String
    let messages: [ChatCompletionMessage]
    let stream: Bool
    /// 启用的工具；为空时由合成编码自动省略该字段，保持旧行为。
    let tools: [ChatToolDefinition]?
}

/// Responses 请求体：system prompt 走 instructions，对话历史走 input。
private struct ResponsesRequestBody: Encodable {
    let model: String
    /// 可选；nil 时由 Encodable 合成逻辑（encodeIfPresent）自动省略该字段。
    let instructions: String?
    let input: [ResponsesInputItem]
    let stream: Bool
    let tools: [ResponsesToolDefinition]?
}

/// Responses 的 input 项：普通 message / function_call / function_call_output 三种变体。
/// 采用单结构 + 自定义编码，按类型只输出相关字段，避免 null 污染请求体。
private struct ResponsesInputItem: Encodable {
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

/// Chat Completions 的 SSE 增量分片：choices[0].delta 的 content 或 tool_calls 分片。
private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let toolCalls: [DeltaToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }
        let delta: Delta?
    }
    let choices: [Choice]
}

/// Chat Completions 的 tool_calls 分片：name/id/type 通常首片给出，arguments 逐片累积。
private struct DeltaToolCall: Decodable {
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
private final class ChatToolCallAccumulator {
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
private struct ResponsesEvent: Decodable {
    struct ErrorBody: Decodable {
        let message: String?
    }

    struct ResponseBody: Decodable {
        let error: ErrorBody?
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

    enum CodingKeys: String, CodingKey {
        case type, delta, message, error, response, item, arguments
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
private final class ResponsesToolCallAccumulator {
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
private struct APIErrorEnvelope: Decodable {
    struct APIErrorBody: Decodable {
        let message: String?
    }
    let error: APIErrorBody?
}

/// GET /models 响应：OpenAI 格式 `{"data":[{"id":"..."}]}`。
private struct ModelListResponse: Decodable {
    struct Item: Decodable {
        let id: String?
    }
    let data: [Item]?
}

/// Chat Completions 非流式响应：取 choices[0].message.content 与 tool_calls。
private struct ChatCompletionResponse: Decodable {
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
}

/// 非流式响应中的工具调用项（Chat Completions）。
private struct ResponseToolCall: Decodable {
    struct Function: Decodable {
        let name: String?
        let arguments: String?
    }
    let id: String?
    let function: Function?
}

/// Responses 非流式响应：拼接 output[].content[] 中 type == output_text 的文本，
/// 并解析 output[] 中 type == "function_call" 的工具调用项。
private struct ResponsesResponse: Decodable {
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
}

// MARK: - 服务

/// OpenAI 兼容 SSE 客户端 + Keychain 存取 + 配置读写。
/// 服务层无 UI 依赖（不 import SwiftUI/AppKit）；整体 @MainActor 以保证状态访问串行、回调落在主线程。
@MainActor
final class AIChatService {
    static let shared = AIChatService()

    private init() {}

    // MARK: 配置（非敏感，存 UserDefaults）

    private enum ConfigKey {
        static let baseURL = "ai.baseURL"
        /// 旧版单模型键（保留用于迁移与兼容读取）。
        static let model = "ai.model"
        /// 模型列表（JSON 编码后的 Data，含显示名与 modelId，首项为默认）。
        static let modelList = "ai.modelList"
        /// 候选池：端点返回的全部可用 model id（[String] JSON）。
        static let availableModels = "ai.availableModels"
        /// 当前选中模型的 modelId。
        static let selectedModel = "ai.selectedModel"
        static let systemPrompt = "ai.systemPrompt"
        static let apiProtocol = "ai.apiProtocol"
    }

    /// 用户填写的根地址，如 `https://api.openai.com/v1`。
    /// 未配置时回退环境变量 `QUICKSHOW_AI_BASE_URL`（仅内存兜底，不落盘）。
    var baseURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: ConfigKey.baseURL) ?? ""
            if !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return stored }
            return environmentValue("QUICKSHOW_AI_BASE_URL") ?? ""
        }
        set { UserDefaults.standard.set(newValue, forKey: ConfigKey.baseURL) }
    }

    /// 读取环境变量兜底值：缺失或空白返回 nil。
    private func environmentValue(_ key: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var model: String {
        get { UserDefaults.standard.string(forKey: ConfigKey.model) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: ConfigKey.model) }
    }

    /// 模型列表。首次读取时若列表缺失但旧 `ai.model` 有值，则迁移为列表首项。
    /// 说明：本类整体 @MainActor，所有访问都在主线程串行，故用普通属性做内存缓存即可，
    /// 无需额外加锁；缓存命中即返回，避免每次 get 都反序列化整个 JSON。
    var modelList: [AIModel] {
        get {
            ensureModelListMigration()
            if let cache = _modelListCache { return cache }

            let loaded = Self.decodeModelList(UserDefaults.standard.data(forKey: ConfigKey.modelList))
            // 兼容旧版单模型配置：迁移为列表第一项（保留旧键不删除）。
            if loaded.isEmpty {
                let legacy = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !legacy.isEmpty {
                    let migrated = [AIModel(name: legacy, modelId: legacy)]
                    _modelListCache = migrated
                    writeModelList(migrated)
                    return migrated
                }
            }
            _modelListCache = loaded
            return loaded
        }
        set {
            _modelListCache = newValue
            writeModelList(newValue)
            // 列表变化后校正选中模型，保证其仍存在于列表中。
            let selected = UserDefaults.standard.string(forKey: ConfigKey.selectedModel) ?? ""
            if !newValue.contains(where: { $0.modelId == selected }) {
                if let first = newValue.first {
                    UserDefaults.standard.set(first.modelId, forKey: ConfigKey.selectedModel)
                } else {
                    UserDefaults.standard.removeObject(forKey: ConfigKey.selectedModel)
                }
            }
        }
    }

    /// 候选池：端点返回的全部可用 model id（只读池，供设置页搜索/挑选）。
    /// 与 modelList 同为内存缓存 + UserDefaults 落盘。
    var availableModels: [String] {
        get {
            ensureModelListMigration()
            if let cache = _availableModelsCache { return cache }
            let loaded: [String]
            if let data = UserDefaults.standard.data(forKey: ConfigKey.availableModels),
               let ids = try? JSONDecoder().decode([String].self, from: data) {
                loaded = ids
            } else {
                loaded = []
            }
            _availableModelsCache = loaded
            return loaded
        }
        set {
            _availableModelsCache = newValue
            writeAvailableModels(newValue)
        }
    }

    // MARK: 模型缓存与迁移（内部）

    /// modelList 内存缓存（nil 表示尚未加载）。
    private var _modelListCache: [AIModel]?
    /// availableModels 内存缓存（nil 表示尚未加载）。
    private var _availableModelsCache: [String]?

    private static func decodeModelList(_ data: Data?) -> [AIModel] {
        guard let data,
              let list = try? JSONDecoder().decode([AIModel].self, from: data) else {
            return []
        }
        return list
    }

    private func writeModelList(_ list: [AIModel]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: ConfigKey.modelList)
        }
    }

    private func writeAvailableModels(_ ids: [String]) {
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: ConfigKey.availableModels)
        }
    }

    /// 一次性迁移（以 `ai.availableModels` 键是否存在作为迁移标记）：
    /// 旧版把拉取到的全部模型直接塞进 modelList，导致我的模型膨胀、界面卡顿。
    /// 迁移时把 modelList 中的 modelId 去重收进候选池，并把 modelList 收缩为仅保留
    /// 当前 selectedModel 所在条目（无效则保留首项）。条目 ≤ 1 时写空池标记避免反复迁移。
    private func ensureModelListMigration() {
        guard UserDefaults.standard.object(forKey: ConfigKey.availableModels) == nil else { return }

        // 读取现有我的模型（优先缓存，其次原始 JSON；再兜底旧 ai.model）。
        var baseList: [AIModel]
        if let cache = _modelListCache {
            baseList = cache
        } else {
            baseList = Self.decodeModelList(UserDefaults.standard.data(forKey: ConfigKey.modelList))
        }
        if baseList.isEmpty {
            let legacy = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !legacy.isEmpty {
                baseList = [AIModel(name: legacy, modelId: legacy)]
            }
        }

        guard baseList.count > 1 else {
            // 条目 ≤ 1：原样保留我的模型，写空候选池标记，迁移只发生一次。
            _modelListCache = baseList
            if !baseList.isEmpty { writeModelList(baseList) }
            writeAvailableModels([])
            return
        }

        // 候选池 = 现有全部 modelId 去重（保序）。
        var seen = Set<String>()
        var pool: [String] = []
        for item in baseList {
            let id = item.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            pool.append(id)
        }

        // 我的模型收缩：优先保留当前选中条目，否则首项。
        let selected = UserDefaults.standard.string(forKey: ConfigKey.selectedModel) ?? ""
        let kept: [AIModel]
        if let match = baseList.first(where: { $0.modelId == selected }) {
            kept = [match]
        } else if let first = baseList.first {
            kept = [first]
        } else {
            kept = []
        }

        _modelListCache = kept
        writeModelList(kept)
        writeAvailableModels(pool)
        if !kept.contains(where: { $0.modelId == selected }), let first = kept.first {
            UserDefaults.standard.set(first.modelId, forKey: ConfigKey.selectedModel)
        }
    }

    /// 当前选中模型（切换对下一轮生效）。未显式选择时回退列表首项。
    var selectedModel: String {
        get {
            let list = modelList
            let stored = UserDefaults.standard.string(forKey: ConfigKey.selectedModel) ?? ""
            if !stored.isEmpty, list.contains(where: { $0.modelId == stored }) {
                return stored
            }
            if let first = list.first { return first.modelId }
            // 无任何配置时回退环境变量 `QUICKSHOW_AI_MODEL`（仅内存兜底）。
            if let envModel = environmentValue("QUICKSHOW_AI_MODEL") { return envModel }
            return stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ConfigKey.selectedModel)
            // 同步旧键，兼容仍读取 ai.model 的外部路径。
            UserDefaults.standard.set(newValue, forKey: ConfigKey.model)
        }
    }

    /// 可选 system prompt，空串表示不发送 system 消息。
    var systemPrompt: String {
        get { UserDefaults.standard.string(forKey: ConfigKey.systemPrompt) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: ConfigKey.systemPrompt) }
    }

    /// 当前 API 协议，默认 Chat Completions（键缺失或值非法时回退默认）。
    var apiProtocol: APIProtocol {
        get {
            let raw = UserDefaults.standard.string(forKey: ConfigKey.apiProtocol) ?? ""
            return APIProtocol(rawValue: raw) ?? .chatCompletions
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ConfigKey.apiProtocol) }
    }

    // MARK: Keychain（敏感信息，绝不落 UserDefaults）

    /// 诊断日志：Keychain 读取失败的原因可在「控制台.app」或 `log show` 按 subsystem 过滤查看
    private let logger = Logger(subsystem: "com.dzhang.quickshow.ai", category: "keychain")

    private let keychainService = "com.dzhang.quickshow.ai"
    private let keychainAccount = "apiKey"

    /// 读取 API Key。读不到（未配置/Keychain 异常）时回退环境变量 `QUICKSHOW_AI_API_KEY`
    /// （仅内存兜底，绝不写入 Keychain）；仍无则返回 nil。
    var apiKey: String? {
        var query = baseKeychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        // 环境变量兜底：优先内存注入，避免把 CI/测试用 Key 落盘。
        if let envKey = environmentValue("QUICKSHOW_AI_API_KEY") { return envKey }
        // 诊断日志：status 常见值（SecBase.h）——-25300 errSecItemNotFound 条目不存在；
        // -34018 errSecInteractionNotAllowed 无 UI 交互场景；-60007 errSecAuthFailed 签名/授权被拒
        logger.warning("Keychain 读取失败 status=\(status) dataNil=\(item == nil)")
        return nil
    }

    /// 保存 API Key（删除重建策略）。任何 Keychain 错误均静默忽略。
    /// 为什么放弃 SecItemUpdate：条目可能是在旧签名二进制下创建的，其 ACL 不含当前
    /// 稳定证书（QuickShow Development）的授权，导致此后每次读取都弹钥匙串密码。
    /// 改为「先删后建」可确保条目始终在**当前签名**下重建，ACL 永远与运行二进制一致。
    func saveAPIKey(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }

        // 1) 先删除旧条目（忽略「不存在」错误），清除可能携带的旧签名 ACL。
        SecItemDelete(baseKeychainQuery() as CFDictionary)

        // 2) 在当前签名下重建条目；显式声明可访问性（行为与现状一致但更明确）。
        var addQuery = baseKeychainQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// 删除 API Key。
    func deleteAPIKey() {
        SecItemDelete(baseKeychainQuery() as CFDictionary)
    }

    private func baseKeychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    // MARK: SSE 流式请求

    /// 当前进行中的生产任务，供 abort() 取消。
    private var currentTask: Task<Void, Never>?

    /// 发起一次流式对话，产出文本增量或完整工具调用事件。
    /// - 文本事件行为与旧 `AsyncThrowingStream<String>` 完全一致；工具调用在流结束时整批产出。
    /// - 错误通过 AsyncThrowingStream 抛出，由 State 层呈现。
    func send(messages: [ChatCompletionMessage]) -> AsyncThrowingStream<AIStreamEvent, Error> {
        // 重复发送前先中止上一次请求，避免并发流交叉。
        abort()

        return AsyncThrowingStream<AIStreamEvent, Error> { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.performStream(messages: messages) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    // 用户主动中止：无错误，半截内容由 State 层落定为 .aborted。
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.currentTask = task
            // 下游提前终止（消费任务被取消）时同步取消网络请求。
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 立即中止当前流式请求。取消生产任务会触发 bytes 序列抛 CancellationError，停止回调。
    func abort() {
        currentTask?.cancel()
        currentTask = nil
    }

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

    /// 非流式补全（用于 LLM 标题摘要等后台轻量请求），返回纯文本。
    func complete(messages: [ChatCompletionMessage]) async throws -> String {
        let proto = apiProtocol
        let path = proto == .responses ? "/responses" : "/chat/completions"
        guard let url = endpointURL(path: path) else { throw AIChatError.invalidBaseURL }
        guard let key = apiKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIChatError.missingAPIKey
        }
        let resolvedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedModel.isEmpty else { throw AIChatError.missingModel }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // 非流式补全用于标题摘要等轻量后台请求：不带工具，避免摘要器误触发工具调用。
        request.httpBody = try encodeRequestBody(
            proto: proto,
            model: resolvedModel,
            messages: messages,
            stream: false,
            includeTools: false
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

    // MARK: 内部实现

    /// 首 token 到达标记（watchdog 与读取循环同处 MainActor，读写天然串行）。
    private final class FirstTokenFlag {
        var received = false
    }

    /// 执行一次 SSE 请求并逐事件回调（MainActor 上下文）。
    private func performStream(
        messages: [ChatCompletionMessage],
        onEvent: (AIStreamEvent) -> Void
    ) async throws {
        // 协议在请求发起时一次性快照，避免流进行中被设置变更影响分流。
        let proto = apiProtocol

        let endpointPath = proto == .responses ? "/responses" : "/chat/completions"
        guard let url = endpointURL(path: endpointPath) else { throw AIChatError.invalidBaseURL }
        guard let key = apiKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIChatError.missingAPIKey
        }
        let resolvedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedModel.isEmpty else { throw AIChatError.missingModel }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120 // 与首 token 看门狗一致，避免默认 60s 提前打断
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encodeRequestBody(
            proto: proto,
            model: resolvedModel,
            messages: messages,
            stream: true,
            includeTools: true
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AIChatError.invalidResponse
        }

        // 非 2xx：读取 body 提取错误信息，映射为中文化提示后抛出。
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 4000 { break } // 防异常端点返回超长 body
            }
            throw AIChatError.http(
                status: http.statusCode,
                message: extractErrorMessage(from: body)
            )
        }

        // 首 token 看门狗：120s 内无任何增量即判超时并取消请求。
        let firstTokenFlag = FirstTokenFlag()
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if !firstTokenFlag.received {
                self?.abort()
            }
        }
        defer { watchdog.cancel() }

        // 首 token 到达时撤销看门狗，两种协议共用。
        let markFirstToken = {
            if !firstTokenFlag.received {
                firstTokenFlag.received = true
                watchdog.cancel() // 首 token 已到，撤销超时判定
            }
        }

        // 工具调用分片累积器（每轮流各自独立）。
        let chatAccumulator = ChatToolCallAccumulator()
        let responsesAccumulator = ResponsesToolCallAccumulator()

        do {
            streaming: for try await line in bytes.lines {
                try Task.checkCancellation()

                // 只处理 data: 行：忽略空行、`:` 注释行与心跳行、event:/id: 等字段。
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst("data:".count)
                    .trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty else { continue }
                guard let data = payload.data(using: .utf8) else { continue }

                if proto == .responses {
                    // Responses：按顶层 type 分流，无 [DONE] 哨兵，靠 completed/failed 结束。
                    guard let event = try? JSONDecoder().decode(ResponsesEvent.self, from: data) else {
                        continue
                    }
                    switch event.type {
                    case "response.output_text.delta":
                        guard let delta = event.delta, !delta.isEmpty else { continue }
                        markFirstToken()
                        onEvent(.text(delta))
                    case "response.output_item.added", "response.output_item.done":
                        // function_call 项登记：added 记 call_id/name，done 时携带最终 arguments。
                        guard let item = event.item, item.type == "function_call" else { continue }
                        let key = item.id ?? "index-\(event.outputIndex ?? 0)"
                        responsesAccumulator.register(
                            key: key,
                            callID: item.callId,
                            name: item.name,
                            arguments: item.arguments
                        )
                        markFirstToken()
                    case "response.function_call_arguments.delta":
                        guard let delta = event.delta, !delta.isEmpty else { continue }
                        let key = event.itemId ?? "index-\(event.outputIndex ?? 0)"
                        responsesAccumulator.appendArguments(key: key, delta: delta)
                        markFirstToken()
                    case "response.function_call_arguments.done":
                        guard let itemID = event.itemId else { continue }
                        responsesAccumulator.register(
                            key: itemID,
                            callID: nil,
                            name: nil,
                            arguments: event.arguments
                        )
                    case "response.completed":
                        if !responsesAccumulator.isEmpty {
                            onEvent(.toolCalls(responsesAccumulator.completed))
                            responsesAccumulator.clear()
                        }
                        break streaming // 正常结束
                    case "response.failed", "response.error", "error":
                        throw AIChatError.streamError(event.resolvedErrorMessage)
                    default:
                        continue // response.created / content_part.* 等一律忽略
                    }
                } else {
                    // Chat Completions：data: {...} 取 delta.content / delta.tool_calls，[DONE] 结束。
                    if payload == "[DONE]" {
                        if !chatAccumulator.isEmpty {
                            onEvent(.toolCalls(chatAccumulator.completed))
                            chatAccumulator.clear()
                        }
                        break streaming
                    }
                    // 个别分片解析失败不中断整段流（如 usage-only chunk）。
                    guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                          let delta = chunk.choices.first?.delta else {
                        continue
                    }
                    if let content = delta.content, !content.isEmpty {
                        markFirstToken()
                        onEvent(.text(content))
                    }
                    if let toolCalls = delta.toolCalls, !toolCalls.isEmpty {
                        chatAccumulator.ingest(toolCalls)
                        markFirstToken()
                    }
                }
            }
            // 流自然结束（部分端点无 [DONE]/completed 哨兵）：补发累积的工具调用。
            if proto == .responses {
                if !responsesAccumulator.isEmpty {
                    onEvent(.toolCalls(responsesAccumulator.completed))
                    responsesAccumulator.clear()
                }
            } else if !chatAccumulator.isEmpty {
                onEvent(.toolCalls(chatAccumulator.completed))
                chatAccumulator.clear()
            }
        } catch is CancellationError {
            // 区分「用户主动中止」与「首 token 超时」：超时需向 State 抛出明确错误。
            if !firstTokenFlag.received {
                throw AIChatError.timeout
            }
            throw CancellationError()
        }
    }

    /// 拼接端点：Base URL 去尾部斜杠后追加协议路径。
    private func endpointURL(path: String) -> URL? {
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
    private func encodeRequestBody(
        proto: APIProtocol,
        model: String,
        messages: [ChatCompletionMessage],
        stream: Bool,
        includeTools: Bool
    ) throws -> Data {
        // 启用的工具声明：为空时返回 nil，合成编码自动省略该字段。
        let chatTools = includeTools ? chatToolDefinitions() : nil
        let responsesTools = includeTools ? responsesToolDefinitions() : nil

        guard proto == .responses else {
            return try JSONEncoder().encode(
                ChatCompletionRequestBody(model: model, messages: messages, stream: stream, tools: chatTools)
            )
        }

        // 从消息数组提取 system 作为 instructions；缺失时回退配置中的 systemPrompt。
        var instructions: String?
        if let system = messages.first(where: { $0.role == "system" })?.content?.plainText {
            let trimmed = system.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { instructions = trimmed }
        }
        if instructions == nil {
            let fallback = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty { instructions = fallback }
        }

        // 对话历史（非 system）映射为 input：普通消息、assistant function_call、工具结果三类。
        let input = responsesInput(from: messages)

        return try JSONEncoder().encode(
            ResponsesRequestBody(model: model, instructions: instructions, input: input, stream: stream, tools: responsesTools)
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
    private func extractErrorMessage(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data),
           let message = envelope.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        return String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }
}