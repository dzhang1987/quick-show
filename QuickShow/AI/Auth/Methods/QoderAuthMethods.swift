// QoderAuthMethods: 阿里通义灵码 (Qoder) 支持的授权方式实现。
// 包含：触控 ID (Touch ID) 免密导入方式、Qoder Device Flow 浏览器外部授权方式。

import Foundation
import AppKit

// MARK: - 方式 ①：本机已登录凭据探测 + 触控 ID (Touch ID) 导入

final class QoderBiometricAuthMethod: BiometricImportAuthMethod {
    let kind: AuthMethodKind = .biometricImport
    let providerId: String = "qoder"
    let displayName: String = "触控 ID 导入 Qoder 账号"
    let detailDescription: String = "自动检测本机已登录的通义灵码 / Qoder 客户端，使用触控 ID 免密安全导入"

    func isAvailable() async -> Bool {
        let home = NSHomeDirectory()
        let appStatusPath = "\(home)/.qoder/.qoder-app-status.json"
        let hasEnv = ProcessInfo.processInfo.environment["QODER_PERSONAL_ACCESS_TOKEN"] != nil
        return FileManager.default.fileExists(atPath: appStatusPath) || hasEnv
    }

    func detectLocalAccount() async -> LocalDetectedAccount? {
        let home = NSHomeDirectory()

        // 1. 检查环境变量
        if let envPat = ProcessInfo.processInfo.environment["QODER_PERSONAL_ACCESS_TOKEN"],
           !envPat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LocalDetectedAccount(
                providerId: providerId,
                displayName: "环境变量 Qoder Token",
                email: "QODER_PERSONAL_ACCESS_TOKEN",
                detail: "已配置于当前终端环境变量",
                token: envPat.trimmingCharacters(in: .whitespacesAndNewlines),
                userId: nil,
                avatarURL: nil
            )
        }

        // 2. 检查 ~/.qoder/.qoder-app-status.json
        let appStatusPath = "\(home)/.qoder/.qoder-app-status.json"
        if FileManager.default.fileExists(atPath: appStatusPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: appStatusPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let email = json["username"] as? String ?? json["email"] as? String ?? ""
            let avatar = json["avatar_url"] as? String ?? ""
            var userId: String? = nil
            if let range = avatar.range(of: "/users/") {
                let sub = avatar[range.upperBound...]
                if let endRange = sub.range(of: "/") {
                    let extracted = String(sub[..<endRange.lowerBound])
                    if !extracted.isEmpty { userId = extracted }
                }
            }
            if !email.isEmpty || !avatar.isEmpty {
                return LocalDetectedAccount(
                    providerId: providerId,
                    displayName: email.isEmpty ? "Qoder 本机账号" : "Qoder (\(email))",
                    email: email.isEmpty ? "已登录用户" : email,
                    detail: "已登录 Qoder 客户端",
                    token: nil,
                    userId: userId,
                    avatarURL: avatar.isEmpty ? nil : avatar
                )
            }
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

        // 从环境变量或本地配置静默提取
        let envPat = ProcessInfo.processInfo.environment["QODER_PERSONAL_ACCESS_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pat = envPat, !pat.isEmpty {
            let accountInfo = ProviderAccountInfo(
                userId: detected.userId,
                displayName: detected.displayName,
                email: detected.email,
                avatarURL: detected.avatarURL,
                authMethod: "biometric_import",
                authorizedAt: Date(),
                refreshToken: nil
            )
            return AuthCredentials(token: pat, accountInfo: accountInfo)
        }

        throw NSError(domain: "QoderAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "未能在本机提取到免密 Token，建议手动填入 API Key 或使用下方「浏览器登录授权」"])
    }
}

// MARK: - 方式 ②：Qoder Device Flow 浏览器外部授权

final class QoderDeviceFlowBrowserAuthMethod: InteractiveBrowserAuthMethod {
    let kind: AuthMethodKind = .browserOAuth
    let providerId: String = "qoder"
    let displayName: String = "🌐 浏览器登录授权"
    let detailDescription: String = "唤起系统默认浏览器，前往 Qoder 官方授权页面完成登录"

    private var pollTask: Task<Void, Never>?

    func isAvailable() async -> Bool { true }

