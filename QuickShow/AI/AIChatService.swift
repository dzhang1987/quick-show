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

/// 流式事件：文本增量（打字机）、思考过程增量或一次完整的工具调用集合。
/// 文本/思考事件保持与旧 `AsyncStream<String>` 一致的逐片行为；工具调用在流结束（[DONE] /
/// response.completed / 自然关闭）时一次性产出，避免中途回合。
enum AIStreamEvent {
    case text(String)
    /// 模型思考过程（reasoning）增量：Chat Completions 的 reasoning_content/reasoning，
    /// 或 Responses 的 reasoning_text/reasoning_summary_text；与正文分开累积。
    case reasoning(String)
    case toolCalls([CompletedToolCall])
    /// 本轮真实 prompt token 用量（由服务端 usage 上报，端点在末片/完成事件携带）。
    case usage(promptTokens: Int)
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
    /// 模型上下文窗口（tokens）。可选：旧 JSON 缺失时按 nil 解码，运行时回退适配层默认值。
    var contextWindow: Int?

    init(id: UUID = UUID(), name: String, modelId: String, contextWindow: Int? = nil) {
        self.id = id
        self.name = name
        self.modelId = modelId
        self.contextWindow = contextWindow
    }
}

/// 一次流式请求的会话级选项：会话绑定模型与思考档位。
/// 两者均可为 nil，表示交给服务层回落到全局默认模型 / 模型默认思考行为。
struct AIChatRequestOptions {
    /// 会话绑定模型 id（nil = 使用全局 selectedModel）。
    var modelId: String?
    /// 会话思考档位（nil = 不发送思考字段，跟随模型默认）。
    var thinkingLevel: ThinkingLevel?

    init(modelId: String? = nil, thinkingLevel: ThinkingLevel? = nil) {
        self.modelId = modelId
        self.thinkingLevel = thinkingLevel
    }
}

// MARK: - 服务

