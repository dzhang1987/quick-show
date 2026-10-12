// AgentCoordinator: 多智能体并发协同总线与任务调度中枢。
// 支持异步并发派发（launch_agent）、同步等待（await_agents）、点对点协作通信（send_message），
// 并自动维护每个子智能体的专属独立会话与流式状态。

import Foundation
import os

@MainActor
final class AgentCoordinator {
    static let shared = AgentCoordinator()

    private let logger = Logger(subsystem: "com.dzhang.quickshow.ai", category: "agentCoordinator")

    /// 正在后台执行流式推理的子任务 Task
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    /// 等待特定子任务完成的挂起 Continuation 队列
    private var taskContinuations: [UUID: [CheckedContinuation<String, Never>]] = [:]

    private init() {}

    // MARK: - 1. 异步并发派发 (Launch)

    /// 异步并发启动一个子智能体任务（立即返回，子 Agent 在后台独立流式会话中运行）
    func launchAgent(
        parentId: UUID,
        agentTarget: String,
        task: String,
        attachments: [ChatImageAttachment] = []
    ) -> (taskId: UUID, agent: AIAgent, title: String) {
        let cleanTarget = agentTarget.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let agents = AIAgentStore.shared.agents

        let matchedAgent = agents.first { agent in
            agent.id.lowercased() == cleanTarget ||
            agent.name.lowercased() == cleanTarget ||
            cleanTarget.contains(agent.id.lowercased()) ||
            agent.name.lowercased().contains(cleanTarget)
        } ?? (cleanTarget.contains("view") || cleanTarget.contains("视觉") || cleanTarget.contains("image") || cleanTarget.contains("图")
            ? AIAgentStore.shared.visualDelegateAgent
            : nil) ?? AIAgentStore.shared.activeAgent

        let taskSnippet = task.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(20)
        let sessionTitle = "[\(matchedAgent.name)] \(taskSnippet)"

        // 1. 创建子 Agent 专属独立会话（保留在主会话，不强制跳转）
        let childSession = ChatSessionStore.shared.createChildSession(
            parentId: parentId,
            agentId: matchedAgent.id,
            title: sessionTitle,
            switchToChild: false
        )
        let childId = childSession.id

        // 2. 插入初始用户指令与占位助手消息
        let userMsg = ChatMessage(
            role: .user,
            content: task,
            state: .done,
            images: attachments
        )
        let assistantID = UUID()
        let assistantMsg = ChatMessage(
            id: assistantID,
            role: .assistant,
            content: "",
            state: .streaming
        )
        ChatSessionStore.shared.appendMessage(userMsg, to: childId)
        ChatSessionStore.shared.appendMessage(assistantMsg, to: childId)

        // 3. 构建发送给子智能体的请求上下文
        var requestMessages: [ChatCompletionMessage] = []
        if !matchedAgent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requestMessages.append(ChatCompletionMessage(role: "system", content: matchedAgent.systemPrompt))
        }

        var userParts: [ChatContentPart] = [.textPart(task)]
        for img in attachments {
            userParts.append(.imagePart(dataURI: img.dataURI))
        }
        requestMessages.append(ChatCompletionMessage(role: "user", content: .parts(userParts)))

        // 4. 后台并发拉起流式生成 Task
        let taskRunner = Task { [weak self] in
            guard let self else { return }
            var accumulatedText = ""
            var accumulatedReasoning = ""

            do {
                let stream = AIProviderService.shared.send(
                    messages: requestMessages,
                    agent: matchedAgent
                )

                for try await event in stream {
                    switch event {
                    case .text(let chunk):
                        accumulatedText += chunk
                        ChatSessionStore.shared.appendStreamToken(chunk, to: assistantID, in: childId)
                    case .reasoning(let reasoningChunk):
                        accumulatedReasoning += reasoningChunk
                        ChatSessionStore.shared.appendReasoningToken(reasoningChunk, to: assistantID, in: childId)
                    case .usage, .toolCalls:
                        break
                    }
                }

                // 标记该子会话正常完成
                ChatSessionStore.shared.updateMessageState(assistantID, state: .done, in: childId)
                ChatSessionStore.shared.updateTaskStatus(
                    sessionId: childId,
                    status: .completed,
                    summary: String(accumulatedText.prefix(120))
                )
            } catch {
                let errMsg = error.localizedDescription
                ChatSessionStore.shared.updateMessageState(assistantID, state: .failed(errMsg), in: childId)
                ChatSessionStore.shared.updateTaskStatus(
                    sessionId: childId,
                    status: .failed,
                    summary: "执行失败：\(errMsg)"
                )
            }

            // 完成通知：唤醒所有挂起等待该任务的协程
            self.notifyTaskCompletion(taskId: childId, result: accumulatedText)
        }

