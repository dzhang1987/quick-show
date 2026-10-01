import Combine
import Foundation

// MARK: - 图片附件模型

/// 对话消息中的图片附件：统一转 JPEG 后以 base64 保存。
/// 缩略图单独存一份，供列表 / 气泡快速渲染，避免大图解码卡顿。
struct ChatImageAttachment: Identifiable, Equatable, Codable {
    let id: UUID
    /// 原图 JPEG base64（不含 `data:image/jpeg;base64,` 前缀）。
    var base64JPEG: String
    /// 缩略图 JPEG base64（不含前缀，可空）。
    var thumbnailBase64JPEG: String?
    var pixelWidth: Int
    var pixelHeight: Int
    /// 原图字节数（UI 展示体积用）。
    var byteCount: Int
    /// 原始文件名（可空，展示用）。
    var fileName: String?

    init(
        id: UUID = UUID(),
        base64JPEG: String,
        thumbnailBase64JPEG: String? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int,
        fileName: String? = nil
    ) {
        self.id = id
        self.base64JPEG = base64JPEG
        self.thumbnailBase64JPEG = thumbnailBase64JPEG
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.fileName = fileName
    }

    /// OpenAI 兼容的 data URI（vision 请求体用）。
    var dataURI: String { "data:image/jpeg;base64,\(base64JPEG)" }
}

// MARK: - 消息模型

/// 单条对话消息。相较于旧版新增 `images` 图片附件字段，旧数据缺失该字段时按空数组解码。
struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: Role
    var content: String
    var state: MessageState
    /// 图片附件（仅用户消息会携带；助手消息恒为空）。
    var images: [ChatImageAttachment]

    /// 消息角色。system 仅用于请求注入，不进入 UI 会话数组。
    enum Role: String, Codable {
        case system, user, assistant
    }

    /// 消息生命周期状态。
    /// - sending：已占位、等待首 token
    /// - streaming：已收到增量、打字机渲染中
    /// - done：正常落定
    /// - failed：失败，携带用户可读错误文案
    /// - aborted：被用户中止，保留半截内容
    enum MessageState: Equatable, Codable {
        case sending
        case streaming
        case done
        case failed(String)
        case aborted
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        state: MessageState,
        images: [ChatImageAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.state = state
        self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, state, images
    }

    /// 自定义解码：兼容旧持久化数据（缺失 images / titleNeedsSummary 等新字段）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        state = try container.decode(MessageState.self, forKey: .state)
        images = try container.decodeIfPresent([ChatImageAttachment].self, forKey: .images) ?? []
    }
}

// MARK: - 会话模型

/// 单个会话：标题 + 时间戳 + 置顶标记 + 消息列表。每会话独立落盘为一个 JSON 文件。
struct ChatSession: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// 置顶标记（分组排序时置顶优先）。
    var pinned: Bool
    /// 标题是否仍待 LLM 摘要：新会话为 true；用户重命名或摘要完成后置 false。
    var titleNeedsSummary: Bool
    var messages: [ChatMessage]

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        pinned: Bool = false,
        titleNeedsSummary: Bool = true,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pinned = pinned
        self.titleNeedsSummary = titleNeedsSummary
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, pinned, titleNeedsSummary, messages
    }

    /// 自定义解码：兼容缺省字段（pinned / titleNeedsSummary / messages）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        titleNeedsSummary = try container.decodeIfPresent(Bool.self, forKey: .titleNeedsSummary) ?? true
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
    }
}

/// 会话分组：供侧边栏按时间分区渲染（Wave 2 UI 消费）。
struct ChatSessionGroup: Identifiable, Equatable {
    /// 分组标识（pinned / today / yesterday / week / earlier）。
    let id: String
    let title: String
    let sessions: [ChatSession]
}

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

    // MARK: - 内部：加载与迁移

    /// 启动加载：先迁移旧单会话，再读取全部会话文件并恢复当前会话。
    private func load() {
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        migrateLegacyIfNeeded()

        let files = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []

        var loaded: [ChatSession] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ChatSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ChatSession.self, from: data)
            }
        loaded.sort { $0.updatedAt > $1.updatedAt }
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