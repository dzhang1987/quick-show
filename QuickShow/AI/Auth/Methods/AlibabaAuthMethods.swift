// AlibabaAuthMethods: 阿里云百炼 (DashScope) 授权方式实现。
// 包含：触控 ID (Touch ID) 导入本地环境变量 / 存量凭据。

import Foundation

// MARK: - 方式：本地环境探测 + 触控 ID (Touch ID) 导入

final class AlibabaBiometricAuthMethod: BiometricImportAuthMethod {
    let kind: AuthMethodKind = .biometricImport
    let providerId: String = "alibaba"
    let displayName: String = "触控 ID 导入 DashScope 凭据"
    let detailDescription: String = "检测本机环境变量中的 DASHSCOPE_API_KEY 或存量配置，使用触控 ID 免密导入"

    func isAvailable() async -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let key = env["DASHSCOPE_API_KEY"], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return hasLegacyApiKey()
    }

    func detectLocalAccount() async -> LocalDetectedAccount? {
        let env = ProcessInfo.processInfo.environment
        if let key = env["DASHSCOPE_API_KEY"], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalDetectedAccount(
                providerId: providerId,
                displayName: "本机环境变量 DashScope Key",
                email: "DASHSCOPE_API_KEY",
                detail: "已配置于当前终端环境变量",
                token: clean
            )
        }

        // 存量旧版 apikey 文件平滑迁移
        if let legacyKey = readLegacyApiKey() {
            return LocalDetectedAccount(
                providerId: providerId,
                displayName: "存量配置已迁移账号",
                email: "本地旧版配置",
                detail: "检测到存量 apikey 文件",
                token: legacyKey
            )
        }

        return nil
    }

    func importViaBiometrics(detected: LocalDetectedAccount) async throws -> AuthCredentials {
        let token = detected.token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw NSError(domain: "AlibabaAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "未获取到有效的 DashScope API Key"])
        }

        // 如果存在旧版文件，在成功导入后清理旧文件
        cleanupLegacyApiKeyIfNeeded()

        let accountInfo = ProviderAccountInfo(
            userId: detected.userId,
            displayName: detected.displayName,
            email: detected.email,
            avatarURL: nil,
            authMethod: "biometric_import",
            authorizedAt: Date(),
            refreshToken: nil
        )
        return AuthCredentials(token: token, accountInfo: accountInfo)
    }

    // MARK: - 存量旧版文件辅助

    private func legacyApiKeyURL() -> URL? {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport
            .appendingPathComponent("QuickShow", isDirectory: true)
            .appendingPathComponent("apikey")
    }

    private func hasLegacyApiKey() -> Bool {
        guard let url = legacyApiKeyURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func readLegacyApiKey() -> String? {
        guard let url = legacyApiKeyURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cleanupLegacyApiKeyIfNeeded() {
        guard let url = legacyApiKeyURL(), FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
