// AIChatState+Streaming.swift
// 职责：会话流式发送 / 中止 / 工具调用回路 / token 合帧与消息落定（自 AIChatState.swift 拆出）。
import Foundation

extension AIChatState {

    // MARK: - 发送 / 中止

    /// 发送当前输入（含剪贴板上下文与图片附件）。
    /// 仅约束「当前会话」不可并发发送（同一会话上下文无法承载两轮并发）；
    /// 其他会话的进行中生成不受影响（并行生成核心语义）。
    func send() {
        // 生成中的 ⏎：不再拦截报错，转为 steering 入当前会话队列（转向当前任务方向），
        // 待当前回合工具批次全部跑完后、下一次 LLM 调用前注入。⏎=转向的单一收口点。
        // 输入框/附件清空由 UI 层既有逻辑处理，此处不消费输入框。
        if isStreaming {
            enqueueSteering()
            return
        }

        let userInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let clip = clipboardAttachment
        let images = imageAttachments
        guard !userInput.isEmpty || clip != nil || !images.isEmpty else { return }

        guard hasConfiguredEndpoint else {
            appendLocalFailure("尚未配置 AI 服务，请在设置中填写 Base URL 与 API Key。")
            return
        }

        let session = store.ensureCurrentSession()
        let sessionId = session.id

        // 新建该会话的流式上下文；旧上下文若残留（异常路径兜底）先强制冲刷半截内容再重建。
        if streamContexts[sessionId] != nil {
            forceFlushPendingTokens(in: sessionId)
            streamContexts[sessionId] = nil
        }
        let ctx = StreamContext()

        // 1) 追加用户消息（含剪贴板附加与图片），清空输入与附件。
        // 落盘合并：三次变更先只改内存（persist: false），首个流式合帧时再统一落盘一次。
        var userContent = composeUserContent(input: userInput, clipboard: clip)
        if userContent.isEmpty, !images.isEmpty { userContent = "请查看图片。" }
        let userMessage = ChatMessage(role: .user, content: userContent, state: .done, images: images)
        let isFirstUserMessage = session.messages.allSatisfy { $0.role != .user }
        store.appendMessage(userMessage, to: sessionId, persist: false)

        // 首条用户消息：用截断文本做临时标题（待首轮回复后 LLM 摘要）。
        if session.titleNeedsSummary, isFirstUserMessage {
            let temporary = ChatSessionStore.makeTemporaryTitle(from: userInput)
            store.setTitle(id: sessionId, title: temporary, markSummarized: false, persist: false)
        }

        inputText = ""
        clipboardAttachment = nil
        imageAttachments = []
        // 发送即消费草稿：立即从内存与磁盘移除该会话草稿，不留残留。
        discardCurrentDraft()

        // 2) 追加助手占位（.sending），进入流式态。
        let assistantID = UUID()
        store.appendMessage(
            ChatMessage(id: assistantID, role: .assistant, content: "", state: .sending),
            to: sessionId,
            persist: false
        )
        // 跳底事件信号（发送时刻，主线程 @MainActor 同步发布）：视图层据此无条件贴底并恢复跟随，
        // 不依赖合并帧下的消息数组 diff（见 scrollJumpRequests 注释）。
        scrollJumpRequests[sessionId] = Date()
        ctx.sendPathPersisted = false
        streamContexts[sessionId] = ctx
        streamingSessionIds.insert(sessionId)
        syncStreamingState()

        // 3) 组装请求（注入 system prompt + 截断后的上下文），进入工具调用回路。
        let requestMessages = buildRequestMessages(for: sessionId)
        startConversationLoop(
            sessionId: sessionId,
            initialWire: requestMessages,
            firstAssistantID: assistantID,
            context: ctx
        )
    }

