// AIChatState+Notifications.swift
// 职责：LLM 标题摘要与流式完成系统通知（自 AIChatState.swift 拆出）。
import Foundation

extension AIChatState {

    // MARK: - 内部：LLM 标题摘要

    /// 以用户首条提问为输入，后台非流式请求大模型提炼主题标题；单次闭环，失败静默保留临时标题。
    func scheduleTitleSummary(sessionId: UUID, userInput: String? = nil) {
        guard let session = store.session(id: sessionId), session.titleNeedsSummary else { return }
        guard titleTasks[sessionId] == nil else { return }

        let rawUser = userInput ?? session.messages.first(where: { $0.role == .user })?.content ?? ""
        let seedUser = String(rawUser.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seedUser.isEmpty else { return }

        titleTasks[sessionId] = Task { [weak self] in
            defer { self?.titleTasks[sessionId] = nil }
            guard let self else { return }
            let messages = [
                ChatCompletionMessage(
                    role: "system",
                    content: "你是对话标题生成器。请根据用户的输入，提炼出简明扼要的对话主题。要求：不超过 10 个汉字（英文 2~4 个单词），语义完整，直接输出标题本身，严禁任何标点符号、引号、序号或解释说明。"
                ),
                ChatCompletionMessage(
                    role: "user",
                    content: "用户输入：\(seedUser)\n\n标题："
                )
            ]
            guard let raw = try? await self.service.complete(messages: messages) else { return }
            let title = Self.sanitizeTitle(raw)
            guard !title.isEmpty else { return }
            // 生成期间用户可能已手动重命名，二次确认后再写入。
            guard let latest = self.store.session(id: sessionId), latest.titleNeedsSummary else { return }
            self.store.setTitle(id: sessionId, title: title, markSummarized: true)
        }
    }

    /// 清洗标题：去换行、引号与标点符号，保留完整语义；仅在异常超长时平滑截断。
    private static func sanitizeTitle(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "「」\"'“”《》#*·-：:。，,!！?？"))
        guard !cleaned.isEmpty else { return "" }
        if cleaned.count <= 16 {
            return cleaned
        }
        return String(cleaned.prefix(15)) + "…"
    }

    // MARK: - 流式完成通知

    /// 成功完成一轮回复后触发系统通知（仅在用户没在看对话窗时）。
    /// 触发条件：窗口不可见（失焦被自动隐藏）或窗口虽在但非 key；
    /// 仅 didComplete（自然完成）会调用本方法，abort / 请求失败路径不触发。
    func notifyCompletionIfNeeded(sessionId: UUID) {
        let manager = AIWindowManager.shared
        if manager.isPanelVisible && manager.isPanelKey { return }

        let session = store.session(id: sessionId)
        let lastAssistant = session?.messages.last(where: { $0.role == .assistant })?.content ?? ""
        let summary = Self.plainSummary(lastAssistant)

        let sessionTitle = session?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var body = sessionTitle.isEmpty ? String(localized: "回复已完成") : sessionTitle
        if !summary.isEmpty {
            body += "\n" + summary
        }
        AICompletionNotifier.shared.notify(title: "QuickShow AI", body: body, sessionId: sessionId)
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

}
