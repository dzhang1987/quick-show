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

    // MARK: - 结构化持久化 (agents.json 单一真源，脱离 UserDefaults)

    private var agentsFileURL: URL? {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("QuickShow", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("agents.json")
    }

    private func saveAgents() {
        guard let url = agentsFileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(agents) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadAgents() {
        var rawData: Data? = nil
        var needsMigrationFromUserDefaults = false

        if let fileURL = agentsFileURL,
           FileManager.default.fileExists(atPath: fileURL.path),
           let fileData = try? Data(contentsOf: fileURL) {
            rawData = fileData
        } else if let udData = UserDefaults.standard.data(forKey: Keys.agentsData) {
            rawData = udData
            needsMigrationFromUserDefaults = true
        }

        if let data = rawData,
           let loaded = try? JSONDecoder().decode([AIAgent].self, from: data),
           !loaded.isEmpty {
            var updated = loaded
            var didMigrate = false
            for i in 0..<updated.count {
                if updated[i].modelId == "qoder/gm51model" {
                    updated[i].modelId = "qoder/gmodel"
                    didMigrate = true
                } else if updated[i].modelId == "qoder/qmodel_preview" {
                    updated[i].modelId = "qoder/qmodel_38max"
                    didMigrate = true
                } else if updated[i].modelId == "qoder/lite" {
                    updated[i].modelId = "qoder/efficient"
                    didMigrate = true
                }
                // 存量智能体易懂化重命名迁移
                if updated[i].id == "orchestrator" && (updated[i].name == "编排中枢" || updated[i].name.isEmpty) {
                    updated[i].name = "全能助理"
                    didMigrate = true
                }
                if updated[i].id == "observer" && (updated[i].name == "视觉感知" || updated[i].name == "视觉专家" || updated[i].name.isEmpty) {
                    updated[i].name = "识图助理"
                    updated[i].iconName = "eye"
                    didMigrate = true
                }
                if updated[i].id == "oracle" && (updated[i].name == "深度推理" || updated[i].name.isEmpty) {
                    updated[i].name = "深度思考"
                    didMigrate = true
                }
                if updated[i].id == "librarian" && (updated[i].name == "知识检索" || updated[i].name.isEmpty) {
                    updated[i].name = "资料检索"
                    updated[i].iconName = "books.vertical"
                    didMigrate = true
                }
            }
            // 自动补齐存量中缺失的官方默认智能体（如 concierge 系统管家）
            let providerId = UserDefaults.standard.string(forKey: "ai.selectedProviderId.v2") ?? "qoder"
            let defaults = AIAgent.defaultAgents(primaryProviderId: providerId)
            let existingIds = Set(updated.map { $0.id })
            for defAgent in defaults {
                if !existingIds.contains(defAgent.id) {
                    updated.append(defAgent)
                    didMigrate = true
                }
            }
            self.agents = updated
            saveAgents()
            if needsMigrationFromUserDefaults {
                UserDefaults.standard.removeObject(forKey: Keys.agentsData)
            }
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