    func startBrowserAuthorization(
        onStateChange: @escaping @Sendable (AIAuthManager.AuthState) -> Void,
        onSuccess: @escaping @Sendable (AuthCredentials) -> Void
    ) async throws {
        cancelAuthorization()
        onStateChange(.authorizing(message: "正在唤起浏览器，请在 Qoder 授权页面点击确认..."))

        let verifier = OAuthCrypto.generateRandomBase64URL(byteCount: 43)
        let challenge = OAuthCrypto.sha256Base64URL(from: verifier)
        let nonce = UUID().uuidString
        let machineId = QoderNativeSigner.getStableMachineID()
        let clientId = "e883ade2-e6e3-4d6d-adf7-f92ceff5fdcb"

        var comp = URLComponents(string: "https://qoder.com/device/selectAccounts")!
        comp.queryItems = [
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "challenge_method", value: "S256"),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "machine_id", value: machineId),
            URLQueryItem(name: "client_id", value: clientId)
        ]

        guard let authURL = comp.url else {
            onStateChange(.failed(error: "无法构造 Qoder 授权地址"))
            return
        }

        NSWorkspace.shared.open(authURL)

        pollTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(300)
            let pollEndpoints = [
                "https://openapi.qoder.com.cn/api/v1/deviceToken/poll",
                "https://openapi.qoder.sh/api/v1/deviceToken/poll"
            ]

            while !Task.isCancelled && Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }

                for baseURL in pollEndpoints {
                    guard let pollURL = URL(string: "\(baseURL)?nonce=\(nonce)&verifier=\(verifier)&challenge_method=S256") else { continue }
                    var req = URLRequest(url: pollURL)
                    req.httpMethod = "GET"
                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                    req.setValue("opencode-qoder", forHTTPHeaderField: "User-Agent")
                    req.timeoutInterval = 4

                    guard let (data, response) = try? await URLSession.shared.data(for: req),
                          let http = response as? HTTPURLResponse else {
                        continue
                    }

                    if http.statusCode == 200,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let token = json["token"] as? String, !token.isEmpty {
                        await self?.finishDeviceAuth(token: token, onSuccess: onSuccess)
                        return
                    }
                }
            }

            if !Task.isCancelled {
                onStateChange(.failed(error: "授权等待超时，请重新发起"))
            }
        }
    }

    private func finishDeviceAuth(
        token: String,
        onSuccess: @escaping @Sendable (AuthCredentials) -> Void
    ) async {
        var userId: String? = nil
        var name = "Qoder 用户"
        var email = ""
        var avatarURL: String? = nil

        if let jt = try? await QoderNativeSigner.exchangeJobToken(pat: token) {
            let userinfoEndpoints = [
                "https://openapi.qoder.sh/api/v1/userinfo",
                "https://openapi.qoder.com.cn/api/v1/userinfo"
            ]
            for endpoint in userinfoEndpoints {
                guard let url = URL(string: endpoint) else { continue }
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue("Bearer \(jt)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                req.setValue("opencode-qoder", forHTTPHeaderField: "User-Agent")
                req.setValue(QoderNativeSigner.openAPICosyVersion, forHTTPHeaderField: "Cosy-Version")
                req.setValue(QoderNativeSigner.clientType, forHTTPHeaderField: "Cosy-ClientType")
                req.timeoutInterval = 6
                guard let (data, response) = try? await URLSession.shared.data(for: req),
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                let dataObj = json["data"] as? [String: Any]
                let uid = json["id"] as? String ?? json["userId"] as? String ?? dataObj?["id"] as? String
                if let uid, !uid.isEmpty { userId = uid }

                let n = json["name"] as? String ?? json["username"] as? String ?? dataObj?["name"] as? String
                if let n, !n.isEmpty { name = n }

                let e = json["email"] as? String ?? dataObj?["email"] as? String
                if let e, !e.isEmpty { email = e }

                let a = json["avatar"] as? String ?? json["avatar_url"] as? String ?? dataObj?["avatar"] as? String
                if let a, !a.isEmpty { avatarURL = a }
                break
            }
        }

        let acc = ProviderAccountInfo(
            userId: userId,
            displayName: name,
            email: email,
            avatarURL: avatarURL,
            authMethod: "browser",
            authorizedAt: Date(),
            refreshToken: nil
        )
        let creds = AuthCredentials(token: token, accountInfo: acc)
        onSuccess(creds)
    }

    func cancelAuthorization() {
        pollTask?.cancel()
        pollTask = nil
    }
}
