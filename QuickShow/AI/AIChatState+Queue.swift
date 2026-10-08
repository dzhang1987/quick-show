// AIChatState+Queue.swift
// 职责：待注入队列（steering / follow-up 入队、消费、注入与对外契约）（自 AIChatState.swift 拆出）。
import Foundation

extension AIChatState {

    // MARK: - 待注入队列（steering / follow-up 内部实现）

    /// 生成中 ⏎ 的单一收口：把当前输入（含图片）作为 steering 入当前会话队列。
    /// UI 层负责清空输入框，此处只入队、不消费输入态。
    func enqueueSteering() {
        let userInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = imageAttachments
        guard !userInput.isEmpty || !images.isEmpty else { return }
        guard let sessionId = currentSessionId else { return }
        var content = userInput
        if content.isEmpty, !images.isEmpty { content = "请查看图片。" }
        pendingQueues[sessionId, default: []].append(
            QueuedChatInput(id: UUID(), kind: .steering, text: content, images: images)
        )
    }

    /// 逐条消费队列：移除并返回最早一条指定类别的待注入输入；无则返回 nil。
    /// 以 kind 过滤实现「steering 优先于 follow-up」的调度语义。
    func dequeuePending(kind: QueuedChatInput.Kind, in sessionId: UUID) -> QueuedChatInput? {
        guard var queue = pendingQueues[sessionId],
              let index = queue.firstIndex(where: { $0.kind == kind }) else { return nil }
        let item = queue.remove(at: index)
        pendingQueues[sessionId] = queue.isEmpty ? nil : queue
        return item
    }

    /// 注入一条待发送输入：追加 user 消息（走 store 既有 mutate+persist 正常落盘）
    /// + 新 assistant 占位（.sending），返回新占位 id；
    /// 后续由调用方以含新消息的上下文发起下一轮请求。
    /// 转向标记在此收口：steering 注入的 user 消息打 isSteered（UI 弱标记用），
    /// followUp 是普通追加语义不打标；两个注入点共用本函数，无需各自感知。
    func injectPendingInput(
        _ item: QueuedChatInput,
        sessionId: UUID,
        context ctx: StreamContext
    ) -> UUID {
        let userMessage = ChatMessage(
            role: .user,
            content: item.text,
            state: .done,
            images: item.images,
            isSteered: item.kind == .steering ? true : nil
        )
        store.appendMessage(userMessage, to: sessionId, persist: true)

        let assistantID = UUID()
        store.appendMessage(
            ChatMessage(id: assistantID, role: .assistant, content: "", state: .sending),
            to: sessionId,
            persist: false
        )
        ctx.sendPathPersisted = false
        return assistantID
    }

    // MARK: - steering / follow-up 待注入队列（对外契约）

    /// 当前会话的待注入队列（按入队顺序）；切到其他会话即读到该会话自己的队列，
    /// 队列严格按会话 id 隔离，A 会话绝不出现在 B 会话。UI 依赖其响应式刷新。
    var pendingQueue: [QueuedChatInput] {
        guard let sessionId = currentSessionId else { return [] }
        return pendingQueues[sessionId] ?? []
    }

    /// 生成中 ⌥⏎：入当前会话 follow-up 队列（仅生成中有意义；无生成时由 UI 走普通发送）。
    /// 空文本且无图片时不入队。
    func enqueueFollowUp(text: String, images: [ChatImageAttachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        guard let sessionId = currentSessionId, isStreaming else { return }
        pendingQueues[sessionId, default: []].append(
            QueuedChatInput(id: UUID(), kind: .followUp, text: trimmed, images: images)
        )
    }

    /// 取回某条到输入框：从当前会话队列移除并回填 inputText + 附件暂存
    /// （复用 withdrawLastRound 的回填模式：整体替换输入与附件态）。
    func recallQueuedInput(id: UUID) {
        guard let sessionId = currentSessionId,
              var queue = pendingQueues[sessionId],
              let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue.remove(at: index)
        pendingQueues[sessionId] = queue.isEmpty ? nil : queue
        inputText = item.text
        imageAttachments = item.images
    }

    /// ⌘⌫ 撤回当前会话队列最早一条（不区分 kind）：移除并回填 inputText + 附件暂存，
    /// 与 recallQueuedInput 同一回填模式（整体替换输入与附件态，输入框已有草稿时直接覆盖）。
    /// 键路仅在输入框为空时触发：撤回后文字回填进输入框，心智自洽。空队列返回 false。
    @discardableResult
    func recallFirstQueuedInput() -> Bool {
        guard let sessionId = currentSessionId,
              var queue = pendingQueues[sessionId],
              !queue.isEmpty else { return false }
        let item = queue.removeFirst()
        pendingQueues[sessionId] = queue.isEmpty ? nil : queue
        inputText = item.text
        imageAttachments = item.images
        return true
    }

    /// 中止当前会话生成并把该会话队列全部回填输入框：
    /// 各条 text 以换行拼接进 inputText（保留框内已有文本，接在其后），
    /// images 取并集入附件暂存；随后走既有中止路径，半截回复保留 .aborted 语义。
    func abortAndRecallQueue() {
        let sessionId = currentSessionId
        if let sessionId, let queue = pendingQueues[sessionId], !queue.isEmpty {
            let joined = queue.map(\.text).joined(separator: "\n")
            if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputText = joined
            } else {
                inputText = inputText + "\n" + joined
            }
            var merged = imageAttachments
            for item in queue {
                for image in item.images where !merged.contains(where: { $0.id == image.id }) {
                    merged.append(image)
                }
            }
            imageAttachments = merged
            pendingQueues[sessionId] = nil
        }
        abortStreaming(sessionId: sessionId)
    }

}
