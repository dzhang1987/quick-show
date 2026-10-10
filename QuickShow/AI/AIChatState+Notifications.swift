// AIChatState+Notifications.swift
// 职责：LLM 标题摘要与流式完成系统通知（自 AIChatState.swift 拆出）。
import Foundation

extension AIChatState {

    // MARK: - 内部：LLM 标题摘要

    /// 首轮回复完成后，后台非流式请求生成 ≤12 字中文标题；失败静默保留临时标题。
    func scheduleTitleSummary(sessionId: UUID) {
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
