// AntigravityAuthMethods: Google Antigravity (Gemini) 支持的多种授权方式实现。
// 包含：触控 ID (Touch ID) 免密导入方式、Google OAuth 2.0 PKCE 浏览器外部授权方式。

import Foundation
import AppKit

// MARK: - 方式 ①：本机已登录凭据探测 + 触控 ID (Touch ID) 导入

final class AntigravityBiometricAuthMethod: BiometricImportAuthMethod {
    let kind: AuthMethodKind = .biometricImport
    let providerId: String = "antigravity"
    let displayName: String = "触控 ID 导入本机账号"
    let detailDescription: String = "自动检测本机已登录的 Antigravity / Gemini 客户端，使用触控 ID 免密安全导入"

    func isAvailable() async -> Bool {
        let home = NSHomeDirectory()
        let tokenPath = "\(home)/.gemini/jetski-standalone-oauth-token"
        let appStorage = "\(home)/Library/Application Support/Antigravity/app_storage.json"
        return FileManager.default.fileExists(atPath: tokenPath) || FileManager.default.fileExists(atPath: appStorage)
    }

    func detectLocalAccount() async -> LocalDetectedAccount? {
        let home = NSHomeDirectory()

        // 1. 静默读取本地独立凭据文件 (~/.gemini/jetski-standalone-oauth-token)，彻底避免触发钥匙串密码弹窗
        let jetskiTokenPath = "\(home)/.gemini/jetski-standalone-oauth-token"
        if FileManager.default.fileExists(atPath: jetskiTokenPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: jetskiTokenPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let tokenObj = json["token"] as? [String: Any] ?? [:]
            let accessToken = tokenObj["access_token"] as? String ?? ""
            let idToken = json["id_token"] as? String ?? ""

            var email = ""
            if !idToken.isEmpty, let parsed = OAuthCrypto.parseEmailFromJWT(idToken), !parsed.isEmpty {
                email = parsed
            } else {
                let googleAccountsPath = "\(home)/.gemini/google_accounts.json"
                if let accData = try? Data(contentsOf: URL(fileURLWithPath: googleAccountsPath)),
                   let accJson = try? JSONSerialization.jsonObject(with: accData) as? [String: Any] {
                    if let old = accJson["old"] as? [String], let first = old.first {
                        email = first
                    } else if let active = accJson["active"] as? String {
                        email = active
                    }
                }
            }

            if !accessToken.isEmpty || !email.isEmpty {
                let display = email.isEmpty ? "Antigravity 已登录账号" : "Antigravity (\(email))"
                return LocalDetectedAccount(
                    providerId: providerId,
                    displayName: display,
                    email: email.isEmpty ? "Google 账号" : email,
                    detail: "已登录 Antigravity 客户端",
                    token: accessToken.isEmpty ? nil : accessToken,
                    userId: nil,
                    avatarURL: nil
                )
            }
        }

        // 2. 检查环境变量中的 Gemini / Google API Key
        let env = ProcessInfo.processInfo.environment
        if let key = env["GEMINI_API_KEY"] ?? env["GOOGLE_API_KEY"],
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalDetectedAccount(
                providerId: providerId,
                displayName: "本机环境变量 Gemini Key",
                email: "GEMINI_API_KEY",
                detail: "已配置于当前终端环境变量",
                token: clean
            )
        }

        // 3. 检查 gcloud 已登录账号
        let gcloudCandidates = ["/usr/local/bin/gcloud", "\(home)/google-cloud-sdk/bin/gcloud", "/opt/homebrew/bin/gcloud"]
        for gpath in gcloudCandidates {
            if FileManager.default.isExecutableFile(atPath: gpath) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: gpath)
                proc.arguments = ["config", "get-value", "account"]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = Pipe()
                if let _ = try? proc.run() {
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let acc = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !acc.isEmpty && acc.contains("@") {
                        return LocalDetectedAccount(
                            providerId: providerId,
                            displayName: "Google Cloud 账号",
                            email: acc,
                            detail: "gcloud CLI 环境",
                            token: nil
                        )
                    }
                }
            }
        }

        // 4. 检查本机 Antigravity 安装与已登录状态
        let antiAppSupport = "\(home)/Library/Application Support/Antigravity"
        let storagePath = "\(antiAppSupport)/app_storage.json"
        if FileManager.default.fileExists(atPath: storagePath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: storagePath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let lastUser = json["jetski.onboarding.lastLoginUsername"] as? String ?? ""
            return LocalDetectedAccount(
                providerId: providerId,
                displayName: lastUser.isEmpty ? "Antigravity 本地环境" : lastUser,
                email: lastUser.isEmpty ? "Google 账号" : lastUser,
                detail: "已登录 Antigravity 客户端",
                token: nil
            )
        }

        return nil
    }

    func importViaBiometrics(detected: LocalDetectedAccount) async throws -> AuthCredentials {
        if let directToken = detected.token, !directToken.isEmpty {
            let accountInfo = ProviderAccountInfo(
                userId: detected.userId,
                displayName: detected.displayName,
                email: detected.email,
                avatarURL: detected.avatarURL,
                authMethod: "biometric_import",
                authorizedAt: Date(),
                refreshToken: nil
            )
            return AuthCredentials(token: directToken, accountInfo: accountInfo)
        }

        // 从本地独立凭据文件静默提取
        let home = NSHomeDirectory()
        let tokenPath = "\(home)/.gemini/jetski-standalone-oauth-token"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: tokenPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokenObj = json["token"] as? [String: Any],
              let accessToken = tokenObj["access_token"] as? String, !accessToken.isEmpty else {
            throw NSError(domain: "AntigravityAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "未能在本机凭据文件中提取到有效的 Token"])
        }

        let refreshToken = tokenObj["refresh_token"] as? String
        var email = ""

        if let idToken = json["id_token"] as? String,
           let parsed = OAuthCrypto.parseEmailFromJWT(idToken), !parsed.isEmpty {
            email = parsed
        } else {
            let googleAccountsPath = "\(home)/.gemini/google_accounts.json"
            if let accData = try? Data(contentsOf: URL(fileURLWithPath: googleAccountsPath)),
               let accJson = try? JSONSerialization.jsonObject(with: accData) as? [String: Any] {
                if let old = accJson["old"] as? [String], let first = old.first {
                    email = first
                } else if let active = accJson["active"] as? String {
                    email = active
                }
            }
        }

        let displayName = email.isEmpty ? detected.displayName : "Antigravity (\(email))"
        let accountInfo = ProviderAccountInfo(
            userId: detected.userId,
            displayName: displayName,
            email: email.isEmpty ? detected.email : email,
            avatarURL: detected.avatarURL,
            authMethod: "biometric_import",
            authorizedAt: Date(),
            refreshToken: refreshToken
        )
        return AuthCredentials(token: accessToken, accountInfo: accountInfo)
    }
}

