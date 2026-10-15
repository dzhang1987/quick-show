// AIAuthMethod: 授权方式抽象与协议族。
// 遵循面向接口原则，将授权方式抽象为一等公民，支持单一供应商 1 对多聚合多套授权方案。

import Foundation

/// 认证成功提取的标准凭据载体
struct AuthCredentials: Sendable {
    let token: String
    let accountInfo: ProviderAccountInfo
}

/// 本地环境或已登录账号探测结果
struct LocalDetectedAccount: Equatable, Sendable, Identifiable {
    var id: String { providerId }
    var providerId: String
    var displayName: String
    var email: String
    var detail: String
    var token: String?
    var userId: String? = nil
    var avatarURL: String? = nil
}

/// 授权方式类别
enum AuthMethodKind: String, Sendable, CaseIterable {
    case apiKey           // 手工输入 API Key / PAT 个人访问令牌
    case biometricImport  // 本地已登录凭据探测 + 触控 ID (Touch ID) 免密导入
    case browserOAuth     // 浏览器网页端外部授权 (OAuth PKCE 或 Device Flow)
    case environment      // 系统终端环境变量自动装载
}

/// 统一授权方式基础契约 (面向接口)
protocol AIAuthMethod: Sendable {
    /// 方式分类标识
    var kind: AuthMethodKind { get }

    /// 适用供应商的唯一标识 (如 "alibaba", "antigravity", "qoder", "openai")
    var providerId: String { get }

    /// 人类可读名称 (如 "API Key 密钥", "触控 ID 免密导入", "🌐 浏览器登录授权")
    var displayName: String { get }

    /// 辅助提示与详细文案
    var detailDescription: String { get }

    /// 当前方式在本机当前环境下是否可用 (例如是否探测到本地凭据、系统硬件是否支持生物识别)
    func isAvailable() async -> Bool
}

/// 本机环境探测与生物识别 (Touch ID) 导入协议
protocol BiometricImportAuthMethod: AIAuthMethod {
    /// 静默探测本机已安装环境或已登录凭据 (完全静默、绝不调用弹窗接口)
    func detectLocalAccount() async -> LocalDetectedAccount?

    /// 在机主通过 Touch ID / 锁屏密码验证后，提取并标准化凭据
    func importViaBiometrics(detected: LocalDetectedAccount) async throws -> AuthCredentials
}

/// 交互式浏览器外部授权协议 (OAuth 2.0 PKCE / Device Flow)
protocol InteractiveBrowserAuthMethod: AIAuthMethod {
    /// 启动浏览器授权流程
    func startBrowserAuthorization(
        onStateChange: @escaping @Sendable (AIAuthManager.AuthState) -> Void,
        onSuccess: @escaping @Sendable (AuthCredentials) -> Void
    ) async throws

    /// 取消授权并释放网络/轮询资源
    func cancelAuthorization()
}

/// 手工录入 API Key 协议
protocol StandardAPIKeyAuthMethod: AIAuthMethod {
    /// 校验 Key 格式是否合法
    func validate(key: String) -> Bool

    /// 输入框占位提示文案
    var placeholder: String { get }

    /// 辅助提示与页脚说明
    var footerText: String { get }
}

/// 通用开箱即用 API Key 授权方式实现
struct DefaultAPIKeyAuthMethod: StandardAPIKeyAuthMethod {
    let kind: AuthMethodKind = .apiKey
    let providerId: String
    let displayName: String
    let detailDescription: String
    let placeholder: String
    let footerText: String

    init(
        providerId: String,
        displayName: String = "API Key 密钥",
        detailDescription: String = "手工配置供应商 API Key",
        placeholder: String = "输入 API Key",
        footerText: String = "密钥仅保存在本机受保护目录，绝不上云"
    ) {
        self.providerId = providerId
        self.displayName = displayName
        self.detailDescription = detailDescription
        self.placeholder = placeholder
        self.footerText = footerText
    }

    func isAvailable() async -> Bool { true }

    func validate(key: String) -> Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
