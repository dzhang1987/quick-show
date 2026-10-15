// GeminiProvider: Google Gemini / Antigravity 原生协议 Provider 实现。
// 支持 Gemini 官方直连 API，提供多模态图文 payload 组装与 SSE 响应解析。

import Foundation
import os

final class GeminiProvider: LLMProvider, @unchecked Sendable {
    let providerType: AIProviderType = .antigravityNative
    private static let logger = Logger(subsystem: "cn.chiproad.QuickShow", category: "GeminiProvider")

    init() {}

    func supportedAuthMethods(for provider: AIProvider) -> [any AIAuthMethod] {
        [
            DefaultAPIKeyAuthMethod(
                providerId: provider.id,
                displayName: "Gemini API Key",
                detailDescription: "直接输入 Google AI Studio API Key",
                placeholder: "AIzaSy...",
                footerText: "密钥仅保存在本机受保护目录，绝不上云"
            ),
            AntigravityBiometricAuthMethod(),
            AntigravityGooglePKCEMethod()
        ]
    }

    func stream(
        provider: AIProvider,
        model: AIModelSpec,
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions,
        apiKey: String
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let isLocal = provider.baseURL.contains("127.0.0.1") || provider.baseURL.contains("localhost")
        if isLocal {
            return OpenAIProvider().stream(provider: provider, model: model, messages: messages, options: options, apiKey: apiKey)
        }

        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let isClassicStudioKey = cleanKey.hasPrefix("AIzaSy")

        // 1. 如果指定了经典的 AI Studio API Key (AIzaSy 开头)，走 Google AI Studio 端点
        if isClassicStudioKey {
            return streamViaAIStudio(provider: provider, model: model, messages: messages, options: options, apiKey: cleanKey)
        }

        // 2. 优先尝试 Antigravity 官方云端网关原生 HTTP SSE 直连 (TTFT ~ 1.5s，彻底剥离 agy 5.5s 本地冷启动)
        return AsyncThrowingStream<AIStreamEvent, Error> { continuation in
            let task = Task {
                do {
                    // 确保拿到新鲜有效的 Access Token（若过期则 0.3s 内自动刷新自愈）
                    guard let accessToken = await AntigravityCloudCodeAdapter.ensureFreshAccessToken(explicitKey: cleanKey) else {
                        throw AIChatError.network("未能获取到有效的 Antigravity 访问凭据，请重新授权")
                    }

                    let directStream = AntigravityCloudCodeAdapter.stream(
                        model: model,
                        messages: messages,
                        options: options,
                        initialToken: accessToken
                    )
                    for try await event in directStream {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    Self.logger.warning("[GeminiProvider] 原生直连异常: \(error.localizedDescription)，尝试检查 agy CLI 兜底...")
                    // 直连遇到异常时，若本机已安装 agy，无缝平滑 fallback 至 CLI 兜底
                    if let agyPath = Self.findAgyExecutable() {
                        Self.logger.info("[GeminiProvider] 本地找到 agy 可执行文件: \(agyPath)，执行平滑 fallback")
                        do {
                            let fallbackStream = self.streamViaAntigravityCLI(
                                agyPath: agyPath,
                                model: model,
                                messages: messages,
                                options: options
                            )
                            for try await event in fallbackStream {
                                try Task.checkCancellation()
                                continuation.yield(event)
                            }
                            continuation.finish()
                            return
                        } catch {
                            Self.logger.error("[GeminiProvider] agy CLI 兜底失败: \(error.localizedDescription)")
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamViaAIStudio(
        provider: AIProvider,
        model: AIModelSpec,
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions,
        apiKey: String
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream<AIStreamEvent, Error> { continuation in
            let task = Task {
                do {
                    let req = try AntigravityNativeAdapter.buildRequest(
                        baseURL: provider.baseURL,
                        model: model.id,
                        apiKey: apiKey,
                        messages: messages,
                        systemPrompt: nil,
                        stream: true
                    )

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
                        throw AIChatError.http(status: status, message: "Gemini API 返回 HTTP \(status)")
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !raw.isEmpty, raw != "[DONE]" else { break }

                        let (delta, usageTokens) = AntigravityNativeAdapter.parseChunk(jsonString: raw)
                        if let usage = usageTokens {
                            continuation.yield(.usage(promptTokens: usage))
                        }
                        if let delta {
                            continuation.yield(.text(delta))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func fetchModels(provider: AIProvider, apiKey: String) async throws -> [String] {
        [
            "gemini-3.1-pro",
            "gemini-3.8-flash",
            "gemini-3.7-flash",
            "claude-opus-4-6",
            "claude-sonnet-4-6",
            "gpt-oss-120b"
        ]
    }

    func thinkingFields(for modelId: String, level: ThinkingLevel?) -> [String: Any] {
        guard let level else { return [:] }
        switch level {
        case .off: return ["effort": "low"]
        case .low: return ["effort": "low"]
        case .medium: return ["effort": "medium"]
        case .high: return ["effort": "high"]
        }
    }

    // MARK: - Antigravity CLI (agy) 原生无感流式驱动

    private func streamViaAntigravityCLI(
        agyPath: String,
        model: AIModelSpec,
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream<AIStreamEvent, Error> { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: agyPath)

            let resolvedModel = Self.resolveAgyModelId(model.id, effort: options.thinkingLevel)
            let isThinkingModel = model.supportsThinking || model.id.contains("pro") || model.id.contains("thinking") || model.id.contains("claude")
            let shouldEnableThinking = (options.thinkingLevel != .off) && (isThinkingModel || options.thinkingLevel != nil)

            let promptText = Self.buildPrompt(from: messages, enableThinking: shouldEnableThinking)

            var args = [
                "--model", resolvedModel,
                "--output-format", "stream-json",
                "--input-format", "text",
                "--disable-slash-commands",
                "--dangerously-skip-permissions"
            ]

            // 严禁传 --effort 命令行参数（Gemini 的 effort 级别已直接正交映射到模型后缀，避免触发 CLI 冲突报错）
            args += ["-p", promptText]
            process.arguments = args

            var env = ProcessInfo.processInfo.environment
            let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            let extraPaths = [
                "\(NSHomeDirectory())/.local/bin",
                "/usr/local/bin",
                "/opt/homebrew/bin"
            ]
            env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
            env["HOME"] = NSHomeDirectory()
            env["TERM"] = "dumb"
            env["PYTHONUNBUFFERED"] = "1"
            env["AGY_CLI_DISABLE_ESCAPE_SEQUENCE_OPTIMIZATIONS"] = "1"
            process.environment = env

            // 使用独立轻量临时沙箱目录，彻底避免扫描用户主目录大量文件和 git 仓库
            let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent("QuickShowAGYSandbox", isDirectory: true)
            try? FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
            process.currentDirectoryURL = sandboxURL

            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe

            let task = Task.detached(priority: .userInitiated) {
                do {
                    try process.run()

                    let parser = ThinkingStreamParser()
                    let fileHandle = pipe.fileHandleForReading
                    for try await line in fileHandle.bytes.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty else { continue }

                        if let data = line.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            let eventType = json["event"] as? String

                            if eventType == "step_update",
                               let step = json["step_update"] as? [String: Any] {
                                let stepType = step["step_type"] as? String ?? ""

                                if stepType.contains("thought") || stepType.contains("thinking") {
                                    // 原生思考步：直接分发为思考流
                                    if let delta = step["text_delta"] as? String, !delta.isEmpty {
                                        continuation.yield(.reasoning(delta))
                                    }
                                } else if let delta = step["text_delta"] as? String, !delta.isEmpty {
                                    // 处于正文/通用步：经过 ThinkingStreamParser 实时拆分 [THINK]...[/THINK]
                                    parser.feed(delta, onText: { t in
                                        continuation.yield(.text(t))
                                    }, onReasoning: { r in
                                        continuation.yield(.reasoning(r))
                                    })
                                }

                                if let usage = step["usage"] as? [String: Any],
                                   let inputTokens = usage["input_tokens"] as? Int {
                                    continuation.yield(.usage(promptTokens: inputTokens))
                                }
                            } else if eventType == "result",
                                      let res = json["result"] as? [String: Any],
                                      let usage = res["usage"] as? [String: Any],
                                      let inputTokens = usage["input_tokens"] as? Int {
                                continuation.yield(.usage(promptTokens: inputTokens))
                            }
                        }
                    }

                    // 冲刷缓冲区残留
                    parser.flush(onText: { t in
                        continuation.yield(.text(t))
                    }, onReasoning: { r in
                        continuation.yield(.reasoning(r))
                    })

                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !errMsg.isEmpty {
                            continuation.finish(throwing: AIChatError.network("Antigravity CLI 执行异常: \(errMsg)"))
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    private static func findAgyExecutable() -> String? {
        let candidates = [
            "/usr/local/bin/agy",
            "\(NSHomeDirectory())/.local/bin/agy",
            "\(NSHomeDirectory())/.gemini/antigravity/bin/agy"
        ]
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        return nil
    }

    private static func resolveAgyModelId(_ id: String, effort: ThinkingLevel?) -> String {
        let clean = id.replacingOccurrences(of: "antigravity/", with: "")
        switch clean {
        case "gemini-3.8-flash", "gemini-3.8-flash-high", "gemini-3.8-flash-medium", "gemini-3.8-flash-low":
            switch effort {
            case .low, .off: return "gemini-3.8-flash-low"
            case .medium: return "gemini-3.8-flash-medium"
            case .high, nil: return "gemini-3.8-flash-high"
            }
        case "gemini-3.7-flash", "gemini-3.7-flash-high", "gemini-3.7-flash-medium", "gemini-3.7-flash-low":
            switch effort {
            case .low, .off: return "gemini-3.8-flash-low"
            case .medium: return "gemini-3.8-flash-medium"
            case .high, nil: return "gemini-3.8-flash-high"
            }
        case "gemini-3.1-pro", "gemini-3.1-pro-high", "gemini-3.1-pro-low":
            switch effort {
            case .low, .off: return "gemini-3.8-flash-low"
            default: return "gemini-3.8-flash-high"
            }
        case "claude-opus", "claude-opus-4-6", "claude-opus-4-6-thinking":
            return "claude-opus-4-6-thinking"
        case "claude-sonnet", "claude-sonnet-4-6":
            return "claude-sonnet-4-6"
        case "gpt-oss-120b", "gpt-oss-120b-medium":
            return "gpt-oss-120b-medium"
        case "gemini-2.5-flash", "gemini-2.5-pro", "gemini-pro", "gemini-pro-agent":
            return "gemini-3.8-flash-high"
        default:
            return clean
        }
    }

    private static let thinkingOpenTag = "<<<BEGIN_THINKING>>>"
    private static let thinkingCloseTag = "<<<END_THINKING>>>"

    private static func buildPrompt(
        from messages: [ChatCompletionMessage],
        enableThinking: Bool
    ) -> String {
        var basePrompt = ""
        if messages.count == 1, let single = messages.first?.content?.plainText {
            basePrompt = single
        } else {
            var parts: [String] = []
            for msg in messages {
                let roleName: String
                switch msg.role {
                case "user": roleName = "User"
                case "assistant": roleName = "Assistant"
                case "system": roleName = "System"
                default: roleName = msg.role
                }
                if let text = msg.content?.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    parts.append("\(roleName): \(text)")
                }
            }
            basePrompt = parts.joined(separator: "\n\n")
        }

        if enableThinking {
            return """
[系统指令]：你具备深度思考能力。在给出最终答复前，请务必先将你详尽的推理逻辑、演算步骤或思考过程完整包裹在 \(thinkingOpenTag) 和 \(thinkingCloseTag) 标签之间；在 \(thinkingCloseTag) 之后再输出面向用户的最终答复。
注意规范：
1. 思考过程必须以 \(thinkingOpenTag) 开头，并在思考结束时输出 \(thinkingCloseTag)。
2. 在思考过程中严禁提及或输出 \(thinkingCloseTag) 的字样。

\(basePrompt)
"""
        }
        return basePrompt
    }
}

// MARK: - 流式思考标签解析状态机

private final class ThinkingStreamParser: @unchecked Sendable {
    private var inThinking = false
    private var buffer = ""
    private var activeCloseTag: String?

    private let tagPairs: [(open: String, close: String)] = [
        ("<<<BEGIN_THINKING>>>", "<<<END_THINKING>>>"),
        ("[THINK]", "[/THINK]"),
        ("<thought>", "</thought>"),
        ("<think>", "</think>"),
        ("<reasoning>", "</reasoning>")
    ]

    private func cleanTextDelta(_ text: String) -> String {
        var res = text
        for pair in tagPairs {
            res = res.replacingOccurrences(of: pair.open, with: "")
            res = res.replacingOccurrences(of: pair.close, with: "")
        }
        return res
    }

    func feed(_ chunk: String, onText: (String) -> Void, onReasoning: (String) -> Void) {
        buffer += chunk

        while !buffer.isEmpty {
            if inThinking {
                // 当前正处于思考状态：寻找匹配的闭合标签
                let closeTagsToCheck: [String] = activeCloseTag != nil ? [activeCloseTag!] : tagPairs.map { $0.close }
                var earliestCloseRange: Range<String.Index>?
                var matchedCloseTag: String?

                for close in closeTagsToCheck {
                    if let range = buffer.range(of: close) {
                        if earliestCloseRange == nil || range.lowerBound < earliestCloseRange!.lowerBound {
                            earliestCloseRange = range
                            matchedCloseTag = close
                        }
                    }
                }

                if let closeRange = earliestCloseRange, let _ = matchedCloseTag {
                    // 防假闭合检测：如果 closeTag 紧邻反引号（例如模型在复述规则或引用 `<<<END_THINKING>>>` / `[/THINK]`），
                    // 这是行内引用，绝不能作为思考结束的标记！将其作为普通思考内容安全放出，继续留在思考态。
                    let isInlineQuoted: Bool = {
                        let beforeIndex = closeRange.lowerBound
                        let afterIndex = closeRange.upperBound
                        if beforeIndex > buffer.startIndex && afterIndex < buffer.endIndex {
                            let prevChar = buffer[buffer.index(before: beforeIndex)]
                            let nextChar = buffer[afterIndex]
                            if (prevChar == "`" && nextChar == "`") || (prevChar == "\"" && nextChar == "\"") || (prevChar == "“" && nextChar == "”") {
                                return true
                            }
                        }
                        return false
                    }()

                    if isInlineQuoted {
                        // 假闭合：作为思考内容放出，吸收直到 closeTag 之后
                        let segment = String(buffer[..<closeRange.upperBound])
                        onReasoning(segment)
                        buffer = String(buffer[closeRange.upperBound...])
                        continue
                    }

                    let reasoningPart = String(buffer[..<closeRange.lowerBound])
                    if !reasoningPart.isEmpty {
                        onReasoning(reasoningPart)
                    }
                    // 彻底吸收真正的 closeTag，退出思考状态
                    buffer = String(buffer[closeRange.upperBound...])
                    inThinking = false
                    activeCloseTag = nil
                } else {
                    let maxCloseLen = 24
                    let safeCount = max(0, buffer.count - maxCloseLen)
                    if safeCount > 0 {
                        let safeIndex = buffer.index(buffer.startIndex, offsetBy: safeCount)
                        let safePart = String(buffer[..<safeIndex])
                        onReasoning(safePart)
                        buffer = String(buffer[safeIndex...])
                    }
                    break
                }
            } else {
                // 非思考状态（正文状态）：首先检查是否存在残留的孤立 closeTag（例如模型意外误吐）
                var earliestCloseRange: Range<String.Index>?
                for pair in tagPairs {
                    if let range = buffer.range(of: pair.close) {
                        if earliestCloseRange == nil || range.lowerBound < earliestCloseRange!.lowerBound {
                            earliestCloseRange = range
                        }
                    }
                }

                if let closeRange = earliestCloseRange {
                    let textPart = cleanTextDelta(String(buffer[..<closeRange.lowerBound]))
                    if !textPart.isEmpty {
                        onText(textPart)
                    }
                    // 将孤立 closeTag 吸收丢弃
                    buffer = String(buffer[closeRange.upperBound...])
                    continue
                }

                // 正常检查 openTag
                var earliestOpenRange: Range<String.Index>?
                var matchedOpenPair: (open: String, close: String)?

                for pair in tagPairs {
                    if let range = buffer.range(of: pair.open) {
                        if earliestOpenRange == nil || range.lowerBound < earliestOpenRange!.lowerBound {
                            earliestOpenRange = range
                            matchedOpenPair = pair
                        }
                    }
                }

                if let openRange = earliestOpenRange, let pair = matchedOpenPair {
                    let textPart = cleanTextDelta(String(buffer[..<openRange.lowerBound]))
                    if !textPart.isEmpty {
                        onText(textPart)
                    }
                    buffer = String(buffer[openRange.upperBound...])
                    inThinking = true
                    activeCloseTag = pair.close
                } else {
                    let maxOpenLen = 24
                    let safeCount = max(0, buffer.count - maxOpenLen)
                    if safeCount > 0 {
                        let safeIndex = buffer.index(buffer.startIndex, offsetBy: safeCount)
                        let safePart = cleanTextDelta(String(buffer[..<safeIndex]))
                        if !safePart.isEmpty {
                            onText(safePart)
                        }
                        buffer = String(buffer[safeIndex...])
                    }
                    break
                }
            }
        }
    }

    func flush(onText: (String) -> Void, onReasoning: (String) -> Void) {
        if !buffer.isEmpty {
            if inThinking {
                onReasoning(buffer)
            } else {
                let cleaned = cleanTextDelta(buffer)
                if !cleaned.isEmpty {
                    onText(cleaned)
                }
            }
            buffer = ""
        }
    }
}
