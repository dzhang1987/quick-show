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
    /// 输入历史跟踪器（管理清空状态下上下箭头历史用户消息导航）
    let historyTracker = ChatInputHistoryTracker()
    /// 行内重命名进行中的会话 id（侧栏 TextField 与快捷键监听共用的稳定真源；nil = 未在重命名）。
    /// 置于 state 层：AIChatState.shared 单例引用恒稳定，keyMonitor 闭包不再捕获 View struct 的
    /// @State 链（结构重构后该捕获链失效导致 ESC 无法消费重命名态）。
    @Published var renamingSessionId: UUID? = nil
    /// 就地编辑进行中的消息 id（nil = 未在就地编辑；ESC 优先消费退出编辑态）。
    @Published var editingMessageId: UUID? = nil
    /// 快速会话切换 / 全局搜索面板在场态（Quick Switcher 稳定真源；ESC 优先退出）。
    @Published var isQuickSwitcherPresented: Bool = false
    /// 最近一次关闭 Quick Switcher 的时间戳（防单次 ESC 穿透连击关闭主窗）。
    var lastQuickSwitcherDismissTime: Date = .distantPast
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
    /// 上下文压缩进行中的会话集合（按会话隔离，防并发/防重复触发，杜绝跨会话状态污染）。
    @Published var compactingSessionIds: Set<UUID> = []

    /// 当前会话是否正在进行上下文压缩（门面属性，兼容全局调用）。
    var isCompacting: Bool {
        guard let id = currentSessionId else { return false }
        return compactingSessionIds.contains(id)
    }

    /// 查询指定会话是否正在压缩。
    func isCompacting(sessionId: UUID) -> Bool {
        compactingSessionIds.contains(sessionId)
    }

    /// 获取指定会话的上下文压缩信息（按会话从 store 自洽派生，物理隔离零污染）。
    func compactionInfo(for sessionId: UUID) -> CompactionInfo? {
        guard let session = store.session(id: sessionId) else { return nil }
        return Self.makeCompactionInfo(for: session)
    }

    /// 获取指定会话的压缩特征戳（用于 Equatable diff 与响应式感知，精确感知本会话的压缩变更）。
    func compactionStamp(for sessionId: UUID) -> String {
        let isCompacting = compactingSessionIds.contains(sessionId)
        let info = compactionInfo(for: sessionId)
        let count = info?.summarizedCount ?? 0
        let beforeId = info?.beforeMessageID ?? "none"
        let summaryHash = info?.summary.hashValue ?? 0
        return "\(sessionId.uuidString)|\(isCompacting)|\(count)|\(beforeId)|\(summaryHash)"
    }

    /// 当前会话的压缩摘要信息；nil = 从未压缩过（门面属性）。
    var compactionInfo: CompactionInfo? {
        guard let id = currentSessionId else { return nil }
        return compactionInfo(for: id)
    }
    /// 最近一次压缩结果（成功/失败）；nil = 本运行周期内从未尝试过。
    /// 仅内存态不落盘——反馈语义是「本次使用期间」，跨重启无意义。
    @Published var lastCompactionOutcome: CompactionOutcome?
    /// 是否处于「等待第二次 ESC 确认终止大模型响应」状态（1.5s 有效窗口）。
    @Published var isAwaitingAbortConfirmation: Bool = false
    /// ESC 二次确认窗口代次令牌（GCD 防抖，防旧调度跨世代闭包乱序清除）。
    var abortConfirmationGeneration: Int = 0
    /// 抑制二次确认提醒截止时间（抽屉按 ESC 连带急停后设置短时抑制期，防连击/重复键误弹）。
    var suppressAbortConfirmationUntil: Date = .distantPast

    /// 视觉感知 Observer 先行解析状态提示（供 UI 弱化胶囊展示，nil = 无解析进行中）。
    @Published var observerStatus: String? = nil

    /// 多智能体 Steering 路由反馈提示（如 "已将补充要求转发给【知识检索专家】"）。
    @Published var agentSteeringNotice: String? = nil

    func showAgentSteeringNotice(_ text: String) {
        agentSteeringNotice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if self?.agentSteeringNotice == text {
                self?.agentSteeringNotice = nil
            }
        }
    }

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

    /// 当前生效智能体 id（优先会话绑定，其次新会话草稿暂存，否则全局默认激活智能体）。
    var effectiveAgentId: String {
        store.currentSession?.agentId ?? draftAgentId ?? AIAgentStore.shared.activeAgentId
    }

    /// 当前生效智能体
    var currentAgent: AIAgent {
        AIAgentStore.shared.agent(for: effectiveAgentId) ?? AIAgentStore.shared.activeAgent
    }

    /// 绑定当前会话智能体（新会话草稿态下暂存并同步更新全局激活）
    func setSessionAgent(_ agentId: String?) {
        let trimmed = agentId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (trimmed?.isEmpty == false) ? trimmed : nil
        if let sessionId = currentSessionId {
            store.setSessionAgent(id: sessionId, agentId: resolved)
        } else {
            draftAgentId = resolved
            if let resolved {
                AIAgentStore.shared.activeAgentId = resolved
            }
        }
        objectWillChange.send()
    }

    /// Base URL 与 API Key 均已配置（综合会话生效模型、当前 Agent、全局选中 Provider 与全局回退）。
    var hasConfiguredEndpoint: Bool {
        let session = currentSessionId.flatMap { store.session(id: $0) }
        let effectiveModel = session?.modelId ?? currentAgent.modelId

        // 1. 若当前生效模型明确属于某个已配置 Provider，优先判定
        if let matchedProvider = AIProviderStore.shared.providers.first(where: { $0.models.contains(where: { $0.id == effectiveModel }) }) {
            let key = AIProviderStore.shared.apiKey(for: matchedProvider.id) ?? ""
            if !matchedProvider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !key.isEmpty {
                return true
            }
        }

        // 2. 检查当前 Agent 所属 Provider
        let agent = currentAgent
        if let provider = AIProviderStore.shared.provider(for: agent.providerId) {
            let key = AIProviderStore.shared.apiKey(for: provider.id) ?? ""
            if !provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !key.isEmpty {
                return true
            }
        }

        // 3. 检查全局当前选中的 Provider
        if let selected = AIProviderStore.shared.selectedProvider {
            let key = AIProviderStore.shared.apiKey(for: selected.id) ?? ""
            if !selected.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !key.isEmpty {
                return true
            }
        }

        // 4. 回退检查全局 Base URL 与 Key
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

    /// 新会话草稿态暂存绑定的智能体 ID（nil 则跟随全局激活）
    @Published var draftAgentId: String? = nil
    /// 新会话草稿态暂存绑定的模型 ID（nil 则跟随当前 Agent 默认）
    @Published var draftModelId: String? = nil
    /// 新会话草稿态暂存绑定的思考档位（nil 则跟随模型默认）
    @Published var draftThinkingLevel: ThinkingLevel? = nil

    /// 按会话隔离的输入草稿（key = 会话 id，value = 未发送文本）；非 @Published，
    /// 不参与视图刷新。真源在磁盘 `AIChats/drafts.json`，此处为内存镜像。
    var drafts: [UUID: String] = [:]
    /// 新会话独立未发送草稿（处于新会话草稿态时在此暂存与落盘）。
    var newSessionDraft: String = ""
    /// 标记当前是否正在将草稿转正为正式会话（防转正时 switchDraft 误将首条消息写回 newSessionDraft）。
    var isPromotingDraft = false
    /// 当前 inputText 归属的会话 id（nil 表示新会话草稿态）。
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
    /// 支持传入 targetSessionId 参数解决 Combine @Published willSet 时序先于属性赋值的问题。
    func syncStreamingState(targetSessionId: UUID?? = nil) {
        let targetId = (targetSessionId != nil) ? targetSessionId! : currentSessionId
        let streaming = targetId.map { streamingSessionIds.contains($0) } ?? false
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
        newSessionDraft = store.loadNewSessionDraft()
        draftOwnerSessionId = store.currentSessionId
        if let id = store.currentSessionId, let text = drafts[id] {
            inputText = text
        } else if store.currentSessionId == nil, !newSessionDraft.isEmpty {
            inputText = newSessionDraft
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
                self.syncStreamingState(targetSessionId: .some(sessionId))
                // 会话切换/新对话：危险工具「总是允许」记忆随会话失效（幂等，仅真实切换时清）。
                if sessionChanged {
                    self.editingMessageId = nil
                    self.cancelAbortConfirmation()
                    self.historyTracker.reset()
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

        // 会话数据/当前会话变化 → 广播给观察 AIChatState 的视图实时重绘并重算压缩信息。
        Publishers.CombineLatest(store.$sessions, store.$currentSessionId)
            .sink { [weak self] _, _ in
                self?.objectWillChange.send()
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

    /// 当前会话绑定的模型 id；nil = 跟随全局默认模型（新会话草稿态回退至草稿暂存）。
    var currentSessionModelId: String? {
        store.currentSession?.modelId ?? draftModelId
    }

    /// 当前会话思考档位；nil = 跟随模型默认（新会话草稿态回退至草稿暂存）。
    var currentThinkingLevel: ThinkingLevel? {
        store.currentSession?.thinkingLevel ?? draftThinkingLevel
    }

    /// 上下文水位；nil = 暂无会话/无数据。
    /// usedTokens：优先用会话 contextTokens 真实值（叠加其后新增未发送消息的字符/2 估算）；
    /// 无真实值时对全部消息按字符/2 估算。windowTokens 取当前生效模型的上下文窗口。
    var contextWatermark: ContextWatermark? {
        store.currentSession.flatMap { watermark(for: $0) }
    }

    /// 绑定当前会话模型（空串视为跟随全局默认）；只影响后续请求。
    func setSessionModel(_ modelId: String) {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? nil : trimmed
        if let sessionId = currentSessionId {
            store.setSessionModel(id: sessionId, modelId: resolved)
        } else {
            draftModelId = resolved
        }
        objectWillChange.send()
    }

    /// 设置当前会话思考档位（nil = 跟随模型默认）；只影响后续请求。
    func setThinkingLevel(_ level: ThinkingLevel?) {
        if let sessionId = currentSessionId {
            store.setThinkingLevel(id: sessionId, level: level)
        } else {
            draftThinkingLevel = level
        }
        objectWillChange.send()
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

    /// 服务层请求选项：会话绑定智能体、模型与思考档位（nil 交给服务层回落全局默认）。
    func requestOptions(for sessionId: UUID) -> AIChatRequestOptions {
        let session = store.session(id: sessionId)
        let agentId = session?.agentId ?? effectiveAgentId
        let agent = AIAgentStore.shared.agent(for: agentId) ?? AIAgentStore.shared.activeAgent
        let effectiveModel = session?.modelId ?? agent.modelId
        let effectiveThinking = session?.thinkingLevel ?? agent.thinkingLevel
        return AIChatRequestOptions(modelId: effectiveModel, thinkingLevel: effectiveThinking, agentId: agentId)
    }

    /// 压缩执行计划：待纳入摘要的消息 id（前缀语义）与消息本体。
    struct CompactionPlan {
        let messageIDs: [String]
        let messages: [ChatMessage]
    }

    /// ⌘K 清空当前会话消息（保留会话本身，重置标题待重新摘要；草稿态则清空草稿）。
    func clearSession() {
        editingMessageId = nil
        cancelAbortConfirmation()
        if isStreaming {
            abortStreaming()
        }
        if let session = store.currentSession {
            store.clearMessages(in: session.id)
            store.resetSessionTitle(id: session.id)
            resetContextWatermark(for: session.id)
        } else {
            discardCurrentDraft()
            inputText = ""
        }
    }

    // MARK: - 图片附加

    /// 添加图片附件（Wave 2 拖拽/粘贴入口调用；内部统一转 JPEG base64）。
    func addImageAttachment(_ attachment: ChatImageAttachment) {
        imageAttachments.append(attachment)
        historyTracker.onUserEdited(newText: inputText, newImages: imageAttachments)
    }

    /// 直接由 NSImage 添加图片附件（转换失败返回 false）。
    @discardableResult
    func addImage(_ image: NSImage, fileName: String? = nil) -> Bool {
        guard let attachment = ImageAttachmentProcessor.makeAttachment(from: image, fileName: fileName) else {
            return false
        }
        imageAttachments.append(attachment)
        historyTracker.onUserEdited(newText: inputText, newImages: imageAttachments)
        return true
    }

    func removeImageAttachment(id: UUID) {
        imageAttachments.removeAll { $0.id == id }
        historyTracker.onUserEdited(newText: inputText, newImages: imageAttachments)
    }

    // MARK: - 输入历史快捷导航

    /// 向上切换历史用户消息（清空状态或历史浏览中按 ↑ 触发）：
    /// 成功切换返回 true，未处理（如非空草稿打字中）返回 false 放行原生光标移动。
    @discardableResult
    func navigateInputHistoryUp() -> Bool {
        let result = historyTracker.navigateUp(
            currentText: inputText,
            currentImages: imageAttachments,
            messages: messages
        )
        switch result {
        case .updated(let item):
            inputText = item.content
            imageAttachments = item.images
            return true
        case .unhandled:
            return false
        }
    }

    /// 向下切换历史用户消息（历史浏览中按 ↓ 触发）：
    /// 成功切换返回 true，未处理（如未处于历史浏览中）返回 false 放行原生光标移动。
    @discardableResult
    func navigateInputHistoryDown() -> Bool {
        let result = historyTracker.navigateDown(
            currentText: inputText,
            currentImages: imageAttachments,
            messages: messages
        )
        switch result {
        case .updated(let item):
            inputText = item.content
            imageAttachments = item.images
            return true
        case .unhandled:
            return false
        }
    }

    // MARK: - 会话操作（Wave 2 侧边栏调用）

    /// 新建会话（⌘N 或侧栏按钮）：
    /// 惰性新建：不预先创建空会话文件，进入草稿待命态（currentSessionId = nil）。
    /// 只有在用户输入首条消息并发送时，才真正创建会话，绝不影响后台正在生成的会话。
    func newSession() {
        draftAgentId = nil
        draftModelId = nil
        draftThinkingLevel = nil

        // 若当前已经处于草稿待命态，直接复用当前界面并重新聚焦
        guard store.currentSessionId != nil else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .aiChatRefocusInput, object: nil)
            }
            return
        }

        // 保存切走前的草稿
        flushDraft()

        // 切换到草稿待命态
        store.currentSessionId = nil
        syncStreamingState(targetSessionId: .some(nil))

        // 重新聚焦输入框
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .aiChatRefocusInput, object: nil)
        }
    }

    /// 切换当前会话（不打断任何会话的进行中生成——并行生成核心语义）。
    /// 未读清除、isStreaming 派生刷新与草稿隔离由 $currentSessionId 订阅统一处理（见 init）。
    func selectSession(id: UUID) {
        guard store.session(id: id) != nil else { return }
        draftAgentId = nil
        draftModelId = nil
        draftThinkingLevel = nil
        // 切走前立即落盘旧会话草稿（不等防抖），随后订阅以 switchDraft 载入新会话草稿。
        flushDraft()
        store.currentSessionId = id
        // 关键解耦：延后至下一 runloop 调度输入框聚焦，避免在同个事务内与首帧布局争夺响应者链和输入法 TSM
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .aiChatRefocusInput, object: nil)
        }
    }

    // MARK: - 会话草稿（输入框按会话持久化）

    /// 会话切换的草稿隔离：把 inputText 归属从旧会话迁移到新会话。
    /// 仅在所有 currentSessionId 变更路径（selectSession / newSession / 删会话自动切 / 初始恢复）
    /// 汇合的 $currentSessionId 订阅中调用，保证单点、无遗漏。
    private func switchDraft(to newId: UUID?) {
        let oldId = draftOwnerSessionId
        guard oldId != newId else { return }
        // 旧态保存：旧会话仍存在才回写；若是新会话草稿态 (oldId == nil) 则写回 newSessionDraft 并落盘
        if let oldId {
            if store.session(id: oldId) != nil {
                if !inputText.isEmpty {
                    drafts[oldId] = inputText
                } else {
                    drafts[oldId] = nil
                }
            }
        } else {
            if isPromotingDraft {
                // 正转正为新会话：新会话独立草稿已被转为首条消息消费，彻底清空，绝不回写
                newSessionDraft = ""
                store.persistNewSessionDraft("")
            } else {
                newSessionDraft = inputText
                store.persistNewSessionDraft(inputText)
            }
        }
        draftOwnerSessionId = newId
        if let newId {
            inputText = drafts[newId] ?? ""
        } else {
            inputText = newSessionDraft
        }
    }

    /// 防抖回调：把当前 inputText 写回其归属会话的内存草稿并落盘。
    /// 仅操作 drafts 字典与磁盘，绝不回写 inputText / firstResponder。
    private func saveDraftText(_ text: String) {
        if let owner = draftOwnerSessionId {
            if text.isEmpty {
                drafts[owner] = nil
            } else {
                drafts[owner] = text
            }
            store.persistSessionDrafts(drafts)
        } else {
            newSessionDraft = text
            store.persistNewSessionDraft(text)
        }
    }

    /// 立即把当前 inputText flush 到内存字典与磁盘（不等防抖）。
    /// 触发点：切换会话 / 新建会话 / App 退出。切换后 switchDraft 会改动 inputText，
    /// 从而重置 Combine 防抖计时（pending 的旧值被新值取代，不会串写新会话）。
    private func flushDraft() {
        if let owner = draftOwnerSessionId {
            if inputText.isEmpty {
                drafts[owner] = nil
            } else {
                drafts[owner] = inputText
            }
            store.persistSessionDrafts(drafts)
        } else {
            newSessionDraft = inputText
            store.persistNewSessionDraft(inputText)
        }
    }

    /// 发送 / 追问清空时丢弃当前会话草稿：内存移除 + 磁盘立即同步（不等防抖）。
    /// 由 AIChatState.send() 与视图 clearDraft() 调用，覆盖所有输入消费路径。
    func discardCurrentDraft() {
        if let owner = draftOwnerSessionId {
            drafts[owner] = nil
            store.persistSessionDrafts(drafts)
        }
        // 显式丢弃草稿时，确保新会话独立草稿同步清空（消除残留）
        newSessionDraft = ""
        store.persistNewSessionDraft("")
        historyTracker.reset()
    }

    /// 内置 system 引导：角色定位 + 工具安全边界与 ask_user 纪律。
    /// 仅在 ask_user 工具启用时注入（禁用时不引导模型调用不存在的工具，保持最小侵入）；
    /// 用户自定义 systemPrompt 叠加其后——两者共存，用户配置不会导致内置引导丢失。
    static let builtinSystemGuidance = """
        你是 QuickShow 的 AI 助手，运行在 macOS 原生悬浮输入条上。

        核心职责边界与行为纪律：
        1. 工具安全防线已由系统内核统一接管：
           - QuickShow 客户端内置了严格的原生工具权限治理体系（只读秒级放行、受控变更审批、破坏性高危拦截与一键 Undo 撤销）。
           - 当用户明确要求写入/读取文件、执行 shell 命令或调用其他系统工具时，请直接自主发起对应工具调用，严禁调用 ask_user 重复向用户索要“是否确认执行”。
        2. ask_user 工具仅用于业务需求澄清与方案抉择，仅在以下情况调用：
           - 用户需求存在多种截然不同的架构或实现路线，需要用户做产品/技术抉择；
           - 缺少完成任务的关键业务输入（如命名、账号或目标值）。
        3. 提问时把需要澄清的点合并成一次 ask_user 调用（最多 5 题），单选题务必将最推荐的默认方案置于首位选项。
        4. 用户意图明确时，直接执行解决问题。
        """

    // MARK: - 重试

    /// 重试最后一次请求：
    /// 1. 若尾部失败发生于已执行完毕的工具调用之后（如 launch_subagents），执行智能断点续跑，
    ///    就地刷新最新成果向 LLM 续发总结请求，严禁将先前的工具调用与用户提问整条抹杀。
    /// 2. 若为初始阶段或常规失败，回退重发最后一条 user 消息。
    func retryLast() {
        guard !isStreaming else { return }
        let session = store.ensureCurrentSession()
        let sessionId = session.id

        // 1. 若当前会话是主会话（或派生过子任务），先热刷新一次子任务成果
        AgentCoordinator.shared.refreshSubagentResultsInParent(parentSessionId: sessionId)

        // 2. 检查是否可断点续跑（失败发生于工具完成之后的助手总结阶段）
        let allMessages = store.messages(in: sessionId)
        if let lastMsg = allMessages.last, case .failed = lastMsg.state {
            let priorMessages = allMessages.dropLast()
            if let priorAssistant = priorMessages.last,
               priorAssistant.role == .assistant,
               let toolCalls = priorAssistant.toolCalls,
               !toolCalls.isEmpty,
               toolCalls.allSatisfy({ $0.result != nil }) {
                resumeConversationAfterTools(sessionId: sessionId, failedMessageId: lastMsg.id)
                return
            }
        }

        // 3. 常规失败回退重试：移除尾部失败与残留孤立 tool_calls，原样重发最后一条 user 消息
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
