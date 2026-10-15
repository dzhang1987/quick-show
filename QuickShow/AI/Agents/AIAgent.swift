// AIAgent 数据模型：参考 oh-my-opencode-slim 定义特化智能体与角色分工。

import Foundation

// MARK: - 智能体实体模型
struct AIAgent: Identifiable, Codable, Equatable {
    var id: String                    // 唯一标识，如 "orchestrator", "observer", "coder", "oracle", "librarian"
    var name: String                  // 显示名称
    var iconName: String              // SF Symbol 图标，如 "sparkles", "eye.fill", "curlybraces"
    var description: String           // 职责描述
    var systemPrompt: String          // 特化 System Prompt
    var providerId: String            // 绑定的服务商 ID
    var modelId: String               // 绑定的模型 ID
    var thinkingLevel: ThinkingLevel? // 默认思考强度
    var isEnabled: Bool               // 是否启用
    var isVisualDelegate: Bool        // 是否作为全局视觉委派担当 (Observer)
    var enabledTools: [String]        // 启用的工具列表 (空表示继承全局)

    init(
        id: String = UUID().uuidString,
        name: String,
        iconName: String = "sparkles",
        description: String = "",
        systemPrompt: String = "",
        providerId: String = "alibaba",
        modelId: String = "glm-5.3",
        thinkingLevel: ThinkingLevel? = nil,
        isEnabled: Bool = true,
        isVisualDelegate: Bool = false,
        enabledTools: [String] = []
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.description = description
        self.systemPrompt = systemPrompt
        self.providerId = providerId
        self.modelId = modelId
        self.thinkingLevel = thinkingLevel
        self.isEnabled = isEnabled
        self.isVisualDelegate = isVisualDelegate
        self.enabledTools = enabledTools
    }

    /// 获取当前角色推荐的专属工具列表
    static func defaultToolNames(for roleId: String) -> [String] {
        switch roleId {
        case "orchestrator":
            return ["launch_subagents", "ask_user", "get_quickshow_state"]
        case "observer":
            return ["preview_file"]
        case "coder":
            return ["read_file", "write_file", "preview_file", "get_env", "list_env", "run_shell", "send_message"]
        case "librarian":
            return ["web_search", "fetch_url", "read_clipboard", "send_message"]
        case "oracle":
            return ["send_message"]
        case "concierge":
            return ["get_system_status", "list_running_apps", "open_app", "read_clipboard", "write_clipboard", "geocode", "search_places", "plan_route", "show_map", "my_location", "get_quickshow_state"]
        default:
            return []
        }
    }

    /// 实际生效的工具列表：若自定义了 enabledTools 则优先采用，否则回退到角色推荐默认工具
    var resolvedTools: [String] {
        if !enabledTools.isEmpty {
            return enabledTools
        }
        return Self.defaultToolNames(for: id)
    }
}

