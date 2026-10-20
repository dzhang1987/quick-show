// AIProviderService: 统一多服务商网络路由引擎，支持流式分发与单次 Observer 视觉先行分析。

import Foundation
import os

@MainActor
final class AIProviderService {
    static let shared = AIProviderService()

    private let logger = Logger(subsystem: "com.dzhang.quickshow.ai", category: "providerService")

    private init() {}

    // MARK: - 流式发送分流总入口

    func send(
        messages: [ChatCompletionMessage],
        agent: AIAgent,
        overrideModelId: String? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        disableTools: Bool = false
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let effectiveModel = overrideModelId?.isEmpty == false ? overrideModelId : agent.modelId
        let effectiveThinking = thinkingLevel ?? agent.thinkingLevel
        let options = AIChatRequestOptions(
            modelId: effectiveModel,
            thinkingLevel: effectiveThinking,
            agentId: agent.id,
            disableTools: disableTools
        )
        return AIChatService.shared.send(messages: messages, options: options)
    }

    // MARK: - 单次非流式调用 (供 A 模式 Observer 视觉先行解析调用)

    func performOneOffCompletion(
        agent: AIAgent,
        prompt: String,
        images: [ChatImageAttachment]
    ) async throws -> String {
        var parts: [ChatContentPart] = [.textPart(prompt)]
        for img in images {
            parts.append(.imagePart(dataURI: img.dataURI))
        }
        let userMessage = ChatCompletionMessage(role: "user", content: .parts(parts))

        var messages: [ChatCompletionMessage] = []
        if !agent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(ChatCompletionMessage(role: "system", content: agent.systemPrompt))
        }
        messages.append(userMessage)

        let stream = send(messages: messages, agent: agent)
        var fullText = ""

        for try await event in stream {
            if case .text(let chunk) = event {
                fullText += chunk
            }
        }
        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
