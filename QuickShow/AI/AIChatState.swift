import AppKit
import Combine
import Foundation

/// AI 会话门面：串联 ChatSessionStore（多会话数据层）与 AIChatService（网络层），
/// 负责流式发送、中断、重试、图片/剪贴板附加与 LLM 标题摘要。
/// 对外保留旧 AIChatView 的调用点（messages / inputText / isStreaming / send 等），
/// 消息读写全部落到「当前会话」，⌘K 清空语义为清空当前会话消息。
/// 全程 @MainActor，保证网络回调与 SwiftUI 状态更新都落在主线程。
@MainActor
final class AIChatState: ObservableObject {
    static let shared = AIChatState()

    // MARK: - 公开状态

    /// 当前会话的消息（由 ChatSessionStore 同步而来，供 AIChatView 直接渲染）。
    @Published private(set) var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    /// 剪贴板附加上下文（非 nil 表示已附加）。
    @Published var clipboardAttachment: String?
    /// 待发送图片附件（Wave 2 附件 UI 消费；发送后清空）。
    @Published var imageAttachments: [ChatImageAttachment] = []
    @Published private(set) var isStreaming: Bool = false

    /// 多会话数据层（Wave 2 侧边栏消费其分组 / 搜索 / 增删改 API）。
    let store = ChatSessionStore.shared