/// OpenAI 兼容 SSE 客户端 + API Key 文件存取 + 配置读写。
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

    // MARK: API Key 文件存储（放弃 Keychain）

    /// 诊断日志：文件读写异常可在此查看
    private let logger = Logger(subsystem: "com.dzhang.quickshow.ai", category: "apikey")

    /// 旧版 Keychain 坐标（仅用于一次性迁移与清理遗留条目）。
    private let legacyKeychainService = "com.dzhang.quickshow.ai"
    private let legacyKeychainAccount = "apiKey"

    /// API Key 落盘文件：`~/Library/Application Support/QuickShow/apikey`（纯文本单行）。
    /// 放弃 Keychain 的原因：本地开发频繁重编译导致签名变化，Keychain 条目 ACL 每次读取都弹密码授权。
    private var apiKeyFileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("QuickShow", isDirectory: true)
            .appendingPathComponent("apikey")
    }

    /// 读取 API Key（对外兼容旧属性名）：文件 → 旧 Keychain 一次性迁移 → 环境变量兜底。
    var apiKey: String? { loadAPIKey() }

    /// 读取 API Key。文件不存在时尝试从旧 Keychain 条目搬家；任何异常静默返回 nil，不阻塞主流程。
    func loadAPIKey() -> String? {
        if let url = apiKeyFileURL, FileManager.default.fileExists(atPath: url.path) {
            // 读取前顺手把过宽权限收紧到 0600。
            tightenPermissionsIfNeeded(at: url)
            if let data = try? Data(contentsOf: url),
               let key = String(data: data, encoding: .utf8) {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        } else if let migrated = migrateLegacyKeychainKeyIfNeeded() {
            // 文件尚不存在：从旧 Keychain 搬家（v1.5.2 前旧版本存量数据），成功后直接返回。
            return migrated
        }

        // 环境变量兜底：仅内存注入，绝不落盘。
        if let envKey = environmentValue("QUICKSHOW_AI_API_KEY") { return envKey }
        return nil
    }

    /// 保存 API Key：原子写文件并设 0600 权限。任何错误静默忽略。
    func saveAPIKey(_ key: String) {
        guard let url = apiKeyFileURL else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return }

        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            // 目录不存在则创建并设 0700（已存在则复用，不覆盖其权限）。
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            // 原子写：先写临时文件再替换，避免中途崩溃留下半截内容。
            try data.write(to: url, options: .atomic)
            // 文件权限收紧为仅当前用户可读写。
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            logger.warning("API Key 写入失败：\(error.localizedDescription)")
        }
    }

    /// 清除 API Key：删文件，并尽力删除旧 Keychain 遗留条目（错误忽略）。
    func clearAPIKey() {
        if let url = apiKeyFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        SecItemDelete(legacyKeychainQuery() as CFDictionary)
    }

    /// 把文件权限收紧为 0600（仅当存在 group/other 权限位时）。
    private func tightenPermissionsIfNeeded(at url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return
        }
        if permissions.intValue & 0o077 != 0 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// 一次性 Keychain 迁移：把 v1.5.2 之前旧版本存在 Keychain 的 API Key 搬到文件并清理旧条目。
    /// 读取旧条目可能弹最后一次钥匙串授权属预期；用户拒绝或任何错误一律静默放弃，绝不阻塞。
    private func migrateLegacyKeychainKeyIfNeeded() -> String? {
        var query = legacyKeychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 搬到文件后清掉 Keychain 条目，彻底摆脱授权弹窗。
        saveAPIKey(trimmed)
        SecItemDelete(legacyKeychainQuery() as CFDictionary)
        return trimmed
    }

    /// 旧版 Keychain 条目的查询字典（迁移与清理共用）。
    private func legacyKeychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: legacyKeychainAccount
        ]
    }

    // MARK: SSE 流式请求

    /// 发起一次流式对话，产出文本增量或完整工具调用事件。
    /// - 文本事件行为与旧 `AsyncThrowingStream<String>` 完全一致；工具调用在流结束时整批产出。
    /// - 错误通过 AsyncThrowingStream 抛出，由 State 层呈现。
    /// - 并行流支持（2026-10 会话并行专项）：本层不再持有全局任务句柄、不提供全局 abort——
    ///   多会话各自持有独立流，中止语义由消费侧 Task 取消经 onTermination 链路传导回网络任务。
    func send(
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions = AIChatRequestOptions()
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        return AsyncThrowingStream<AIStreamEvent, Error> { continuation in
            // 流局部取消盒：看门狗超时经此取消「本流」的生产任务（Task 无法自引用，盒中转）。
            let cancelBox = TaskCancellationBox()
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.performStream(
                        messages: messages,
                        options: options,
                        cancel: { cancelBox.cancel() }
                    ) { event in
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
            cancelBox.set(task)
            // 下游提前终止（消费任务被取消）时同步取消网络请求。
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
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

    // MARK: 内部实现

    /// 首 token 到达标记（watchdog 与读取循环同处 MainActor，读写天然串行）。
    private final class FirstTokenFlag {
        var received = false
    }

    /// 流局部任务取消盒：生产 Task 无法在自身闭包内自引用，经盒中转供看门狗超时取消。
    /// set 在 Task 创建后立即执行（微秒级），watchdog 最早 120s 后才触发，无竞态窗口。
    /// @unchecked Sendable：NSLock 保护唯一可变状态 task。
    private final class TaskCancellationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func set(_ task: Task<Void, Never>) {
            lock.lock()
            defer { lock.unlock() }
            self.task = task
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            task?.cancel()
        }
    }

    /// 执行一次 SSE 请求并逐事件回调（MainActor 上下文）。
    /// `cancel`：本流生产任务的取消入口（首 token 看门狗超时调用；流局部，不影响其他会话）。
    private func performStream(
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions,
        cancel: (() -> Void)?,
        onEvent: (AIStreamEvent) -> Void
    ) async throws {
        // 协议在请求发起时一次性快照，避免流进行中被设置变更影响分流。
        let proto = apiProtocol

        let endpointPath = proto == .responses ? "/responses" : "/chat/completions"
        guard let url = endpointURL(path: endpointPath) else { throw AIChatError.invalidBaseURL }
        guard let key = apiKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIChatError.missingAPIKey
        }
        // 模型解析优先级：会话绑定模型（请求传入且非空）→ 全局 selectedModel。
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
        request.timeoutInterval = 120 // 与首 token 看门狗一致，避免默认 60s 提前打断
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // 思考字段由适配层按「模型 + 统一档位」转换，服务层不感知具体模型差异。
        let thinkingFields = AIModelAdapter.thinkingFields(for: resolvedModel, level: options.thinkingLevel)
        request.httpBody = try encodeRequestBody(
            proto: proto,
            model: resolvedModel,
            messages: messages,
            stream: true,
            includeTools: true,
            thinkingFields: thinkingFields
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

        // 首 token 看门狗：120s 内无任何增量即判超时并取消本流生产任务（流局部取消）。
        let firstTokenFlag = FirstTokenFlag()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if !firstTokenFlag.received {
                cancel?()
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
                    // usage 归一：独立事件顶层 usage 或 response.completed 的 response.usage。
                    if let usage = event.usage ?? event.response?.usage,
                       let prompt = usage.resolvedPromptTokens {
                        onEvent(.usage(promptTokens: prompt))
                    }
                    switch event.type {
                    case "response.output_text.delta":
                        guard let delta = event.delta, !delta.isEmpty else { continue }
                        markFirstToken()
                        onEvent(.text(delta))
                    case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
                        // Responses 思考增量：正文之外的 reasoning 通道，与 output_text 分开派发。
                        guard let delta = event.delta, !delta.isEmpty else { continue }
                        markFirstToken()
                        onEvent(.reasoning(delta))
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
                    guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
                        continue
                    }
                    // usage-only 分片：choices 为空数组、顶层携带 usage，先提取再继续。
                    if let usage = chunk.usage, let prompt = usage.resolvedPromptTokens {
                        onEvent(.usage(promptTokens: prompt))
                    }
                    guard let delta = chunk.choices.first?.delta else {
                        continue
                    }
                    if let content = delta.content, !content.isEmpty {
                        markFirstToken()
                        onEvent(.text(content))
                    }
                    // 思考增量：reasoning_content（DeepSeek 风格）/ reasoning（兼容端点）同归一通道。
                    if let reasoning = delta.resolvedReasoning, !reasoning.isEmpty {
                        markFirstToken()
                        onEvent(.reasoning(reasoning))
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
    /// `thinkingFields`：适配层注入的顶层思考字段；Chat Completions 流式额外注入
    /// `stream_options.include_usage = true` 以在末片获取 usage。
    /// `maxTokens`：输出上限；按协议映射为 `max_tokens`（Chat）/`max_output_tokens`（Responses）。
    private func encodeRequestBody(
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