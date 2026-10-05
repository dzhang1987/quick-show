// AIChatState+Compaction.swift
// 职责：上下文自动/手动压缩（水位估算、压缩计划、执行与摘要写回）（自 AIChatState.swift 拆出）。
import Foundation

extension AIChatState {

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
    func maybeAutoCompact(sessionId: UUID) {
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
    func watermark(for session: ChatSession) -> ContextWatermark? {
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

    /// 执行压缩：旧摘要 + 本批消息 → 合并为单份新摘要；成功写回会话。
    /// 失败不再静默：各失败路径把一句中文原因记入 lastCompactionOutcome，
    /// 由视口 toast + 水位圆环详情卡两级呈现；唯「会话已删除」保持静默
    /// （会话都没了，没有可反馈的 UI 上下文）。防重入逻辑（isCompacting）不变。
    private func runCompaction(sessionId: UUID, plan: CompactionPlan) async {
        guard let session = store.session(id: sessionId) else { return }
        let prompt = buildCompactionPrompt(existingSummary: session.contextSummary, messages: plan.messages)
        let options = compactionRequestOptions(for: session)
        let raw: String
        do {
            raw = try await service.complete(
                messages: prompt,
                options: options,
                maxTokens: compactionMaxTokens
            )
        } catch {
            // 网络/鉴权/超时等服务侧错误：不向用户暴露技术细节，一句简述即可
            lastCompactionOutcome = .failed(sessionId: sessionId, reason: "服务请求失败")
            return
        }
        let summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            lastCompactionOutcome = .failed(sessionId: sessionId, reason: "服务返回了空摘要")
            return
        }

        // 应用前二次校验：目标消息仍存在（防止压缩期间清空/撤回导致写错）。
        guard let latest = store.session(id: sessionId) else { return }
        let existingIDs = Set(latest.messages.map { $0.id.uuidString })
        guard plan.messageIDs.allSatisfy({ existingIDs.contains($0) }) else {
            lastCompactionOutcome = .failed(sessionId: sessionId, reason: "会话内容已变化")
            return
        }

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
        lastCompactionOutcome = .succeeded(sessionId: sessionId, count: plan.messageIDs.count, at: Date())
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
    func refreshCompactionInfo() {
        guard let session = store.currentSession,
              let info = Self.makeCompactionInfo(for: session) else {
            if compactionInfo != nil { compactionInfo = nil }
            return
        }
        // 手工比较关键字段，避免无意义重复扇出。
        if let existing = compactionInfo,
           existing.beforeMessageID == info.beforeMessageID,
           existing.summarizedCount == info.summarizedCount,
           existing.summary == info.summary,
           existing.summarizedIDs == info.summarizedIDs {
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
        return CompactionInfo(
            beforeMessageID: beforeMessageID,
            summarizedCount: summarized.count,
            summary: summary,
            summarizedIDs: summarized
        )
    }

}