    /// 工具调用回路：流式请求 → 执行工具 → 结果回传 → 续请求，直到产出文本或达轮数上限。
    /// 整个回路运行在单个 Task 内，取消该任务即可打断包含工具轮在内的全流程。
    /// 回路按会话隔离并行：每会话独立的 Task 与合帧缓冲，互不干扰。
    private func startConversationLoop(
        sessionId: UUID,
        initialWire: [ChatCompletionMessage],
        firstAssistantID: UUID,
        context ctx: StreamContext
    ) {
        ctx.task = Task { [weak self] in
            guard let self else { return }
            var wireMessages = initialWire
            var assistantID = firstAssistantID
            var toolRounds = 0
            var didComplete = false

            do {
                roundLoop: while true {
                    // 进入新一轮前若已中止则不再发起请求（避免工具轮后继续续请求）。
                    if ctx.abortRequested || Task.isCancelled {
                        self.settle(assistantID, state: .aborted, in: sessionId)
                        break roundLoop
                    }
                    // 每轮独立发起一次流式请求；模型与思考档位按当前会话绑定解析（nil 回落全局默认）。
                    let stream = self.service.send(
                        messages: wireMessages,
                        options: self.requestOptions(for: sessionId)
                    )
                    var roundText = ""
                    var completedCalls: [CompletedToolCall] = []

                    for try await event in stream {
                        switch event {
                        case let .text(token):
                            roundText += token
                            self.appendToken(token, to: assistantID, in: sessionId)
                        case let .reasoning(token):
                            // 思考增量与正文分开累积，落定后仍保留供折叠查看。
                            self.appendReasoning(token, to: assistantID, in: sessionId)
                        case let .toolCalls(calls):
                            completedCalls = calls
                        case let .usage(promptTokens):
                            // 记录本轮真实 prompt token 用量，流收尾时写入会话（最后一批为准）。
                            ctx.usagePromptTokens = promptTokens
                        }
                    }
                    // 冲刷本轮尾部缓冲。
                    self.forceFlushPendingTokens(in: sessionId)

                    // 用户中止：落定为 .aborted 并结束整个回路。
                    if ctx.abortRequested {
                        self.settle(assistantID, state: .aborted, in: sessionId)
                        break roundLoop
                    }

                    // 没有工具调用：回合将结束。先查 steering，无则查 follow-up；
                    // 任一存在即注入一条（逐条消费）并续跑一轮，直到两队列皆空才真正 settle
                    // （steering 优先于 follow-up）。
                    if completedCalls.isEmpty {
                        let pending = self.dequeuePending(kind: .steering, in: sessionId)
                            ?? self.dequeuePending(kind: .followUp, in: sessionId)
                        if let pending {
                            self.settle(assistantID, state: .done, in: sessionId)
                            assistantID = self.injectPendingInput(pending, sessionId: sessionId, context: ctx)
                            wireMessages = self.buildRequestMessages(for: sessionId)
                            continue roundLoop
                        }
                        self.settle(assistantID, state: .done, in: sessionId)
                        didComplete = true
                        break roundLoop
                    }

                    // 有工具调用：先把记录挂到当前助手消息（状态逐个 pending）。
                    let records = completedCalls.map {
                        ToolCallRecord(id: $0.id, name: $0.name, arguments: $0.arguments, result: nil, status: .pending)
                    }
                    self.attachToolCalls(assistantID, text: roundText, records: records, in: sessionId)

                    // assistant 的 tool_calls 追加到 wire（随后每条结果紧跟其后）。
                    let wireCalls = completedCalls.map {
                        WireToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
                    }
                    wireMessages.append(ChatCompletionMessage(
                        role: "assistant",
                        content: roundText.isEmpty ? nil : .text(roundText),
                        toolCalls: wireCalls,
                        toolCallId: nil
                    ))

                    // 工具分段执行：连续的 parallelSafe 工具聚成一批并发执行，serial 工具逐个串行执行。
                    // 无论并行与否，updateToolCallResult 与 wireMessages.append 严格按 completedCalls
                    // 原始顺序落定，保证工具结果顺序与协议消息顺序不变。
                    let registry = AIToolRegistry.shared
                    var callIndex = 0
                    while callIndex < completedCalls.count {
                        // 每段开始前检查中止（与旧串行逐次检查语义一致）。
                        if ctx.abortRequested || Task.isCancelled {
                            self.failUnresolvedToolCalls(assistantID, in: sessionId)
                            self.settle(assistantID, state: .aborted, in: sessionId)
                            break roundLoop
                        }

                        let call = completedCalls[callIndex]
                        guard registry.executionPolicy(for: call.name) == .parallelSafe else {
                            // serial：保持旧逻辑（执行 → 落定 → 回传 → 下一段顶部再查中止）。
                            self.updateToolCallStatus(assistantID, callID: call.id, in: sessionId, status: .running)
                            let request = ToolCallRequest(id: call.id, name: call.name, argumentsJSON: call.arguments)
                            let result = await AIToolExecutor.shared.execute(call: request)
                            self.updateToolCallResult(
                                assistantID,
                                callID: call.id,
                                in: sessionId,
                                result: result.resultJSON,
                                status: result.status
                            )
                            wireMessages.append(ChatCompletionMessage.toolResult(callID: call.id, content: result.resultJSON))
                            callIndex += 1
                            continue
                        }

                        // 收集连续的一段 parallelSafe 调用。
                        let batchStart = callIndex
                        var batch: [CompletedToolCall] = []
                        while callIndex < completedCalls.count,
                              registry.executionPolicy(for: completedCalls[callIndex].name) == .parallelSafe {
                            batch.append(completedCalls[callIndex])
                            callIndex += 1
                        }

                        // 先在主线程把这批所有卡片批量置为 running。
                        for item in batch {
                            self.updateToolCallStatus(assistantID, callID: item.id, in: sessionId, status: .running)
                        }

                        // 并发执行批内所有调用：子任务只执行并返回结果，绝不触碰 MainActor 状态。
                        // 中止检查只用 Task.isCancelled（abortStreaming 会同时置 abortRequested 并 cancel 任务），
                        // 避免在 @Sendable 子任务中捕获非 Sendable 的 ctx；已中止则返回 failed 占位，
                        // 保证模型侧每条 tool_call 都有配对结果。
                        let batchResults = await withTaskGroup(of: (Int, ToolExecutionResult).self) { group in
                            for (offset, item) in batch.enumerated() {
                                let index = batchStart + offset
                                group.addTask {
                                    if Task.isCancelled {
                                        return (index, ToolExecutionResult(
                                            callID: item.id,
                                            name: item.name,
                                            argumentsJSON: item.arguments,
                                            resultJSON: AIToolExecutor.encodeJSON(["ok": false, "error": "用户已中止执行"]),
                                            status: .failed
                                        ))
                                    }
                                    let request = ToolCallRequest(id: item.id, name: item.name, argumentsJSON: item.arguments)
                                    let result = await AIToolExecutor.shared.execute(call: request)
                                    return (index, result)
                                }
                            }
                            var collected: [(Int, ToolExecutionResult)] = []
                            for await item in group {
                                collected.append(item)
                            }
                            return collected
                        }

                        // 按原始 index 升序落定结果与回传消息，严格保持 completedCalls 顺序。
                        for (_, result) in batchResults.sorted(by: { $0.0 < $1.0 }) {
                            self.updateToolCallResult(
                                assistantID,
                                callID: result.callID,
                                in: sessionId,
                                result: result.resultJSON,
                                status: result.status
                            )
                            wireMessages.append(ChatCompletionMessage.toolResult(callID: result.callID, content: result.resultJSON))
                        }

                        // 批结束后发生中止：不再处理后续工具段，跳出整个回路。
                        if ctx.abortRequested || Task.isCancelled {
                            if callIndex < completedCalls.count {
                                // 仍有未执行工具：标记失败占位并落定 aborted（等价旧「下一段顶部检查」）。
                                self.failUnresolvedToolCalls(assistantID, in: sessionId)
                                self.settle(assistantID, state: .aborted, in: sessionId)
                            } else {
                                // 本轮工具已全部落定，不再发起续请求（等价旧「for 循环后的中止检查」）。
                                self.settle(assistantID, state: .done, in: sessionId)
                            }
                            break roundLoop
                        }
                    }
                    // 工具执行期间发生中止：工具轮已全部落定，不再发起续请求。
                    if ctx.abortRequested || Task.isCancelled {
                        self.settle(assistantID, state: .done, in: sessionId)
                        break roundLoop
                    }

                    // 本轮工具全部执行完，工具调用助手消息落定为 done（单点落盘）。
                    self.settle(assistantID, state: .done, in: sessionId)

                    toolRounds += 1

                    // 软限制收尾：还剩 2 轮时向 wire 注入一条引导消息，促使模型停止
                    // 发起新工具调用、基于已有结果给出最终答复，避免任务被硬截断拦腰砍断。
                    // 仅追加到请求侧 wire，不落 UI 与持久化；若此后 steering 注入重建
                    // wire（buildRequestMessages）会丢失本提示，退化为硬截断兜底，可接受。
                    if toolRounds == AIToolExecutor.maxToolRounds - 2 {
                        let remaining = AIToolExecutor.maxToolRounds - toolRounds
                        wireMessages.append(ChatCompletionMessage(
                            role: "user",
                            content: "系统提示：工具调用轮数即将耗尽（还剩 \(remaining) 轮）。请停止发起更多工具调用，基于已获得的结果直接给出最终答复。"
                        ))
                    }
                    if toolRounds >= AIToolExecutor.maxToolRounds {
                        // 达到轮数上限：落一条文本说明并停止续请求。
                        let limitNote = "已达工具调用轮数上限（\(AIToolExecutor.maxToolRounds) 轮），停止继续调用工具。"
                        self.store.appendMessage(
                            ChatMessage(role: .assistant, content: limitNote, state: .done),
                            to: sessionId,
                            persist: true
                        )
                        didComplete = true
                        break roundLoop
                    }

                    // 注入点 1：当前回合工具批次已全部跑完、下一次 LLM 调用前，
                    // 检查 steering 队列（逐条取最早一条注入）；此处不检查 follow-up。
                    if let pending = self.dequeuePending(kind: .steering, in: sessionId) {
                        assistantID = self.injectPendingInput(pending, sessionId: sessionId, context: ctx)
                        wireMessages = self.buildRequestMessages(for: sessionId)
                    } else {
                        // 创建下一轮助手占位，继续回路。
                        assistantID = UUID()
                        self.store.appendMessage(
                            ChatMessage(id: assistantID, role: .assistant, content: "", state: .sending),
                            to: sessionId,
                            persist: false
                        )
                        ctx.sendPathPersisted = false
                    }
                }
            } catch is CancellationError {
                // 用户主动中止：保留半截回复，落定为 .aborted。
                self.forceFlushPendingTokens(in: sessionId)
                self.failUnresolvedToolCalls(assistantID, in: sessionId)
                self.settle(assistantID, state: .aborted, in: sessionId)
            } catch {
                // 中止与超时错误竞争时优先落定为用户中止。
                self.forceFlushPendingTokens(in: sessionId)
                if ctx.abortRequested {
                    self.failUnresolvedToolCalls(assistantID, in: sessionId)
                    self.settle(assistantID, state: .aborted, in: sessionId)
                } else {
                    self.settle(assistantID, state: .failed(error.localizedDescription), in: sessionId)
                }
            }

            // 回路统一收尾：移除上下文、刷新流集合（didComplete 的摘要/通知/未读一并处理）。
            self.finishStream(sessionId: sessionId, didComplete: didComplete)
        }
    }

