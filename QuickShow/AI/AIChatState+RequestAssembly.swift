// AIChatState+RequestAssembly.swift
// 职责：请求 wire 组装（system/摘要注入、上下文截断与多模态消息构造）（自 AIChatState.swift 拆出）。
import Foundation

extension AIChatState {

    // MARK: - 内部：请求组装

    /// 历史被清空/撤回/重编辑时重置真实水位与 baseline：避免旧真实值失真，
    /// 下一次请求的 usage 上报会重新写入。
    func resetContextWatermark(for sessionId: UUID) {
        store.setContextTokens(id: sessionId, tokens: nil)
        usageBaselines[sessionId] = store.messages(in: sessionId).count
        // 同时重算压缩信息（撤回/编辑后 beforeMessageID 可能变化）。
        refreshCompactionInfo()
    }

    /// 构造发往服务端的消息数组：system prompt 在最前，其次为早期对话的压缩摘要，
    /// 最后是未压缩上下文（按 token 水位截断兜底；system 不参与丢弃）。
    func buildRequestMessages(for sessionId: UUID) -> [ChatCompletionMessage] {
        var result: [ChatCompletionMessage] = []

        // system 段组装：内置引导（ask_user 启用时）+ 用户自定义，合并为单条 system 消息
        // （Responses 协议会合并全部 system 为 instructions，此处单条即两协议通吃）。
        var systemParts: [String] = []
        let askUserEnabled = AIToolRegistry.shared.enabledTools()
            .contains { $0.name == "ask_user" }
        if askUserEnabled {
            systemParts.append(Self.builtinSystemGuidance)
        }
        let customSystem = service.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customSystem.isEmpty {
            systemParts.append(customSystem)
        }
        if !systemParts.isEmpty {
            result.append(ChatCompletionMessage(
                role: ChatMessage.Role.system.rawValue,
                content: systemParts.joined(separator: "\n\n")
            ))
        }
        // 摘要注入：紧随 systemPrompt，作为压缩后的早期上下文。
        if let summary = store.session(id: sessionId)?.contextSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            result.append(ChatCompletionMessage(
                role: ChatMessage.Role.system.rawValue,
                content: "以下是本会话早期对话的压缩摘要：\n\(summary)"
            ))
        }
        for message in trimmedContextMessages(in: sessionId) {
            result.append(contentsOf: makeRequestMessages(from: message))
        }
        return result
    }

    /// 单条展示消息 → wire 消息（可能展开为多条）。
    /// 带工具调用的助手消息会被重建为 assistant(tool_calls) + 逐条 tool 结果，保证协议合法；
    /// 若存在未落定结果的调用（如中止/失败），退化为纯文本消息，避免出现无配对结果的 tool_calls。
    private func makeRequestMessages(from message: ChatMessage) -> [ChatCompletionMessage] {
        guard message.role == .assistant, let records = message.toolCalls, !records.isEmpty else {
            return [makeBasicRequestMessage(from: message)]
        }

        let allResolved = records.allSatisfy { $0.result != nil }
        guard allResolved else {
            return [makeBasicRequestMessage(from: message)]
        }

        var result: [ChatCompletionMessage] = []
        let calls = records.map {
            WireToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
        }
        result.append(ChatCompletionMessage(
            role: "assistant",
            content: message.content.isEmpty ? nil : .text(message.content),
            toolCalls: calls,
            toolCallId: nil
        ))
        for record in records {
            result.append(ChatCompletionMessage.toolResult(callID: record.id, content: record.result ?? ""))
        }
        return result
    }

    /// 普通单条消息 → wire 消息：用户消息带图时组装多模态 content 数组。
    private func makeBasicRequestMessage(from message: ChatMessage) -> ChatCompletionMessage {
        let role = message.role.rawValue
        guard message.role == .user, !message.images.isEmpty else {
            return ChatCompletionMessage(role: role, content: message.content)
        }
        var parts: [ChatContentPart] = []
        if !message.content.isEmpty {
            parts.append(.textPart(message.content))
        }
        for image in message.images {
            parts.append(.imagePart(dataURI: image.dataURI))
        }
        return ChatCompletionMessage(role: role, content: .parts(parts))
    }

    /// 上下文截断（兜底）：排除已纳入摘要的消息，按当前生效模型的上下文窗口推导 token 预算
    /// （窗口 × 80% 再扣掉已有摘要占用），从最旧整轮丢弃（按会话独立）；
    /// 字符→token 按 2 字符≈1 token 换算。
    /// 仅纳入已落定（done）或已中止（aborted）的消息，排除进行中与失败占位。
    private func trimmedContextMessages(in sessionId: UUID) -> [ChatMessage] {
        let session = store.session(id: sessionId)
        let summarized = Set(session?.summarizedMessageIDs ?? [])
        let eligible = store.messages(in: sessionId).filter { message in
            guard message.role != .system else { return false }
            guard !summarized.contains(message.id.uuidString) else { return false }
            switch message.state {
            case .done, .aborted: return true
            default: return false
            }
        }
        guard !eligible.isEmpty else { return [] }

        // 按「轮」分组：以 user 消息为轮起点，其后的 assistant 归入同轮。
        var turns: [[ChatMessage]] = []
        var current: [ChatMessage] = []
        for message in eligible {
            if message.role == .user, !current.isEmpty {
                turns.append(current)
                current = [message]
            } else {
                current.append(message)
            }
        }
        if !current.isEmpty { turns.append(current) }

        // token 预算：当前生效模型（会话绑定优先）的窗口 × 80%，扣除摘要占用。
        let effectiveModelId = session?.modelId ?? service.selectedModel
        let window = AIModelAdapter.contextWindow(for: effectiveModelId)
        let summaryTokens = (session?.contextSummary?.count ?? 0) / charsPerToken
        let tokenBudget = max(0, Int(Double(window) * contextWindowUsageRatio) - summaryTokens)

        // 从最新一轮向前累计，超预算或超条数即停；至少保留最后一轮。
        var selected: [[ChatMessage]] = []
        var messageCount = 0
        var tokenCount = 0
        for turn in turns.reversed() {
            let turnChars = turn.reduce(0) { $0 + $1.content.count }
            let turnTokens = turnChars / charsPerToken
            let exceedsCount = messageCount + turn.count > contextMessageLimit
            let exceedsBudget = !selected.isEmpty && tokenCount + turnTokens > tokenBudget
            if exceedsCount || exceedsBudget { break }
            selected.append(turn)
            messageCount += turn.count
            tokenCount += turnTokens
        }
        return selected.reversed().flatMap { $0 }
    }

}