// MARK: - 方式 ②：Google OAuth 2.0 PKCE 浏览器外部授权

final class AntigravityGooglePKCEMethod: InteractiveBrowserAuthMethod {
    let kind: AuthMethodKind = .browserOAuth
    let providerId: String = "antigravity"
    let displayName: String = "🌐 浏览器登录授权"
    let detailDescription: String = "唤起系统默认浏览器，前往 Google 官方授权页面完成登录"

    private var loopbackServer: OAuthLoopbackServer?

    func isAvailable() async -> Bool { true }

    func startBrowserAuthorization(
        onStateChange: @escaping @Sendable (AIAuthManager.AuthState) -> Void,
        onSuccess: @escaping @Sendable (AuthCredentials) -> Void
    ) async throws {
        cancelAuthorization()
        onStateChange(.authorizing(message: "正在唤起浏览器，请在 Google 登录页面完成授权..."))

        let verifier = OAuthCrypto.generateRandomBase64URL(byteCount: 64)
        let challenge = OAuthCrypto.sha256Base64URL(from: verifier)
        let clientId = AntigravityCloudCodeAdapter.oauthClientId

        let server = OAuthLoopbackServer()
        self.loopbackServer = server

        server.start(
            onPortBound: { port in
                let redirectURI = "http://127.0.0.1:\(port)/oauth2callback"
                var comp = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                comp.queryItems = [
                    URLQueryItem(name: "client_id", value: clientId),
                    URLQueryItem(name: "redirect_uri", value: redirectURI),
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "scope", value: "openid email profile https://www.googleapis.com/auth/cloud-platform"),
                    URLQueryItem(name: "code_challenge", value: challenge),
                    URLQueryItem(name: "code_challenge_method", value: "S256"),
                    URLQueryItem(name: "access_type", value: "offline")
                ]

                guard let url = comp.url else {
                    onStateChange(.failed(error: "无法构造 Google OAuth 授权链接"))
                    return
                }

                NSWorkspace.shared.open(url)
            },
            onCodeReceived: { [weak self] code, port in
                Task {
                    await self?.exchangeGoogleCode(
                        code: code,
                        verifier: verifier,
                        port: port,
                        clientId: clientId,
                        onStateChange: onStateChange,
                        onSuccess: onSuccess
                    )
                }
            },
            onError: { err in
                onStateChange(.failed(error: "本地回调监听失败: \(err.localizedDescription)"))
            }
        )
    }

    private func exchangeGoogleCode(
        code: String,
        verifier: String,
        port: UInt16,
        clientId: String,
        onStateChange: @escaping @Sendable (AIAuthManager.AuthState) -> Void,
        onSuccess: @escaping @Sendable (AuthCredentials) -> Void
    ) async {
        let redirectURI = "http://127.0.0.1:\(port)/oauth2callback"
        guard let url = URL(string: AntigravityCloudCodeAdapter.oauthTokenEndpoint) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "client_id": clientId,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        let bodyString = bodyParams.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        req.httpBody = bodyString.data(using: .utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            onStateChange(.failed(error: "兑换 Google 访问凭据失败"))
            return
        }

        let refreshToken = json["refresh_token"] as? String
        var userId: String?
        var displayName = "Google 用户"
        var email = ""
        var avatarURL: String?

        if let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo") {
            var userReq = URLRequest(url: userInfoURL)
            userReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            if let (userData, _) = try? await URLSession.shared.data(for: userReq),
               let userJSON = try? JSONSerialization.jsonObject(with: userData) as? [String: Any] {
                if let sub = userJSON["sub"] as? String { userId = sub }
                if let n = userJSON["name"] as? String { displayName = n }
                if let e = userJSON["email"] as? String { email = e }
                if let p = userJSON["picture"] as? String { avatarURL = p }
            }
        }

        let accountInfo = ProviderAccountInfo(
            userId: userId,
            displayName: displayName,
            email: email,
            avatarURL: avatarURL,
            authMethod: "browser",
            authorizedAt: Date(),
            refreshToken: refreshToken
        )
        let creds = AuthCredentials(token: accessToken, accountInfo: accountInfo)
        onSuccess(creds)
    }

    func cancelAuthorization() {
        loopbackServer?.stop()
        loopbackServer = nil
    }
}