// MARK: - 默认智能体团队预设 (对齐 6 大垂类智能体矩阵)
extension AIAgent {
    /// 默认智能体全套预设列表
    static func defaultAgents(primaryProviderId: String = "alibaba") -> [AIAgent] {
        if primaryProviderId == "qoder" {
            return [
                AIAgent(
                    id: "orchestrator",
                    name: "全能助理",
                    iconName: "sparkles",
                    description: "主控助理，负责通用对话、需求拆解与多领域调度协调。",
                    systemPrompt: """
                    你是一个专业博学的 AI 全能助理（Orchestrator），崇尚从第一性原理分析问题。
                    说话做事直接了当，实事求是。遇到不清楚的边界主动调用 `ask_user` 确认。
                    面对复杂多步骤工程，使用 `launch_subagents` 并发调度专业专家（代码专家、资料检索、深度思考、系统管家、识图助理），汇总成果后输出清晰结构化的解答。
                    """,
                    providerId: "qoder",
                    modelId: "qoder/gmodel",
                    thinkingLevel: .medium,
                    isEnabled: true,
                    isVisualDelegate: false,
                    enabledTools: defaultToolNames(for: "orchestrator")
                ),
                AIAgent(
                    id: "observer",
                    name: "识图助理",
                    iconName: "eye",
                    description: "图文与多模态解析助手，专门负责图片分析、图表解析与屏幕截图特征提取。",
                    systemPrompt: """
                    你是专业的识图助手（Observer）。你的核心职责是精准理解用户提供的各类图像（界面截图、架构图、表格图、流程图或照片）。
                    请客观、详细地提取图像中的文字（OCR）、布局结构、核心要素与异常信息，以结构化 Markdown 清晰呈现。
                    """,
                    providerId: "qoder",
                    modelId: "qoder/qmodel",
                    thinkingLevel: nil,
                    isEnabled: true,
                    isVisualDelegate: true,
                    enabledTools: defaultToolNames(for: "observer")
                ),
                AIAgent(
                    id: "coder",
                    name: "代码专家",
                    iconName: "curlybraces",
                    description: "代码特化助手，专注高性能代码编写、Bug 修复与现代软件架构设计。",
                    systemPrompt: """
                    你是顶尖的软件架构与代码工程专家（Coder）。遵循极致工程规范，追求零冗余、高可读与极致性能。
                    给出代码时务必完整可靠，注释清晰，并点明关键技术设计考量。
                    """,
                    providerId: "qoder",
                    modelId: "qoder/kmodel",
                    thinkingLevel: nil,
                    isEnabled: true,
                    isVisualDelegate: false,
                    enabledTools: defaultToolNames(for: "coder")
                ),
                AIAgent(
                    id: "oracle",
                    name: "深度思考",
                    iconName: "brain.head.profile",
                    description: "高思考强度分析师，擅长数学逻辑推演、复杂系统方案决策与深度论证。",
                    systemPrompt: """
                    你是一个深思熟虑的逻辑与决策推演助手（Oracle）。在输出最终结论前，先从基本公理出发逐层推导演绎，
                    剖析方案利弊权衡（Trade-offs），给出严谨缜密的推论过程。
                    """,
                    providerId: "qoder",
                    modelId: "qoder/kmodel_latest",
                    thinkingLevel: .high,
                    isEnabled: true,
                    isVisualDelegate: false,
                    enabledTools: defaultToolNames(for: "oracle")
                ),
                AIAgent(
                    id: "librarian",
                    name: "资料检索",
                    iconName: "books.vertical",
                    description: "快速检索与资料提炼助手，擅长阅读大量信息并输出要点摘要。",
                    systemPrompt: """
                    你是高效的资料研究员（Librarian），擅长快速提取长文本、文档与背景材料中的核心要点。
                    回答言简意赅、条理分明，用最少的废话呈现最高密度的信息。
                    """,
                    providerId: "qoder",
                    modelId: "qoder/dfmodel",
                    thinkingLevel: .low,
                    isEnabled: true,
                    isVisualDelegate: false,
                    enabledTools: defaultToolNames(for: "librarian")
                ),
                AIAgent(
                    id: "concierge",
                    name: "系统管家",
                    iconName: "macbook.and.iphone",
                    description: "macOS 桌面管家与系统自动化助理，负责硬件指标监测、应用调度控制、剪贴板交互与地图导航。",
                    systemPrompt: """
                    你是贴心的 macOS 系统管家与桌面助理（Concierge）。
                    精通 macOS 系统生态，负责硬件指标监测、应用调度控制、剪贴板联动与地图通勤导航。
                    表达风格亲切得体、利落简洁，突出原生 macOS 桌面交互的流畅质感。
                    """,
                    providerId: "qoder",
                    modelId: "qoder/gmodel",
                    thinkingLevel: .low,
                    isEnabled: true,
                    isVisualDelegate: false,
                    enabledTools: defaultToolNames(for: "concierge")
                )
            ]
        }

        return [
            // 1. 全能助理 (Orchestrator)
            AIAgent(
                id: "orchestrator",
                name: "全能助理",
                iconName: "sparkles",
                description: "主控助理，负责通用对话、需求拆解与多领域调度协调。",
                systemPrompt: """
                你是一个专业博学的 AI 全能助理（Orchestrator），崇尚从第一性原理分析问题。
                说话做事直接了当，实事求是。遇到不清楚的边界主动调用 `ask_user` 确认。
                面对复杂多步骤工程，使用 `launch_subagents` 并发调度专业专家（代码专家、资料检索、深度思考、系统管家、识图助理），汇总成果后输出清晰结构化的解答。
                """,
                providerId: primaryProviderId,
                modelId: "glm-5.3",
                thinkingLevel: .medium,
                isEnabled: true,
                isVisualDelegate: false,
                enabledTools: defaultToolNames(for: "orchestrator")
            ),

            // 2. 识图助理 (Observer)
            AIAgent(
                id: "observer",
                name: "识图助理",
                iconName: "eye",
                description: "图文与多模态解析助手，专门负责图片分析、图表解析与屏幕截图特征提取。",
                systemPrompt: """
                你是专业的识图助手（Observer）。你的核心职责是精准理解用户提供的各类图像（界面截图、架构图、表格图、流程图或照片）。
                请客观、详细地提取图像中的文字（OCR）、布局结构、核心要素与异常信息，以结构化 Markdown 清晰呈现。
                """,
                providerId: primaryProviderId,
                modelId: "qwen3.8-flash",
                thinkingLevel: nil,
                isEnabled: true,
                isVisualDelegate: true,
                enabledTools: defaultToolNames(for: "observer")
            ),

            // 3. 代码特化 (Coder)
            AIAgent(
                id: "coder",
                name: "代码专家",
                iconName: "curlybraces",
                description: "代码特化助手，专注高性能代码编写、Bug 修复与现代软件架构设计。",
                systemPrompt: """
                你是顶尖的软件架构与代码工程专家（Coder）。遵循极致工程规范，追求零冗余、高可读与极致性能。
                给出代码时务必完整可靠，注释清晰，并点明关键技术设计考量。
                """,
                providerId: primaryProviderId,
                modelId: "glm-5.3",
                thinkingLevel: .high,
                isEnabled: true,
                isVisualDelegate: false,
                enabledTools: defaultToolNames(for: "coder")
            ),

            // 4. 深度思考 (Oracle)
            AIAgent(
                id: "oracle",
                name: "深度思考",
                iconName: "brain.head.profile",
                description: "高思考强度分析师，擅长数学逻辑推演、复杂系统方案决策与深度论证。",
                systemPrompt: """
                你是一个深思熟虑的逻辑与决策推演助手（Oracle）。在输出最终结论前，先从基本公理出发逐层推导演绎，
                剖析方案利弊权衡（Trade-offs），给出严谨缜密的推论过程。
                """,
                providerId: primaryProviderId,
                modelId: "kimi-k3",
                thinkingLevel: .high,
                isEnabled: true,
                isVisualDelegate: false,
                enabledTools: defaultToolNames(for: "oracle")
            ),

            // 5. 资料检索 (Librarian)
            AIAgent(
                id: "librarian",
                name: "资料检索",
                iconName: "books.vertical",
                description: "快速检索与资料提炼助手，擅长阅读大量信息并输出要点摘要。",
                systemPrompt: """
                你是高效的资料研究员（Librarian），擅长快速提取长文本、文档与背景材料中的核心要点。
                回答言简意赅、条理分明，用最少的废话呈现最高密度的信息。
                """,
                providerId: primaryProviderId,
                modelId: "deepseek-v4.1-flash",
                thinkingLevel: .low,
                isEnabled: true,
                isVisualDelegate: false,
                enabledTools: defaultToolNames(for: "librarian")
            ),

            // 6. 系统管家 (Concierge)
            AIAgent(
                id: "concierge",
                name: "系统管家",
                iconName: "macbook.and.iphone",
                description: "macOS 桌面管家与系统自动化助理，负责硬件指标监测、应用调度控制、剪贴板交互与地图导航。",
                systemPrompt: """
                你是贴心的 macOS 系统管家与桌面助理（Concierge）。
                精通 macOS 系统生态，负责硬件指标监测、应用调度控制、剪贴板联动与地图通勤导航。
                表达风格亲切得体、利落简洁，突出原生 macOS 桌面交互的流畅质感。
                """,
                providerId: primaryProviderId,
                modelId: "glm-5.3",
                thinkingLevel: .low,
                isEnabled: true,
                isVisualDelegate: false,
                enabledTools: defaultToolNames(for: "concierge")
            )
        ]
    }
}
