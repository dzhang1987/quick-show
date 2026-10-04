import AppKit
import Combine
import Foundation

// MARK: - 待注入输入模型（steering / follow-up 双队列）

/// 一条待注入的用户输入（steering / follow-up 双队列元素）。
/// 仅内存态：不参与会话持久化，注入或中止回填后自然清空。
/// 队列按会话 id 隔离存储于 AIChatState.pendingQueues。
struct QueuedChatInput: Identifiable, Equatable {
    /// 队列类别：决定注入时机与调度优先级。
    /// - steering：转向，在当前回合工具批次全部跑完、下一次 LLM 调用前注入；
    /// - followUp：追问，仅在回合将结束（无更多工具调用）且无 steering 待处理时注入。
    enum Kind: Equatable {
        case steering
        case followUp
    }

    let id: UUID
    let kind: Kind
    let text: String
    let images: [ChatImageAttachment]
}

// MARK: - 上下文压缩信息（UI 契约）

/// 会话上下文压缩信息：供 UI 渲染「已压缩历史」折叠卡。
/// 定义于 AIChatState.swift。
struct CompactionInfo {
    /// 第一条未压缩消息的 id；nil 或找不到时卡片放会话流最顶部。
    let beforeMessageID: String?
    /// 已压缩消息条数。
    let summarizedCount: Int
    /// 摘要全文（折叠卡展开用）。
    let summary: String
}

/// AI 会话门面：串联 ChatSessionStore（多会话数据层）与 AIChatService（网络层），
/// 负责流式发送、中断、重试、图片/剪贴板附加与 LLM 标题摘要。
/// 对外保留旧 AIChatView 的调用点（messages / inputText / isStreaming / send 等），
/// 消息读写全部落到「当前会话」，⌘K 清空语义为清空当前会话消息。
/// 全程 @MainActor，保证网络回调与 SwiftUI 状态更新都落在主线程。
///
/// 并行生成（2026-10 会话并行专项）：流式上下文按会话隔离（streamContexts 字典），
/// 每个会话可独立发起/中止生成，互不干扰；侧栏经 streamingSessionIds 渲染
/// 生成中状态，unreadSessionIds 渲染后台完成未读提示。isStreaming 保持
/// 「当前会话是否生成中」语义（视图层既有调用点不变）。
@MainActor
final class AIChatState: ObservableObject {
    static let shared = AIChatState()

    // MARK: - 公开状态

    /// 当前会话的消息（由 ChatSessionStore 同步而来，供 AIChatView 直接渲染）。
    @Published private(set) var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    /// 行内重命名进行中的会话 id（侧栏 TextField 与快捷键监听共用的稳定真源；nil = 未在重命名）。
    /// 置于 state 层：AIChatState.shared 单例引用恒稳定，keyMonitor 闭包不再捕获 View struct 的
    /// @State 链（结构重构后该捕获链失效导致 ESC 无法消费重命名态）。
    @Published var renamingSessionId: UUID? = nil
    /// 剪贴板附加上下文（非 nil 表示已附加）。
    @Published var clipboardAttachment: String?
    /// 待发送图片附件（Wave 2 附件 UI 消费；发送后清空）。
    @Published var imageAttachments: [ChatImageAttachment] = []
    /// 当前会话是否生成中（视图层旧调用点语义不变；由 syncStreamingState 维护）。
    @Published private(set) var isStreaming: Bool = false
    /// 生成中的会话集合（侧栏状态可视化消费：呼吸点 + 可点击中止）。
    @Published private(set) var streamingSessionIds: Set<UUID> = []
    /// 后台生成完成但用户尚未查看的会话集合（侧栏未读提示；切回会话即清除）。
    @Published private(set) var unreadSessionIds: Set<UUID> = []
    /// 会话级跳底请求（发送时刻）：视图层监听本会话时间戳变化 → 无条件贴底并恢复跟随。
    /// 必须用事件信号而非消息数组 diff：send() 在同一 runloop 连续 append 用户消息与助手占位，
    /// onChange(of: messages.count) 合并为一次渲染帧触发时 last 已是占位，role 判定不可靠。
    @Published var scrollJumpRequests: [UUID: Date] = [:]
    /// 按会话隔离的待注入队列（steering + follow-up 合并存储，元素顺序即入队顺序）。
    /// @Published 供视图/侧栏响应式刷新；对外经 pendingQueue 读取当前会话队列。
    @Published private var pendingQueues: [UUID: [QueuedChatInput]] = [:]
    /// 上下文压缩进行中（UI loading；同时用于防并发/防重复触发）。
    @Published private(set) var isCompacting: Bool = false
    /// 当前会话的压缩摘要信息；nil = 从未压缩过。
    @Published private(set) var compactionInfo: CompactionInfo?

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
    /// 按会话隔离的流式上下文：并行生成的真源（含回路任务与合帧缓冲）。
    private var streamContexts: [UUID: StreamContext] = [:]
    /// 按会话隔离的标题摘要任务（多会话同时完成首轮回复时各自独立生成）。
    private var titleTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// 上一次观察到的会话 id 集合基线：用于检测「会话被删除」并清理其运行时状态。
    private var knownSessionIds: Set<UUID> = []

