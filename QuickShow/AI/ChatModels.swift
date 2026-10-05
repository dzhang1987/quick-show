// 对话数据模型层：由 ChatSessionStore.swift 顶部模型区整段拆分而来。

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

// MARK: - 工具调用记录

/// 一次工具调用记录（随会话持久化，UI 卡片渲染用）。
/// 说明：字段与工具执行层（ToolCallStatus）对齐；`result` 为工具返回的 JSON 字符串。
struct ToolCallRecord: Codable, Equatable {
    let id: String
    let name: String
    var arguments: String
    var result: String?
    var status: ToolCallStatus
}

// MARK: - 消息模型

/// 单条对话消息。相较于旧版新增 `images` 图片附件、`toolCalls` 工具调用记录、
/// `reasoning` 思考过程与 `isSteered` 转向标记字段，旧数据缺失这些字段时分别按
/// 空数组 / nil 解码，保证向后兼容。
struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: Role
    var content: String
    var state: MessageState
    /// 图片附件（仅用户消息会携带；助手消息恒为空）。
    var images: [ChatImageAttachment]
    /// 助手消息发起的工具调用记录（仅带工具调用的助手消息会携带；普通消息为 nil）。
    var toolCalls: [ToolCallRecord]?
    /// 助手消息的思考过程（reasoning）增量累积；用户消息恒为 nil。
    /// 落定（done/aborted）后保留原值，供 UI 折叠行展开查看。
    var reasoning: String?
    /// 转向注入弱标记：仅经 steering 队列注入的 user 消息为 true（普通发送与
    /// follow-up 注入均为 nil），供 UI 在气泡上方渲染「已转向」弱记号。
    var isSteered: Bool?

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
        images: [ChatImageAttachment] = [],
        toolCalls: [ToolCallRecord]? = nil,
        reasoning: String? = nil,
        isSteered: Bool? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.state = state
        self.images = images
        self.toolCalls = toolCalls
        self.reasoning = reasoning
        self.isSteered = isSteered
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, state, images, toolCalls, reasoning, isSteered
    }

    /// 自定义解码：兼容旧持久化数据（缺失 images / toolCalls / reasoning / isSteered 等新字段）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        state = try container.decode(MessageState.self, forKey: .state)
        images = try container.decodeIfPresent([ChatImageAttachment].self, forKey: .images) ?? []
        // 旧会话无此字段：decodeIfPresent 保证可正常恢复。
        toolCalls = try container.decodeIfPresent([ToolCallRecord].self, forKey: .toolCalls)
        // 旧会话无 reasoning 字段：缺失即 nil，不打断解码。
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        // 旧会话无 isSteered 字段：缺失即 nil（非转向消息，无弱标记），不打断解码。
        isSteered = try container.decodeIfPresent(Bool.self, forKey: .isSteered)
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
    /// 会话绑定的模型 id（nil = 跟随全局默认模型）。
    var modelId: String?
    /// 会话思考档位（nil = 跟随模型默认）。
    var thinkingLevel: ThinkingLevel?
    /// 最近一次请求的真实 prompt token 用量（上下文水位真源；旧会话缺失即 nil）。
    var contextTokens: Int?
    /// 累计上下文摘要文本（多次压缩后仍是合并后的单份；nil = 从未压缩过）。
    var contextSummary: String?
    /// 已纳入摘要的消息 id（前缀语义；旧会话缺失即 nil）。
    var summarizedMessageIDs: [String]?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        pinned: Bool = false,
        titleNeedsSummary: Bool = true,
        messages: [ChatMessage] = [],
        modelId: String? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        contextTokens: Int? = nil,
        contextSummary: String? = nil,
        summarizedMessageIDs: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pinned = pinned
        self.titleNeedsSummary = titleNeedsSummary
        self.messages = messages
        self.modelId = modelId
        self.thinkingLevel = thinkingLevel
        self.contextTokens = contextTokens
        self.contextSummary = contextSummary
        self.summarizedMessageIDs = summarizedMessageIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, pinned, titleNeedsSummary, messages
        case modelId, thinkingLevel, contextTokens, contextSummary, summarizedMessageIDs
    }

    /// 自定义解码：兼容缺省字段（pinned / titleNeedsSummary / messages / 会话级模型、水位与压缩字段）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        titleNeedsSummary = try container.decodeIfPresent(Bool.self, forKey: .titleNeedsSummary) ?? true
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        // 旧 JSON 无这些字段：decodeIfPresent 保证解码不失败。
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        thinkingLevel = try container.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel)
        contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens)
        contextSummary = try container.decodeIfPresent(String.self, forKey: .contextSummary)
        summarizedMessageIDs = try container.decodeIfPresent([String].self, forKey: .summarizedMessageIDs)
    }
}

/// 会话分组：供侧边栏按时间分区渲染（Wave 2 UI 消费）。
struct ChatSessionGroup: Identifiable, Equatable {
    /// 分组标识（pinned / today / yesterday / week / earlier）。
    let id: String
    let title: String
    let sessions: [ChatSession]
}
