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
        for p in providers {
            if let m = p.model(for: modelId) { return m }
        }
        return nil
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
            // 兜底：若是 alibaba 且独立 key 尚未写入，尝试读取旧版全局 key
            if providerId == "alibaba" {
                return loadLegacyApiKey()
            }
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

    private func loadLegacyApiKey() -> String? {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let legacy = appSupport
            .appendingPathComponent("QuickShow", isDirectory: true)
            .appendingPathComponent("apikey")
        if let data = try? Data(contentsOf: legacy),
           let str = String(data: data, encoding: .utf8) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // 再兜底：读取 OpenCode auth.json 中的 alibaba-cn key
        return loadOpenCodeAlibabaKey()
    }

    private func loadOpenCodeAlibabaKey() -> String? {
        let home = NSHomeDirectory()
        let authPath = "\(home)/.local/share/opencode/auth.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ali = json["alibaba-cn"] as? [String: Any],
              let key = ali["key"] as? String else {
            return nil
        }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 持久化与迁移

    private func saveProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: Keys.providersData)
        }
    }

    private func loadProviders() {
        if let data = UserDefaults.standard.data(forKey: Keys.providersData),
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
            self.providers = updated
            saveProviders()
            self.selectedProviderId = UserDefaults.standard.string(forKey: Keys.selectedProviderId) ?? loaded.first?.id ?? "alibaba"
            return
        }

        // 首次加载：执行自动迁移与 OpenCode 默认值同步
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

        // 迁移/写入 Alibaba 的 API Key
        if let aliKey = loadLegacyApiKey() {
            setAPIKey(aliKey, for: "alibaba")
        }

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
