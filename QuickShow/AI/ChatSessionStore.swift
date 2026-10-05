import Combine
import Foundation

// MARK: - 会话存储

/// 多会话数据层：负责会话的增删改查、分组、搜索与按会话独立落盘。
/// 存储路径：`~/Library/Application Support/QuickShow/AIChats/<uuid>.json`。
/// 首次启动会把旧单会话文件 `AIChatSession.json` 迁移为第一个会话（保留原文件不删除）。
/// 全程 @MainActor，与 AIChatState / 视图同隔离域。
@MainActor
final class ChatSessionStore: ObservableObject {
    static let shared = ChatSessionStore()

    /// 全部会话（内存真源，按需落盘）。
    @Published private(set) var sessions: [ChatSession] = []
    /// 当前选中会话 id；变更即持久化到 UserDefaults。
    @Published var currentSessionId: UUID? {
        didSet { persistCurrentId() }
    }

    private let fileManager = FileManager.default
    /// 每会话文件的目录。
    private let directoryURL: URL
    /// 旧版单会话文件路径。
    private let legacyFileURL: URL
    /// 迁移标记文件（空文件），避免用户删空会话后重复迁移旧数据。
    private let migrationMarkerURL: URL
    /// 当前会话 id 的 UserDefaults 键。
    private let currentIdKey = "ai.currentSessionId"
    /// 草稿文件名：与真实会话文件同目录（`AIChats/drafts.json`），内容为 `[会话UUID字符串: 草稿文本]`。
    /// load() 必须显式跳过，避免被当作会话文件解码。
    static let draftsFileName = "drafts.json"
    /// 草稿文件路径。
    private var draftsFileURL: URL {
        directoryURL.appendingPathComponent(Self.draftsFileName)
    }
    /// 滚动位置文件名（`AIChats/scroll_positions.json`）：`[会话UUID字符串: {top, pinned}]`。
    /// 会话级阅读位置记忆的跨重启持久层（与草稿同款模式）；load() 显式跳过。
    static let scrollPositionsFileName = "scroll_positions.json"
    /// 滚动位置文件路径。
    private var scrollPositionsFileURL: URL {
        directoryURL.appendingPathComponent(Self.scrollPositionsFileName)
    }
    /// 滚动位置的磁盘形态（内存形态 ScrollSnapshot 是视图层私有类型，此处独立 Codable）。
    struct PersistedScrollPosition: Codable {
        /// 离开时视口顶部消息 id（nil = 无锚点，恢复贴底）。
        var topMessageID: UUID?
        /// 离开时是否贴底跟随（true = 恢复贴底，false = 回到锚点）。
        var isPinned: Bool
    }

    private init() {
        let support = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("QuickShow", isDirectory: true)

        let base = support ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directoryURL = base.appendingPathComponent("AIChats", isDirectory: true)
        legacyFileURL = base.appendingPathComponent("AIChatSession.json")
        migrationMarkerURL = directoryURL.appendingPathComponent(".migrated")

        load()
    }

    // MARK: - 查询

    /// 当前会话（无则 nil）。
    var currentSession: ChatSession? {
        guard let id = currentSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    func session(id: UUID) -> ChatSession? {
        sessions.first { $0.id == id }
    }

    func messages(in sessionId: UUID) -> [ChatMessage] {
        session(id: sessionId)?.messages ?? []
    }

    /// 确保存在当前会话：有则返回，无则回退第一个，仍无则新建。
    @discardableResult
    func ensureCurrentSession() -> ChatSession {
        if let current = currentSession { return current }
        if let first = sessions.first {
            currentSessionId = first.id
            return first
        }
        return createSession()
    }

    // MARK: - 增删改

    /// 新建会话并设为当前。title 默认「新会话」（待首条消息生成临时标题）。
    @discardableResult
    func createSession(title: String = "新会话") -> ChatSession {
        let now = Date()
        let session = ChatSession(
            title: title,
            createdAt: now,
            updatedAt: now,
            pinned: false,
            titleNeedsSummary: true,
            messages: []
        )
        sessions.insert(session, at: 0)
        currentSessionId = session.id
        persist(session)
        return session
    }

    /// 删除会话及其落盘文件；若删的是当前会话，自动切到第一个。
    func deleteSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        removeFile(id)
        if currentSessionId == id {
            currentSessionId = sessions.first?.id
        }
    }