    /// Base URL 与 API Key 均已配置。
    var hasConfiguredEndpoint: Bool {
        let base = AIChatService.shared.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = AIChatService.shared.apiKey ?? ""
        return !base.isEmpty && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 私有状态

    private let service = AIChatService.shared
    private var streamTask: Task<Void, Never>?
    private var titleTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// 用户是否已请求中止本轮生成（用于中止与超时错误竞争时优先落定为 .aborted）。
    private var abortRequested = false

    // MARK: - 流式合帧状态（F1）

    /// 累积待写入的 token（合帧缓冲区，降低 store/视图失效频率）。
    private var pendingTokens: String = ""
    /// 累积待写入的思考过程增量（与正文共用合帧定时器，避免 reasoning 逐片写 store）。
    private var pendingReasoning: String = ""
    /// 合帧缓冲区对应的助手消息 id。
    private var pendingMessageID: UUID?
    /// 合帧缓冲区对应的会话 id。
    private var pendingSessionID: UUID?
    /// 合帧冲刷定时任务（~50ms）；nil 表示当前无挂起冲刷。
    private var flushTask: Task<Void, Never>?
    /// 发送路径是否已落盘一次（首帧冲刷时落盘，避免发请求前多次写盘）。
    private var sendPathPersisted = false

    /// 合帧间隔：约 50ms，把视图失效频率从 token 速率降到 ≤20 次/秒。
    private let flushInterval: UInt64 = 50_000_000

    /// 剪贴板附加的字符上限（超出静默截断）。
    private let clipboardLimit = 8000
    /// 上下文截断：最多保留的 user/assistant 消息条数（20 轮）。
    private let contextMessageLimit = 40
    /// 上下文截断：累计字符预算。
    private let contextCharBudget = 24000

    private init() {
        // 会话数据变化 → 同步当前会话消息到 @Published messages，保持旧视图调用点不变。
        Publishers.CombineLatest(store.$sessions, store.$currentSessionId)
            .sink { [weak self] sessions, sessionId in
                guard let self else { return }
                self.messages = sessions.first(where: { $0.id == sessionId })?.messages ?? []
            }
            .store(in: &cancellables)
    }

    // MARK: - 发送 / 中止

    /// 发送当前输入（含剪贴板上下文与图片附件）。
    func send() {
        guard !isStreaming else { return }

        let userInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let clip = clipboardAttachment
        let images = imageAttachments
        guard !userInput.isEmpty || clip != nil || !images.isEmpty else { return }

        guard hasConfiguredEndpoint else {
            appendLocalFailure("尚未配置 AI 服务，请在设置中填写 Base URL 与 API Key。")
            return
        }

        abortRequested = false
        // 清理上一轮可能残留的合帧状态（正常结束时本已清空，此处兜底）。
        forceFlushPendingTokens()

        let session = store.ensureCurrentSession()
        let sessionId = session.id

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

        // 2) 追加助手占位（.sending），进入流式态。
        let assistantID = UUID()
        store.appendMessage(
            ChatMessage(id: assistantID, role: .assistant, content: "", state: .sending),
            to: sessionId,
            persist: false
        )
        sendPathPersisted = false
        isStreaming = true

        // 3) 组装请求（注入 system prompt + 截断后的上下文），进入工具调用回路。
        let requestMessages = buildRequestMessages(for: sessionId)
        startConversationLoop(
            sessionId: sessionId,
            initialWire: requestMessages,
            firstAssistantID: assistantID
        )
    }

    /// 工具调用回路：流式请求 → 执行工具 → 结果回传 → 续请求，直到产出文本或达轮数上限。
    /// 整个回路运行在单个 Task 内，`abortStreaming` 取消该任务即可打断包含工具轮在内的全流程。
    private func startConversationLoop(
        sessionId: UUID,
        initialWire: [ChatCompletionMessage],
        firstAssistantID: UUID
    ) {
        streamTask = Task { [weak self] in
            guard let self else { return }
            var wireMessages = initialWire
            var assistantID = firstAssistantID
            var toolRounds = 0
            var didComplete = false

            do {
                roundLoop: while true {
                    // 进入新一轮前若已中止则不再发起请求（避免工具轮后继续续请求）。
                    if self.abortRequested || Task.isCancelled {
                        self.settle(assistantID, state: .aborted, in: sessionId)
                        break roundLoop
                    }
                    // 每轮独立发起一次流式请求。
                    let stream = self.service.send(messages: wireMessages)
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
                        }
                    }
                    // 冲刷本轮尾部缓冲。
                    self.forceFlushPendingTokens()

                    // 用户中止：落定为 .aborted 并结束整个回路。
                    if self.abortRequested {
                        self.settle(assistantID, state: .aborted, in: sessionId)
                        break roundLoop
                    }

                    // 没有工具调用：本助手消息为最终文本，正常结束。
                    if completedCalls.isEmpty {
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

                    // 串行执行工具，避免并发副作用；每次执行前检查中止。
                    for call in completedCalls {
                        if self.abortRequested || Task.isCancelled {
                            self.failUnresolvedToolCalls(assistantID, in: sessionId)
                            self.settle(assistantID, state: .aborted, in: sessionId)
                            break roundLoop
                        }
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
                        // 工具结果回传模型。
                        wireMessages.append(ChatCompletionMessage.toolResult(callID: call.id, content: result.resultJSON))
                    }
                    // 工具执行期间发生中止：工具轮已全部落定，不再发起续请求。
                    if self.abortRequested || Task.isCancelled {
                        self.settle(assistantID, state: .done, in: sessionId)
                        break roundLoop
                    }

                    // 本轮工具全部执行完，工具调用助手消息落定为 done（单点落盘）。
                    self.settle(assistantID, state: .done, in: sessionId)

                    toolRounds += 1
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

                    // 创建下一轮助手占位，继续回路。
                    assistantID = UUID()
                    self.store.appendMessage(
                        ChatMessage(id: assistantID, role: .assistant, content: "", state: .sending),
                        to: sessionId,
                        persist: false
                    )
                    self.sendPathPersisted = false
                }
            } catch is CancellationError {
                // 用户主动中止：保留半截回复，落定为 .aborted。
                self.forceFlushPendingTokens()
                self.failUnresolvedToolCalls(assistantID, in: sessionId)
                self.settle(assistantID, state: .aborted, in: sessionId)
            } catch {
                // 中止与超时错误竞争时优先落定为用户中止。
                self.forceFlushPendingTokens()
                if self.abortRequested {
                    self.failUnresolvedToolCalls(assistantID, in: sessionId)
                    self.settle(assistantID, state: .aborted, in: sessionId)
                } else {
                    self.settle(assistantID, state: .failed(error.localizedDescription), in: sessionId)
                }
            }

            self.isStreaming = false
            // 首轮助手回复完成后，后台生成中文标题（失败静默，不影响主对话流）。
            if didComplete {
                self.scheduleTitleSummary(sessionId: sessionId)
                // 成功完成一轮回复：用户没在看对话窗时发系统通知。
                self.notifyCompletionIfNeeded(sessionId: sessionId)
            }
        }
    }

    /// 中止流式生成并落定半截回复为 .aborted。
    func abortStreaming() {
        guard isStreaming else { return }
        abortRequested = true
        service.abort()       // 立即停止网络回调
        streamTask?.cancel()  // 触发消费侧 CancellationError，进入 .aborted 分支
    }

    /// ⌘K 清空当前会话消息（保留会话本身，重置标题待重新摘要）。
    func clearSession() {
        if isStreaming {
            abortStreaming()
        }
        let session = store.ensureCurrentSession()
        store.clearMessages(in: session.id)
        store.resetSessionTitle(id: session.id)
    }

    // MARK: - 剪贴板 / 图片附加

