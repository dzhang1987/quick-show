// AI 服务商数据模型：定义多服务商（Alibaba, OpenAI, Qoder, Antigravity, Custom）与模型规格。

import Foundation

// MARK: - 服务商通信协议类型
enum AIProviderType: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "openai_compatible"
    case qoderNative = "qoder_native"
    case antigravityNative = "antigravity_native"
    case nativeBridge = "native_bridge"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容协议 (Chat / Responses)"
        case .qoderNative: return "Qoder 原生协议 (COSY 签名 + PAT)"
        case .antigravityNative: return "Antigravity 原生协议 (Gemini / OAuth)"
        case .nativeBridge: return "原生专用桥接 (本地代理端点)"
        }
    }
}

// MARK: - 服务商账号授权信息
struct ProviderAccountInfo: Codable, Equatable {
    var userId: String?
    var displayName: String
    var email: String
    var avatarURL: String?
    var authMethod: String // "browser", "auto_detect", "manual"
    var authorizedAt: Date
    var refreshToken: String?

    init(
        userId: String? = nil,
        displayName: String,
        email: String,
        avatarURL: String? = nil,
        authMethod: String,
        authorizedAt: Date,
        refreshToken: String? = nil
    ) {
        self.userId = userId
        self.displayName = displayName
        self.email = email
        self.avatarURL = avatarURL
        self.authMethod = authMethod
        self.authorizedAt = authorizedAt
        self.refreshToken = refreshToken
    }
}

// MARK: - 模型能力规格
struct AIModelSpec: Identifiable, Codable, Equatable {
    var id: String                    // model identifier, e.g. "glm-5.3", "qwen-vl-max", "gpt-4o"
    var name: String                  // 可读显示名
    var contextWindow: Int            // 上下文窗口 (tokens)，默认 524288 (512K)
    var supportsVision: Bool          // 核心标记：是否具备多模态视觉看图能力
    var supportsThinking: Bool        // 是否支持思考链 (reasoning)
    var defaultThinkingLevel: ThinkingLevel? // 默认思考档位

    init(
        id: String,
        name: String? = nil,
        contextWindow: Int = 524288,
        supportsVision: Bool = false,
        supportsThinking: Bool = false,
        defaultThinkingLevel: ThinkingLevel? = nil
    ) {
        self.id = id
        self.name = (name?.isEmpty == false) ? (name!) : id
        self.contextWindow = contextWindow > 0 ? contextWindow : 524288
        self.supportsVision = supportsVision
        self.supportsThinking = supportsThinking
        self.defaultThinkingLevel = defaultThinkingLevel
    }
}

// MARK: - 服务商实体模型
struct AIProvider: Identifiable, Codable, Equatable {
    var id: String                    // 唯一标识，如 "alibaba", "openai", "qoder", "antigravity"
    var name: String                  // 显示名称
    var type: AIProviderType          // 协议类型
    var baseURL: String               // API 根地址
    var apiProtocol: AIProtocolOption // 针对 OpenAI 兼容协议的 chat / responses 子协议
    var isEnabled: Bool               // 是否启用
    var models: [AIModelSpec]         // 该提供商下的模型池

    init(
        id: String = UUID().uuidString,
        name: String,
        type: AIProviderType = .openAICompatible,
        baseURL: String = "",
        apiProtocol: AIProtocolOption = .chat,
        isEnabled: Bool = true,
        models: [AIModelSpec] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.baseURL = baseURL
        self.apiProtocol = apiProtocol
        self.isEnabled = isEnabled
        self.models = models
    }

    /// 根据 modelId 查找模型规格
    func model(for modelId: String) -> AIModelSpec? {
        models.first { $0.id == modelId }
    }
}

// MARK: - 官方主流预设模版
extension AIProvider {
    /// 阿里云百炼 (DashScope) 官方预设
    static func alibabaPreset(baseURL: String? = nil) -> AIProvider {
        AIProvider(
            id: "alibaba",
            name: "阿里云百炼 (DashScope)",
            type: .openAICompatible,
            baseURL: baseURL ?? "https://llm-z18v28cnaqql8iex.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
            apiProtocol: .chat,
            isEnabled: true,
            models: [
                AIModelSpec(id: "glm-5.3", name: "GLM-5.3", contextWindow: 1048576, supportsVision: false, supportsThinking: true),
                AIModelSpec(id: "qwen3.8-flash", name: "Qwen 3.8 Flash (视觉)", contextWindow: 1048576, supportsVision: true, supportsThinking: false),
                AIModelSpec(id: "qwen-vl-max", name: "通义千问 VL Max (视觉旗舰)", contextWindow: 131072, supportsVision: true, supportsThinking: false),
                AIModelSpec(id: "qwen3.7-plus", name: "Qwen 3.7 Plus (视觉/文本)", contextWindow: 524288, supportsVision: true, supportsThinking: false),
                AIModelSpec(id: "kimi-k3", name: "Kimi K3 (深度思考)", contextWindow: 1048576, supportsVision: false, supportsThinking: true),
                AIModelSpec(id: "deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", contextWindow: 1048576, supportsVision: false, supportsThinking: true)
            ]
        )
    }

