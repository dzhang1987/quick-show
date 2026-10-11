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
}

// MARK: - 默认智能体团队预设 (对齐 oh-my-opencode-slim)
extension AIAgent {
    /// 默认智能体全套预设列表
    static func defaultAgents(primaryProviderId: String = "alibaba") -> [AIAgent] {
        if primaryProviderId == "qoder" {
            return [
                AIAgent(
                    id: "orchestrator",
                    name: "编排中枢",
                    iconName: "sparkles",
                    description: "主控指挥官，负责通用对话、需求拆解与多领域调度协调。",
                    systemPrompt: "你是一个专业博学的 AI 编排助手，崇尚从第一性原理分析问题。说话做事直接了当，实事求是。遇到不清楚的边界主动确认，给出清晰结构化的解答。",
                    providerId: "qoder",
                    modelId: "qoder/gm51model",
                    thinkingLevel: .medium,
                    isEnabled: true,
                    isVisualDelegate: false
                ),
                AIAgent(
                    id: "observer",
                    name: "视觉感知",
                    iconName: "eye.fill",
                    description: "多模态视觉专家，专门负责图片分析、图表解析与屏幕截图特征提取。",
                    systemPrompt: "你是专业的视觉分析专家。你的核心职责是精准理解用户提供的各类图像（界面截图、架构图、表格图、流程图或照片）。请客观、详细地提取图像中的文字（OCR）、布局结构、核心要素与异常信息，以结构化 Markdown 清晰呈现。",
                    providerId: "qoder",
                    modelId: "qoder/qmodel",
                    thinkingLevel: nil,
                    isEnabled: true,
                    isVisualDelegate: true
                ),
                AIAgent(
                    id: "coder",
                    name: "代码专家",
                    iconName: "curlybraces",
                    description: "代码特化助手，专注高性能代码编写、Bug 修复与现代软件架构设计。",
                    systemPrompt: "你是顶尖的软件架构与代码工程专家。遵循极致工程规范，追求零冗余、高可读与极致性能。给出代码时务必完整可靠，注释清晰，并点明关键技术设计考量。",
                    providerId: "qoder",
                    modelId: "qoder/kmodel",
                    thinkingLevel: nil,
                    isEnabled: true,
                    isVisualDelegate: false
                ),
                AIAgent(
                    id: "oracle",
                    name: "深度推理",
                    iconName: "brain.head.profile",
                    description: "高思考强度分析师，擅长数学逻辑推演、复杂系统方案决策与深度论证。",
                    systemPrompt: "你是一个深思熟虑的逻辑与决策推演助手。在输出最终结论前，先从基本公理出发逐层推导演绎，剖析方案利弊权衡（Trade-offs），给出严谨缜密的推论过程。",
                    providerId: "qoder",
                    modelId: "qoder/kmodel_latest",
                    thinkingLevel: .high,
                    isEnabled: true,
                    isVisualDelegate: false
                ),
                AIAgent(
                    id: "librarian",
                    name: "知识检索",
                    iconName: "books.vertical.fill",
                    description: "快速检索与知识提炼专家，擅长阅读大量信息并输出要点摘要。",
                    systemPrompt: "你是高效的知识情报员，擅长快速提取长文本、文档与背景材料中的核心要点。回答言简意赅、条理分明，用最少的废话呈现最高密度的信息。",
                    providerId: "qoder",
                    modelId: "qoder/dfmodel",
                    thinkingLevel: .low,
                    isEnabled: true,
                    isVisualDelegate: false
                )
            ]
        }

        return [
            // 1. 编排中枢 (Orchestrator)：主力通用对话、理解意图并推进执行
            AIAgent(
                id: "orchestrator",
                name: "编排中枢",
                iconName: "sparkles",
                description: "主控指挥官，负责通用对话、需求拆解与多领域调度协调。",
                systemPrompt: """
                你是一个专业博学的 AI 编排助手，崇尚从第一性原理分析问题。
                说话做事直接了当，实事求是。遇到不清楚的边界主动确认，给出清晰结构化的解答。
                """,
                providerId: primaryProviderId,
                modelId: "glm-5.3",
                thinkingLevel: .medium,
                isEnabled: true,
                isVisualDelegate: false
            ),

            // 2. 视觉感知 (Observer)：多模态特化担当，看图、OCR、图表视觉理解
            AIAgent(
                id: "observer",
                name: "视觉感知",
                iconName: "eye.fill",
                description: "多模态视觉专家，专门负责图片分析、图表解析与屏幕截图特征提取。",
                systemPrompt: """
                你是专业的视觉分析专家。你的核心职责是精准理解用户提供的各类图像（界面截图、架构图、表格图、流程图或照片）。
                请客观、详细地提取图像中的文字（OCR）、布局结构、核心要素与异常信息，以结构化 Markdown 清晰呈现。
                """,
                providerId: primaryProviderId,
                modelId: "qwen3.8-flash",
                thinkingLevel: nil,
                isEnabled: true,
                isVisualDelegate: true // 全局多模态视觉担当
            ),

            // 3. 代码特化 (Coder)：代码编写、Debug 与重构
            AIAgent(
                id: "coder",
                name: "代码专家",
                iconName: "curlybraces",
                description: "代码特化助手，专注高性能代码编写、Bug 修复与现代软件架构设计。",
                systemPrompt: """
                你是顶尖的软件架构与代码工程专家。遵循极致工程规范，追求零冗余、高可读与极致性能。
                给出代码时务必完整可靠，注释清晰，并点明关键技术设计考量。
                """,
                providerId: primaryProviderId,
                modelId: "glm-5.3",
                thinkingLevel: .high,
                isEnabled: true,
                isVisualDelegate: false
            ),

            // 4. 深度推理 (Oracle)：架构决策、逻辑论证、复杂问题推导
            AIAgent(
                id: "oracle",
                name: "深度推理",
                iconName: "brain.head.profile",
                description: "高思考强度分析师，擅长数学逻辑推演、复杂系统方案决策与深度论证。",
                systemPrompt: """
                你是一个深思熟虑的逻辑与决策推演助手。在输出最终结论前，先从基本公理出发逐层推导演绎，
                剖析方案利弊权衡（Trade-offs），给出严谨缜密的推论过程。
                """,
                providerId: primaryProviderId,
                modelId: "kimi-k3",
                thinkingLevel: .high,
                isEnabled: true,
                isVisualDelegate: false
            ),

            // 5. 资料检索 (Librarian)：快速搜集、总结文档与知识提炼
            AIAgent(
                id: "librarian",
                name: "知识检索",
                iconName: "books.vertical.fill",
                description: "快速检索与知识提炼专家，擅长阅读大量信息并输出要点摘要。",
                systemPrompt: """
                你是高效的知识情报员，擅长快速提取长文本、文档与背景材料中的核心要点。
                回答言简意赅、条理分明，用最少的废话呈现最高密度的信息。
                """,
                providerId: primaryProviderId,
                modelId: "deepseek-v4.1-flash",
                thinkingLevel: .low,
                isEnabled: true,
                isVisualDelegate: false
            )
        ]
    }
}
