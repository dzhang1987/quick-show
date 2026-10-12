// LaunchAgentTool: 异步并发派发子智能体任务。
// 主中枢或任一 Agent 可通过此工具在后台独立拉起子智能体运行，不阻塞当前 Agent 生成。

import Foundation

final class LaunchAgentTool: AITool {
    let name = "launch_agent"
    let displayName = "异步启动子智能体"
    let category: ToolCategory = .interaction
    let description = """
    异步并发启动一个子智能体（如视觉专家 observer、系统架构师 architect、全能工程师 engineer、快速探索者 explorer 等）执行专项任务。该工具会立即返回 task_id 并由子智能体在后台专属会话中流式并行执行，不阻塞当前智能体。可以在一轮中同时启动多个子智能体实现并行工作。
    """

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
                    "description": "委派给该子智能体的详细任务需求与上下文要求"
                ],
                "include_attachments": [
                    "type": "boolean",
                    "description": "是否将当前会话中用户上传的多模态媒体附件（图片、音频、视频、文件等）传递给子智能体（默认为 true）"
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

        let launched = await MainActor.run {
            AgentCoordinator.shared.launchAgent(
                parentId: parentId,
                agentTarget: agentTarget,
                task: task,
                attachments: imagesToPass
            )
        }

        let output: [String: Any] = [
            "ok": true,
            "task_id": launched.taskId.uuidString,
            "agent_id": launched.agent.id,
            "agent_name": launched.agent.name,
            "session_title": launched.title,
            "status": "running",
            "message": "已成功启动子智能体 [\(launched.agent.name)]，后台异步执行中。你可以继续生成其他内容，或稍后调用 await_agents 等待其成果。"
        ]

        return AIToolExecutor.encodeJSON(output)
    }
}