    /// 重命名会话（用户主动命名 → 不再走 LLM 摘要）。
    func renameSession(id: UUID, title: String) {
        setTitle(id: id, title: title, markSummarized: true)
    }

    /// 设置标题。`markSummarized` 为 false 时保留「待摘要」标记（用于临时标题）。
    /// `persist` 为 false 时只改内存不落盘（供发送路径合并写盘用）。
    func setTitle(id: UUID, title: String, markSummarized: Bool, persist shouldPersist: Bool = true) {
        mutate(id, persist: shouldPersist) { session in
            session.title = title
            if markSummarized { session.titleNeedsSummary = false }
        }
    }

    /// 清空标题为待摘要状态（⌘K 清空后下一轮重新起标题）。
    func resetSessionTitle(id: UUID) {
        mutate(id, touch: false) { session in
            session.title = "新会话"
            session.titleNeedsSummary = true
        }
    }

    /// 切换置顶。
    func togglePin(id: UUID) {
        mutate(id, touch: false) { $0.pinned.toggle() }
    }

    /// 绑定会话模型（nil = 跟随全局默认）。不 touch updatedAt，只影响后续请求。
    func setSessionModel(id: UUID, modelId: String?) {
        mutate(id, touch: false) { $0.modelId = modelId }
    }

    /// 设置会话思考档位（nil = 跟随模型默认）。不 touch updatedAt，只影响后续请求。
    func setThinkingLevel(id: UUID, level: ThinkingLevel?) {
        mutate(id, touch: false) { $0.thinkingLevel = level }
    }

    /// 记录最近一次请求的真实 prompt token 用量（上下文水位真源）；传 nil 表示失效重置。
    func setContextTokens(id: UUID, tokens: Int?) {
        mutate(id, touch: false) { $0.contextTokens = tokens }
    }

    /// 写入上下文压缩结果（累计摘要 + 已纳入摘要的消息 id）。
    /// 不 touch updatedAt，保持会话列表排序语义不变。
    func setCompaction(id: UUID, summary: String, summarizedMessageIDs: [String]) {
        mutate(id, touch: false) { session in
            session.contextSummary = summary
            session.summarizedMessageIDs = summarizedMessageIDs
        }
    }

    /// 追加一条消息。`persist` 为 false 时只改内存不落盘（供发送路径合并写盘用）。
    func appendMessage(_ message: ChatMessage, to sessionId: UUID, persist shouldPersist: Bool = true) {
        mutate(sessionId, persist: shouldPersist) { $0.messages.append(message) }
    }

    /// 按 id 修改消息内容（流式增量用 persist=false 避免每 token 落盘）。
    func updateMessage(
        id: UUID,
        in sessionId: UUID,
        touch: Bool = false,
        persist shouldPersist: Bool = false,
        _ transform: (inout ChatMessage) -> Void
    ) {
        mutate(sessionId, touch: touch, persist: shouldPersist) { session in
            guard let index = session.messages.firstIndex(where: { $0.id == id }) else { return }
            transform(&session.messages[index])
        }
    }

    /// 替换最后一条助手消息（重新生成场景）。
    func replaceLastAssistantMessage(with message: ChatMessage, in sessionId: UUID) {
        mutate(sessionId) { session in
            if let index = session.messages.lastIndex(where: { $0.role == .assistant }) {
                session.messages[index] = message
            } else {
                session.messages.append(message)
            }
        }
    }

    /// 删除指定消息。
    func removeMessage(id: UUID, in sessionId: UUID) {
        mutate(sessionId) { $0.messages.removeAll { $0.id == id } }
    }

    /// 删除指定消息及其之后的所有消息（撤回/编辑重发最后一轮用；一次变更 + 一次落盘，保证 JSON 立即同步）。
    func removeMessages(from messageId: UUID, in sessionId: UUID) {
        mutate(sessionId) { session in
            guard let index = session.messages.firstIndex(where: { $0.id == messageId }) else { return }
            session.messages.removeSubrange(index...)
        }
    }

    /// 清空指定会话的消息（⌘K 清空语义）。
    func clearMessages(in sessionId: UUID) {
        mutate(sessionId) { $0.messages.removeAll() }
    }

