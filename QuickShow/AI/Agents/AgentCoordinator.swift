// AgentCoordinator: 多智能体并发协同总线与任务调度中枢。
// 支持异步并发派发（launch_agent）、同步等待（await_agents）、点对点协作通信（send_message），
// 并自动维护每个子智能体的专属独立会话与流式状态。

import Foundation
import os

@MainActor
final class AgentCoordinator {
    static let shared = AgentCoordinator()

    /// 子智能体任务默认硬超时熔断上限（5 分钟 = 300 秒，为长文本思考、深度检索与多轮代码生成留足充裕缓冲）
    static let defaultSubagentTimeoutSeconds: TimeInterval = 300

    private let logger = Logger(subsystem: "com.dzhang.quickshow.ai", category: "agentCoordinator")

    /// 正在后台执行流式推理的子任务 Task
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    /// 等待特定子任务完成的挂起 Continuation 队列
    private var taskContinuations: [UUID: [CheckedContinuation<String, Never>]] = [:]

    /// 每个子任务专属的实时 steering 转向队列（按 childSessionId 索引）
    private var subagentSteeringQueues: [UUID: [String]] = [:]

    var debugRunningTaskCount: Int { runningTasks.count }
    var debugContinuationCount: Int { taskContinuations.values.reduce(0) { $0 + $1.count } }

    private init() {}

    // MARK: - 0. 统一并发调度 (Launch Subagents)

    /// 统一并发调度派发并等待所有子智能体任务完成
    func launchSubagents(
        parentId: UUID,
        tasks: [(agentId: String, task: String, attachments: [ChatImageAttachment])]
    ) async -> [[String: Any]] {
        guard !tasks.isEmpty else { return [] }

        var launchedTasks: [(taskId: UUID, agent: AIAgent, startTime: Date)] = []
        for req in tasks {
            let (taskId, agent, _) = launchAgent(
                parentId: parentId,
                agentTarget: req.agentId,
                task: req.task,
                attachments: req.attachments
            )
            launchedTasks.append((taskId, agent, Date()))
        }

        let taskIds = launchedTasks.map(\.taskId)
        let awaited = await awaitAgents(taskIds: taskIds)

        var results: [[String: Any]] = []
        for item in launchedTasks {
            let res = awaited[item.taskId]
            let duration = Int(Date().timeIntervalSince(item.startTime) * 1000)
            let regTask = AgentTaskRegistry.shared.task(childSessionId: item.taskId)
            var payload: [String: Any] = [
                "session_id": item.taskId.uuidString,
                "agent_id": item.agent.id,
                "agent_name": item.agent.name,
                "status": res?.status.rawValue ?? "completed",
                "output": res?.output ?? "",
                "duration_ms": duration
            ]
            if let artifacts = regTask?.artifacts, !artifacts.isEmpty {
                payload["artifacts"] = artifacts
            }
            results.append(payload)
        }

        return results
    }

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

        // 1. 精确与包含匹配
        var matched = agents.first { agent in
            agent.id.lowercased() == cleanTarget ||
            agent.name.lowercased() == cleanTarget ||
            cleanTarget.contains(agent.id.lowercased()) ||
            agent.name.lowercased().contains(cleanTarget)
        }

