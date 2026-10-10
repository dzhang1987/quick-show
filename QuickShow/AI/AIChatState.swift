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
    /// 已压缩消息 id 集合：消息流行级降档（透明度弱化）的判定数据源。
    let summarizedIDs: Set<String>
}

// MARK: - 压缩结果反馈（UI 契约）

/// 最近一次上下文压缩的结果：成功（会话 + 本次条数 + 时间戳）/ 失败（会话 + 原因简述）。
/// 压缩原先是「失败静默」路径（runCompaction 各 guard 直接 return），用户无从感知；
/// 此状态供两处消费：视口内即时 toast（边沿触发、弹完即走）+ 水位圆环详情卡的持久行。
enum CompactionOutcome: Equatable {
    /// 成功：本次压缩的消息条数（非累计值）+ 完成时间戳（兼作 toast 去重标识）。
    case succeeded(sessionId: UUID, count: Int, at: Date)
    /// 失败：一句中文原因简述（服务请求失败 / 空摘要 / 会话已变化）。
    case failed(sessionId: UUID, reason: String)
}

/// AI 会话门面：串联 ChatSessionStore（多会话数据层）与 AIChatService（网络层），
/// 负责流式发送、中断、重试、图片附加与 LLM 标题摘要。
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
    /// 待发送图片附件（Wave 2 附件 UI 消费；发送后清空）。
    @Published var imageAttachments: [ChatImageAttachment] = []
    /// 当前会话是否生成中（视图层旧调用点语义不变；由 syncStreamingState 维护）。
    @Published private(set) var isStreaming: Bool = false
    /// 生成中的会话集合（侧栏状态可视化消费：呼吸点 + 可点击中止）。
    @Published var streamingSessionIds: Set<UUID> = []
    /// 后台生成完成但用户尚未查看的会话集合（侧栏未读提示；切回会话即清除）。
    @Published var unreadSessionIds: Set<UUID> = []
    /// 会话级跳底请求（发送时刻）：视图层监听本会话时间戳变化 → 无条件贴底并恢复跟随。
    /// 必须用事件信号而非消息数组 diff：send() 在同一 runloop 连续 append 用户消息与助手占位，
    /// onChange(of: messages.count) 合并为一次渲染帧触发时 last 已是占位，role 判定不可靠。
    @Published var scrollJumpRequests: [UUID: Date] = [:]
    /// 按会话隔离的待注入队列（steering + follow-up 合并存储，元素顺序即入队顺序）。
    /// @Published 供视图/侧栏响应式刷新；对外经 pendingQueue 读取当前会话队列。
    @Published var pendingQueues: [UUID: [QueuedChatInput]] = [:]
    /// 上下文压缩进行中（UI loading；同时用于防并发/防重复触发）。
    @Published var isCompacting: Bool = false
    /// 当前会话的压缩摘要信息；nil = 从未压缩过。
    @Published var compactionInfo: CompactionInfo?
    /// 最近一次压缩结果（成功/失败）；nil = 本运行周期内从未尝试过。
    /// 仅内存态不落盘——反馈语义是「本次使用期间」，跨重启无意义。
    @Published var lastCompactionOutcome: CompactionOutcome?
    /// 是否处于「等待第二次 ESC 确认终止大模型响应」状态（1.5s 有效窗口）。
    @Published var isAwaitingAbortConfirmation: Bool = false
    var abortConfirmationTimer: Timer?

    /// 当前会话的最近一次压缩结果；非当前会话的结果不回传——自动压缩在流结束后
    /// 异步触发，用户可能已切换会话，跨会话的 toast/详情行会错位（防串会话反馈）。
    var currentSessionOutcome: CompactionOutcome? {
        guard let outcome = lastCompactionOutcome else { return nil }
        switch outcome {
        case .succeeded(let sessionId, _, _), .failed(let sessionId, _):
            return sessionId == store.currentSessionId ? outcome : nil
        }
    }

    /// 多会话数据层（Wave 2 侧边栏消费其分组 / 搜索 / 增删改 API）。
    let store = ChatSessionStore.shared

    /// Base URL 与 API Key 均已配置。
    var hasConfiguredEndpoint: Bool {
        let base = AIChatService.shared.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = AIChatService.shared.apiKey ?? ""
        return !base.isEmpty && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 私有状态

    let service = AIChatService.shared
    /// 按会话隔离的流式上下文：并行生成的真源（含回路任务与合帧缓冲）。
    var streamContexts: [UUID: StreamContext] = [:]
    /// 按会话隔离的标题摘要任务（多会话同时完成首轮回复时各自独立生成）。
    var titleTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// 上一次观察到的会话 id 集合基线：用于检测「会话被删除」并清理其运行时状态。
    var knownSessionIds: Set<UUID> = []

    /// 按会话隔离的输入草稿（key = 会话 id，value = 未发送文本）；非 @Published，
    /// 不参与视图刷新。真源在磁盘 `AIChats/drafts.json`，此处为内存镜像。
    var drafts: [UUID: String] = [:]
    /// 当前 inputText 归属的会话 id（切换会话时据此把旧会话草稿落回 drafts）。
    private var draftOwnerSessionId: UUID?
    /// 草稿防抖间隔（Combine debounce）。
    private let draftDebounceInterval: TimeInterval = 0.5

    // MARK: - 合帧间隔常量

    /// 合帧间隔：约 50ms，把视图失效频率从 token 速率降到 ≤20 次/秒。
    let flushInterval: UInt64 = 50_000_000

    /// 上下文截断：最多保留的 user/assistant 消息条数（100 轮）。
    let contextMessageLimit = 200
    /// 字符 → token 粗略换算：2 字符 ≈ 1 token（用于水位估算与 token 预算换算）。
    let charsPerToken = 2
    /// 上下文预算占窗口比例：用满窗口的 80% 作为历史预算，留出输出与工具结果余量。
    let contextWindowUsageRatio = 0.8
    /// 自动压缩触发水位（已用/窗口）：流结束后水位 ≥ 此值即异步发起压缩。
    let compactionTriggerRatio = 0.70
    /// 压缩目标水位：一次压到窗口的 40% 以下，避免频繁触发。
    let compactionTargetRatio = 0.40
    /// 自动压缩至少需要纳入的消息条数（避免碎片化摘要）；手动触发不受此限。
    let compactionMinMessages = 6
    /// 压缩摘要请求的输出上限（tokens）。
    let compactionMaxTokens = 2000

    /// 单会话流式上下文：回路 Task、中止标记与合帧缓冲的完整隔离单元。
    /// 生命周期：send() 创建 → 回路结束（落定/中止/失败）时从字典移除。
    final class StreamContext {
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
    var usageBaselines: [UUID: Int] = [:]

    // MARK: - 流式状态同步

    /// 由 streamingSessionIds 与当前会话派生 isStreaming（视图旧调用点语义保持）。
    /// 流集合变化、会话切换时统一调用，保证两信号永不脱节。
    func syncStreamingState() {
        let streaming = currentSessionId.map { streamingSessionIds.contains($0) } ?? false
        if isStreaming != streaming {
            isStreaming = streaming
            if !streaming {
                cancelAbortConfirmation()
            }
        }
    }

    /// 当前会话 id（便捷读取，nil 表示尚无会话）。
    var currentSessionId: UUID? {
        store.currentSessionId
    }

    private init() {
        // 草稿恢复：store 已在属性初始化阶段完成 load()，此处先读草稿文件、建立
        // 「当前 inputText 归属会话」基线并回填，再挂订阅——初始 inputText 已就位，
        // 配合下方 inputText 订阅的 dropFirst，避免初始空值被防抖回写覆盖磁盘草稿。
        drafts = store.loadSessionDrafts()
        draftOwnerSessionId = store.currentSessionId
        if let id = store.currentSessionId, let text = drafts[id] {
            inputText = text
        }

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

        // 会话切换：草稿隔离 + 未读清除 + isStreaming 派生刷新（切换不打断流，见 selectSession）。
        // 草稿切换收口在此单一订阅：selectSession / newSession / deleteSession 自动切会话 /
        // ensureCurrentSession 兜底建会话等所有 currentSessionId 变更路径都会经过这里。
        store.$currentSessionId
            .sink { [weak self] sessionId in
                guard let self else { return }
                // switchDraft 会更新 draftOwnerSessionId；先取旧值判定「是否真的换了会话」，
                // 避免重复点击当前会话时误清空「总是允许」记忆（首次订阅重放也不算切换）。
                let sessionChanged = self.draftOwnerSessionId != sessionId
                self.switchDraft(to: sessionId)
                if let sessionId {
                    self.unreadSessionIds.remove(sessionId)
                }
                self.syncStreamingState()
                // 会话切换/新对话：危险工具「总是允许」记忆随会话失效（幂等，仅真实切换时清）。
                if sessionChanged {
                    ChatInteractionCenter.shared.resetSessionMemory()
                }
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
                var draftsChanged = false
                for id in disappeared {
                    self.abortStreaming(sessionId: id)   // 取消回路任务（走 didComplete=false 分支）
                    self.streamingSessionIds.remove(id)
                    self.unreadSessionIds.remove(id)
                    self.usageBaselines[id] = nil
                    // 会话被删 → 同步清理其草稿（内存 + 磁盘），避免 drafts.json 残留孤儿键。
                    if self.drafts.removeValue(forKey: id) != nil { draftsChanged = true }
                }
                self.knownSessionIds = currentIds
                if draftsChanged { self.store.persistSessionDrafts(self.drafts) }
            }
            .store(in: &cancellables)

        // 会话数据/当前会话变化 → 重算压缩信息（摘要写入、切会话、清空/撤回后即时刷新）。
        Publishers.CombineLatest(store.$sessions, store.$currentSessionId)
            .sink { [weak self] _, _ in
                self?.refreshCompactionInfo()
            }
            .store(in: &cancellables)

        // 草稿防抖落盘：inputText 变化后 ~0.5s 写盘。dropFirst 跳过订阅重放的初始值
        // （恢复阶段已在 init 顶部就位，无需回写）；回调只落内存字典 + 磁盘，不回写
        // inputText、不触碰 firstResponder，杜绝与 NSTextView 输入链互相干扰。
        $inputText
            .dropFirst()
            .debounce(for: .seconds(draftDebounceInterval), scheduler: DispatchQueue.main)
            .sink { [weak self] text in
                self?.saveDraftText(text)
            }
            .store(in: &cancellables)

        // App 退出：立即 flush 当前草稿，避免防抖窗口内的最后编辑丢失。
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.flushDraft()
            }
            .store(in: &cancellables)

        refreshCompactionInfo()
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
    func pendingEstimateTokens(in session: ChatSession) -> Int {
        let baseline = usageBaselines[session.id] ?? session.messages.count
        guard session.messages.count > baseline else { return 0 }
        let tail = session.messages[baseline...]
        let chars = tail.reduce(0) { $0 + $1.content.count }
        return chars / charsPerToken
    }

    /// 全量消息的 token 估算（无真实 usage 时使用）。
    func estimatedTokens(for messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + $1.content.count } / charsPerToken
    }

    /// 服务层请求选项：会话绑定模型与思考档位（nil 交给服务层回落全局默认）。
    func requestOptions(for sessionId: UUID) -> AIChatRequestOptions {
        let session = store.session(id: sessionId)
        return AIChatRequestOptions(modelId: session?.modelId, thinkingLevel: session?.thinkingLevel)
    }

    /// 压缩执行计划：待纳入摘要的消息 id（前缀语义）与消息本体。
    struct CompactionPlan {
        let messageIDs: [String]
        let messages: [ChatMessage]
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

    // MARK: - 图片附加

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
    /// 先 flush 旧会话草稿，再交由 createSession → $currentSessionId 订阅完成新会话草稿隔离。
    @discardableResult
    func newSession() -> ChatSession {
        flushDraft()
        return store.createSession()
    }

    /// 切换当前会话（不打断任何会话的进行中生成——并行生成核心语义）。
    /// 未读清除、isStreaming 派生刷新与草稿隔离由 $currentSessionId 订阅统一处理（见 init）。
    func selectSession(id: UUID) {
        guard store.session(id: id) != nil else { return }
        // 切走前立即落盘旧会话草稿（不等防抖），随后订阅以 switchDraft 载入新会话草稿。
        flushDraft()
        store.currentSessionId = id
    }

    // MARK: - 会话草稿（输入框按会话持久化）

    /// 会话切换的草稿隔离：把 inputText 归属从旧会话迁移到新会话。
    /// 仅在所有 currentSessionId 变更路径（selectSession / newSession / 删会话自动切 / 初始恢复）
    /// 汇合的 $currentSessionId 订阅中调用，保证单点、无遗漏。
    private func switchDraft(to newId: UUID?) {
        let oldId = draftOwnerSessionId
        guard oldId != newId else { return }
        // 旧会话仍存在才回写：会话已删时由 $sessions 订阅负责清理，避免此处复活孤儿草稿。
        if let oldId, !inputText.isEmpty, store.session(id: oldId) != nil {
            drafts[oldId] = inputText
        }
        draftOwnerSessionId = newId
        inputText = newId.flatMap { drafts[$0] } ?? ""
    }

    /// 防抖回调：把当前 inputText 写回其归属会话的内存草稿并落盘。
    /// 仅操作 drafts 字典与磁盘，绝不回写 inputText / firstResponder。
    private func saveDraftText(_ text: String) {
        guard let owner = draftOwnerSessionId else { return }
        if text.isEmpty {
            drafts[owner] = nil
        } else {
            drafts[owner] = text
        }
        store.persistSessionDrafts(drafts)
    }

    /// 立即把当前 inputText flush 到内存字典与磁盘（不等防抖）。
    /// 触发点：切换会话 / 新建会话 / App 退出。切换后 switchDraft 会改动 inputText，
    /// 从而重置 Combine 防抖计时（pending 的旧值被新值取代，不会串写新会话）。
    private func flushDraft() {
        guard let owner = draftOwnerSessionId else { return }
        if inputText.isEmpty {
            drafts[owner] = nil
        } else {
            drafts[owner] = inputText
        }
        store.persistSessionDrafts(drafts)
    }

    /// 发送 / 追问清空时丢弃当前会话草稿：内存移除 + 磁盘立即同步（不等防抖）。
    /// 由 AIChatState.send() 与视图 clearDraft() 调用，覆盖所有输入消费路径。
    func discardCurrentDraft() {
        guard let owner = draftOwnerSessionId else { return }
        drafts[owner] = nil
        store.persistSessionDrafts(drafts)
    }

    /// 内置 system 引导：角色定位 + ask_user 互动纪律。
    /// 仅在 ask_user 工具启用时注入（禁用时不引导模型调用不存在的工具，保持最小侵入）；
    /// 用户自定义 systemPrompt 叠加其后——两者共存，用户配置不会导致内置引导丢失
    /// （引导管行为纪律，用户文案管个性化任务，职责不重叠）。
    /// 纪律采用「必问触发清单（或）+ 豁免条件（与）+ 拿不准视为不满足」结构：
    /// 举证责任反转——默认必须先问，只有逐条核对豁免条件全部满足才允许直接做，
    /// 避免形容词化规则被模型自行放宽（尤其在拼接行动派人格的自定义 prompt 时）。
    static let builtinSystemGuidance = """
        你是 QuickShow 的 AI 助手，运行在 macOS 悬浮输入条上。

        互动纪律（默认先确认，满足豁免条件才直接做）：
        - 出现以下任一情况，必须先调用 ask_user 工具向用户确认，没有例外：
          ① 你在两种以上都合理的做法之间犹豫过（哪怕一瞬间）——犹豫即分支；
          ② 操作有副作用：写/删文件、执行命令、改配置等不可逆或影响系统的行为；
          ③ 用户意图存在一种以上合理理解；
          ④ 缺少完成任务的必要信息（路径、命名、目标值等）。
        - 只有同时满足以下全部条件，才允许跳过提问直接执行：
          ① 执行路径唯一；② 操作无副作用且可逆；③ 用户指令已包含全部必要信息。
          拿不准算不算满足时，一律视为不满足，回到先问。
        - 提问时把需要澄清的点合并成一次 ask_user 调用（最多 5 题），避免反复打扰；
          每题给出 2-6 个具体选项（单选或复选），用户也可能会直接输入答案。
        - 用户已明确表达「直接做」时，以上纪律豁免，直接执行。
        """

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