    /// 读取系统剪贴板文本作为附加上下文；空剪贴板返回 false。
    func attachClipboard() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        clipboardAttachment = String(text.prefix(clipboardLimit))
        return true
    }

    func removeClipboardAttachment() {
        clipboardAttachment = nil
    }

    /// 添加图片附件（Wave 2 拖拽/粘贴入口调用；内部统一转 JPEG base64）。
    func addImageAttachment(_ attachment: ChatImageAttachment) {
        imageAttachments.append(attachment)
    }

    /// 直接由 NSImage 添加图片附件（转换失败返回 false）。
    @discardableResult
    func addImage(_ image: NSImage, fileName: String? = nil) -> Bool {
        guard let attachment = ImageAttachmentProcessor.makeAttachment(from: image, fileName: fileName) else {
            return false
        }
        imageAttachments.append(attachment)
        return true
    }

    func removeImageAttachment(id: UUID) {
        imageAttachments.removeAll { $0.id == id }
    }

    // MARK: - 会话操作（Wave 2 侧边栏调用）

    /// 新建会话并切换为当前。
    @discardableResult
    func newSession() -> ChatSession {
        store.createSession()
    }

    /// 切换当前会话。
    func selectSession(id: UUID) {
        guard store.session(id: id) != nil else { return }
        if isStreaming { abortStreaming() }
        store.currentSessionId = id
    }

    // MARK: - 内部：消息更新

    /// 流式增量：只累积到合帧缓冲区，由 ~50ms 定时器批量写入 store。
    /// 直接丢弃每 token 的 store 写入，避免 @Published sessions 整组扇出与侧栏全量重建。
    private func appendToken(_ token: String, to id: UUID, in sessionId: UUID) {
        pendingTokens += token
        pendingMessageID = id
        pendingSessionID = sessionId
        scheduleFlushIfNeeded()
    }

    /// 思考过程增量：与正文共用同一合帧缓冲区与定时器，同样避免逐片写 store。
    private func appendReasoning(_ token: String, to id: UUID, in sessionId: UUID) {
        pendingReasoning += token
        pendingMessageID = id
        pendingSessionID = sessionId
        scheduleFlushIfNeeded()
    }

    /// 若当前无挂起冲刷，启动一个 ~50ms 的合帧定时任务。
    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.flushInterval ?? 50_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingTokens()
        }
    }

    /// 把合帧缓冲一次性写入 store（不落盘；落盘由单独的持久化点负责）。
    /// 与定时器、forceFlush 均在 MainActor 串行执行，天然无并发竞态。
    private func flushPendingTokens() {
        flushTask = nil
        guard let id = pendingMessageID, let sessionId = pendingSessionID else { return }

        let contentChunk = pendingTokens
        let reasoningChunk = pendingReasoning
        guard !contentChunk.isEmpty || !reasoningChunk.isEmpty else { return }

        pendingTokens = ""
        pendingReasoning = ""
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
        if !sendPathPersisted {
            sendPathPersisted = true
            store.persist(sessionId: sessionId)
        }
    }

    /// 强制冲刷：取消挂起定时器并立即写入缓冲。流结束 / 中止 / 失败三条路径在 settle 前调用，
    /// 保证尾部内容不丢；取消后定时任务的 isCancelled 检查确保不会重复冲刷。
    private func forceFlushPendingTokens() {
        flushTask?.cancel()
        flushTask = nil
        flushPendingTokens()
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

    // MARK: - 内部：请求组装

    /// 组合用户消息：有剪贴板附件时按约定格式拼接。
    private func composeUserContent(input: String, clipboard: String?) -> String {
        guard let clipboard, !clipboard.isEmpty else { return input }
        let clipped = String(clipboard.prefix(clipboardLimit))
        return """
        以下是我附加的剪贴板内容：
        <<<剪贴板开始>>>
        \(clipped)
        <<<剪贴板结束>>>

        我的问题：\(input)
        """
    }

    /// 构造发往服务端的消息数组：system prompt 在最前，上下文按轮截断（system 不参与丢弃）。
    private func buildRequestMessages(for sessionId: UUID) -> [ChatCompletionMessage] {
        var result: [ChatCompletionMessage] = []

        let system = service.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            result.append(ChatCompletionMessage(role: ChatMessage.Role.system.rawValue, content: system))
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

    /// 上下文截断：保留最近 20 轮 / 24000 字符，从最旧整轮丢弃（按会话独立）。
    /// 仅纳入已落定（done）或已中止（aborted）的消息，排除进行中与失败占位。
    private func trimmedContextMessages(in sessionId: UUID) -> [ChatMessage] {
        let eligible = store.messages(in: sessionId).filter { message in
            guard message.role != .system else { return false }
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

        // 从最新一轮向前累计，超预算或超条数即停；至少保留最后一轮。
        var selected: [[ChatMessage]] = []
        var messageCount = 0
        var charCount = 0
        for turn in turns.reversed() {
            let turnChars = turn.reduce(0) { $0 + $1.content.count }
            let exceedsCount = messageCount + turn.count > contextMessageLimit
            let exceedsBudget = !selected.isEmpty && charCount + turnChars > contextCharBudget
            if exceedsCount || exceedsBudget { break }
            selected.append(turn)
            messageCount += turn.count
            charCount += turnChars
        }
        return selected.reversed().flatMap { $0 }
    }

    // MARK: - 内部：LLM 标题摘要

    /// 首轮回复完成后，后台非流式请求生成 ≤12 字中文标题；失败静默保留临时标题。
    private func scheduleTitleSummary(sessionId: UUID) {
        guard let session = store.session(id: sessionId), session.titleNeedsSummary else { return }
        guard let firstUser = session.messages.first(where: { $0.role == .user }),
              // 取首条有正文的落定助手消息作为种子（跳过仅含工具调用的助手消息）。
              let firstAssistant = session.messages.first(where: { $0.role == .assistant && $0.state == .done && !$0.content.isEmpty }) else {
            return
        }

        let seedUser = String(firstUser.content.prefix(500))
        let seedAssistant = String(firstAssistant.content.prefix(500))

        titleTask = Task { [weak self] in
            guard let self else { return }
            let messages = [
                ChatCompletionMessage(
                    role: "system",
                    content: "你是对话标题生成器。请用不超过 12 个汉字概括对话主题，只输出标题本身，不要标点、引号、编号或任何解释。"
                ),
                ChatCompletionMessage(
                    role: "user",
                    content: "用户：\(seedUser)\n助手：\(seedAssistant)\n\n标题："
                )
            ]
            guard let raw = try? await self.service.complete(messages: messages) else { return }
            let title = Self.sanitizeTitle(raw)
            guard !title.isEmpty else { return }
            // 生成期间用户可能已重命名，二次确认后再写入。
            guard let latest = self.store.session(id: sessionId), latest.titleNeedsSummary else { return }
            self.store.setTitle(id: sessionId, title: title, markSummarized: true)
        }
    }

    /// 清洗标题：去换行、引号与 Markdown 标记，截断 12 字。
    private static func sanitizeTitle(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "「」\"'“”《》#*·-"))
        return String(cleaned.prefix(12))
    }

    // MARK: - 流式完成通知

    /// 成功完成一轮回复后触发系统通知（仅在用户没在看对话窗时）。
    /// 触发条件：窗口不可见（失焦被自动隐藏）或窗口虽在但非 key；
    /// 仅 didComplete（自然完成）会调用本方法，abort / 请求失败路径不触发。
    private func notifyCompletionIfNeeded(sessionId: UUID) {
        let manager = AIWindowManager.shared
        if manager.isPanelVisible && manager.isPanelKey { return }

        let session = store.session(id: sessionId)
        let lastAssistant = session?.messages.last(where: { $0.role == .assistant })?.content ?? ""
        let summary = Self.plainSummary(lastAssistant)

        let sessionTitle = session?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var body = sessionTitle.isEmpty ? "回复已完成" : sessionTitle
        if !summary.isEmpty {
            body += "\n" + summary
        }
        AICompletionNotifier.shared.notify(title: "QuickShow AI", body: body)
    }

    /// 通知正文摘要：粗略去 Markdown 标记、折叠空白，截断 ~80 字符。
    private static func plainSummary(_ text: String) -> String {
        var result = text
        for token in ["```", "`", "**", "*", "#", ">", "_", "~"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        return String(result.prefix(80))
    }

    // MARK: - 重试

    /// 重试最后一次请求：移除尾部失败占位，原样重发最后一条 user 消息。
    func retryLast() {
        guard !isStreaming else { return }
        let session = store.ensureCurrentSession()
        let sessionId = session.id
        messagesSnapshotRemoveFailed(in: sessionId)

        guard let lastUser = store.messages(in: sessionId).last(where: { $0.role == .user }) else {
            store.persist(sessionId: sessionId)
            return
        }
        store.removeMessage(id: lastUser.id, in: sessionId)
        inputText = lastUser.content
        imageAttachments = lastUser.images
        send()
    }

    /// 移除当前会话尾部、与本轮重试无关的残留消息：
    /// 尾部失败占位，以及工具回路产生的助手工具调用消息（避免重发后残留孤立 tool_calls）。
    private func messagesSnapshotRemoveFailed(in sessionId: UUID) {
        var staleIDs: [UUID] = []
        for message in store.messages(in: sessionId).reversed() {
            if case .failed = message.state {
                staleIDs.append(message.id)
                continue
            }
            if message.role == .assistant, !(message.toolCalls?.isEmpty ?? true) {
                staleIDs.append(message.id)
                continue
            }
            break
        }
        for id in staleIDs {
            store.removeMessage(id: id, in: sessionId)
        }
    }
}