    /// 显式落盘指定会话。
    func persist(sessionId: UUID) {
        guard let session = session(id: sessionId) else { return }
        persist(session)
    }

    // MARK: - 分组与搜索

    /// 分组规则：置顶单独成组（组内按 updatedAt 倒序）；
    /// 其余按更新时间分为「今天 / 昨天 / 过去 7 天 / 更早」，组内同样倒序。
    func groupedSessions() -> [ChatSessionGroup] {
        let sorted = sessions.sorted { $0.updatedAt > $1.updatedAt }

        var groups: [ChatSessionGroup] = []
        let pinned = sorted.filter { $0.pinned }
        if !pinned.isEmpty {
            groups.append(ChatSessionGroup(id: "pinned", title: "置顶", sessions: pinned))
        }

        var remaining = sorted.filter { !$0.pinned }
        func take(_ predicate: (ChatSession) -> Bool) -> [ChatSession] {
            let matched = remaining.filter(predicate)
            remaining.removeAll(where: predicate)
            return matched
        }

        let today = take { Calendar.current.isDateInToday($0.updatedAt) }
        if !today.isEmpty {
            groups.append(ChatSessionGroup(id: "today", title: "今天", sessions: today))
        }

        let yesterday = take { Calendar.current.isDateInYesterday($0.updatedAt) }
        if !yesterday.isEmpty {
            groups.append(ChatSessionGroup(id: "yesterday", title: "昨天", sessions: yesterday))
        }

        let week = take { Self.isWithinLastWeek($0.updatedAt) }
        if !week.isEmpty {
            groups.append(ChatSessionGroup(id: "week", title: "过去 7 天", sessions: week))
        }

        if !remaining.isEmpty {
            groups.append(ChatSessionGroup(id: "earlier", title: "更早", sessions: remaining))
        }
        return groups
    }

