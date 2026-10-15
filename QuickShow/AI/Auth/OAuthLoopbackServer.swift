// OAuthLoopbackServer: 原生轻量 OAuth 本地回环服务器 (基于 Network.framework)。
// 用于 OAuth 2.0 PKCE 浏览器回调监听，无需外部网络依赖。

import Foundation
import Network
import CommonCrypto
import Security

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

enum OAuthCrypto {
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

    static func parseEmailFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }
}
