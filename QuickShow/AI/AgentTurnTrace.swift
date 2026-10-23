import Foundation

// MARK: - 智能体回合执行轨迹 (Agent Turn Trace)
//
// 设计哲学（第一性原理）：
// - 智能体在处理复杂任务时，通常经历多轮 ReAct 循环（多轮思考与工具调用）。
// - 在用户心智中，一次提问对应的全部多轮推导与工具调研，是同一个完整的“解决过程（Turn Trace）”，
//   绝不可因底层产生了多条 ChatMessage 而在界面上机械分裂为多个独立的折叠条（千层饼现象）。
// - 本模型将一个 Assistant MessageGroup 内的全部思考与工具动作聚合为一个连贯的时间轨迹。

/// 智能体单个回合的聚合执行轨迹（思考与工具链）
struct AgentTurnTrace: Equatable {

    /// 单轮执行步骤
    struct Step: Identifiable, Equatable {
        let id: String
        let roundIndex: Int
        let reasoning: String?
        let toolCalls: [ToolCallRecord]
        let isLive: Bool

        var hasReasoning: Bool {
            !(reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }

        var hasTools: Bool {
            !toolCalls.isEmpty
        }
    }

    /// 本回合包含的所有步骤（按轮次排序）
    let steps: [Step]
    /// 是否仍在流式生成中
    let isLive: Bool

    /// 本回合调用的全部工具总数
    var totalToolsCount: Int {
        steps.reduce(0) { $0 + $1.toolCalls.count }
    }

    /// 本回合失败/被拒绝的工具总数
    var failedToolsCount: Int {
        steps.reduce(0) { sum, step in
            sum + step.toolCalls.filter { $0.status == .failed || $0.status == .denied }.count
        }
    }

    /// 是否包含任何思考内容
    var hasReasoning: Bool {
        steps.contains { $0.hasReasoning }
    }

    /// 是否包含任何工具调用
    var hasTools: Bool {
        totalToolsCount > 0
    }

    /// 是否为空轨迹
    var isEmpty: Bool {
        !hasReasoning && !hasTools
    }

    /// 轮次总数
    var roundCount: Int {
        steps.count
    }

    /// 当前正在运行的工具名称（优先取最新活跃轮次）
    var runningToolDisplayName: String? {
        for step in steps.reversed() {
            if let running = step.toolCalls.first(where: { $0.status == .running || $0.status == .pending }) {
                return AIToolRegistry.shared.tool(named: running.name)?.displayName ?? running.name
            }
        }
        return nil
    }

    /// 提取最新一段思考摘要（用于折叠态简要呈现）
    var latestReasoningSummary: String {
        for step in steps.reversed() {
            if let reasoning = step.reasoning {
                let paragraphs = reasoning
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if let last = paragraphs.last {
                    return last
                }
            }
        }
        return String(localized: "思考中…")
    }

    /// 提取全部步骤中的所有工具调用列表
    var allToolCalls: [ToolCallRecord] {
        steps.flatMap { $0.toolCalls }
    }
}

// MARK: - 工厂提取

extension AgentTurnTrace {
    /// 从同一个助手消息组（Assistant MessageGroup）的消息序列中提取聚合轨迹。
    /// - Parameters:
    ///   - messages: 属于同一 Assistant 回合的全部消息。
    ///   - isStreaming: 当前会话是否正在流式生成中。
    /// - Returns: 若包含思考或工具调用则返回聚合轨迹，否则返回 nil。
    static func extract(from messages: [ChatMessage], isStreaming: Bool) -> AgentTurnTrace? {
        var steps: [Step] = []
        for (index, msg) in messages.enumerated() {
            let reasoning = msg.reasoning
            let calls = msg.toolCalls ?? []
            let isStepLive = isStreaming && (index == messages.count - 1)
            let hasReasoning = !(reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

            if hasReasoning || !calls.isEmpty {
                steps.append(Step(
                    id: msg.id.uuidString,
                    roundIndex: index + 1,
                    reasoning: reasoning,
                    toolCalls: calls,
                    isLive: isStepLive
                ))
            }
        }
        guard !steps.isEmpty else { return nil }
        return AgentTurnTrace(steps: steps, isLive: isStreaming)
    }
}