    /// 回路收尾：清理该会话的流式上下文与流集合，isStreaming 派生刷新；
    /// 成功完成时依次处理未读标记、LLM 标题摘要与完成通知。
    private func finishStream(sessionId: UUID, didComplete: Bool) {
        // usage 回写：把本轮真实 prompt token 写入会话并持久化（上下文水位真源）。
        if let tokens = streamContexts[sessionId]?.usagePromptTokens {
            store.setContextTokens(id: sessionId, tokens: tokens)
            usageBaselines[sessionId] = store.messages(in: sessionId).count
        }
        streamContexts[sessionId] = nil
        // 清理该会话残留的待注入队列：正常完成时两队列已在回路内排空；
        // 中止路径由 abortAndRecallQueue 回填后清空；失败/删除兜底清空，
        // 避免陈旧条目泄漏到下一次会话并意外注入。
        pendingQueues[sessionId] = nil
        streamingSessionIds.remove(sessionId)
        syncStreamingState()
        // 流结束后异步检查水位：达阈值则自动压缩（不阻塞输入；isCompacting 已天然防重入）。
        maybeAutoCompact(sessionId: sessionId)
        guard didComplete else { return }

        // 后台完成未读：完成时非当前会话 → 标记未读（切回该会话即清除）。
        // 会话已被删除时不再标记（否则会在 unreadSessionIds 留下永久死项）。
        if sessionId != currentSessionId, store.session(id: sessionId) != nil {
            unreadSessionIds.insert(sessionId)
        }
        // 首轮助手回复完成后，后台生成中文标题（失败静默，不影响主对话流）。
        scheduleTitleSummary(sessionId: sessionId)
        // 成功完成一轮回复：用户没在看对话窗时发系统通知。
        notifyCompletionIfNeeded(sessionId: sessionId)
    }

