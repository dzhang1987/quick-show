// LaunchSubagentsTool: 统一多智能体并发调度工具（合三为一）。
// 编排中枢通过此工具向一个或多个垂类专家（Coder, Librarian, Oracle, Concierge, Observer 等）派发任务，
// 底层真并发执行并一次性汇聚返回所有成果，消灭中间状态与任务 ID 丢失风险。

import Foundation

final class LaunchSubagentsTool: AITool {
    let name = "launch_subagents"
    let displayName = "并发调度子智能体"
    let category: ToolCategory = .interaction
    let description = """
    向一个或多个专业垂类子智能体派发专项任务。支持同时派发多个任务实现后台真并发执行，系统会自动等待所有子任务完成并汇总返回成果。单任务直接派发，多任务自动并行。
    """

    var isInteractive: Bool { true } // 豁免默认 30 秒硬超时限制，静候子智能体生成

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "tasks": [
                    "type": "array",
                    "description": "派发给子智能体的任务列表（1个为单任务委托，多个为并发协作）",
                    "items": [
                        "type": "object",
                        "properties": [
                            "agent_id": [
                                "type": "string",
                                "description": "目标子智能体 ID。可选值：'observer' (识图助理与图文分析), 'coder' (代码专家与工程规范), 'librarian' (资料检索与实时情报专家，专属配备 web_search 与 fetch_url 联网工具，负责全网搜索最新行情、新闻与文档), 'oracle' (深度思考与逻辑推演), 'concierge' (系统管家与桌面控制)"
                            ],
                            "task": [
                                "type": "string",
                                "description": "派发给该子智能体的详细需求、上下文背景与交付标准"
                            ],
                            "include_attachments": [
                                "type": "boolean",
                                "description": "是否将当前会话中用户上传的多模态媒体附件（图片等）传递给子智能体（默认为 true）"
                            ]
                        ],
                        "required": ["agent_id", "task"]
                    ]
                ]
            ],
            "required": ["tasks"]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let tasksRaw = arguments["tasks"] as? [[String: Any]], !tasksRaw.isEmpty else {
            throw ToolExecutionError("缺少必需参数：tasks 任务数组不能为空")
        }

        let executionSessionId = ToolExecutionContext.currentSessionId
        let (parentId, sessionImages) = await MainActor.run { () -> (UUID, [ChatImageAttachment]) in
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
            let rootId = session.parentSessionId ?? session.id
            let lastWithImages = session.messages.last { !$0.images.isEmpty }
            return (rootId, lastWithImages?.images ?? [])
        }

        var parsedTasks: [(agentId: String, task: String, attachments: [ChatImageAttachment])] = []
        for raw in tasksRaw {
            guard let agentId = raw["agent_id"] as? String, !agentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            guard let task = raw["task"] as? String, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let includeAttachments = (raw["include_attachments"] as? Bool) ?? (raw["include_images"] as? Bool) ?? true
            let imgs = includeAttachments ? sessionImages : []
            parsedTasks.append((agentId, task, imgs))
        }

        guard !parsedTasks.isEmpty else {
            throw ToolExecutionError("tasks 数组中没有合法的有效任务")
        }

        let results = await AgentCoordinator.shared.launchSubagents(
            parentId: parentId,
            tasks: parsedTasks
        )

        let output: [String: Any] = [
            "ok": true,
            "total_tasks": results.count,
            "results": results
        ]

        return AIToolExecutor.encodeJSON(output)
    }
}
