// AIChatState+SessionEdits.swift
// 职责：最后一轮撤回 / 编辑重发 / 对话导出（自 AIChatState.swift 拆出）。
import Foundation

extension AIChatState {

    // MARK: - 最后一轮撤回 / 编辑重发 / 对话导出

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

        // 回填文本与图片附件（含缩略图），UI 可继续显示与编辑。
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

        // 放回输入暂存后走同一发送链路，重发内容严格等于 UI 传入的文本+图片。
        inputText = text
        imageAttachments = images
        send()
    }

    /// 导出当前会话完整对话为 Markdown 纯文本（供复制到剪贴板）。
    /// 会话标题作一级标题；逐条 user/assistant 消息输出段落标题，正文用动态长度代码围栏包裹，
    /// 避免 Markdown 注入错乱；跳过 sending 占位；末尾附导出时间落款。
    func exportConversationMarkdown() -> String {
        let session = store.currentSession
        let rawTitle = session?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawTitle.isEmpty ? String(localized: "新会话") : rawTitle

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
