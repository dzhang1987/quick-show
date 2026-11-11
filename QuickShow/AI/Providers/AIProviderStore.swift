// AIProviderStore: 管理所有 AI 服务商配置与按 Provider 隔离的安全 API Key 存储。

import Foundation
import os
import SwiftUI

@MainActor
final class AIProviderStore: ObservableObject {
    static let shared = AIProviderStore()

    private enum Keys {
        static let providersData = "ai.providers.v2"
        static let selectedProviderId = "ai.selectedProviderId.v2"
    }

    private let logger = Logger(subsystem: "com.dzhang.quickshow.ai", category: "providerStore")

    @Published var providers: [AIProvider] = [] {
        didSet {
            saveProviders()
        }
    }

    @Published var selectedProviderId: String = "alibaba" {
        didSet {
            UserDefaults.standard.set(selectedProviderId, forKey: Keys.selectedProviderId)
        }
    }

    private init() {
        loadProviders()
    }

    // MARK: - 查询接口

    var selectedProvider: AIProvider? {
        providers.first { $0.id == selectedProviderId } ?? providers.first
    }

    func provider(for id: String) -> AIProvider? {
        providers.first { $0.id == id }
    }

    func modelSpec(providerId: String, modelId: String) -> AIModelSpec? {
        provider(for: providerId)?.model(for: modelId)
    }

    func modelSpec(for modelId: String) -> AIModelSpec? {
        resolveProvider(forModelId: modelId)?.model(for: modelId)
    }

    /// 解析模型归属服务商：模型身份 = (providerId, modelId) 二元组，绝不能只按模型 id 猜。
    ///
    /// 为何必须收敛成单一入口：不同服务商完全可能提供同名 model id（例如百炼主账号与
    /// Token Plan 都挂了 `deepseek-v4.1-flash-1017`），按 id 裸扫「第一个持有者」会把
    /// 二元组压成一维，静默路由到配置数组里排前面的服务商——请求打到错的端点与错的 Key，
    /// 勾选态、上下文窗口、视觉与思考能力判定也会一并错位。
    ///
    /// 优先级：显式绑定的服务商（仍持有该模型）→ 智能体绑定的服务商（仍持有）→
    /// 首个持有该模型的服务商（旧数据无绑定时的兼容回退）→ 显式绑定的服务商（模型被移出模型池时的容错）→
    /// 协议前缀兜底（Qoder / Gemini 原生）→ 全局选中服务商。
    func resolveProvider(
        forModelId modelId: String,
        providerId: String? = nil,
        agentProviderId: String? = nil
    ) -> AIProvider? {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let explicitId = providerId?.trimmedNonEmpty
        let agentOwnerId = agentProviderId?.trimmedNonEmpty

        // 1. 显式绑定：该服务商仍持有此模型，直接采信（唯一可信的用户意图）
        if let explicitId, let pinned = provider(for: explicitId), pinned.model(for: trimmed) != nil {
            return pinned
        }
        // 2. 智能体绑定：服务商默认模型归属，同样只在持有该模型时采信
        if let agentOwnerId, let owner = provider(for: agentOwnerId), owner.model(for: trimmed) != nil {
            return owner
        }
        // 3. 按持有者推断：多持有者时沿用配置顺序首个（仅旧数据无绑定时才会走到这里）
        if let firstOwner = providers.first(where: { $0.model(for: trimmed) != nil }) {
            return firstOwner
        }
        // 4. 模型已被移出模型池：仍回到显式绑定的服务商，避免静默换端点换 Key
        if let explicitId, let pinned = provider(for: explicitId) {
            return pinned
        }
        // 5. 协议前缀兜底：服务商列表里可能尚未登记，但原生协议有固定归属
        if trimmed.hasPrefix("qoder/") { return provider(for: "qoder") }
        if trimmed.hasPrefix("gemini-") || trimmed.hasPrefix("antigravity/") { return provider(for: "antigravity") }
        // 6. 全局选中服务商
        return selectedProvider
    }

