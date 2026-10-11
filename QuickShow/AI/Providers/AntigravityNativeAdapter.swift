// AntigravityNativeAdapter: 原生 Swift 直连 Google Gemini API / Antigravity 网关端点，支持图文多模态与 SSE 流式响应。

import Foundation

enum AntigravityNativeAdapter {

    // MARK: - 请求构造

    static func buildRequest(
        baseURL: String,
        model: String,
        apiKey: String,
        messages: [ChatCompletionMessage],
        systemPrompt: String? = nil,
        stream: Bool = true
    ) throws -> URLRequest {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }

        // 清洗 model id: 剔除可能存在的 "antigravity/" 前缀
        let cleanModel = model.replacingOccurrences(of: "antigravity/", with: "")

        let streamSuffix = stream ? ":streamGenerateContent?alt=sse" : ":generateContent"
        let fullURLString = "\(base)/models/\(cleanModel)\(streamSuffix)"

        guard let url = URL(string: fullURLString) else {
            throw NSError(domain: "AntigravityNativeAdapter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 Antigravity URL: \(fullURLString)"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 鉴权方式：如果是 Bearer Token 则放 Header，否则同时设置 x-goog-api-key
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanKey.hasPrefix("Bearer ") || cleanKey.hasPrefix("ya29.") {
            request.setValue(cleanKey.hasPrefix("Bearer ") ? cleanKey : "Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(cleanKey, forHTTPHeaderField: "x-goog-api-key")
        }

        // 构造 Gemini Contents
        var contents: [[String: Any]] = []
        var systemInstructionParts: [[String: Any]] = []

        // 处理系统提示词
        if let sys = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !sys.isEmpty {
            systemInstructionParts.append(["text": sys])
        }

        for msg in messages {
            if msg.role == "system" {
                if let text = msg.content?.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    systemInstructionParts.append(["text": text])
                }
                continue
            }

            let geminiRole = (msg.role == "assistant") ? "model" : "user"
            var parts: [[String: Any]] = []

            if let content = msg.content {
                switch content {
                case .text(let txt):
                    if !txt.isEmpty { parts.append(["text": txt]) }
                case .parts(let partList):
                    for p in partList {
                        if let text = p.text, !text.isEmpty {
                            parts.append(["text": text])
                        } else if let imageURL = p.imageURL {
                            let dataURI = imageURL.url
                            let rawB64 = dataURI
                                .replacingOccurrences(of: "data:image/jpeg;base64,", with: "")
                                .replacingOccurrences(of: "data:image/png;base64,", with: "")
                            parts.append([
                                "inline_data": [
                                    "mime_type": "image/jpeg",
                                    "data": rawB64
                                ]
                            ])
                        }
                    }
                }
            }

            if !parts.isEmpty {
                contents.append([
                    "role": geminiRole,
                    "parts": parts
                ])
            }
        }

        var rootJSON: [String: Any] = ["contents": contents]
        if !systemInstructionParts.isEmpty {
            rootJSON["system_instruction"] = ["parts": systemInstructionParts]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: rootJSON)
        return request
    }

    // MARK: - SSE 片段解析

    /// 解析 Gemini streamGenerateContent 的单行 JSON 数据
    static func parseChunk(jsonString: String) -> (textDelta: String?, promptTokens: Int?) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }

        var textDelta: String? = nil
        var promptTokens: Int? = nil

        if let usage = json["usageMetadata"] as? [String: Any],
           let count = usage["promptTokenCount"] as? Int {
            promptTokens = count
        }

        if let candidates = json["candidates"] as? [[String: Any]],
           let firstCandidate = candidates.first,
           let content = firstCandidate["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            var combinedText = ""
            for part in parts {
                if let txt = part["text"] as? String {
                    combinedText += txt
                }
            }
            if !combinedText.isEmpty {
                textDelta = combinedText
            }
        }

        return (textDelta, promptTokens)
    }
}