        // 2. 语义别名映射（解决大模型传“系统专家”、“运维专家”等无法命中“系统管家”的问题）
        if matched == nil {
            if cleanTarget.contains("系统") || cleanTarget.contains("运维") || cleanTarget.contains("进程") || cleanTarget.contains("管家") || cleanTarget.contains("硬件") || cleanTarget.contains("mac") {
                matched = agents.first { $0.id == "concierge" }
            } else if cleanTarget.contains("view") || cleanTarget.contains("视觉") || cleanTarget.contains("image") || cleanTarget.contains("图") || cleanTarget.contains("图片") || cleanTarget.contains("识图") {
                matched = AIAgentStore.shared.visualDelegateAgent ?? agents.first { $0.id == "observer" }
            } else if cleanTarget.contains("code") || cleanTarget.contains("代码") || cleanTarget.contains("写") || cleanTarget.contains("开发") || cleanTarget.contains("编程") || cleanTarget.contains("bug") {
                matched = agents.first { $0.id == "coder" }
            } else if cleanTarget.contains("search") || cleanTarget.contains("搜") || cleanTarget.contains("查") || cleanTarget.contains("文献") || cleanTarget.contains("知识") || cleanTarget.contains("情报") || cleanTarget.contains("资料") {
                matched = agents.first { $0.id == "librarian" }
            } else if cleanTarget.contains("reason") || cleanTarget.contains("推理") || cleanTarget.contains("深度") || cleanTarget.contains("分析") || cleanTarget.contains("架构") || cleanTarget.contains("决策") || cleanTarget.contains("思考") {
                matched = agents.first { $0.id == "oracle" }
            }
        }

        // 3. 兜底策略：绝对禁止回落到主中枢 orchestrator 自身，避免调度递归死循环
        let matchedAgent = matched ?? agents.first { $0.id != "orchestrator" && $0.isEnabled } ?? AIAgentStore.shared.activeAgent

        let taskTopic = ChatSessionStore.summarizeTitle(from: task, maxLength: 12, fallback: matchedAgent.name)
        let sessionTitle = "[\(matchedAgent.name)] \(taskTopic)"

        // 1. 创建子 Agent 专属独立会话（保留在主会话，不强制跳转）
        let childSession = ChatSessionStore.shared.createChildSession(
            parentId: parentId,
            agentId: matchedAgent.id,
            title: sessionTitle,
            switchToChild: false
        )
        let childId = childSession.id

        // 登记到本地持久化任务注册表 (~/.quickshow/agent_tasks.json)
        let persistentTaskId = "task_\(matchedAgent.id)_\(UUID().uuidString.prefix(8).lowercased())"
        AgentTaskRegistry.shared.registerTask(
            id: persistentTaskId,
            subagentId: matchedAgent.id,
            subagentName: matchedAgent.name,
            parentSessionId: parentId,
            childSessionId: childId,
            taskDescription: task
        )

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

