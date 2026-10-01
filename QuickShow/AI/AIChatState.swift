import AppKit
import Combine
import Foundation

/// AI 会话状态：持有消息列表、流式状态、输入与剪贴板附加，串联 AIChatService。
/// 全程 @MainActor，保证网络回调与 SwiftUI 状态更新都落在主线程。
@MainActor
final class AIChatState: ObservableObject {
    static let shared = AIChatState()

    // MARK: - 数据模型

    struct ChatMessage: Identifiable, Equatable, Codable {
        let id: UUID
        let role: Role
        var content: String
        var state: MessageState

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
    }

    // MARK: - 公开状态

    @Published private(set) var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var clipboardAttachment: String? // 附加后非 nil
    @Published private(set) var isStreaming: Bool = false

    /// Base URL 与 API Key 均已配置。
    var hasConfiguredEndpoint: Bool {
        let base = AIChatService.shared.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = AIChatService.shared.apiKey ?? ""
        return !base.isEmpty && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 私有状态

    private let service = AIChatService.shared
    private var streamTask: Task<Void, Never>?
    /// 用户是否已请求中止本轮生成（用于中止与超时错误竞争时优先落定为 .aborted）。
    private var abortRequested = false

    /// 剪贴板附加的字符上限（超出静默截断）。
    private let clipboardLimit = 8000
    /// 上下文截断：最多保留的 user/assistant 消息条数（20 轮）。
    private let contextMessageLimit = 40
    /// 上下文截断：累计字符预算。
    private let contextCharBudget = 24000

    private init() {
        restoreSession()
    }

    // MARK: - 发送 / 中止

    /// 发送当前输入（含附件的剪贴板上下文）。
    func send() {
        guard !isStreaming else { return }

        let userInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let clip = clipboardAttachment
        guard !userInput.isEmpty || clip != nil else { return }

        guard hasConfiguredEndpoint else {
            appendLocalFailure("尚未配置 AI 服务，请在设置中填写 Base URL 与 API Key。")
            return
        }

        abortRequested = false

        // 1) 追加用户消息（含剪贴板附加），清空输入与附件。
        let userContent = composeUserContent(input: userInput, clipboard: clip)
        messages.append(ChatMessage(id: UUID(), role: .user, content: userContent, state: .done))
        inputText = ""
        clipboardAttachment = nil

        // 2) 追加助手占位（.sending），进入流式态。
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, content: "", state: .sending))
        isStreaming = true

        // 3) 组装请求（注入 system prompt + 截断后的上下文），发起流。
        let requestMessages = buildRequestMessages()
        let stream = service.send(messages: requestMessages)

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await token in stream {
                    self.appendToken(token, to: assistantID)
                }
                self.settle(assistantID, state: .done)
            } catch is CancellationError {
                // 用户主动中止：保留半截回复，落定为 .aborted。
                self.settle(assistantID, state: .aborted)
            } catch {
                // 中止与超时错误竞争时优先落定为用户中止。
                if self.abortRequested {
                    self.settle(assistantID, state: .aborted)
                } else {
                    self.settle(assistantID, state: .failed(error.localizedDescription))
                }
            }
            self.isStreaming = false
            self.persistSession()
        }
    }

    /// 中止流式生成并落定半截回复为 .aborted。
    func abortStreaming() {
        guard isStreaming else { return }
        abortRequested = true
        service.abort()       // 立即停止网络回调
        streamTask?.cancel()  // 触发消费侧 CancellationError，进入 .aborted 分支
    }

    /// ⌘K 清空当前会话（含持久化文件）。
    func clearSession() {
        if isStreaming {
            abortStreaming()
        }
        messages.removeAll()
        persistSession()
    }

    // MARK: - 剪贴板附加

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

    // MARK: - 内部：消息更新

    /// 流式增量：只 mutate 最后一条 assistant 消息的 content（配合稳定 id，SwiftUI 单行 diff）。
    private func appendToken(_ token: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += token
        if messages[index].state == .sending {
            messages[index].state = .streaming
        }
    }

    /// 落定消息状态；仅当仍处于发送中才覆盖，避免覆盖已有失败态。
    private func settle(_ id: UUID, state: ChatMessage.MessageState) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        switch messages[index].state {
        case .sending, .streaming:
            messages[index].state = state
        default:
            break
        }
    }

    /// 本地即时失败（未发起请求，如未配置端点）。
    private func appendLocalFailure(_ text: String) {
        messages.append(
            ChatMessage(id: UUID(), role: .assistant, content: "", state: .failed(text))
        )
        persistSession()
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
    private func buildRequestMessages() -> [ChatCompletionMessage] {
        var result: [ChatCompletionMessage] = []

        let system = service.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            result.append(ChatCompletionMessage(role: ChatMessage.Role.system.rawValue, content: system))
        }
        for message in trimmedContextMessages() {
            result.append(ChatCompletionMessage(role: message.role.rawValue, content: message.content))
        }
        return result
    }

    /// 上下文截断：保留最近 20 轮 / 24000 字符，从最旧整轮丢弃。
    /// 仅纳入已落定（done）或已中止（aborted）的消息，排除进行中与失败占位。
    private func trimmedContextMessages() -> [ChatMessage] {
        let eligible = messages.filter { message in
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

    // MARK: - 内部：持久化

    /// 会话持久化文件：~/Library/Application Support/QuickShow/AIChatSession.json
    private var sessionFileURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appendingPathComponent("QuickShow", isDirectory: true)
            .appendingPathComponent("AIChatSession.json")
    }

    /// 落盘当前会话。每次落定/中止/清空调用；失败静默（会话历史非关键数据）。
    private func persistSession() {
        guard let url = sessionFileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(messages)
            try data.write(to: url, options: .atomic)
        } catch {
            // 静默失败：不打扰用户，不阻塞 UI。
        }
    }

    /// 启动时恢复上次会话；中断在流式中的消息统一落定为 .aborted。
    private func restoreSession() {
        guard let url = sessionFileURL,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return
        }
        messages = stored.map { message in
            var restored = message
            switch restored.state {
            case .sending, .streaming:
                restored.state = .aborted
            default:
                break
            }
            return restored
        }
    }

    // MARK: - 重试（Lane C 视图「重试」按钮调用）

    /// 重试最后一次请求：移除尾部失败占位，原样重发最后一条 user 消息。
    /// 说明：先移除旧 user 消息再 send()，避免 send() 追加新 user 造成消息重复。
    func retryLast() {
        guard !isStreaming else { return }
        while let last = messages.last, case .failed = last.state {
            messages.removeLast()
        }
        guard let index = messages.lastIndex(where: { $0.role == .user }) else {
            persistSession()
            return
        }
        let retryText = messages[index].content
        messages.remove(at: index)
        inputText = retryText
        send()
    }
}