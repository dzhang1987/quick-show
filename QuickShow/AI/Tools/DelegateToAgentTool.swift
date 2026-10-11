// DelegateToAgentTool: 多智能体中枢编排工具。
// 允许编排中枢（Lead / Generalist）将子任务（如识图、架构设计、代码实现）显式派发给特定子智能体执行。

import Foundation

final class DelegateToAgentTool: AITool {
    let name = "delegate_to_agent"
    let displayName = "委派子智能体"
    let category: ToolCategory = .interaction
    let description = """
    将具体任务委派给专业的子智能体（如视觉感知专家 Observer、系统架构师 Architect、全能工程师 Engineer、快速探索者 Explorer 等）独立执行，并获取其专业分析或生成成果。适用于需要识图、跨模型能力、或专业分工的复杂任务。
    """

    var isInteractive: Bool { true } // 豁免默认 30 秒硬超时，静候子智能体生成完整结果

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "agent_id": [
                    "type": "string",
                    "description": "目标子智能体 ID 或名称，例如：'observer' (视觉感知与多模态分析), 'architect' (系统设计与方案架构), 'engineer' (代码开发与问题修复), 'explorer' (快速探索与信息检索)"
                ],
                "task": [
                    "type": "string",
                    "description": "委派给该子智能体的具体任务要求与上下文提示"
                ],
                "include_images": [
                    "type": "boolean",
                    "description": "是否将用户最近上传的图片附件传递给子智能体（默认 true，若目标为视觉智能体 observer 时需为 true）"
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
        let includeImages = (arguments["include_images"] as? Bool) ?? true

        // 1. 查找匹配的子智能体
        let cleanTarget = agentTarget.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = await MainActor.run { () -> AIAgent? in
            let agents = AIAgentStore.shared.agents
            if let matched = agents.first(where: {
                $0.id.lowercased() == cleanTarget ||
                $0.name.lowercased() == cleanTarget ||
                cleanTarget.contains($0.id.lowercased()) ||
                $0.name.lowercased().contains(cleanTarget)
            }) {
                return matched
            }
            if cleanTarget.contains("view") || cleanTarget.contains("视觉") || cleanTarget.contains("image") || cleanTarget.contains("图") {
                return AIAgentStore.shared.visualDelegateAgent
            }
            return nil
        }

        guard let target else {
            let availableList = await MainActor.run {
                AIAgentStore.shared.agents.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
            }
            throw ToolExecutionError("未找到目标智能体 '\(agentTarget)'。可用智能体：\(availableList)")
        }

        // 2. 获取图片附件（如果需要）
        var imagesToPass: [ChatImageAttachment] = []
        if includeImages {
            imagesToPass = await MainActor.run {
                let session = AIChatState.shared.store.ensureCurrentSession()
                let lastWithImages = session.messages.last { !$0.images.isEmpty }
                return lastWithImages?.images ?? []
            }
        }

        // 3. 执行单次子智能体推理
        let resultText = try await AIProviderService.shared.performOneOffCompletion(
            agent: target,
            prompt: task,
            images: imagesToPass
        )

        let output: [String: Any] = [
            "ok": true,
            "agent_id": target.id,
            "agent_name": target.name,
            "result": resultText
        ]

        return AIToolExecutor.encodeJSON(output)
    }
}