    /// OpenAI 官方预设
    static func openAIPreset() -> AIProvider {
        AIProvider(
            id: "openai",
            name: "OpenAI 官方",
            type: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            apiProtocol: .chat,
            isEnabled: true,
            models: [
                AIModelSpec(id: "gpt-4o", name: "GPT-4o (全模态旗舰)", contextWindow: 128000, supportsVision: true, supportsThinking: false),
                AIModelSpec(id: "gpt-4o-mini", name: "GPT-4o mini (快速轻量)", contextWindow: 128000, supportsVision: true, supportsThinking: false),
                AIModelSpec(id: "o3-mini", name: "o3-mini (深度推理)", contextWindow: 200000, supportsVision: false, supportsThinking: true),
                AIModelSpec(id: "o1", name: "o1 (全能推理)", contextWindow: 200000, supportsVision: true, supportsThinking: true)
            ]
        )
    }

    /// Qoder 国际版原生预设 (18个官方模型)
    static func qoderPreset() -> AIProvider {
        AIProvider(
            id: "qoder",
            name: "Qoder 国际版",
            type: .qoderNative,
            baseURL: "https://api3.qoder.sh",
            apiProtocol: .chat,
            isEnabled: true,
            models: [
                AIModelSpec(id: "qoder/auto", name: "Qoder Auto (智能路由)", contextWindow: 180000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "qoder/ultimate", name: "Qoder Ultimate (旗舰主力1M)", contextWindow: 1000000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "qoder/fast", name: "Qoder Fast (轻快极速)", contextWindow: 180000, supportsVision: true, supportsThinking: false),
                AIModelSpec(id: "qoder/performance", name: "Qoder Performance (高性能1M)", contextWindow: 1000000, supportsVision: true, supportsThinking: false),
                AIModelSpec(id: "qoder/efficient", name: "Qoder Efficient (经济免费层)", contextWindow: 180000, supportsVision: true, supportsThinking: false),
                AIModelSpec(id: "qoder/smodel", name: "Sonus (Qoder 多模态)", contextWindow: 180000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "qoder/cmodel", name: "Cantus (Qoder 推理专家)", contextWindow: 180000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "qoder/qmodel_38max", name: "Qwen3.8 Max (通义旗舰)", contextWindow: 600000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "qoder/qfmodel", name: "Qwen3.8 Flash (通义极速)", contextWindow: 600000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "qoder/qmodel_latest", name: "Qwen3.7 Max (通义视觉旗舰)", contextWindow: 1000000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "qoder/qmodel", name: "Qwen3.7 Plus (通义视觉全能)", contextWindow: 1000000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "qoder/kmodel_latest", name: "Kimi K3 (长文推理/架构)", contextWindow: 1000000, supportsVision: true, supportsThinking: false),
                AIModelSpec(id: "qoder/kmodel", name: "Kimi K2.8 Preview (代码专家)", contextWindow: 256000, supportsVision: true, supportsThinking: false),
                AIModelSpec(id: "qoder/gmodel", name: "GLM 5.3 (智谱旗舰编排)", contextWindow: 180000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "qoder/gfmodel", name: "GLM 5.3 Flash (智谱极速长文1M)", contextWindow: 1000000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "qoder/dmodel", name: "DeepSeek V4 Pro (深度推理1M)", contextWindow: 1000000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "qoder/dfmodel", name: "DeepSeek Flash (极速推理1M)", contextWindow: 1000000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "qoder/mmodel", name: "MiniMax M3 (海量上下文1M)", contextWindow: 1000000, supportsVision: true, supportsThinking: false)
            ]
        )
    }

    /// Antigravity 原生预设
    static func antigravityPreset() -> AIProvider {
        AIProvider(
            id: "antigravity",
            name: "Antigravity (Google 原生)",
            type: .antigravityNative,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiProtocol: .chat,
            isEnabled: true,
            models: [
                AIModelSpec(id: "gemini-3.1-pro", name: "Gemini 3.1 Pro (旗舰推理)", contextWindow: 2097152, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash (极速全能)", contextWindow: 1048576, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "gemini-3.7-flash", name: "Gemini 3.7 Flash (极速思考)", contextWindow: 1048576, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "claude-opus-4-6", name: "Claude Opus 4.6 (深度思考)", contextWindow: 200000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6 (旗舰主力)", contextWindow: 200000, supportsVision: true, supportsThinking: true),
                AIModelSpec(id: "gpt-oss-120b", name: "GPT-OSS 120B (开源大模型)", contextWindow: 131072, supportsVision: false, supportsThinking: true)
            ]
        )
    }
}