    /// 全文搜索：标题或消息内容命中（忽略大小写），按 updatedAt 倒序返回。
    func search(_ query: String) -> [ChatSession] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return [] }
        return sessions.filter { session in
            if session.title.lowercased().contains(keyword) { return true }
            return session.messages.contains { $0.content.lowercased().contains(keyword) }
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 由首条用户消息截断出的临时标题（~20 字）。
    static func makeTemporaryTitle(from text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "新会话" }
        return String(cleaned.prefix(20))
    }

    // MARK: - 内部：分组辅助

    private static func isWithinLastWeek(_ date: Date) -> Bool {
        let calendar = Calendar.current
        guard let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date())) else {
            return false
        }
        return date >= weekStart
    }

    // MARK: - 内部：变更与落盘

    /// 统一变更入口：改内存 → 可选 touch updatedAt → 可选落盘。
    private func mutate(
        _ id: UUID,
        touch: Bool = true,
        persist shouldPersist: Bool = true,
        _ transform: (inout ChatSession) -> Void
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        transform(&sessions[index])
        if touch { sessions[index].updatedAt = Date() }
        if shouldPersist { persist(sessions[index]) }
    }

    private func persist(_ session: ChatSession) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(session)
            try data.write(to: fileURL(for: session.id), options: .atomic)
        } catch {
            // 静默失败：会话历史非关键数据，不阻塞 UI。
        }
    }

    private func removeFile(_ id: UUID) {
        try? fileManager.removeItem(at: fileURL(for: id))
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func persistCurrentId() {
        if let id = currentSessionId {
            UserDefaults.standard.set(id.uuidString, forKey: currentIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: currentIdKey)
        }
    }

    // MARK: - 会话草稿落盘

    /// 读取全部会话草稿。key 非法或 value 为空的条目直接丢弃；文件不存在 / 解码失败返回空。
    func loadSessionDrafts() -> [UUID: String] {
        guard let data = try? Data(contentsOf: draftsFileURL),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        var result: [UUID: String] = [:]
        for (key, value) in raw {
            guard !value.isEmpty, let id = UUID(uuidString: key) else { continue }
            result[id] = value
        }
        return result
    }

    /// 原子写全部会话草稿（空 value 的条目不下盘，等价于该会话无草稿）。
    /// 与 persist(_:) 同款：createDirectory + JSONEncoder + `.atomic`。
    func persistSessionDrafts(_ drafts: [UUID: String]) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let raw = Dictionary(uniqueKeysWithValues: drafts.compactMap { entry -> (String, String)? in
                entry.value.isEmpty ? nil : (entry.key.uuidString, entry.value)
            })
            let data = try JSONEncoder().encode(raw)
            try data.write(to: draftsFileURL, options: .atomic)
        } catch {
            // 静默失败：草稿非关键数据，不阻塞输入。
        }
    }

    // MARK: - 会话滚动位置落盘

    /// 读取全部会话滚动位置。key 非法条目丢弃；文件不存在 / 解码失败返回空。
    func loadScrollPositions() -> [UUID: PersistedScrollPosition] {
        guard let data = try? Data(contentsOf: scrollPositionsFileURL),
              let raw = try? JSONDecoder().decode([String: PersistedScrollPosition].self, from: data) else {
            return [:]
        }
        var result: [UUID: PersistedScrollPosition] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key) else { continue }
            result[id] = value
        }
        return result
    }

    /// 原子写全部会话滚动位置（视图层在切走/卸载等低频时机调用）。
    /// 静默失败：位置记忆非关键数据，恢复路径有贴底兜底。
    func persistScrollPositions(_ positions: [UUID: PersistedScrollPosition]) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let raw = Dictionary(uniqueKeysWithValues: positions.map { ($0.key.uuidString, $0.value) })
            let data = try JSONEncoder().encode(raw)
            try data.write(to: scrollPositionsFileURL, options: .atomic)
        } catch {
            // 静默失败。
        }
    }

    // MARK: - 内部：加载与迁移

    /// 启动加载：先迁移旧单会话，再读取全部会话文件并恢复当前会话。
    private func load() {
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        migrateLegacyIfNeeded()

        let files = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []

        // 显式跳过草稿文件：drafts.json 与真实会话同目录，若不排除会被尝试解码为 ChatSession
        // （当前靠解码失败静默跳过，属隐式依赖）。显式排除更确定，也为草稿数据语义正名。
        // scroll_positions.json 同理（滚动位置持久层）。
        var loaded: [ChatSession] = files
            .filter { $0.pathExtension == "json"
                && $0.lastPathComponent != Self.draftsFileName
                && $0.lastPathComponent != Self.scrollPositionsFileName }
            .compactMap { url -> ChatSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ChatSession.self, from: data)
            }
        loaded.sort { $0.updatedAt > $1.updatedAt }
        // 按 id 去重：重复 id 会使侧栏 ForEach 身份域冲突（两条行同时呈选中态）并扰乱右侧常驻层渲染。
        // 仅加载时收敛——已按 updatedAt 降序排序，取首次出现即保留最新那条；运行时 mutate 路径不变。
        var seenIds = Set<UUID>()
        loaded = loaded.filter { seenIds.insert($0.id).inserted }
        sessions = loaded

        let stored = UserDefaults.standard.string(forKey: currentIdKey).flatMap(UUID.init(uuidString:))
        if let stored, loaded.contains(where: { $0.id == stored }) {
            currentSessionId = stored
        } else {
            currentSessionId = loaded.first?.id
        }
    }

    /// 旧文件迁移：仅尝试一次（标记文件）；迁移后保留旧文件不删除。
    private func migrateLegacyIfNeeded() {
        guard !fileManager.fileExists(atPath: migrationMarkerURL.path) else { return }
        defer { try? Data().write(to: migrationMarkerURL) }

        guard fileManager.fileExists(atPath: legacyFileURL.path),
              let data = try? Data(contentsOf: legacyFileURL),
              let stored = try? JSONDecoder().decode([ChatMessage].self, from: data),
              !stored.isEmpty else {
            return
        }

        // 中断在流式中的消息统一落定为 .aborted（沿用旧恢复逻辑）。
        let restored = stored.map { message -> ChatMessage in
            var copy = message
            switch copy.state {
            case .sending, .streaming:
                copy.state = .aborted
            default:
                break
            }
            return copy
        }

        let firstUser = restored.first { $0.role == .user }?.content ?? ""
        let now = Date()
        let session = ChatSession(
            title: Self.makeTemporaryTitle(from: firstUser),
            createdAt: now,
            updatedAt: now,
            pinned: false,
            titleNeedsSummary: true,
            messages: restored
        )
        sessions = [session]
        persist(session)
        currentSessionId = session.id
    }
}