    // MARK: - 合帧间隔常量

    /// 合帧间隔：约 50ms，把视图失效频率从 token 速率降到 ≤20 次/秒。
    private let flushInterval: UInt64 = 50_000_000

    /// 剪贴板附加的字符上限（超出静默截断）。
    private let clipboardLimit = 8000
    /// 上下文截断：最多保留的 user/assistant 消息条数（100 轮）。
    private let contextMessageLimit = 200
    /// 字符 → token 粗略换算：2 字符 ≈ 1 token（用于水位估算与 token 预算换算）。
    private let charsPerToken = 2
    /// 上下文预算占窗口比例：用满窗口的 80% 作为历史预算，留出输出与工具结果余量。
    private let contextWindowUsageRatio = 0.8
    /// 自动压缩触发水位（已用/窗口）：流结束后水位 ≥ 此值即异步发起压缩。
    private let compactionTriggerRatio = 0.70
    /// 压缩目标水位：一次压到窗口的 40% 以下，避免频繁触发。
    private let compactionTargetRatio = 0.40
    /// 自动压缩至少需要纳入的消息条数（避免碎片化摘要）；手动触发不受此限。
    private let compactionMinMessages = 6
    /// 压缩摘要请求的输出上限（tokens）。
    private let compactionMaxTokens = 2000

    /// 单会话流式上下文：回路 Task、中止标记与合帧缓冲的完整隔离单元。
    /// 生命周期：send() 创建 → 回路结束（落定/中止/失败）时从字典移除。
    private final class StreamContext {
        /// 会话生成回路任务（含工具轮在内的全流程）；abort 即 cancel 该任务。
        var task: Task<Void, Never>?
        /// 用户是否已请求中止本轮生成（中止与超时错误竞争时优先落定为 .aborted）。
        var abortRequested = false
        /// 累积待写入的 token（合帧缓冲区，降低 store/视图失效频率）。
        var pendingTokens = ""
        /// 累积待写入的思考过程增量（与正文共用合帧定时器）。
        var pendingReasoning = ""
        /// 合帧缓冲区对应的助手消息 id。
        var pendingMessageID: UUID?
        /// 合帧冲刷定时任务（~50ms）；nil 表示当前无挂起冲刷。
        var flushTask: Task<Void, Never>?
        /// 发送路径是否已落盘一次（首帧冲刷时落盘，避免发请求前多次写盘）。
        var sendPathPersisted = false
        /// 本轮服务端上报的真实 prompt token 用量（多轮工具调用时以最后一轮为准）。
        var usagePromptTokens: Int?
    }

    /// 各会话最近一次 usage 上报时的消息条数：用于估算其后新增未发送消息的 token 增量。
    /// 仅内存态，重启后缺失不影响真实值读取（此时不再叠加估算）。
    private var usageBaselines: [UUID: Int] = [:]

