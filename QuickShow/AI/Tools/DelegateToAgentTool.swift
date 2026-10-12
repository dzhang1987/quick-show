// DelegateToAgentTool: 多智能体中枢委派工具（发起并同步等待）。
// 允许编排中枢（Lead / Generalist）将子任务派发给特定子智能体执行，创建独立子会话并同步获取其专业产出。

import Foundation

final class DelegateToAgentTool: AITool {
    let name = "delegate_to_agent"
    let displayName = "委派子智能体"
    let category: ToolCategory = .interaction
    let description = """
    将具体任务委派给专业的子智能体（如视觉感知专家 Observer、系统架构师 Architect、全能工程师 Engineer、快速探索者 Explorer 等）独立执行，创建独立专属子会话并等待其返回专业分析或生成成果。
    """

    var isInteractive: Bool { true } // 豁免默认 30 秒硬超时，静候子智能体生成完整结果

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "agent_id": [
                    "type": "string",
                    "description": "目标子智能体 ID 或名称，例如：'observer' (视觉与图片分析), 'architect' (系统设计), 'engineer' (代码开发与修复), 'explorer' (信息检索与快速探索)"
                ],
                "task": [
                    "type": "string",
                    "description": "委派给该子智能体的具体任务要求与上下文提示"
                ],
                "include_attachments": [
                    "type": "boolean",
                    "description": "是否将用户最近上传的多模态媒体附件（图片、音频、视频、文件等）传递给子智能体（默认为 true）"
                ]
            ],
            "required": ["agent_id", "task"]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let agentTarget = arguments["agent_id"] as? String, !agentTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutionError("缺少必需参数：agent_id")
        }
        guard let task = arguments["task"] as? String, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutionError("缺少必需参数：task")
        }
        let includeAttachments = (arguments["include_attachments"] as? Bool) ?? (arguments["include_images"] as? Bool) ?? true

        let (parentId, imagesToPass) = await MainActor.run { () -> (UUID, [ChatImageAttachment]) in
            let session = AIChatState.shared.store.ensureCurrentSession()
            let rootId = session.parentSessionId ?? session.id
            var imgs: [ChatImageAttachment] = []
            if includeAttachments {
                let lastWithImages = session.messages.last { !$0.images.isEmpty }
                imgs = lastWithImages?.images ?? []
            }
            return (rootId, imgs)
        }

        // 1. 通过 AgentCoordinator 派发子智能体并创建独立子会话
        let launched = await MainActor.run {
            AgentCoordinator.shared.launchAgent(
                parentId: parentId,
                agentTarget: agentTarget,
                task: task,
                attachments: imagesToPass
            )
        }

        // 2. 同步等待其完成
        let awaited = await AgentCoordinator.shared.awaitAgents(taskIds: [launched.taskId])
        let outputText = awaited[launched.taskId]?.output ?? ""

        let output: [String: Any] = [
            "ok": true,
            "task_id": launched.taskId.uuidString,
            "agent_id": launched.agent.id,
            "agent_name": launched.agent.name,
            "session_title": launched.title,
            "result": outputText
        ]

        return AIToolExecutor.encodeJSON(output)
    }
}
