// AIAuthManager: AI 认证与账号探测全局门面协调器。
// 面向接口设计，完全基于 LLMProvider 统管的 AIAuthMethod 驱动，彻底消除硬编码与双轨制割裂。

import Foundation
import LocalAuthentication
import os

@MainActor
final class AIAuthManager: ObservableObject {
    static let shared = AIAuthManager()

    private let logger = Logger(subsystem: "com.dzhang.quickshow.ai", category: "authManager")

    enum AuthState: Equatable {
        case idle
        case authorizing(message: String)
        case success(message: String)
        case failed(error: String)
    }

    @Published var authStates: [String: AuthState] = [:]
    @Published var detectedAccounts: [String: LocalDetectedAccount] = [:]
    @Published var isDetecting: Bool = false

    /// 正在进行的外部浏览器授权任务映射 (providerId -> method)
    private var activeBrowserMethods: [String: any InteractiveBrowserAuthMethod] = [:]

    private init() {
        refreshLocalDetections()
    }

    // MARK: - 方式查询与统一调度 (面向 LLMProviderRegistry 契约)

    /// 获取特定服务商配置所支持的所有授权方式 (1 对多聚合)
    func authMethods(for provider: AIProvider) -> [any AIAuthMethod] {
        LLMProviderRegistry.shared.authMethods(for: provider)
    }

    func state(for providerId: String) -> AuthState {
        authStates[providerId] ?? .idle
    }

    func detectedAccount(for providerId: String) -> LocalDetectedAccount? {
        detectedAccounts[providerId]
    }

    // MARK: - 方式 ②：自动探测本机已登录账号 (自治委派给具体 AuthMethod)

    func refreshLocalDetections() {
        guard !isDetecting else { return }
        isDetecting = true

        Task {
            var results: [String: LocalDetectedAccount] = [:]
            let allProviders = await MainActor.run { AIProviderStore.shared.providers }

            for provider in allProviders {
                let methods = await MainActor.run { self.authMethods(for: provider) }
                for method in methods {
                    if let biometricMethod = method as? BiometricImportAuthMethod {
                        if let detected = await biometricMethod.detectLocalAccount() {
                            results[provider.id] = detected
                            break // 找到首个有效凭据即可
                        }
                    }
                }
            }

            await MainActor.run {
                self.detectedAccounts = results
                self.isDetecting = false
            }
        }
    }

    // MARK: - 触控 ID (Touch ID) / 机主身份安全授权

    /// 优先唤起 macOS 触控 ID (Touch ID) 指纹识别，若无指纹则降级系统密码。
    /// 用户验证通过返回 true；若用户点击取消或验证失败返回 false。
    private func authenticateWithBiometrics(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "取消"

        var authError: NSError?
        // 优先触控 ID 指纹识别 (Touch ID)
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) {
            return await withCheckedContinuation { continuation in
                context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                    continuation.resume(returning: success)
                }
            }
        } else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
            // 无指纹设备降级到系统锁屏密码
            return await withCheckedContinuation { continuation in
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                    continuation.resume(returning: success)
                }
            }
        } else {
            // 系统未开启任何认证机制（无密码无指纹）
            return true
        }
    }

    // MARK: - 一键触控 ID 静默导入本机账号 (自治提取)

    func importDetectedAccount(for provider: AIProvider, method: (any BiometricImportAuthMethod)? = nil) {
        guard let detected = detectedAccounts[provider.id] else { return }

        // 获取适用的 BiometricImportAuthMethod
        let targetMethod: any BiometricImportAuthMethod
        if let method {
            targetMethod = method
        } else if let found = authMethods(for: provider).compactMap({ $0 as? BiometricImportAuthMethod }).first {
            targetMethod = found
        } else {
            return
        }

        authStates[provider.id] = .authorizing(message: "请使用触控 ID 授权导入本机账号...")

        Task {
            // 1. 优先调用 Touch ID (生物识别) 授权机主身份
            let authorized = await authenticateWithBiometrics(
                reason: "使用触控 ID 允许 QuickShow 导入本机已登录的 \(provider.name) 凭据"
            )

            guard authorized else {
                await MainActor.run {
                    self.authStates[provider.id] = .failed(error: "触控 ID 授权已取消")
                }
                return
            }

            // 2. 指纹验证通过后，委派给对应 AuthMethod 自治提取凭据并安全落盘
            do {
                let creds = try await targetMethod.importViaBiometrics(detected: detected)
                await MainActor.run {
                    AIProviderStore.shared.setAPIKey(creds.token, for: provider.id)
                    AIProviderStore.shared.saveAccountInfo(creds.accountInfo, for: provider.id)
                    AIProviderStore.shared.selectedProviderId = provider.id
                    self.authStates[provider.id] = .success(message: "已通过触控 ID 成功导入：\(creds.accountInfo.displayName)")
                }
            } catch {
                await MainActor.run {
                    self.authStates[provider.id] = .failed(error: error.localizedDescription)
                }
            }
        }
    }

    func importDetectedAccount(for providerId: String) {
        if let provider = AIProviderStore.shared.provider(for: providerId) {
            importDetectedAccount(for: provider)
        }
    }

    // MARK: - 方式 ③：网页端浏览器登录授权 (自治外部授权)

    func startBrowserAuth(for provider: AIProvider, method: (any InteractiveBrowserAuthMethod)? = nil) {
        let targetMethod: any InteractiveBrowserAuthMethod
        if let method {
            targetMethod = method
        } else if let found = authMethods(for: provider).compactMap({ $0 as? InteractiveBrowserAuthMethod }).first {
            targetMethod = found
        } else {
            return
        }

        cancelAuth(for: provider.id)
        activeBrowserMethods[provider.id] = targetMethod

        Task {
            do {
                try await targetMethod.startBrowserAuthorization(
                    onStateChange: { [weak self] state in
                        Task { @MainActor in
                            self?.authStates[provider.id] = state
                        }
                    },
                    onSuccess: { [weak self] creds in
                        Task { @MainActor in
                            self?.activeBrowserMethods.removeValue(forKey: provider.id)
                            AIProviderStore.shared.setAPIKey(creds.token, for: provider.id)
                            AIProviderStore.shared.saveAccountInfo(creds.accountInfo, for: provider.id)
                            AIProviderStore.shared.selectedProviderId = provider.id
                            self?.authStates[provider.id] = .success(message: "\(provider.name) 授权成功！已绑定 \(creds.accountInfo.displayName)")
                        }
                    }
                )
            } catch {
                await MainActor.run {
                    self.activeBrowserMethods.removeValue(forKey: provider.id)
                    self.authStates[provider.id] = .failed(error: error.localizedDescription)
                }
            }
        }
    }

    func startBrowserAuth(for providerId: String) {
        if let provider = AIProviderStore.shared.provider(for: providerId) {
            startBrowserAuth(for: provider)
        }
    }

    func cancelAuth(for providerId: String) {
        activeBrowserMethods[providerId]?.cancelAuthorization()
        activeBrowserMethods.removeValue(forKey: providerId)
        authStates[providerId] = .idle
    }

    // MARK: - 退出登录与清理

    func logout(for providerId: String) {
        cancelAuth(for: providerId)
        AIProviderStore.shared.clearAPIKey(for: providerId)
        AIProviderStore.shared.clearAccountInfo(for: providerId)
        authStates[providerId] = .idle
        refreshLocalDetections()
    }
}