    // MARK: - 流式状态同步

    /// 由 streamingSessionIds 与当前会话派生 isStreaming（视图旧调用点语义保持）。
    /// 流集合变化、会话切换时统一调用，保证两信号永不脱节。
    private func syncStreamingState() {
        let streaming = currentSessionId.map { streamingSessionIds.contains($0) } ?? false
        if isStreaming != streaming {
            isStreaming = streaming
        }
    }

    /// 当前会话 id（便捷读取，nil 表示尚无会话）。
    private var currentSessionId: UUID? {
        store.currentSessionId
    }

    private init() {
        // 会话数据变化 → 同步当前会话消息到 @Published messages，保持旧视图调用点不变。
        // map 后 removeDuplicates：其他会话的流式冲刷也会令 $sessions 扇出，此处按值去重，
        // 当前会话消息数组未变（值相等）时不再向视图扇出无效更新
        // （ChatMessage 数组相等比较对 COW 共享 String 有 O(1) fast path，成本可控）。
        // 切会话时数组必然不同（消息 id 不同），去重不影响切换同步。
        Publishers.CombineLatest(store.$sessions, store.$currentSessionId)
            .map { sessions, sessionId in
                sessions.first(where: { $0.id == sessionId })?.messages ?? []
            }
            .removeDuplicates()
            .sink { [weak self] messages in
                guard let self else { return }
                self.messages = messages
            }
            .store(in: &cancellables)

        // 会话切换：未读清除 + isStreaming 派生刷新（切换不打断流，见 selectSession）。
        store.$currentSessionId
            .sink { [weak self] sessionId in
                guard let self else { return }
                if let sessionId {
                    self.unreadSessionIds.remove(sessionId)
                }
                self.syncStreamingState()
            }
            .store(in: &cancellables)

        // 会话删除：自动清理被删会话的运行时状态（停回路 + 移除流式/未读标记），
        // 避免回路空转与 unread 永久残留。侧栏 onDelete 直调 store.deleteSession，
        // 此处从会话集合的消失自动检出。以 id 集合 + removeDuplicates 收敛触发频率
        // （流式冲刷不改变 id 集合，不重复扇出）；初始订阅重放时 knownSessionIds 为空，
        // subtracting 结果为空，不会误判为删除。
        store.$sessions
            .map { Set($0.map { $0.id }) }
            .removeDuplicates()
            .sink { [weak self] currentIds in
                guard let self else { return }
                let disappeared = self.knownSessionIds.subtracting(currentIds)
                for id in disappeared {
                    self.abortStreaming(sessionId: id)   // 取消回路任务（走 didComplete=false 分支）
                    self.streamingSessionIds.remove(id)
                    self.unreadSessionIds.remove(id)
                    self.usageBaselines[id] = nil
                }
                self.knownSessionIds = currentIds
            }
            .store(in: &cancellables)

        // 会话数据/当前会话变化 → 重算压缩信息（摘要写入、切会话、清空/撤回后即时刷新）。
        Publishers.CombineLatest(store.$sessions, store.$currentSessionId)
            .sink { [weak self] _, _ in
                self?.refreshCompactionInfo()
            }
            .store(in: &cancellables)
        refreshCompactionInfo()
    }

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

    // MARK: - 会话级模型 / 思考档位（UI 契约）

    /// 当前会话绑定的模型 id；nil = 跟随全局默认模型。
    var currentSessionModelId: String? {
        store.currentSession?.modelId
    }

    /// 当前会话思考档位；nil = 跟随模型默认。
    var currentThinkingLevel: ThinkingLevel? {
        store.currentSession?.thinkingLevel
    }

    /// 上下文水位；nil = 暂无会话/无数据。
    /// usedTokens：优先用会话 contextTokens 真实值（叠加其后新增未发送消息的字符/2 估算）；
    /// 无真实值时对全部消息按字符/2 估算。windowTokens 取当前生效模型的上下文窗口。
    var contextWatermark: ContextWatermark? {
        store.currentSession.flatMap { watermark(for: $0) }
    }