    /// 中止流式生成并落定半截回复为 .aborted。
    /// 默认中止「当前会话」；指定 sessionId 时中止目标会话（侧栏中止按钮调用），
    /// 不影响其他会话的进行中生成。
    func abortStreaming(sessionId target: UUID? = nil) {
        let sessionId = target ?? currentSessionId
        guard let sessionId, let ctx = streamContexts[sessionId] else { return }
        ctx.abortRequested = true
        // 取消回路任务触发消费侧 CancellationError，进入 .aborted 分支；
        // 网络层取消经流的 onTermination 链路自动传导（AIChatService 无全局 abort）。
        ctx.task?.cancel()
    }

    /// 指定会话是否生成中（侧栏状态可视化查询）。
    func isStreaming(sessionId: UUID) -> Bool {
        streamingSessionIds.contains(sessionId)
    }

    // MARK: - 内部：消息更新

    /// 流式增量：只累积到该会话的合帧缓冲区，由 ~50ms 定时器批量写入 store。
    /// 直接丢弃每 token 的 store 写入，避免 @Published sessions 整组扇出与侧栏全量重建。
    private func appendToken(_ token: String, to id: UUID, in sessionId: UUID) {
        guard let ctx = streamContexts[sessionId] else { return }
        ctx.pendingTokens += token
        ctx.pendingMessageID = id
        scheduleFlushIfNeeded(for: sessionId)
    }

