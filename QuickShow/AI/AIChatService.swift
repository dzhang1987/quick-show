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
/// 各职责域方法拆分为同目录 extension 文件：
/// - `AIChatService+Config.swift`：配置持久化与 API Key 文件/Keychain。
/// - `AIChatService+Streaming.swift`：send / performStream 流式主链路。
/// - `AIChatService+Completion.swift`：complete / fetchModels 非流式补全与模型列表。
/// - `AIChatService+RequestEncoding.swift`：请求体编码、工具声明与 Responses 映射。
@MainActor
final class AIChatService {
    static let shared = AIChatService()

    private init() {}

    // MARK: 配置（非敏感，存 UserDefaults）

    /// UserDefaults 键名集合：各配置域 extension 共享，故非 private。
    enum ConfigKey {
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

    // MARK: 存储属性（跨文件 extension 共享）

    /// modelList 内存缓存（nil 表示尚未加载）。
    var _modelListCache: [AIModel]?
    /// availableModels 内存缓存（nil 表示尚未加载）。
    var _availableModelsCache: [String]?

    /// 诊断日志：文件读写异常可在此查看
    let logger = Logger(subsystem: "com.dzhang.quickshow.ai", category: "apikey")

    /// 旧版 Keychain 坐标（仅用于一次性迁移与清理遗留条目）。
    let legacyKeychainService = "com.dzhang.quickshow.ai"
    let legacyKeychainAccount = "apiKey"
}