        // 4. 后台并发拉起流式生成 Task（支持多轮 Agentic Tool Loop 与动态 Steering）
        let taskRunner = Task { [weak self] in
            guard let self else { return }
            var currentAssistantId = assistantID
            var accumulatedFinalText = ""
            var toolRounds = 0
            let maxToolRounds = 3

            subagentLoop: while toolRounds < maxToolRounds {
                if Task.isCancelled { break subagentLoop }
                var roundText = ""
                var roundReasoning = ""
                var completedCalls: [CompletedToolCall] = []

                // 检查并消费注入的实时 Steering 指令
                if let steerings = self.subagentSteeringQueues[childId], !steerings.isEmpty {
                    self.subagentSteeringQueues[childId] = []
                    for steer in steerings {
                        requestMessages.append(ChatCompletionMessage(
                            role: "user",
                            content: "[用户中途补充要求]：\n\(steer)"
                        ))
                    }
                }

                AgentTaskRegistry.shared.updateTaskAction(
                    id: persistentTaskId,
                    action: toolRounds == 0 ? "正在思考与组织行动…" : "结合工具反馈继续分析…",
                    status: .running
                )

                do {
                    let stream = AIProviderService.shared.send(
                        messages: requestMessages,
                        agent: matchedAgent
                    )

                    for try await event in stream {
                        if Task.isCancelled { break subagentLoop }
                        switch event {
                        case .text(let chunk):
                            roundText += chunk
                            ChatSessionStore.shared.appendStreamToken(chunk, to: currentAssistantId, in: childId)
                        case .reasoning(let reasoningChunk):
                            roundReasoning += reasoningChunk
                            ChatSessionStore.shared.appendReasoningToken(reasoningChunk, to: currentAssistantId, in: childId)
                        case .toolCallDispatched(let callId, let name):
                            // 实时同步任务动作到托盘与注册表
                            AgentTaskRegistry.shared.updateTaskAction(
                                id: persistentTaskId,
                                action: "正在准备调用 \(name)…",
                                status: .toolExecuting
                            )
                            ChatSessionStore.shared.updateMessage(id: currentAssistantId, in: childId) { msg in
                                var calls = msg.toolCalls ?? []
                                if !calls.contains(where: { $0.id == callId }) {
                                    calls.append(ToolCallRecord(id: callId, name: name, arguments: "", result: nil, status: .pending))
                                    msg.toolCalls = calls
                                }
                            }
                        case .toolCalls(let calls):
                            completedCalls = calls
                        case .usage:
                            break
                        }
                    }

                    if Task.isCancelled { break subagentLoop }

                    // 没有工具调用：说明本次生成即为最终答复
                    if completedCalls.isEmpty {
                        accumulatedFinalText = roundText
                        ChatSessionStore.shared.updateMessageState(currentAssistantId, state: .done, in: childId)
                        ChatSessionStore.shared.updateTaskStatus(
                            sessionId: childId,
                            status: .completed,
                            summary: String(roundText.prefix(120))
                        )
                        break subagentLoop
                    }

                    // 存在工具调用：
                    // 1. 将工具调用记录挂到当前子会话助手消息（使子会话 UI 实时呈现工具卡片）
                    let records = completedCalls.map {
                        ToolCallRecord(id: $0.id, name: $0.name, arguments: $0.arguments, result: nil, status: .pending, thoughtSignature: $0.thoughtSignature)
                    }
                    ChatSessionStore.shared.updateMessage(id: currentAssistantId, in: childId) { msg in
                        msg.content = roundText
                        msg.toolCalls = records
                    }

                    // 2. 将助手消息（携带 tool_calls）追加到请求上下文 wire
                    let wireCalls = completedCalls.map {
                        WireToolCall(id: $0.id, name: $0.name, arguments: $0.arguments, thoughtSignature: $0.thoughtSignature)
                    }
                    requestMessages.append(ChatCompletionMessage(
                        role: "assistant",
                        content: roundText.isEmpty ? nil : .text(roundText),
                        toolCalls: wireCalls,
                        toolCallId: nil
                    ))

                    // 3. 执行工具调用
                    for call in completedCalls {
                        if Task.isCancelled { break subagentLoop }
                        AgentTaskRegistry.shared.updateTaskAction(
                            id: persistentTaskId,
                            action: "正在调用 \(call.name)…",
                            status: .toolExecuting
                        )

                        ChatSessionStore.shared.updateMessage(id: currentAssistantId, in: childId) { msg in
                            guard var calls = msg.toolCalls, let idx = calls.firstIndex(where: { $0.id == call.id }) else { return }
                            calls[idx].status = .running
                            msg.toolCalls = calls
                        }

                        let request = ToolCallRequest(id: call.id, name: call.name, argumentsJSON: call.arguments)
                        let result = await ToolExecutionContext.$currentSessionId.withValue(childId) {
                            await AIToolExecutor.shared.execute(call: request)
                        }

                        ChatSessionStore.shared.updateMessage(id: currentAssistantId, in: childId) { msg in
                            guard var calls = msg.toolCalls, let idx = calls.firstIndex(where: { $0.id == call.id }) else { return }
                            calls[idx].status = result.status
                            calls[idx].result = result.resultJSON
                            msg.toolCalls = calls
                        }

                        requestMessages.append(ChatCompletionMessage.toolResult(
                            callID: call.id,
                            content: result.resultJSON
                        ))
                    }

                    AgentTaskRegistry.shared.updateTaskAction(
                        id: persistentTaskId,
                        action: "工具调用完成，正在汇总分析…",
                        status: .running
                    )

                    // 4. 当前助手消息标记为完成
                    ChatSessionStore.shared.updateMessageState(currentAssistantId, state: .done, in: childId)
                    toolRounds += 1

                    // 5. 为下一轮 LLM 迭代预建助手消息占位
                    currentAssistantId = UUID()
                    let nextAssistantMsg = ChatMessage(
                        id: currentAssistantId,
                        role: .assistant,
                        content: "",
                        state: .streaming
                    )
                    ChatSessionStore.shared.appendMessage(nextAssistantMsg, to: childId)

                } catch {
                    let errMsg = error.localizedDescription
                    ChatSessionStore.shared.updateMessageState(currentAssistantId, state: .failed(errMsg), in: childId)
                    ChatSessionStore.shared.updateTaskStatus(
                        sessionId: childId,
                        status: .failed,
                        summary: "执行失败：\(errMsg)"
                    )
                    accumulatedFinalText = "执行失败：\(errMsg)"
                    AgentTaskRegistry.shared.settleTask(
                        id: persistentTaskId,
                        status: .failed,
                        summary: "执行失败：\(errMsg)"
                    )
                    break subagentLoop
                }
            }

            // 达到工具轮数上限且尚未输出最终答复：执行强制收敛总结（Force Synthesis）
            if toolRounds >= maxToolRounds && accumulatedFinalText.isEmpty && !Task.isCancelled {
                AgentTaskRegistry.shared.updateTaskAction(
                    id: persistentTaskId,
                    action: "信息检索完毕，正在撰写最终报告…",
                    status: .running
                )

                requestMessages.append(ChatCompletionMessage(
                    role: "user",
                    content: "[系统提示]：工具调用轮次已达上限（\(maxToolRounds) 轮），信息收集阶段已结束。请基于上述已获取的所有工具返回结果，直接撰写完整、结构清晰、详尽的最终 Markdown 总结答卷，严禁再次发起工具调用。"
                ))

                do {
                    let synthStream = AIProviderService.shared.send(
                        messages: requestMessages,
                        agent: matchedAgent,
                        disableTools: true
                    )
                    var synthText = ""
                    for try await event in synthStream {
                        if Task.isCancelled { break }
                        switch event {
                        case .text(let chunk):
                            synthText += chunk
                            ChatSessionStore.shared.appendStreamToken(chunk, to: currentAssistantId, in: childId)
                        case .reasoning(let reasoningChunk):
                            ChatSessionStore.shared.appendReasoningToken(reasoningChunk, to: currentAssistantId, in: childId)
                        case .usage, .toolCallDispatched, .toolCalls:
                            break
                        }
                    }
                    accumulatedFinalText = synthText
                    ChatSessionStore.shared.updateMessageState(currentAssistantId, state: .done, in: childId)
                    ChatSessionStore.shared.updateTaskStatus(
                        sessionId: childId,
                        status: .completed,
                        summary: String(synthText.prefix(120))
                    )
                } catch {
                    let errMsg = error.localizedDescription
                    ChatSessionStore.shared.updateMessageState(currentAssistantId, state: .failed(errMsg), in: childId)
                    accumulatedFinalText = "总结报告生成失败：\(errMsg)"
                }
            }

            // 彻底兜底：确保当前助手消息状态落定，绝不遗留悬挂 .streaming 状态
            ChatSessionStore.shared.updateMessage(id: currentAssistantId, in: childId) { msg in
                if case .streaming = msg.state {
                    if msg.content.isEmpty {
                        msg.content = accumulatedFinalText.isEmpty ? "执行已完成" : accumulatedFinalText
                    }
                    msg.state = .done
                }
            }

            // 大产物检测与本地隔离存储 (~/.quickshow/artifacts/<parentId>/<taskId>/report.md)
            var savedArtifactPath: String?
            if accumulatedFinalText.count > 2500 || accumulatedFinalText.contains("```") {
                let artifactURL = AgentTaskRegistry.shared.makeArtifactPath(
                    parentSessionId: parentId,
                    taskId: persistentTaskId,
                    fileName: "report.md"
                )
                try? accumulatedFinalText.write(to: artifactURL, atomically: true, encoding: .utf8)
                savedArtifactPath = artifactURL.path
            }

            AgentTaskRegistry.shared.settleTask(
                id: persistentTaskId,
                status: .completed,
                summary: String(accumulatedFinalText.prefix(120)),
                artifactPath: savedArtifactPath
            )

            // 完成通知：唤醒所有挂起等待该任务的协程
            self.notifyTaskCompletion(taskId: childId, result: accumulatedFinalText)
        }