    /// 思考过程增量：与正文共用同一合帧缓冲区与定时器，同样避免逐片写 store。
    private func appendReasoning(_ token: String, to id: UUID, in sessionId: UUID) {
        guard let ctx = streamContexts[sessionId] else { return }
        ctx.pendingReasoning += token
        ctx.pendingMessageID = id
        scheduleFlushIfNeeded(for: sessionId)
    }

    /// 若该会话无挂起冲刷，启动一个 ~50ms 的合帧定时任务（per-session 独立节拍）。
    private func scheduleFlushIfNeeded(for sessionId: UUID) {
        guard let ctx = streamContexts[sessionId], ctx.flushTask == nil else { return }
        ctx.flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.flushInterval ?? 50_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingTokens(in: sessionId)
        }
    }

    /// 把该会话的合帧缓冲一次性写入 store（不落盘；落盘由单独的持久化点负责）。
    /// 与定时器、forceFlush 均在 MainActor 串行执行，天然无并发竞态。
    private func flushPendingTokens(in sessionId: UUID) {
        guard let ctx = streamContexts[sessionId] else { return }
        ctx.flushTask = nil
        guard let id = ctx.pendingMessageID else { return }

        let contentChunk = ctx.pendingTokens
        let reasoningChunk = ctx.pendingReasoning
        guard !contentChunk.isEmpty || !reasoningChunk.isEmpty else { return }

        ctx.pendingTokens = ""
        ctx.pendingReasoning = ""
        store.updateMessage(id: id, in: sessionId) { message in
            // reasoning 累积不改消息 id、不触碰其他字段，保持 ChatMessage Equatable 合成语义，
            // UI 侧 .equatable() 仍可对其余未变行跳过重建。
            if !reasoningChunk.isEmpty {
                message.reasoning = (message.reasoning ?? "") + reasoningChunk
            }
            if !contentChunk.isEmpty {
                message.content += contentChunk
                if message.state == .sending {
                    message.state = .streaming
                }
            }
        }

        // 发送路径合并落盘：首个合帧时统一写盘一次（此时请求已在途，避开首 token 关键路径）。
        if !ctx.sendPathPersisted {
            ctx.sendPathPersisted = true
            store.persist(sessionId: sessionId)
        }
    }

    /// 强制冲刷：取消该会话挂起定时器并立即写入缓冲。流结束 / 中止 / 失败三条路径在 settle 前调用，
    /// 保证尾部内容不丢；取消后定时任务的 isCancelled 检查确保不会重复冲刷。
    private func forceFlushPendingTokens(in sessionId: UUID) {
        guard let ctx = streamContexts[sessionId] else { return }
        ctx.flushTask?.cancel()
        ctx.flushTask = nil
        flushPendingTokens(in: sessionId)
    }

    /// 落定消息状态；仅当仍处于发送中才覆盖，避免覆盖已有失败态。落盘在此单点完成（F4）。
    private func settle(_ id: UUID, state: ChatMessage.MessageState, in sessionId: UUID) {
        store.updateMessage(id: id, in: sessionId, persist: true) { message in
            switch message.state {
            case .sending, .streaming:
                message.state = state
            default:
                break
            }
        }
    }

    /// 把工具调用记录挂到助手消息上（内存即时；状态初始为 pending）。
    /// 不改变消息状态：流式期间仍是 sending/streaming，由 settle 最终落定。
    private func attachToolCalls(_ id: UUID, text: String, records: [ToolCallRecord], in sessionId: UUID) {
        store.updateMessage(id: id, in: sessionId) { message in
            message.content = text
            message.toolCalls = records
        }
    }

    /// 更新单个工具调用的状态（内存即时，不落盘；由回合结束时的 settle 统一落盘）。
    private func updateToolCallStatus(_ id: UUID, callID: String, in sessionId: UUID, status: ToolCallStatus) {
        store.updateMessage(id: id, in: sessionId) { message in
            guard var calls = message.toolCalls,
                  let index = calls.firstIndex(where: { $0.id == callID }) else { return }
            calls[index].status = status
            message.toolCalls = calls
        }
    }

    /// 写入单个工具调用的结果与最终状态。
    private func updateToolCallResult(
        _ id: UUID,
        callID: String,
        in sessionId: UUID,
        result: String,
        status: ToolCallStatus
    ) {
        store.updateMessage(id: id, in: sessionId) { message in
            guard var calls = message.toolCalls,
                  let index = calls.firstIndex(where: { $0.id == callID }) else { return }
            calls[index].result = result
            calls[index].status = status
            message.toolCalls = calls
        }
    }

    /// 中止时将仍未落定的工具调用（pending/running）标记为 failed，避免 UI 卡在进行中。
    private func failUnresolvedToolCalls(_ id: UUID, in sessionId: UUID) {
        store.updateMessage(id: id, in: sessionId) { message in
            guard var calls = message.toolCalls else { return }
            for index in calls.indices where calls[index].status == .pending || calls[index].status == .running {
                calls[index].status = .failed
            }
            message.toolCalls = calls
        }
    }

    /// 本地即时失败（未发起请求，如未配置端点）。
    private func appendLocalFailure(_ text: String) {
        let session = store.ensureCurrentSession()
        store.appendMessage(
            ChatMessage(role: .assistant, content: "", state: .failed(text)),
            to: session.id
        )
    }

}
