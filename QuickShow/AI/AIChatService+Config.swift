// 职责来源：AIChatService.swift 的「配置（非敏感，存 UserDefaults）」「模型缓存与迁移（内部）」「API Key 文件存储（放弃 Keychain）」三个 MARK 分区。

import Foundation
import Security
import os

extension AIChatService {
    // MARK: 配置（非敏感，存 UserDefaults）

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
}