    /// 解析模型规格（窗口 / 视觉 / 思考能力都挂在具体服务商的条目上，必须按绑定取）。
    func resolvedModelSpec(
        forModelId modelId: String,
        providerId: String? = nil,
        agentProviderId: String? = nil
    ) -> AIModelSpec? {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return resolveProvider(forModelId: trimmed, providerId: providerId, agentProviderId: agentProviderId)?
            .model(for: trimmed)
    }

    // MARK: - 增删改

    func saveProvider(_ provider: AIProvider) {
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[idx] = provider
        } else {
            providers.append(provider)
        }
    }

    func deleteProvider(id: String) {
        if selectedProviderId == id {
            selectedProviderId = providers.first(where: { $0.id != id })?.id ?? ""
        }
        providers.removeAll { $0.id == id }
        clearAPIKey(for: id)
    }

    // MARK: - API Key 安全文件存取 (按 Provider 隔离)

    private var keysDirectoryURL: URL? {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport
            .appendingPathComponent("QuickShow", isDirectory: true)
            .appendingPathComponent("keys", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func keyFileURL(for providerId: String) -> URL? {
        keysDirectoryURL?.appendingPathComponent("\(providerId).key")
    }

    func apiKey(for providerId: String) -> String? {
        guard let url = keyFileURL(for: providerId),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        tightenPermissionsIfNeeded(at: url)
        if let data = try? Data(contentsOf: url),
           let str = String(data: data, encoding: .utf8) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    func setAPIKey(_ key: String, for providerId: String) {
        guard let url = keyFileURL(for: providerId) else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clearAPIKey(for: providerId)
            return
        }
        do {
            try trimmed.write(to: url, atomically: true, encoding: .utf8)
            tightenPermissionsIfNeeded(at: url)
        } catch {
            logger.error("写入 Provider API Key 失败 [\(providerId)]: \(error.localizedDescription)")
        }
    }

    func clearAPIKey(for providerId: String) {
        guard let url = keyFileURL(for: providerId),
              FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        clearAccountInfo(for: providerId)
    }

    // MARK: - 账号信息存储 (ProviderAccountInfo)

    private func accountFileURL(for providerId: String) -> URL? {
        keysDirectoryURL?.appendingPathComponent("\(providerId).account.json")
    }

    func accountInfo(for providerId: String) -> ProviderAccountInfo? {
        guard let url = accountFileURL(for: providerId),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder().decode(ProviderAccountInfo.self, from: data) else {
            return nil
        }
        return info
    }

    func saveAccountInfo(_ info: ProviderAccountInfo, for providerId: String) {
        guard let url = accountFileURL(for: providerId) else { return }
        if let data = try? JSONEncoder().encode(info) {
            try? data.write(to: url, options: .atomic)
            tightenPermissionsIfNeeded(at: url)
        }
    }

    func clearAccountInfo(for providerId: String) {
        guard let url = accountFileURL(for: providerId),
              FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func tightenPermissionsIfNeeded(at url: URL) {
        let path = url.path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let posix = attrs[.posixPermissions] as? NSNumber,
           posix.intValue != 0o600 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    // MARK: - 结构化持久化 (providers.json 单一真源，脱离 UserDefaults)

    private var providersFileURL: URL? {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("QuickShow", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("providers.json")
    }

    private func saveProviders() {
        guard let url = providersFileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(providers) {
            try? data.write(to: url, options: .atomic)
            tightenPermissionsIfNeeded(at: url)
        }
    }

    private func loadProviders() {
        var rawData: Data? = nil
        var needsMigrationFromUserDefaults = false

        if let fileURL = providersFileURL,
           FileManager.default.fileExists(atPath: fileURL.path),
           let fileData = try? Data(contentsOf: fileURL) {
            rawData = fileData
        } else if let udData = UserDefaults.standard.data(forKey: Keys.providersData) {
            rawData = udData
            needsMigrationFromUserDefaults = true
        }

        if let data = rawData,
           let loaded = try? JSONDecoder().decode([AIProvider].self, from: data),
           !loaded.isEmpty {
            var updated = loaded
            // 确保 antigravity 原生预设模型收敛为纯净正交模型
            if let idx = updated.firstIndex(where: { $0.id == "antigravity" }) {
                let preset = AIProvider.antigravityPreset()
                let hasLegacyEffortSuffixes = updated[idx].models.contains {
                    $0.id.hasSuffix("-high") || $0.id.hasSuffix("-medium") || $0.id.hasSuffix("-low") || $0.id.hasSuffix("-thinking")
                }
                if hasLegacyEffortSuffixes || updated[idx].models.isEmpty {
                    updated[idx].models = preset.models
                } else {
                    var existingIds = Set(updated[idx].models.map { $0.id })
                    for m in preset.models {
                        if !existingIds.contains(m.id) {
                            updated[idx].models.append(m)
                            existingIds.insert(m.id)
                        }
                    }
                }
            }

            // 确保 qoder 原生预设模型对齐最新 18 个官方模型并清理已下线模型
            if let idx = updated.firstIndex(where: { $0.id == "qoder" }) {
                let preset = AIProvider.qoderPreset()
                let hasLegacyRetiredModels = updated[idx].models.contains {
                    $0.id == "qoder/lite" || $0.id == "qoder/gm51model" || $0.id == "qoder/qmodel_preview"
                }
                if hasLegacyRetiredModels || updated[idx].models.count < preset.models.count || updated[idx].models.isEmpty {
                    updated[idx].models = preset.models
                } else {
                    var existingIds = Set(updated[idx].models.map { $0.id })
                    for m in preset.models {
                        if !existingIds.contains(m.id) {
                            updated[idx].models.append(m)
                            existingIds.insert(m.id)
                        }
                    }
                }
            }
            self.providers = updated
            saveProviders()
            if needsMigrationFromUserDefaults {
                UserDefaults.standard.removeObject(forKey: Keys.providersData)
            }
            self.selectedProviderId = UserDefaults.standard.string(forKey: Keys.selectedProviderId) ?? loaded.first?.id ?? "alibaba"
            return
        }

        // 首次加载：执行自动迁移与初始化默认值
        migrateAndSeedDefaults()
    }

    private func migrateAndSeedDefaults() {
        var seeded: [AIProvider] = []

        // 1. 尝试从已存配置或 OpenCode 读取 Alibaba DashScope
        let legacyBaseURL = UserDefaults.standard.string(forKey: "ai.baseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultAliBaseURL = (legacyBaseURL?.isEmpty == false) ? legacyBaseURL! : "https://llm-z18v28cnaqql8iex.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"

        var alibaba = AIProvider.alibabaPreset(baseURL: defaultAliBaseURL)

        // 如果旧版已有 modelList，将其合并至 alibaba 模型池
        if let legacyData = UserDefaults.standard.data(forKey: "ai.modelList"),
           let legacyList = try? JSONDecoder().decode([AIModel].self, from: legacyData),
           !legacyList.isEmpty {
            var existingIds = Set(alibaba.models.map { $0.id })
            for item in legacyList {
                if !existingIds.contains(item.modelId) {
                    let isVision = item.modelId.contains("vl") || item.modelId.contains("flash")
                    alibaba.models.append(AIModelSpec(
                        id: item.modelId,
                        name: item.name,
                        contextWindow: item.contextWindow ?? 524288,
                        supportsVision: isVision,
                        supportsThinking: item.modelId.contains("glm") || item.modelId.contains("k3") || item.modelId.contains("r1")
                    ))
                    existingIds.insert(item.modelId)
                }
            }
        }
        seeded.append(alibaba)

        // 2. 预设 OpenAI
        seeded.append(AIProvider.openAIPreset())

        // 3. 预设 Qoder
        seeded.append(AIProvider.qoderPreset())

        // 4. 预设 Antigravity
        seeded.append(AIProvider.antigravityPreset())

        self.providers = seeded
        self.selectedProviderId = "alibaba"
        saveProviders()
    }
}

// MARK: - 空串归一

private extension String {
    /// 裁剪空白后的自身；全空视为「未绑定」（nil）。
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
