// AIAuthManager: 原生统一管理 Qoder 与 Antigravity (Google) 的三模认证流程：
// ① 手动 API Key / PAT
// ② 自动探测本机账号 (Qoder CLI / Antigravity / gcloud)
// ③ 网页端浏览器登录授权 (Qoder Device Flow / Google OAuth 2.0 PKCE)

import Foundation
import Network
import AppKit
import CommonCrypto
import Security
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

    struct LocalDetectedAccount: Equatable {
        var providerId: String
        var displayName: String
        var email: String
        var detail: String
        var token: String?
        var userId: String? = nil
        var avatarURL: String? = nil
    }

    @Published var authStates: [String: AuthState] = [:]
    @Published var detectedAccounts: [String: LocalDetectedAccount] = [:]
    @Published var isDetecting: Bool = false

    private var qoderPollTask: Task<Void, Never>?
    private var loopbackServer: OAuthLoopbackServer?

    private init() {
        refreshLocalDetections()
    }

    // MARK: - 状态查询

    func state(for providerId: String) -> AuthState {
        authStates[providerId] ?? .idle
    }

    func detectedAccount(for providerId: String) -> LocalDetectedAccount? {
        detectedAccounts[providerId]
    }

    // MARK: - 方式 ②：自动探测本机已登录账号

    func refreshLocalDetections() {
        isDetecting = true
        Task.detached(priority: .utility) { [weak self] in
            let qoderAcc = await self?.detectQoderAccount()
            let antiAcc = await self?.detectAntigravityAccount()

            await MainActor.run {
                if let qoderAcc {
                    self?.detectedAccounts["qoder"] = qoderAcc
                } else {
                    self?.detectedAccounts.removeValue(forKey: "qoder")
                }

                if let antiAcc {
                    self?.detectedAccounts["antigravity"] = antiAcc
                } else {
                    self?.detectedAccounts.removeValue(forKey: "antigravity")
                }
                self?.isDetecting = false
            }
        }
    }

    private nonisolated func detectQoderAccount() async -> LocalDetectedAccount? {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()

        // 1. 查找 qodercli 可执行文件路径
        let candidates = [
            "/usr/local/bin/qodercli",
            "\(home)/.local/bin/qodercli",
            "\(home)/.qoder/bin/qodercli",
            "\(home)/.qoder/entry/qoder"
        ]

        var cliPath: String?
        for path in candidates {
            if fileManager.fileExists(atPath: path) && fileManager.isExecutableFile(atPath: path) {
                cliPath = path
                break
            }
        }

        if let executable = cliPath {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["status", "-o", "json"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let loggedIn = json["logged_in"] as? Bool, loggedIn {
                    let name = json["username"] as? String ?? "Qoder 已登录用户"
                    let email = json["email"] as? String ?? ""
                    let userType = json["user_type"] as? String ?? "personal"
                    let avatar = json["avatar_url"] as? String ?? ""
                    var parsedUid: String? = nil
                    if let range = avatar.range(of: "/users/") {
                        let sub = avatar[range.upperBound...]
                        if let endRange = sub.range(of: "/") {
                            let uid = String(sub[..<endRange.lowerBound])
                            if !uid.isEmpty { parsedUid = uid }
                        }
                    }
                    return LocalDetectedAccount(
                        providerId: "qoder",
                        displayName: name,
                        email: email,
                        detail: "Qoder CLI (\(userType))",
                        token: nil,
                        userId: parsedUid,
                        avatarURL: avatar.isEmpty ? nil : avatar
                    )
                }
            } catch {
                // ignore
            }
        }

        // 2. 检查本机 Qoder 客户端全局状态 (~/.qoder/.qoder-app-status.json)
        let appStatusPath = "\(home)/.qoder/.qoder-app-status.json"
        if fileManager.fileExists(atPath: appStatusPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: appStatusPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let loggedIn = json["logged_in"] as? Bool, loggedIn {
            let name = json["name"] as? String ?? "Qoder 已登录用户"
            let email = json["email"] as? String ?? ""
            let avatar = json["avatar_url"] as? String ?? ""
            var parsedUid: String? = nil
            if let range = avatar.range(of: "/users/") {
                let sub = avatar[range.upperBound...]
                if let endRange = sub.range(of: "/") {
                    let uid = String(sub[..<endRange.lowerBound])
                    if !uid.isEmpty { parsedUid = uid }
                }
            }
            return LocalDetectedAccount(
                providerId: "qoder",
                displayName: name,
                email: email,
                detail: "Qoder 客户端环境",
                token: nil,
                userId: parsedUid,
                avatarURL: avatar.isEmpty ? nil : avatar
            )
        }

        // 3. 兜底检查环境变量中的 PAT
        if let envPat = ProcessInfo.processInfo.environment["QODER_PERSONAL_ACCESS_TOKEN"],
           !envPat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LocalDetectedAccount(
                providerId: "qoder",
                displayName: "环境变量 Qoder Token",
                email: "QODER_PERSONAL_ACCESS_TOKEN",
                detail: "从环境变量直接检测",
                token: envPat.trimmingCharacters(in: .whitespacesAndNewlines),
                userId: nil,
                avatarURL: nil
            )
        }

        return nil
    }

    private nonisolated func detectAntigravityAccount() async -> LocalDetectedAccount? {
        // 1. 检查环境变量中的 Gemini / Google API Key
        let env = ProcessInfo.processInfo.environment
        if let key = env["GEMINI_API_KEY"] ?? env["GOOGLE_API_KEY"],
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalDetectedAccount(
                providerId: "antigravity",
                displayName: "本机环境变量 Gemini Key",
                email: "GEMINI_API_KEY",
                detail: "已配置于当前终端环境变量",
                token: clean
            )
        }

        // 2. 检查 gcloud 已登录账号
        let home = NSHomeDirectory()
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
                            providerId: "antigravity",
                            displayName: "Google Cloud 账号",
                            email: acc,
                            detail: "gcloud CLI 环境",
                            token: nil
                        )
                    }
                }
            }
        }

        // 3. 检查本机 Antigravity 安装与已登录状态
        let antiAppSupport = "\(home)/Library/Application Support/Antigravity"
        let storagePath = "\(antiAppSupport)/app_storage.json"
        if FileManager.default.fileExists(atPath: storagePath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: storagePath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let lastUser = json["jetski.onboarding.lastLoginUsername"] as? String ?? ""
            return LocalDetectedAccount(
                providerId: "antigravity",
                displayName: lastUser.isEmpty ? "Antigravity 本地环境" : lastUser,
                email: lastUser.isEmpty ? "Google 账号" : lastUser,
                detail: "已登录 Antigravity 客户端",
                token: nil
            )
        }

        return nil
    }

    // MARK: - 一键导入本机账号

    func importDetectedAccount(for providerId: String) {
        guard let detected = detectedAccounts[providerId] else { return }

        if let token = detected.token, !token.isEmpty {
            // 直接保存有效凭据
            AIProviderStore.shared.setAPIKey(token, for: providerId)
            let acc = ProviderAccountInfo(
                userId: detected.userId,
                displayName: detected.displayName,
                email: detected.email,
                avatarURL: detected.avatarURL,
                authMethod: "auto_detect",
                authorizedAt: Date(),
                refreshToken: nil
            )
            AIProviderStore.shared.saveAccountInfo(acc, for: providerId)
            AIProviderStore.shared.selectedProviderId = providerId
            if providerId == "qoder" {
                let alibabaKey = AIProviderStore.shared.apiKey(for: "alibaba")
                if alibabaKey == nil || alibabaKey?.isEmpty == true {
                    AIAgentStore.shared.resetToDefaults()
                }
            }
            authStates[providerId] = .success(message: "已导入本机凭据：\(detected.displayName)")
        } else {
            // 本机环境检测到已登录，提示并唤起官方网页一键确认
            authStates[providerId] = .authorizing(message: "正在唤起官方授权页确认绑定本机账号 (\(detected.displayName))...")
            startBrowserAuth(for: providerId)
        }
    }

    // MARK: - 方式 ③：网页端浏览器登录授权

    func startBrowserAuth(for providerId: String) {
        switch providerId {
        case "qoder":
            startQoderDeviceAuth()
        case "antigravity":
            startGoogleOAuthPKCE()
        default:
            break
        }
    }

    func cancelAuth(for providerId: String) {
        if providerId == "qoder" {
            qoderPollTask?.cancel()
            qoderPollTask = nil
        } else if providerId == "antigravity" {
            loopbackServer?.stop()
            loopbackServer = nil
        }
        authStates[providerId] = .idle
    }

    func logout(for providerId: String) {
        cancelAuth(for: providerId)
        AIProviderStore.shared.clearAPIKey(for: providerId)
        AIProviderStore.shared.clearAccountInfo(for: providerId)
        authStates[providerId] = .idle
        refreshLocalDetections()
    }

    // MARK: - Qoder Device Flow 实现

    private func startQoderDeviceAuth() {
        qoderPollTask?.cancel()
        qoderPollTask = nil

        if case .authorizing = authStates["qoder"] {
            // 保留由 importDetectedAccount 设置的具体文案
        } else {
            authStates["qoder"] = .authorizing(message: "正在唤起浏览器，请在 Qoder 授权页面点击确认...")
        }

        let verifier = Self.generateRandomBase64URL(byteCount: 43)
        let challenge = Self.sha256Base64URL(from: verifier)
        let nonce = UUID().uuidString
        let machineId = QoderNativeSigner.getStableMachineID()
        let clientId = "e883ade2-e6e3-4d6d-adf7-f92ceff5fdcb" // Qoder 官方客户端 ID

        // 官方可用 Web 域名为 qoder.com，避免 qoder.sh 根域名 DNS 无法解析
        var comp = URLComponents(string: "https://qoder.com/device/selectAccounts")!
        comp.queryItems = [
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "challenge_method", value: "S256"),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "machine_id", value: machineId),
            URLQueryItem(name: "client_id", value: clientId)
        ]

        guard let authURL = comp.url else {
            authStates["qoder"] = .failed(error: "无法构造 Qoder 授权地址")
            return
        }

        // 打开浏览器
        NSWorkspace.shared.open(authURL)

        // 双端点并发轮询：国内端点 openapi.qoder.com.cn 与 国际端点 openapi.qoder.sh
        qoderPollTask = Task { [weak self] in
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
                        await self?.finishQoderAuth(token: token)
                        return
                    }
                }
            }

            if !Task.isCancelled {
                await MainActor.run {
                    self?.authStates["qoder"] = .failed(error: "授权等待超时，请重新发起")
                }
            }
        }
    }

    private func finishQoderAuth(token: String) async {
        AIProviderStore.shared.setAPIKey(token, for: "qoder")
        var userId: String? = detectedAccounts["qoder"]?.userId
        var name = detectedAccounts["qoder"]?.displayName ?? "Qoder 用户"
        var email = detectedAccounts["qoder"]?.email ?? ""
        var avatarURL: String? = detectedAccounts["qoder"]?.avatarURL

        // 解析用户信息 (优先使用已探测到的本地用户信息，其次尝试拉取 userinfo，双端点校验 HTTP 200)
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

        // 若仍未获取到 UID，从 avatarURL 路径中提取
        if userId == nil, let av = avatarURL, let range = av.range(of: "/users/") {
            let sub = av[range.upperBound...]
            if let endRange = sub.range(of: "/") {
                let uid = String(sub[..<endRange.lowerBound])
                if !uid.isEmpty { userId = uid }
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
        AIProviderStore.shared.saveAccountInfo(acc, for: "qoder")
        AIProviderStore.shared.selectedProviderId = "qoder"
        let alibabaKey = AIProviderStore.shared.apiKey(for: "alibaba")
        if alibabaKey == nil || alibabaKey?.isEmpty == true {
            AIAgentStore.shared.resetToDefaults()
        }
        authStates["qoder"] = .success(message: "Qoder 授权成功！已绑定 \(name)")
    }

    // MARK: - Google OAuth 2.0 PKCE 实现

    private func startGoogleOAuthPKCE() {
        cancelAuth(for: "antigravity")
        authStates["antigravity"] = .authorizing(message: "正在唤起浏览器，请在 Google 登录页面完成授权...")

        let verifier = Self.generateRandomBase64URL(byteCount: 64)
        let challenge = Self.sha256Base64URL(from: verifier)
        let clientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"

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
                    Task { @MainActor in
                        AIAuthManager.shared.authStates["antigravity"] = .failed(error: "无法构造 Google OAuth 授权链接")
                    }
                    return
                }

                NSWorkspace.shared.open(url)
            },
            onCodeReceived: { [weak self] code, port in
                Task {
                    await self?.exchangeGoogleCode(code: code, verifier: verifier, port: port, clientId: clientId)
                }
            },
            onError: { [weak self] err in
                Task { @MainActor in
                    self?.authStates["antigravity"] = .failed(error: "本地回调监听失败: \(err.localizedDescription)")
                }
            }
        )
    }

    private func exchangeGoogleCode(code: String, verifier: String, port: UInt16, clientId: String) async {
        let redirectURI = "http://127.0.0.1:\(port)/oauth2callback"
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { return }

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
            await MainActor.run {
                self.authStates["antigravity"] = .failed(error: "兑换 Google 访问凭据失败")
            }
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

        AIProviderStore.shared.setAPIKey(accessToken, for: "antigravity")

        let accountInfo = ProviderAccountInfo(
            userId: userId,
            displayName: displayName,
            email: email,
            avatarURL: avatarURL,
            authMethod: "browser",
            authorizedAt: Date(),
            refreshToken: refreshToken
        )
        AIProviderStore.shared.saveAccountInfo(accountInfo, for: "antigravity")

        await MainActor.run {
            self.authStates["antigravity"] = .success(message: "Google 授权成功！已绑定 \(displayName)")
        }
    }

    // MARK: - 辅助加密工具

    static func generateRandomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256Base64URL(from string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - 原生轻量 OAuth 本地回环服务器 (基于 Network.framework)

final class OAuthLoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private var connection: NWConnection?
    private var timeoutItem: DispatchWorkItem?

    func start(
        onPortBound: @escaping @Sendable (UInt16) -> Void,
        onCodeReceived: @escaping @Sendable (String, UInt16) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: .any)
            self.listener = listener

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        DispatchQueue.main.async {
                            onPortBound(port)
                        }
                    }
                case .failed(let err):
                    DispatchQueue.main.async {
                        onError(err)
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn, onCodeReceived: onCodeReceived)
            }

            listener.start(queue: .global(qos: .userInitiated))

            let timeout = DispatchWorkItem { [weak self] in
                self?.stop()
            }
            self.timeoutItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: timeout)
        } catch {
            onError(error)
        }
    }

    private func handleConnection(
        _ conn: NWConnection,
        onCodeReceived: @escaping @Sendable (String, UInt16) -> Void
    ) {
        self.connection = conn
        conn.start(queue: .global(qos: .userInitiated))

        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let reqStr = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }

            var code: String?
            if let firstLine = reqStr.components(separatedBy: "\r\n").first,
               let pathRange = firstLine.range(of: " /") {
                let rest = firstLine[pathRange.upperBound...]
                if let endRange = rest.range(of: " ") {
                    let requestPath = "/" + rest[..<endRange.lowerBound]
                    if let urlComp = URLComponents(string: String(requestPath)) {
                        code = urlComp.queryItems?.first(where: { $0.name == "code" })?.value
                    }
                }
            }

            let html = """
            <!DOCTYPE html>
            <html>
            <head>
              <meta charset="utf-8">
              <title>QuickShow 授权成功</title>
              <style>
                body {
                  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                  display: flex;
                  align-items: center;
                  justify-content: center;
                  height: 90vh;
                  margin: 0;
                  background: #0f1117;
                  color: #ffffff;
                }
                .box {
                  text-align: center;
                  background: #1a1e2b;
                  padding: 48px 40px;
                  border-radius: 20px;
                  border: 1px solid rgba(255,255,255,0.1);
                  box-shadow: 0 20px 40px rgba(0,0,0,0.5);
                  max-width: 400px;
                }
                .icon { font-size: 52px; margin-bottom: 16px; }
                h1 { margin: 0 0 12px; font-size: 22px; font-weight: 600; color: #10b981; }
                p { margin: 0; font-size: 14px; color: #94a3b8; line-height: 1.6; }
              </style>
            </head>
            <body>
              <div class="box">
                <div class="icon">✨</div>
                <h1>QuickShow 授权成功</h1>
                <p>您的账号已成功连接至 QuickShow。<br>您可以关闭此浏览器标签页并返回应用继续使用。</p>
              </div>
            </body>
            </html>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
            let respData = Data(response.utf8)

            conn.send(content: respData, completion: .contentProcessed({ [weak self] _ in
                conn.cancel()
                if let code = code, let port = self?.listener?.port?.rawValue {
                    self?.stop()
                    DispatchQueue.main.async {
                        onCodeReceived(code, port)
                    }
                }
            }))
        }
    }

    func stop() {
        timeoutItem?.cancel()
        timeoutItem = nil
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
    }
}
