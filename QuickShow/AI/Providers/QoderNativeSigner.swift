// QoderNativeSigner: 原生 Swift 实现 Qoder PAT Token 交换、Base64 自定义重排与 COSY 请求头签名。

import Foundation
import CommonCrypto
import Security

enum QoderNativeSigner {
    static let gatewayCosyVersion = "1.0.0"
    static let openAPICosyVersion = "1.0.1"
    static let clientType = "5"
    static let dataPolicy = "disagree"
    static let loginVersion = "v2"
    static let machineOS = "x86_64_windows"
    static let machineTypeMagic = "5"

    // Qoder 固定的 RSA 2048 公钥 (PEM)
    static let rsaPublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDA8iMH5c02LilrsERw9t6Pv5Nc
    4k6Pz1EaDicBMpdpxKduSZu5OANqUq8er4GM95omAGIOPOh+Nx0spthYA2BqGz+l
    6HRkPJ7S236FZz73In/KVuLnwI8JJ2CbuJap8kvheCCZpmAWpb/cPx/3Vr/J6I17
    XcW+ML9FoCI6AOvOzwIDAQAB
    -----END PUBLIC KEY-----
    """

    private static let customAlphabet = "_doRTgHZBKcGVjlvpC,@aFSx#DPuNJme&i*MzLOEn)sUrthbf%Y^w.(kIQyXqWA!"
    private static let stdAlphabet    = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    // MARK: - 1. PAT 交换 Job Token (无签名直接交换)

    struct JobTokenExchangeResponse: Codable {
        let token: String?
        let code: Int?
        let msg: String?
        let data: JobTokenData?

        struct JobTokenData: Codable {
            let token: String?
            let refreshToken: String?
            let expiresAt: Int?

            enum CodingKeys: String, CodingKey {
                case token
                case refreshToken = "refresh_token"
                case expiresAt = "expires_at"
            }
        }

        var resolvedToken: String? {
            token ?? data?.token
        }
    }

    /// 使用 PAT 换取短期 Job Token (jt-...)，自动尝试国内与国际端点
    static func exchangeJobToken(pat: String) async throws -> String {
        var cleanPat = pat.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanPat = cleanPat.trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
        if cleanPat.lowercased().hasPrefix("bearer ") {
            cleanPat = String(cleanPat.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            cleanPat = cleanPat.trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
        }
        // 如果用户直接填的是已经换出来的 jt- 令牌，或者浏览器授权返回的 dt- (Device Token)，直接返回
        if cleanPat.hasPrefix("jt-") || cleanPat.hasPrefix("dt-") {
            return cleanPat
        }

        let endpoints = [
            "https://openapi.qoder.sh/api/v1/jobToken/exchange",
            "https://openapi.qoder.com.cn/api/v1/jobToken/exchange"
        ]

        var lastError: Error?
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("opencode-qoder", forHTTPHeaderField: "User-Agent")
            req.setValue(openAPICosyVersion, forHTTPHeaderField: "Cosy-Version")
            req.setValue(clientType, forHTTPHeaderField: "Cosy-ClientType")
            req.timeoutInterval = 8

            let body: [String: Any] = ["personal_token": cleanPat]
            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    continue
                }
                let decoded = try JSONDecoder().decode(JobTokenExchangeResponse.self, from: data)
                if let token = decoded.resolvedToken, !token.isEmpty {
                    return token
                }
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NSError(domain: "QoderNativeSigner", code: -3, userInfo: [NSLocalizedDescriptionKey: "Qoder Token 交换失败，请检查网络或 PAT 是否有效"])
    }

    // MARK: - 2. Qoder 自定义 Base64 编码与块重排

    /// Qoder 特有的请求体重排与自定义 Base64 替换编码
    static func encodeBody(_ plaintextData: Data) -> Data {
        let stdBase64 = plaintextData.base64EncodedString()
        let n = stdBase64.count
        guard n > 0 else { return Data() }
        let a = n / 3

        let stdChars = Array(stdBase64)
        // 重排: 后 a 个 + 中间 (a ..< n - a) + 前 a 个
        let reordered = Array(stdChars[(n - a)..<n]) + Array(stdChars[a..<(n - a)]) + Array(stdChars[0..<a])

        let stdMap = Array(stdAlphabet)
        let customMap = Array(customAlphabet)

        var resultChars: [Character] = []
        resultChars.reserveCapacity(n)

        for ch in reordered {
            if ch == "=" {
                resultChars.append("$")
            } else if let idx = stdMap.firstIndex(of: ch) {
                resultChars.append(customMap[idx])
            } else {
                resultChars.append(ch)
            }
        }

        return Data(String(resultChars).utf8)
    }

    // MARK: - 3. 生成 COSY 签名头

    static func buildAuthHeaders(
        bodyData: Data?,
        requestURL: URL,
        jobToken: String,
        userID: String = "qoder-user",
        name: String = "QuickShow User",
        email: String = "user@quickshow.app",
        machineID: String? = nil
    ) throws -> [String: String] {
        let aesKey = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        let aesKeyStr = String(aesKey)

        // 构造 UserInfo
        let userInfo: [String: String] = [
            "uid": userID,
            "security_oauth_token": jobToken,
            "name": name,
            "aid": "",
            "email": email
        ]
        let userInfoJSON = try JSONSerialization.data(withJSONObject: userInfo)
        let userInfoStr = String(data: userInfoJSON, encoding: .utf8) ?? "{}"

        let infoB64 = try aesEncryptCBCBase64(plaintext: userInfoStr, key: aesKeyStr)
        let cosyKey = try rsaEncryptBase64(data: Data(aesKeyStr.utf8))

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let requestId = UUID().uuidString

        let cosyPayload: [String: String] = [
            "version": "v1",
            "requestId": requestId,
            "info": infoB64,
            "cosyVersion": gatewayCosyVersion,
            "ideVersion": ""
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: cosyPayload)
        let payloadB64 = payloadData.base64EncodedString()

        var sigPath = requestURL.path.isEmpty ? "/" : requestURL.path
        if sigPath.hasPrefix("/algo") {
            sigPath = String(sigPath.dropFirst("/algo".count))
        }

        let bodyBytes = bodyData ?? Data()
        let bodyHash = md5Hex(bodyBytes)
        let bodyLen = String(bodyBytes.count)

        // 签名输入串: payloadB64 + "\n" + cosyKey + "\n" + timestamp + "\n" + bodyBytes + "\n" + sigPath
        var sigInput = Data()
        sigInput.append(Data(payloadB64.utf8))
        sigInput.append(Data("\n".utf8))
        sigInput.append(Data(cosyKey.utf8))
        sigInput.append(Data("\n".utf8))
        sigInput.append(Data(timestamp.utf8))
        sigInput.append(Data("\n".utf8))
        sigInput.append(bodyBytes)
        sigInput.append(Data("\n".utf8))
        sigInput.append(Data(sigPath.utf8))

        let sig = md5Hex(sigInput)
        let resolvedMachineID = machineID ?? getStableMachineID()

        return [
            "Authorization": "Bearer COSY.\(payloadB64).\(sig)",
            "Cosy-Key": cosyKey,
            "Cosy-User": userID,
            "Cosy-Date": timestamp,
            "Cosy-Version": gatewayCosyVersion,
            "Cosy-Machineid": resolvedMachineID,
            "Cosy-Machinetoken": resolvedMachineID,
            "Cosy-Machinetype": machineTypeMagic,
            "Cosy-Machineos": machineOS,
            "Cosy-Clienttype": clientType,
            "Cosy-Clientip": "127.0.0.1",
            "Cosy-Bodyhash": bodyHash,
            "Cosy-Bodylength": bodyLen,
            "Cosy-Sigpath": sigPath,
            "Cosy-Data-Policy": dataPolicy,
            "Cosy-Organization-Id": "",
            "Cosy-Organization-Tags": "",
            "Login-Version": loginVersion,
            "X-Request-Id": requestId
        ]
    }

    // MARK: - 辅助加密工具

    private static func md5Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { ptr in
            CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func aesEncryptCBCBase64(plaintext: String, key: String) throws -> String {
        guard let keyData = key.data(using: .utf8), let plainData = plaintext.data(using: .utf8) else {
            throw NSError(domain: "QoderNativeSigner", code: -4, userInfo: nil)
        }

        var numBytesEncrypted: size_t = 0
        let bufferSize = plainData.count + kCCBlockSizeAES128
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        let status = keyData.withUnsafeBytes { keyBytes in
            plainData.withUnsafeBytes { dataBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES128),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, kCCKeySizeAES128,
                    keyBytes.baseAddress, // IV 同 key
                    dataBytes.baseAddress, plainData.count,
                    &buffer, bufferSize,
                    &numBytesEncrypted
                )
            }
        }

        guard status == kCCSuccess else {
            throw NSError(domain: "QoderNativeSigner", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "AES 加密失败"])
        }

        let encryptedData = Data(buffer.prefix(numBytesEncrypted))
        return encryptedData.base64EncodedString()
    }

    private static func rsaEncryptBase64(data: Data) throws -> String {
        let cleanKey = rsaPublicKeyPEM
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let keyData = Data(base64Encoded: cleanKey) else {
            throw NSError(domain: "QoderNativeSigner", code: -5, userInfo: [NSLocalizedDescriptionKey: "RSA 公钥 Base64 解码失败"])
        }

        var error: Unmanaged<CFError>?
        let keyDict: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1024
        ]

        guard let secKey = SecKeyCreateWithData(keyData as CFData, keyDict as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? NSError(domain: "QoderNativeSigner", code: -6, userInfo: nil)
        }

        guard let encrypted = SecKeyCreateEncryptedData(secKey, .rsaEncryptionPKCS1, data as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() ?? NSError(domain: "QoderNativeSigner", code: -7, userInfo: nil)
        }

        return encrypted.base64EncodedString()
    }

    static func getStableMachineID() -> String {
        let key = "quickshow.qoder.machine_id"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }
        let newID = UUID().uuidString.lowercased()
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }
}