    /// 绑定当前会话模型（空串视为跟随全局默认）；只影响后续请求。
    func setSessionModel(_ modelId: String) {
        guard let sessionId = currentSessionId else { return }
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setSessionModel(id: sessionId, modelId: trimmed.isEmpty ? nil : trimmed)
    }

    /// 设置当前会话思考档位（nil = 跟随模型默认）；只影响后续请求。
    func setThinkingLevel(_ level: ThinkingLevel?) {
        guard let sessionId = currentSessionId else { return }
        store.setThinkingLevel(id: sessionId, level: level)
    }

    /// 指定模型是否支持关闭思考（UI 据此决定是否展示「关闭」档）。
    func canDisableThinking(for modelId: String) -> Bool {
        AIModelAdapter.canDisableThinking(for: modelId)
    }

    /// 会话内「最近一次 usage 之后新增未发送消息」的 token 估算（字符/2）。
    /// 无 baseline（如重启后内存缺失）时按 messages.count 兜底，即不叠加估算。
    private func pendingEstimateTokens(in session: ChatSession) -> Int {
        let baseline = usageBaselines[session.id] ?? session.messages.count
        guard session.messages.count > baseline else { return 0 }
        let tail = session.messages[baseline...]
        let chars = tail.reduce(0) { $0 + $1.content.count }
        return chars / charsPerToken
    }

