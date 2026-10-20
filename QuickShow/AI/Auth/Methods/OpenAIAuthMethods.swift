// OpenAIAuthMethods: OpenAI 官方与通用模型授权方式实现。
// 包含：触控 ID (Touch ID) 导入本机环境变量 OPENAI_API_KEY。

import Foundation

// MARK: - 方式：本地环境探测 + 触控 ID (Touch ID) 导入

final class OpenAIBiometricAuthMethod: BiometricImportAuthMethod {
    let kind: AuthMethodKind = .biometricImport
    let providerId: String = "openai"
    let displayName: String = "触控 ID 导入 OpenAI 凭据"
    let detailDescription: String = "检测本机环境变量中的 OPENAI_API_KEY，使用触控 ID 免密导入"

    func isAvailable() async -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let key = env["OPENAI_API_KEY"], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    func detectLocalAccount() async -> LocalDetectedAccount? {
        let env = ProcessInfo.processInfo.environment
        if let key = env["OPENAI_API_KEY"], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalDetectedAccount(
                providerId: providerId,
                displayName: "本机环境变量 OpenAI Key",
                email: "OPENAI_API_KEY",
                detail: "已配置于当前终端环境变量",
                token: clean
            )
        }
        return nil
    }

    func importViaBiometrics(detected: LocalDetectedAccount) async throws -> AuthCredentials {
        let token = detected.token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw NSError(domain: "OpenAIAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "未获取到有效的 OpenAI API Key"])
        }
        let accountInfo = ProviderAccountInfo(
            userId: nil,
            displayName: detected.displayName,
            email: detected.email,
            avatarURL: nil,
            authMethod: "biometric_import",
            authorizedAt: Date(),
            refreshToken: nil
        )
        return AuthCredentials(token: token, accountInfo: accountInfo)
    }
}
