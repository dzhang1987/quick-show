// SendMessageTool: 智能体间点对点直接通信工具。
// 允许主智能体或子智能体相互之间直接发送协作消息、咨询专业意见或转交中间数据。

import Foundation

final class SendMessageTool: AITool {
    let name = "send_message"
    let displayName = "智能体协作通信"
    let category: ToolCategory = .interaction
    let description = """
    向另一个智能体（如视觉专家 observer、系统架构师 architect、全能工程师 engineer、快速探索者 explorer、或通用中枢 generalist）直接发送协作消息或提问，并获取该智能体的直接回应。支持全连接智能体间互通。
    """

    var isInteractive: Bool { true } // 豁免超时限制

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "recipient": [
                    "type": "string",
                    "description": "目标接收智能体 ID 或名称，例如：'observer', 'architect', 'engineer', 'explorer', 'generalist'"
                ],
                "message": [
                    "type": "string",
                    "description": "发送给目标智能体的具体通信内容、提问或需要评估的需求"
                ]
            ],
            "required": ["recipient", "message"]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let recipient = arguments["recipient"] as? String, !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutionError("缺少必需参数：recipient")
        }
        guard let message = arguments["message"] as? String, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutionError("缺少必需参数：message")
        }

        let executionSessionId = ToolExecutionContext.currentSessionId
        let (fromAgent, parentId) = await MainActor.run { () -> (AIAgent, UUID) in
            let session: ChatSession
            if let execId = executionSessionId, let target = AIChatState.shared.store.session(id: execId) {
                session = target
            } else if let current = AIChatState.shared.store.currentSession {
                session = current
            } else if let first = AIChatState.shared.store.sessions.first {
                session = first
            } else {
                session = AIChatState.shared.store.createSession()
            }
            let agentId = session.agentId ?? AIChatState.shared.effectiveAgentId
            let sender = AIAgentStore.shared.agent(for: agentId) ?? AIAgentStore.shared.activeAgent
            let rootId = session.parentSessionId ?? session.id
            return (sender, rootId)
        }

        let reply = try await AgentCoordinator.shared.sendMessage(
            fromAgent: fromAgent,
            targetAgentId: recipient,
            parentSessionId: parentId,
            message: message
        )

        let output: [String: Any] = [
            "ok": true,
            "sender": fromAgent.name,
            "recipient": recipient,
            "reply": reply
        ]

        return AIToolExecutor.encodeJSON(output)
    }
}