    /// 全量消息的 token 估算（无真实 usage 时使用）。
    private func estimatedTokens(for messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + $1.content.count } / charsPerToken
    }

    /// 服务层请求选项：会话绑定模型与思考档位（nil 交给服务层回落全局默认）。
    private func requestOptions(for sessionId: UUID) -> AIChatRequestOptions {
        let session = store.session(id: sessionId)
        return AIChatRequestOptions(modelId: session?.modelId, thinkingLevel: session?.thinkingLevel)
    }

    // MARK: - 上下文自动压缩

    /// 手动触发上下文压缩：isCompacting 时忽略；只要有未压缩消息即执行（放宽水位条件）。
    func compactNow() {
        guard !isCompacting else { return }
        guard let sessionId = currentSessionId, let session = store.session(id: sessionId) else { return }
        // 生成中不压缩：避免把半截流式消息标记为已压缩，导致后续增量丢失。
        guard !streamingSessionIds.contains(sessionId) else { return }
        guard hasUnsummarizedMessages(in: session) else { return }
        startCompaction(sessionId: sessionId, manual: true, session: session)
    }

    /// 流结束后异步检查水位：达阈值则发起自动压缩（不阻塞输入）。
    private func maybeAutoCompact(sessionId: UUID) {
        guard !isCompacting else { return }
        guard !streamingSessionIds.contains(sessionId) else { return }
        guard let session = store.session(id: sessionId) else { return }
        guard let wm = watermark(for: session),
              wm.ratio >= compactionTriggerRatio else { return }
        startCompaction(sessionId: sessionId, manual: false, session: session)
    }

    /// 该会话是否存在未压缩消息（手动触发的前置条件）。
    private func hasUnsummarizedMessages(in session: ChatSession) -> Bool {
        let summarized = Set(session.summarizedMessageIDs ?? [])
        return session.messages.contains { !summarized.contains($0.id.uuidString) }
    }

    /// 计算任意会话的水位（contextWatermark 与会话级触发共用）。
    private func watermark(for session: ChatSession) -> ContextWatermark? {
        let effectiveModelId = session.modelId ?? service.selectedModel
        let window = AIModelAdapter.contextWindow(for: effectiveModelId)
        let used: Int
        if let real = session.contextTokens {
            used = real + pendingEstimateTokens(in: session)
        } else {
            used = estimatedTokens(for: session.messages)
        }
        return ContextWatermark(usedTokens: used, windowTokens: window)
    }

    /// 压缩执行计划：待纳入摘要的消息 id（前缀语义）与消息本体。
    private struct CompactionPlan {
        let messageIDs: [String]
        let messages: [ChatMessage]
    }

    /// 计算压缩范围：从最旧未压缩消息起、由旧到新选，直到「剩余未压缩消息（含已有摘要）
    /// 估算 token ≤ window × 40%」。自动触发要求至少 compactionMinMessages 条；手动不受限。
    private func compactionPlan(for session: ChatSession, manual: Bool) -> CompactionPlan {
        let summarized = Set(session.summarizedMessageIDs ?? [])
        var remaining = session.messages.filter { !summarized.contains($0.id.uuidString) }
        guard !remaining.isEmpty else { return CompactionPlan(messageIDs: [], messages: []) }

        let effectiveModelId = session.modelId ?? service.selectedModel
        let window = AIModelAdapter.contextWindow(for: effectiveModelId)
        let budget = Int(Double(window) * compactionTargetRatio)
        let summaryTokens = (session.contextSummary?.count ?? 0) / charsPerToken

        // 从旧到新搬入 selected，直到剩余（含摘要）落入目标水位。
        var selected: [ChatMessage] = []
        while !remaining.isEmpty {
            let remainingTokens = summaryTokens + remaining.reduce(0) { $0 + $1.content.count } / charsPerToken
            if remainingTokens <= budget { break }
            selected.append(remaining.removeFirst())
        }
        // 手动意图优先：若已在目标水位（按目标选择为空），仍压缩最旧一批，兑现「有未压缩消息即可」。
        if selected.isEmpty, manual, !remaining.isEmpty {
            selected.append(contentsOf: remaining.prefix(compactionMinMessages))
        }

        let minimum = manual ? 1 : compactionMinMessages
        guard selected.count >= minimum else { return CompactionPlan(messageIDs: [], messages: []) }
        return CompactionPlan(
            messageIDs: selected.map { $0.id.uuidString },
            messages: selected
        )
    }

    /// 发起压缩任务：置 isCompacting 防并发/重复触发，任务结束后复位。
    private func startCompaction(sessionId: UUID, manual: Bool, session: ChatSession) {
        let plan = compactionPlan(for: session, manual: manual)
        guard !plan.messageIDs.isEmpty else { return }
        isCompacting = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isCompacting = false }
            await self.runCompaction(sessionId: sessionId, plan: plan)
        }
    }

    /// 执行压缩：旧摘要 + 本批消息 → 合并为单份新摘要；成功写回会话，失败静默忽略。
    private func runCompaction(sessionId: UUID, plan: CompactionPlan) async {
        guard let session = store.session(id: sessionId) else { return }
        let prompt = buildCompactionPrompt(existingSummary: session.contextSummary, messages: plan.messages)
        let options = compactionRequestOptions(for: session)
        guard let raw = try? await service.complete(
            messages: prompt,
            options: options,
            maxTokens: compactionMaxTokens
        ) else { return }
        let summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }

        // 应用前二次校验：目标消息仍存在（防止压缩期间清空/撤回导致写错）。
        guard let latest = store.session(id: sessionId) else { return }
        let existingIDs = Set(latest.messages.map { $0.id.uuidString })
        guard plan.messageIDs.allSatisfy({ existingIDs.contains($0) }) else { return }

        // 合并 id（保序去重）：旧摘要 id 保留 + 本批新 id。
        let mergedIDs: [String]
        if let old = latest.summarizedMessageIDs, !old.isEmpty {
            var seen = Set(old)
            var result = old
            for id in plan.messageIDs where !seen.contains(id) {
                seen.insert(id)
                result.append(id)
            }
            mergedIDs = result
        } else {
            mergedIDs = plan.messageIDs
        }
        store.setCompaction(id: sessionId, summary: summary, summarizedMessageIDs: mergedIDs)
        refreshCompactionInfo()
        // 注意：不重置 contextTokens —— 下一次请求的真实 usage 会自然回落，水位随之下降。
    }

    /// 压缩请求选项：优先会话模型；思考尽量关闭，不支持关闭的模型（如 glm-5.3）则跟随默认。
    private func compactionRequestOptions(for session: ChatSession) -> AIChatRequestOptions {
        let requested = session.modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (requested?.isEmpty == false ? requested : nil) ?? service.selectedModel
        let level: ThinkingLevel? = AIModelAdapter.canDisableThinking(for: resolved) ? .off : nil
        return AIChatRequestOptions(modelId: session.modelId, thinkingLevel: level)
    }

    /// 构造压缩提示词：中文、要求合并为单份紧凑摘要（关键事实/决定/待办/代码上下文/未解决问题）。
    private func buildCompactionPrompt(existingSummary: String?, messages: [ChatMessage]) -> [ChatCompletionMessage] {
        let transcript = messages.map { message -> String in
            let role = message.role == .user ? "用户" : "助手"
            var text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, !message.images.isEmpty { text = "（含 \(message.images.count) 张图片）" }
            // 工具调用结果常含代码/文件/搜索结果等关键上下文，截断后纳入，避免只留空助手消息。
            if let calls = message.toolCalls, !calls.isEmpty {
                let lines = calls.map { call -> String in
                    let result = (call.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let clipped = result.count > 400 ? String(result.prefix(400)) + "…" : result
                    return "工具 \(call.name) 结果：\(clipped.isEmpty ? "（无）" : clipped)"
                }
                text += (text.isEmpty ? "" : "\n") + lines.joined(separator: "\n")
            }
            return "\(role)：\(text)"
        }.joined(separator: "\n\n")

        let systemText = """
        你是会话上下文压缩器。请把给定的对话压缩成一份紧凑的中文摘要，供后续对话作为上下文使用。
        要求：保留关键事实、用户偏好与已定决定、待办事项、代码/文件相关要点、未解决的问题；
        删除寒暄、重复与冗余内容；不要编造未出现的信息；只输出摘要正文，不要任何前后缀说明。
        """

        var userText = ""
        if let existingSummary, !existingSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userText += "已有摘要（需要与新对话合并为一份新摘要，避免重复堆积）：\n\(existingSummary)\n\n"
        }
        userText += "需要压缩的新对话：\n\(transcript)\n\n请输出合并后的单份摘要："

        return [
            ChatCompletionMessage(role: "system", content: systemText),
            ChatCompletionMessage(role: "user", content: userText)
        ]
    }

    /// 重算当前会话的压缩信息并刷新 @Published。
    private func refreshCompactionInfo() {
        guard let session = store.currentSession,
              let info = Self.makeCompactionInfo(for: session) else {
            if compactionInfo != nil { compactionInfo = nil }
            return
        }
        // 手工比较关键字段，避免无意义重复扇出。
        if let existing = compactionInfo,
           existing.beforeMessageID == info.beforeMessageID,
           existing.summarizedCount == info.summarizedCount,
           existing.summary == info.summary {
            return
        }
        compactionInfo = info
    }

    /// 由会话派生压缩信息：摘要为空则 nil；beforeMessageID 取首条未压缩消息。
    private static func makeCompactionInfo(for session: ChatSession) -> CompactionInfo? {
        guard let summary = session.contextSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return nil
        }
        let summarized = Set(session.summarizedMessageIDs ?? [])
        let beforeMessageID = session.messages.first { !summarized.contains($0.id.uuidString) }?.id.uuidString
        let count = (session.summarizedMessageIDs ?? []).count
        return CompactionInfo(beforeMessageID: beforeMessageID, summarizedCount: count, summary: summary)
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

    // MARK: - 待注入队列（steering / follow-up 内部实现）

    /// 生成中 ⏎ 的单一收口：把当前输入（含剪贴板附加与图片）作为 steering 入当前会话队列。
    /// UI 层负责清空输入框，此处只入队、不消费输入态。
    private func enqueueSteering() {
        let userInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let clip = clipboardAttachment
        let images = imageAttachments
        guard !userInput.isEmpty || clip != nil || !images.isEmpty else { return }
        guard let sessionId = currentSessionId else { return }
        var content = composeUserContent(input: userInput, clipboard: clip)
        if content.isEmpty, !images.isEmpty { content = "请查看图片。" }
        pendingQueues[sessionId, default: []].append(
            QueuedChatInput(id: UUID(), kind: .steering, text: content, images: images)
        )
    }

    /// 逐条消费队列：移除并返回最早一条指定类别的待注入输入；无则返回 nil。
    /// 以 kind 过滤实现「steering 优先于 follow-up」的调度语义。
    private func dequeuePending(kind: QueuedChatInput.Kind, in sessionId: UUID) -> QueuedChatInput? {
        guard var queue = pendingQueues[sessionId],
              let index = queue.firstIndex(where: { $0.kind == kind }) else { return nil }
        let item = queue.remove(at: index)
        pendingQueues[sessionId] = queue.isEmpty ? nil : queue
        return item
    }

    /// 注入一条待发送输入：追加 user 消息（走 store 既有 mutate+persist 正常落盘）
    /// + 新 assistant 占位（.sending），返回新占位 id；
    /// 后续由调用方以含新消息的上下文发起下一轮请求。
    private func injectPendingInput(
        _ item: QueuedChatInput,
        sessionId: UUID,
        context ctx: StreamContext
    ) -> UUID {
        let userMessage = ChatMessage(role: .user, content: item.text, state: .done, images: item.images)
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

    /// ⌘K 清空当前会话消息（保留会话本身，重置标题待重新摘要）。
    func clearSession() {
        if isStreaming {
            abortStreaming()
        }
        let session = store.ensureCurrentSession()
        store.clearMessages(in: session.id)
        store.resetSessionTitle(id: session.id)
        resetContextWatermark(for: session.id)
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

    /// 切换当前会话（不打断任何会话的进行中生成——并行生成核心语义）。
    /// 未读清除与 isStreaming 派生刷新由 $currentSessionId 订阅统一处理（见 init）。
    func selectSession(id: UUID) {
        guard store.session(id: id) != nil else { return }
        store.currentSessionId = id
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

    // MARK: - 内部：请求组装

    /// 历史被清空/撤回/重编辑时重置真实水位与 baseline：避免旧真实值失真，
    /// 下一次请求的 usage 上报会重新写入。
    private func resetContextWatermark(for sessionId: UUID) {
        store.setContextTokens(id: sessionId, tokens: nil)
        usageBaselines[sessionId] = store.messages(in: sessionId).count
        // 同时重算压缩信息（撤回/编辑后 beforeMessageID 可能变化）。
        refreshCompactionInfo()
    }

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

    /// 构造发往服务端的消息数组：system prompt 在最前，其次为早期对话的压缩摘要，
    /// 最后是未压缩上下文（按 token 水位截断兜底；system 不参与丢弃）。
    private func buildRequestMessages(for sessionId: UUID) -> [ChatCompletionMessage] {
        var result: [ChatCompletionMessage] = []

        let system = service.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            result.append(ChatCompletionMessage(role: ChatMessage.Role.system.rawValue, content: system))
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

        titleTasks[sessionId] = Task { [weak self] in
            defer { self?.titleTasks[sessionId] = nil }
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

// MARK: - steering / follow-up 待注入队列（对外契约）

extension AIChatState {
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

// MARK: - 最后一轮撤回 / 编辑重发 / 对话导出

extension AIChatState {
    /// 当前会话是否正在生成（存在 streaming/sending 状态的 assistant 消息）。
    /// UI 用它做撤回 / 编辑重发等按钮的门控；与 isStreaming 语义一致，但以消息状态为准，
    /// 可覆盖「上下文残留但流集合已清」等边界。
    var isGenerating: Bool {
        messages.contains { message in
            guard message.role == .assistant else { return false }
            switch message.state {
            case .sending, .streaming: return true
            default: return false
            }
        }
    }

    /// 撤回最后一轮：删除当前会话最后一条 user 消息及其之后的所有消息（助手回复、工具轮、失败占位等），
    /// 并把被删 user 消息的文本与图片附件回填到输入框暂存状态，便于继续编辑。
    /// 仅在非生成中且最后一条 user 消息确实存在时生效；成功返回 true。
    @discardableResult
    func withdrawLastRound() -> Bool {
        guard !isGenerating else { return false }
        guard let session = store.currentSession,
              let lastUser = session.messages.last(where: { $0.role == .user }) else {
            return false
        }

        // 一次变更 + 一次落盘，删轮后 JSON 立即同步。
        store.removeMessages(from: lastUser.id, in: session.id)
        resetContextWatermark(for: session.id)

        // 回填文本与图片附件（含缩略图），UI 可继续显示与编辑；剪贴板附加不在此契约内，保持原状。
        inputText = lastUser.content
        imageAttachments = lastUser.images
        return true
    }

    /// 编辑重发最后一轮：把最后一条 user 消息替换为新的文本+附件，删除其后所有消息，
    /// 然后复用 send() 的完整发送链路（上下文组装 + 工具调用回路）自动重发。
    /// 仅在非生成中且存在最后一条 user 消息时生效；空文本且无图片时不动作，避免误删整轮。
    func editAndResendLast(text: String, images: [ChatImageAttachment]) {
        guard !isGenerating else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        guard let session = store.currentSession,
              let lastUser = session.messages.last(where: { $0.role == .user }) else {
            return
        }

        // 删除最后一条 user 消息及其之后的所有消息：随后由 send() 追加全新 user 消息，
        // 等价于「替换该轮并重发」，同时完全复用 send()/appendMessage/startConversationLoop。
        store.removeMessages(from: lastUser.id, in: session.id)
        resetContextWatermark(for: session.id)

        // 放回输入暂存后走同一发送链路；清空剪贴板附加，确保重发内容严格等于 UI 传入的文本+图片。
        inputText = text
        imageAttachments = images
        clipboardAttachment = nil
        send()
    }

    /// 导出当前会话完整对话为 Markdown 纯文本（供复制到剪贴板）。
    /// 会话标题作一级标题；逐条 user/assistant 消息输出段落标题，正文用动态长度代码围栏包裹，
    /// 避免 Markdown 注入错乱；跳过 sending 占位；末尾附导出时间落款。
    func exportConversationMarkdown() -> String {
        let session = store.currentSession
        let rawTitle = session?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawTitle.isEmpty ? "新会话" : rawTitle

        var blocks: [String] = ["# \(title)"]

        for message in session?.messages ?? [] {
            guard message.role == .user || message.role == .assistant else { continue }
            // 跳过发送中占位（无有效内容）；failed 等落定态保留其内容。
            if case .sending = message.state { continue }

            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // 既无正文也无图片（如仅含工具调用的助手占位）不产出空段落。
            guard !content.isEmpty || !message.images.isEmpty else { continue }

            let header = message.role == .user ? "## 🧑 用户" : "## 🤖 助手"
            var lines = [header]
            if !content.isEmpty {
                lines.append(Self.markdownFenced(message.content))
            }
            if message.role == .user, !message.images.isEmpty {
                lines.append("（含 \(message.images.count) 张图片）")
            }
            blocks.append(lines.joined(separator: "\n\n"))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        blocks.append("---\n\n导出时间：\(formatter.string(from: Date()))")

        return blocks.joined(separator: "\n\n")
    }

    /// 用动态长度代码围栏包裹正文：围栏至少 3 个反引号，且比正文中最长的连续反引号串多 1，
    /// 保证正文内含 ``` 时也不会提前闭合围栏。
    private static func markdownFenced(_ text: String) -> String {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + text + "\n" + fence
    }
}