// AIAgentStore: 管理多智能体团队、当前激活智能体与全局视觉委托 (Observer) 调度分配。

import Foundation
import SwiftUI

@MainActor
final class AIAgentStore: ObservableObject {
    static let shared = AIAgentStore()

    private enum Keys {
        static let agentsData = "ai.agents.v2"
        static let activeAgentId = "ai.activeAgentId.v2"
    }

    @Published var agents: [AIAgent] = [] {
        didSet {
            saveAgents()
        }
    }

    @Published var activeAgentId: String = "orchestrator" {
        didSet {
            UserDefaults.standard.set(activeAgentId, forKey: Keys.activeAgentId)
        }
    }

    private init() {
        loadAgents()
    }

    // MARK: - 查询接口

    var activeAgent: AIAgent {
        if let found = agents.first(where: { $0.id == activeAgentId && $0.isEnabled }) {
            return found
        }
        return agents.first(where: { $0.isEnabled }) ?? agents.first ?? AIAgent.defaultAgents().first!
    }

    func agent(for id: String) -> AIAgent? {
        agents.first { $0.id == id }
    }

    /// 获取全局视觉委托担当 (首选 isVisualDelegate == true，其次 id=="observer"，兜底任一支持 Vision 的 Agent)
    var visualDelegateAgent: AIAgent? {
        if let delegate = agents.first(where: { $0.isVisualDelegate && $0.isEnabled }) {
            return delegate
        }
        if let observer = agents.first(where: { $0.id == "observer" && $0.isEnabled }) {
            return observer
        }
        // 兜底：查找绑定的模型明确标记为 supportsVision 的任一已启用 Agent
        let providerStore = AIProviderStore.shared
        return agents.first { agent in
            guard agent.isEnabled else { return false }
            return providerStore.modelSpec(providerId: agent.providerId, modelId: agent.modelId)?.supportsVision == true
        }
    }

    // MARK: - 增删改

    func saveAgent(_ agent: AIAgent) {
        if let idx = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[idx] = agent
        } else {
            agents.append(agent)
        }
        // 如果设置为视觉担当，取消其他人的担当标记
        if agent.isVisualDelegate {
            for i in 0..<agents.count {
                if agents[i].id != agent.id {
                    agents[i].isVisualDelegate = false
                }
            }
        }
    }

    func deleteAgent(id: String) {
        // 至少保留一个 agent
        guard agents.count > 1 else { return }
        if activeAgentId == id {
            activeAgentId = agents.first(where: { $0.id != id })?.id ?? "orchestrator"
        }
        agents.removeAll { $0.id == id }
    }

    func setVisualDelegate(agentId: String) {
        for i in 0..<agents.count {
            agents[i].isVisualDelegate = (agents[i].id == agentId)
        }
    }

    // MARK: - 持久化与默认值

    private func saveAgents() {
        if let data = try? JSONEncoder().encode(agents) {
            UserDefaults.standard.set(data, forKey: Keys.agentsData)
        }
    }

    private func loadAgents() {
        if let data = UserDefaults.standard.data(forKey: Keys.agentsData),
           let loaded = try? JSONDecoder().decode([AIAgent].self, from: data),
           !loaded.isEmpty {
            self.agents = loaded
            self.activeAgentId = UserDefaults.standard.string(forKey: Keys.activeAgentId) ?? "orchestrator"
            return
        }

        // 默认初始化
        resetToDefaults()
    }

    func resetToDefaults() {
        let providerId = AIProviderStore.shared.selectedProviderId
        let defaults = AIAgent.defaultAgents(primaryProviderId: providerId)
        self.agents = defaults
        self.activeAgentId = "orchestrator"
        saveAgents()
    }
}
