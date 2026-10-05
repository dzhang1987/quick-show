import Foundation
import os
import Security
import CoreFoundation

// MARK: - 联网工具配置

/// web_search 的 Tavily Key 存取（文件存储，敏感信息不落 UserDefaults）+ 环境变量兜底
enum WebToolsConfig {
    /// 诊断日志：文件读写异常可在此查看
    private static let logger = Logger(subsystem: "com.dzhang.quickshow.ai", category: "tavily-apikey")

    /// 旧版 Keychain 坐标（仅用于一次性迁移与清理遗留条目）。
    private static let legacyKeychainService = "com.dzhang.quickshow.ai"
    private static let legacyKeychainAccount = "tavilyApiKey"

    /// Tavily Key 落盘文件：`~/Library/Application Support/QuickShow/tavily_apikey`（纯文本单行）。
    /// 放弃 Keychain 的原因：本地开发频繁重编译导致签名变化，Keychain 条目 ACL 每次读取都弹密码授权。
    private static var apiKeyFileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("QuickShow", isDirectory: true)
            .appendingPathComponent("tavily_apikey")
    }

    /// 读取 Tavily Key（对外兼容旧属性名）：文件 → 旧 Keychain 一次性迁移 → 环境变量兜底。
    static var tavilyAPIKey: String? { loadAPIKey() }

    /// 读取 Tavily Key。文件不存在时尝试从旧 Keychain 条目搬家；任何异常静默返回 nil，不阻塞主流程。
    static func loadAPIKey() -> String? {
        if let url = apiKeyFileURL, FileManager.default.fileExists(atPath: url.path) {
            // 读取前顺手把过宽权限收紧到 0600。
            tightenPermissionsIfNeeded(at: url)
            if let data = try? Data(contentsOf: url),
               let key = String(data: data, encoding: .utf8) {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        } else if let migrated = migrateLegacyKeychainKeyIfNeeded() {
            // 文件尚不存在：从旧 Keychain 搬家，成功后直接返回。
            return migrated
        }

        // 环境变量兜底：仅内存注入，绝不落盘。
        if let envKey = environmentValue("QUICKSHOW_TAVILY_API_KEY") { return envKey }
        return nil
    }

    /// 保存 Tavily Key：原子写文件并设 0600 权限。任何错误静默忽略。
    /// 空字符串表示清除密钥（删除文件），并顺手清理遗留 Keychain 条目。
    static func setTavilyAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearAPIKey()
            return
        }
        guard let url = apiKeyFileURL, let data = trimmed.data(using: .utf8) else { return }

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
            logger.warning("Tavily API Key 写入失败：\(error.localizedDescription)")
        }

        // 顺手清理遗留钥匙串条目（失败静默忽略，不影响文件写入结果）。
        SecItemDelete(legacyKeychainQuery() as CFDictionary)
    }

    /// 清除 Tavily Key：删文件，并尽力删除旧 Keychain 遗留条目（错误忽略）。
    private static func clearAPIKey() {
        if let url = apiKeyFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        SecItemDelete(legacyKeychainQuery() as CFDictionary)
    }

    /// 读取环境变量兜底值：缺失或空白返回 nil。
    private static func environmentValue(_ key: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 把文件权限收紧为 0600（仅当存在 group/other 权限位时）。
    private static func tightenPermissionsIfNeeded(at url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return
        }
        if permissions.intValue & 0o077 != 0 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// 一次性 Keychain 迁移：把旧版本存在 Keychain 的 Tavily Key 搬到文件并清理旧条目。
    /// 该逻辑仅在密钥文件尚不存在时触发，成功搬家后旧条目即被删除，故为一次性语义；
    /// 读取旧条目可能弹最后一次钥匙串授权属预期；用户拒绝或任何错误一律静默放弃，绝不阻塞。
    private static func migrateLegacyKeychainKeyIfNeeded() -> String? {
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
        setTavilyAPIKey(trimmed)
        SecItemDelete(legacyKeychainQuery() as CFDictionary)
        return trimmed
    }

    /// 旧版 Keychain 条目的查询字典（迁移与清理共用）。
    private static func legacyKeychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: legacyKeychainAccount
        ]
    }
}