        runningTasks[childId] = taskRunner
        return (taskId: childId, agent: matchedAgent, title: sessionTitle)
    }

    // MARK: - 2. 同步等待 (Await)

    /// 同步挂起等待一个或多个子 Agent 任务全部完成，并返回汇总成果
    func awaitAgents(taskIds: [UUID], timeoutSeconds: TimeInterval = 180) async -> [UUID: (status: SubagentTaskStatus, output: String)] {
        var results: [UUID: (status: SubagentTaskStatus, output: String)] = [:]

        for id in taskIds {
            guard let session = ChatSessionStore.shared.session(id: id) else {
                results[id] = (.failed, "未找到任务会话 \(id)")
                continue
            }

            if session.taskStatus == .completed || session.taskStatus == .failed {
                let lastAssistant = session.messages.last { $0.role == .assistant }
                let text = lastAssistant?.content ?? ""
                results[id] = (session.taskStatus ?? .completed, text)
                continue
            }

            // 仍在运行中：挂起等待通知或超时
            let output = await withCheckedContinuation { continuation in
                var list = self.taskContinuations[id] ?? []
                list.append(continuation)
                self.taskContinuations[id] = list
            }

            let updated = ChatSessionStore.shared.session(id: id)
            results[id] = (updated?.taskStatus ?? .completed, output)
        }

        return results
    }

    // MARK: - 3. 智能体间点对点通信 (Send Message)

    /// Agent 之间点对点通信：向特定子会话发送协作消息并获取回应
    func sendMessage(
        fromAgent: AIAgent,
        targetAgentId: String,
        parentSessionId: UUID,
        message: String
    ) async throws -> String {
        // 查找或派发对应 targetAgent 的任务
        let children = ChatSessionStore.shared.childSessions(of: parentSessionId)
        let matched = children.first { $0.agentId == targetAgentId }

        if let existingChild = matched {
            let userMessage = ChatMessage(
                role: .user,
                content: "[\(fromAgent.name) 的协作提问]：\n\(message)",
                state: .done
            )
            let assistantID = UUID()
            let assistantMessage = ChatMessage(
                id: assistantID,
                role: .assistant,
                content: "",
                state: .streaming
            )
            ChatSessionStore.shared.appendMessage(userMessage, to: existingChild.id)
            ChatSessionStore.shared.appendMessage(assistantMessage, to: existingChild.id)

            guard let agent = AIAgentStore.shared.agent(for: targetAgentId) else {
                throw ToolExecutionError("未找到目标智能体 \(targetAgentId)")
            }

            // 组装历史消息并触发一轮生成
            var wire: [ChatCompletionMessage] = []
            if !agent.systemPrompt.isEmpty {
                wire.append(ChatCompletionMessage(role: "system", content: agent.systemPrompt))
            }
            for msg in existingChild.messages {
                wire.append(ChatCompletionMessage(role: msg.role.rawValue, content: msg.content))
            }
            wire.append(ChatCompletionMessage(role: "user", content: "[\(fromAgent.name) 的协作提问]：\n\(message)"))

            let stream = AIProviderService.shared.send(messages: wire, agent: agent)
            var responseText = ""
            for try await event in stream {
                if case .text(let t) = event {
                    responseText += t
                    ChatSessionStore.shared.appendStreamToken(t, to: assistantID, in: existingChild.id)
                }
            }
            ChatSessionStore.shared.updateMessageState(assistantID, state: .done, in: existingChild.id)
            return responseText
        } else {
            // 没有先例，直接 launch 并 await
            let (taskId, _, _) = launchAgent(
                parentId: parentSessionId,
                agentTarget: targetAgentId,
                task: "[\(fromAgent.name) 的协作需求]：\n\(message)"
            )
            let awaited = await awaitAgents(taskIds: [taskId])
            return awaited[taskId]?.output ?? "无回复"
        }
    }

    // MARK: - 内部通知机制

    private func notifyTaskCompletion(taskId: UUID, result: String) {
        runningTasks.removeValue(forKey: taskId)
        guard let continuations = taskContinuations.removeValue(forKey: taskId) else { return }
        for cont in continuations {
            cont.resume(returning: result)
        }
    }
}