        runningTasks[childId] = taskRunner
        return (taskId: childId, agent: matchedAgent, title: sessionTitle)
    }

    // MARK: - 2. 同步等待 (Await)

    /// 单个任务等待逻辑（带并发超时熔断保护，MainActor 上执行）
    func awaitSingleAgent(taskId: UUID, timeoutSeconds: TimeInterval) async -> (UUID, SubagentTaskStatus, String) {
        if let session = ChatSessionStore.shared.session(id: taskId) {
            if session.taskStatus == .completed || session.taskStatus == .failed {
                let lastAssistant = session.messages.last { $0.role == .assistant }
                let text = lastAssistant?.content ?? ""
                return (taskId, session.taskStatus ?? .completed, text)
            }
        } else {
            return (taskId, .failed, "未找到任务会话 \(taskId)")
        }

        // 使用 TaskGroup 竞速：正常完成通知 vs 超时定时器
        return await withTaskGroup(of: (SubagentTaskStatus, String).self) { group in
            // 分支 1：挂起等待正常通知
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    var list = self.taskContinuations[taskId] ?? []
                    list.append(continuation)
                    self.taskContinuations[taskId] = list
                }
                let session = ChatSessionStore.shared.session(id: taskId)
                let text = session?.messages.last(where: { $0.role == .assistant })?.content ?? ""
                return (session?.taskStatus ?? .completed, text)
            }

            // 分支 2：超时定时器（最小保护阈值 50ms）
            let timeoutLimit = max(timeoutSeconds, 0.05)
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeoutLimit * 1_000_000_000))
                } catch {
                    // 若被 cancelAll 取消，说明分支 1 已正常返回，安全中断退出，绝不误触超时逻辑
                    return (.completed, "")
                }
                guard !Task.isCancelled else { return (.completed, "") }
                return await MainActor.run { () -> (SubagentTaskStatus, String) in
                    // 再次双重防御：检查会话当前状态，若已正常完成则绝不篡改
                    if let session = ChatSessionStore.shared.session(id: taskId),
                       session.taskStatus == .completed {
                        let text = session.messages.last(where: { $0.role == .assistant })?.content ?? ""
                        return (.completed, text)
                    }

                    let timeoutMsg = "子智能体任务执行超时（\(Int(timeoutLimit)) 秒）"
                    if let continuations = self.taskContinuations.removeValue(forKey: taskId) {
                        for cont in continuations {
                            cont.resume(returning: timeoutMsg)
                        }
                    }
                    // 取消后台流式 Task
                    self.runningTasks.removeValue(forKey: taskId)?.cancel()

                    // 更新会话与注册表状态为失败
                    ChatSessionStore.shared.updateTaskStatus(sessionId: taskId, status: .failed, summary: timeoutMsg)
                    if let regTask = AgentTaskRegistry.shared.task(childSessionId: taskId) {
                        AgentTaskRegistry.shared.settleTask(id: regTask.id, status: .failed, summary: timeoutMsg)
                    }

                    return (.failed, timeoutMsg)
                }
            }

            let firstResult = await group.next() ?? (.failed, "未知执行错误")
            group.cancelAll()
            return (taskId, firstResult.0, firstResult.1)
        }
    }

    /// 同步挂起并发等待一个或多个子 Agent 任务全部完成，并返回汇总成果（严格支持超时熔断）
    func awaitAgents(taskIds: [UUID], timeoutSeconds: TimeInterval = defaultSubagentTimeoutSeconds) async -> [UUID: (status: SubagentTaskStatus, output: String)] {
        var results: [UUID: (status: SubagentTaskStatus, output: String)] = [:]
        guard !taskIds.isEmpty else { return results }

        await withTaskGroup(of: (UUID, SubagentTaskStatus, String).self) { group in
            for id in taskIds {
                group.addTask { @MainActor in
                    await self.awaitSingleAgent(taskId: id, timeoutSeconds: timeoutSeconds)
                }
            }
            for await (taskId, status, output) in group {
                results[taskId] = (status, output)
            }
        }

        return results
    }

    /// 级联取消特定主会话派生的所有正在运行中的子智能体任务
    func abortSubagents(for parentSessionId: UUID) {
        let runningRecords = AgentTaskRegistry.shared.runningTasks(parentSessionId: parentSessionId)
        for record in runningRecords {
            abortSubagent(childSessionId: record.childSessionId)
        }
    }

    /// 单独取消/中止特定子智能体任务
    func abortSubagent(childSessionId: UUID) {
        if let continuations = taskContinuations.removeValue(forKey: childSessionId) {
            for cont in continuations {
                cont.resume(returning: "用户已中止执行")
            }
        }
        runningTasks.removeValue(forKey: childSessionId)?.cancel()
        ChatSessionStore.shared.updateTaskStatus(sessionId: childSessionId, status: .failed, summary: "用户已中止")
        if let record = AgentTaskRegistry.shared.task(childSessionId: childSessionId) {
            AgentTaskRegistry.shared.settleTask(id: record.id, status: .cancelled, summary: "用户已中止")
        }
    }

    /// 查询特定子会话任务是否正在当前进程中活跃执行
    func isSubagentRunning(childSessionId: UUID) -> Bool {
        runningTasks[childSessionId] != nil
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

    func notifyTaskCompletion(taskId: UUID, result: String) {
        runningTasks.removeValue(forKey: taskId)
        guard let continuations = taskContinuations.removeValue(forKey: taskId) else { return }
        for cont in continuations {
            cont.resume(returning: result)
        }
    }

    // MARK: - 4. 实时 Steering 转向与输入路由 (A+B 方案)

    /// 向特定子任务注入实时 steering 转向指令
    func injectSteering(taskId: String, text: String) {
        guard let record = AgentTaskRegistry.shared.task(id: taskId) else { return }
        let childId = record.childSessionId
        var list = subagentSteeringQueues[childId] ?? []
        list.append(text)
        subagentSteeringQueues[childId] = list

        // 同时向该子会话追加一条消息，以便用户切过去能看到
        let userMsg = ChatMessage(
            role: .user,
            content: text,
            state: .done,
            isSteered: true
        )
        ChatSessionStore.shared.appendMessage(userMsg, to: childId)
    }

    /// 智能路由判定：将用户在主会话追加的输入路由至具体的活跃子任务（支持 A+B 方案）
    func routeInput(text: String, parentSessionId: UUID) -> (taskId: String, subagentName: String, cleanText: String)? {
        let running = AgentTaskRegistry.shared.runningTasks(parentSessionId: parentSessionId)
        guard !running.isEmpty else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // 1. 显式前缀或专家指称匹配 (@librarian, @coder, 给搜索专家, 让代码专家 等)
        for task in running {
            let agentId = task.subagentId.lowercased()
            let agentName = task.subagentName.lowercased()

            // @id 或 @name
            if lower.hasPrefix("@" + agentId) {
                let clean = trimmed.dropFirst(agentId.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                return (task.id, task.subagentName, clean.isEmpty ? trimmed : clean)
            }
            if lower.hasPrefix("@" + agentName) {
                let clean = trimmed.dropFirst(agentName.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                return (task.id, task.subagentName, clean.isEmpty ? trimmed : clean)
            }

            // 中文自然称谓（如 "给搜索专家"、"让代码专家"、"对librarian说"）
            if lower.contains("给\(agentName)") || lower.contains("让\(agentName)") || lower.contains("对\(agentName)") {
                return (task.id, task.subagentName, trimmed)
            }
        }

        // 2. 若只有一个正在干活的子任务，所有输入直接无缝流向它
        if running.count == 1, let only = running.first {
            return (only.id, only.subagentName, trimmed)
        }

        // 3. 多任务时的语义特征度评分匹配
        let keywordsMap: [String: [String]] = [
            "librarian": ["搜", "查", "找", "网", "股", "价", "财报", "新闻", "资讯", "行情", "市值", "google", "yahoo", "雪球", "资料", "文献"],
            "coder": ["代码", "写", "改", "函数", "类", "bug", "修复", "重构", "swift", "python", "编译", "脚本"],
            "oracle": ["分析", "评估", "推演", "架构", "逻辑", "估值", "模型", "对比", "优劣", "深度", "价值", "研报", "思考"],
            "observer": ["看", "图", "图片", "视觉", "截图", "ui", "界面", "排版", "识图"],
            "concierge": ["打开", "系统", "设置", "应用", "地图", "定位", "通知", "日历"]
        ]

        var bestMatch: (task: AgentTaskRecord, score: Int)?
        for task in running {
            let kws = keywordsMap[task.subagentId] ?? []
            var score = 0
            for kw in kws {
                if lower.contains(kw) {
                    score += 1
                }
            }
            if score > (bestMatch?.score ?? 0) {
                bestMatch = (task, score)
            }
        }

        if let best = bestMatch, best.score >= 1 {
            return (best.task.id, best.task.subagentName, trimmed)
        }

        // 4. 未明确命中任何单一子任务：留给主会话
        return nil
    }

    // MARK: - 5. 子任务结论回传与同步至主会话 (Sync to Main Agent)

    /// 将特定子 Agent 的产物与结论沉淀并同步回主会话，形成协同闭环
    func syncChildOutputToParent(childSessionId: UUID, userNote: String? = nil) {
        guard let childSession = ChatSessionStore.shared.session(id: childSessionId),
              let parentId = childSession.parentSessionId else {
            return
        }

        let agent = AIAgentStore.shared.agent(for: childSession.agentId ?? "")
        let agentName = agent?.name ?? "专项专家"

        // 获取最新一条 assistant 消息与产物
        let lastAssistant = childSession.messages.last { $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let conclusionText = childSession.taskSummary ?? lastAssistant?.content ?? ""
        let regTask = AgentTaskRegistry.shared.task(childSessionId: childSessionId)

        var syncContent = "💡 **【\(agentName)】已完成专项任务并提报成果：**\n\n"
        if !conclusionText.isEmpty {
            let snippet = conclusionText.count > 500 ? String(conclusionText.prefix(500)) + "..." : conclusionText
            syncContent += "> \(snippet.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
        }
        if let artifacts = regTask?.artifacts, !artifacts.isEmpty {
            syncContent += "**生成产物：**\n"
            for art in artifacts {
                syncContent += "- `\(art)`\n"
            }
            syncContent += "\n"
        }
        if let note = userNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            syncContent += "补充要求：\(note)\n\n"
        }
        syncContent += "请基于上述专家的结论与产物，继续推进任务。"

        let syncUserMsg = ChatMessage(
            role: .user,
            content: syncContent,
            state: .done
        )
        ChatSessionStore.shared.appendMessage(syncUserMsg, to: parentId)

        // 平滑切换回主会话
        ChatSessionStore.shared.currentSessionId = parentId
    }
}
