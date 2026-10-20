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

    /// 获取当前角色推荐的专属工具列表 (委托至 AgentRoleRegistry)
    static func defaultToolNames(for roleId: String) -> [String] {
        AgentRoleRegistry.shared.profile(for: roleId)?.defaultTools ?? []
    }

    /// 实际生效的工具列表：若自定义了 enabledTools 则优先采用，否则回退到角色推荐默认工具
    var resolvedTools: [String] {
        if !enabledTools.isEmpty {
            return enabledTools
        }
        return Self.defaultToolNames(for: id)
    }
}

// MARK: - 默认智能体团队预设 (对齐 6 大垂类智能体矩阵，由 AgentRoleRegistry 单循环动态装配)
extension AIAgent {
    /// 默认智能体全套预设列表 (自适应各种服务商模型)
    static func defaultAgents(primaryProviderId: String = "alibaba") -> [AIAgent] {
        AgentRoleRegistry.shared.allProfiles().map { profile in
            AIAgent(
                id: profile.id,
                name: profile.name,
                iconName: profile.iconName,
                description: profile.description,
                systemPrompt: profile.systemPrompt,
                providerId: primaryProviderId,
                modelId: profile.recommendedModelPicker(primaryProviderId),
                thinkingLevel: profile.defaultThinkingLevel,
                isEnabled: true,
                isVisualDelegate: profile.isVisualDelegate,
                enabledTools: profile.defaultTools
            )
        }
    }
}
