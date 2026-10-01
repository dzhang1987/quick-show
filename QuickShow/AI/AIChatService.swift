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

/// 发往 OpenAI 兼容端点的单条消息。
struct ChatCompletionMessage: Codable {
    let role: String
    let content: MessageContent

    init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
    }

    init(role: String, content: MessageContent) {
        self.role = role
        self.content = content
    }
}

/// Chat Completions 请求体。
private struct ChatCompletionRequestBody: Encodable {
    let model: String
    let messages: [ChatCompletionMessage]
    let stream: Bool
}

/// Responses 请求体：system prompt 走 instructions，对话历史走 input。
private struct ResponsesRequestBody: Encodable {
    let model: String
    /// 可选；nil 时由 Encodable 合成逻辑（encodeIfPresent）自动省略该字段。
    let instructions: String?
    let input: [ResponsesInputMessage]
    let stream: Bool
}

/// Responses 的 input 单条消息（role 仅 user/assistant）。
private struct ResponsesInputMessage: Encodable {
    let role: String
    let content: ResponsesContent
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

/// Chat Completions 的 SSE 增量分片：只关心 choices[0].delta.content。
private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta?
    }
    let choices: [Choice]
}

/// Responses 的 SSE 事件：按顶层 type 分流，字段宽松可选（缺失即忽略该事件）。
private struct ResponsesEvent: Decodable {
    struct ErrorBody: Decodable {
        let message: String?
    }

    struct ResponseBody: Decodable {
        let error: ErrorBody?
    }

    let type: String?
    let delta: String?      // response.output_text.delta 的增量文本
    let message: String?    // 顶层错误信息（type == "error" 时）
    let error: ErrorBody?
    let response: ResponseBody?

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

/// Chat Completions 非流式响应：取 choices[0].message.content。
private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message?
    }
    let choices: [Choice]?
}

/// Responses 非流式响应：拼接 output[].content[] 中 type == output_text 的文本。
private struct ResponsesResponse: Decodable {
    struct Output: Decodable {
        struct Content: Decodable {
            let type: String?
            let text: String?
        }
        let content: [Content]?
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
    var baseURL: String {
        get { UserDefaults.standard.string(forKey: ConfigKey.baseURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: ConfigKey.baseURL) }
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

    /// 读取 API Key。读不到（未配置/Keychain 异常）返回 nil —— 静默降级，不抛出。
    var apiKey: String? {
        var query = baseKeychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            // 诊断日志：status 常见值（SecBase.h）——-25300 errSecItemNotFound 条目不存在；
            // -34018 errSecInteractionNotAllowed 无 UI 交互场景；-60007 errSecAuthFailed 签名/授权被拒
            logger.warning("Keychain 读取失败 status=\(status) dataNil=\(item == nil)")
            return nil
        }
        return key
    }

    /// 新增或更新 API Key。任何 Keychain 错误均静默忽略。
    func saveAPIKey(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }
        let query = baseKeychainQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
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

    /// 发起一次流式对话，逐 token 产出增量文本。
    /// - 错误通过 AsyncThrowingStream 抛出，由 State 层呈现。
    func send(messages: [ChatCompletionMessage]) -> AsyncThrowingStream<String, Error> {
        // 重复发送前先中止上一次请求，避免并发流交叉。
        abort()

        return AsyncThrowingStream<String, Error> { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.performStream(messages: messages) { token in
                        continuation.yield(token)
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
        request.httpBody = try encodeRequestBody(
            proto: proto,
            model: resolvedModel,
            messages: messages,
            stream: false
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIChatError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIChatError.http(status: http.statusCode, message: extractErrorMessage(from: body))
        }
        return try extractCompletionText(proto: proto, data: data)
    }

    /// 从非流式响应中提取文本。
    private func extractCompletionText(proto: APIProtocol, data: Data) throws -> String {
        if proto == .responses {
            guard let decoded = try? JSONDecoder().decode(ResponsesResponse.self, from: data) else {
                throw AIChatError.invalidResponse
            }
            let outputs: [ResponsesResponse.Output] = decoded.output ?? []
            var pieces: [String] = []
            for output in outputs {
                let contents: [ResponsesResponse.Output.Content] = output.content ?? []
                for content in contents {
                    if content.type == "output_text" || content.type == nil {
                        if let piece = content.text { pieces.append(piece) }
                    }
                }
            }
            let text = pieces.joined()
            guard !text.isEmpty else { throw AIChatError.invalidResponse }
            return text
        }
        guard let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
              let text = decoded.choices?.first?.message?.content,
              !text.isEmpty else {
            throw AIChatError.invalidResponse
        }
        return text
    }

    // MARK: 内部实现

    /// 首 token 到达标记（watchdog 与读取循环同处 MainActor，读写天然串行）。
    private final class FirstTokenFlag {
        var received = false
    }

    /// 执行一次 SSE 请求并逐 token 回调（MainActor 上下文）。
    private func performStream(
        messages: [ChatCompletionMessage],
        onToken: (String) -> Void
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
            stream: true
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
                        onToken(delta)
                    case "response.completed":
                        break streaming // 正常结束
                    case "response.failed", "response.error", "error":
                        throw AIChatError.streamError(event.resolvedErrorMessage)
                    default:
                        continue // response.created / output_item.* / content_part.* 等一律忽略
                    }
                } else {
                    // Chat Completions：data: {...} 取 delta.content，[DONE] 结束。
                    if payload == "[DONE]" { break streaming }
                    // 个别分片解析失败不中断整段流（如 usage-only chunk）。
                    guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
                        continue
                    }
                    guard let delta = chunk.choices.first?.delta?.content, !delta.isEmpty else {
                        continue
                    }
                    markFirstToken()
                    onToken(delta)
                }
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
    /// - chat：`{model, messages:[{role,content}], stream}`（system prompt 维持注入 messages[0]）
    /// - responses：`{model, instructions?, input:[{role,content}], stream}`（system 转 instructions）
    private func encodeRequestBody(
        proto: APIProtocol,
        model: String,
        messages: [ChatCompletionMessage],
        stream: Bool
    ) throws -> Data {
        guard proto == .responses else {
            return try JSONEncoder().encode(
                ChatCompletionRequestBody(model: model, messages: messages, stream: stream)
            )
        }

        // 从消息数组提取 system 作为 instructions；缺失时回退配置中的 systemPrompt。
        var instructions: String?
        if let system = messages.first(where: { $0.role == "system" })?.content.plainText {
            let trimmed = system.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { instructions = trimmed }
        }
        if instructions == nil {
            let fallback = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty { instructions = fallback }
        }

        // 对话历史（非 system）映射为 input，role 仅 user/assistant。
        let input = messages
            .filter { $0.role != "system" }
            .map { ResponsesInputMessage(role: $0.role, content: ResponsesContent(from: $0.content)) }

        return try JSONEncoder().encode(
            ResponsesRequestBody(model: model, instructions: instructions, input: input, stream: stream)
        )
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