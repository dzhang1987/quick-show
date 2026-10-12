// AwaitAgentsTool: 同步等待子智能体任务完成。
// 当后续决策需要依赖先前异步启动（launch_agent）的成果时调用此工具获取最终输出。

import Foundation

final class AwaitAgentsTool: AITool {
    let name = "await_agents"
    let displayName = "等待子智能体结果"
    let category: ToolCategory = .interaction
    let description = """
    同步等待一个或多个先前通过 launch_agent 异步启动的子智能体任务执行完毕，并获取它们的输出成果。
    """

    var isInteractive: Bool { true } // 豁免超时限制，静候子智能体生成

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "task_ids": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "先前 launch_agent 返回的一个或多个任务 ID 数组"
                ]
            ],
            "required": ["task_ids"]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let taskIdsRaw = arguments["task_ids"] as? [String], !taskIdsRaw.isEmpty else {
            throw ToolExecutionError("缺少必需参数：task_ids 数组")
        }

        let uuids = taskIdsRaw.compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !uuids.isEmpty else {
            throw ToolExecutionError("传入的 task_ids 格式不合法")
        }

        let results = await AgentCoordinator.shared.awaitAgents(taskIds: uuids)

        var details: [[String: Any]] = []
        for (id, res) in results {
            let session = await MainActor.run { ChatSessionStore.shared.session(id: id) }
            details.append([
                "task_id": id.uuidString,
                "agent_id": session?.agentId ?? "unknown",
                "title": session?.title ?? "",
                "status": res.status.rawValue,
                "output": res.output
            ])
        }

        let output: [String: Any] = [
            "ok": true,
            "tasks_count": details.count,
            "results": details
        ]

        return AIToolExecutor.encodeJSON(output)
    }
}
