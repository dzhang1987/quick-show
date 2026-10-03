import Foundation

// MARK: - 思考强度（统一档位）

/// 思考强度统一档位：适配层把各模型差异化的思考字段收敛到该枚举，
/// UI 与会话层只面对统一档位，不关心底层模型的具体字段名与取值范围。
enum ThinkingLevel: String, Codable, CaseIterable {
    case off, low, medium, high
}

// MARK: - 上下文水位

/// 上下文水位快照：已用 token 与当前模型窗口 token，供 UI 渲染水位条。
struct ContextWatermark {
    let usedTokens: Int
    let windowTokens: Int
    var ratio: Double { windowTokens > 0 ? Double(usedTokens) / Double(windowTokens) : 0 }
}

// MARK: - 模型适配层

/// 模型适配层：集中屏蔽不同 OpenAI 兼容端点在「思考字段」与「上下文窗口」上的差异。
/// 其余代码只面对 ThinkingLevel / ContextWatermark 统一抽象，不关心具体模型。
enum AIModelAdapter {
    /// 默认上下文窗口（tokens）：模型未配置 contextWindow 时使用（512K）。
    static let defaultContextWindow = 524288

    /// 该模型是否支持关闭思考。
    /// 实测（本端点 DashScope OpenAI 兼容层）：glm-5.3 被限制为必须思考，
    /// 不接受 `enable_thinking=false`，故不展示「关闭」档。
    static func canDisableThinking(for modelId: String) -> Bool {
        !modelId.hasPrefix("glm-5.3")
    }

    /// 统一档位 → 具体请求字段。返回空字典 = 不发任何思考字段（跟随模型默认）。
    /// 映射规则（基于对本端点实测，注释注明差异）：
    /// - level 为 nil → `[:]`，跟随模型默认；
    /// - .off → 可关闭的模型发 `["enable_thinking": false]`；不可关闭则 `[:]`（防御，UI 不展示该档）；
    /// - .low/.medium/.high → 发 `reasoning_effort`：glm-5.3 实测只接受 low/high/max 三个值，
    ///   故中档映射 high、高档映射 max；其他模型实测接受 low/medium/high，直接透传档位名。
    static func thinkingFields(for modelId: String, level: ThinkingLevel?) -> [String: Any] {
        guard let level else { return [:] }
        switch level {
        case .off:
            return canDisableThinking(for: modelId) ? ["enable_thinking": false] : [:]
        case .low, .medium, .high:
            let effort: String
            if modelId.hasPrefix("glm-5.3") {
                switch level {
                case .low: effort = "low"
                case .medium: effort = "high"
                case .high: effort = "max"
                case .off: effort = "low"
                }
            } else {
                effort = level.rawValue
            }
            return ["reasoning_effort": effort]
        }
    }

    /// 当前生效模型的上下文窗口（tokens）：从 modelList 中查该模型的 contextWindow 字段，
    /// 查不到或非法时回退默认 524288。
    @MainActor
    static func contextWindow(for modelId: String?) -> Int {
        guard let modelId, !modelId.isEmpty else { return defaultContextWindow }
        if let match = AIChatService.shared.modelList.first(where: { $0.modelId == modelId }),
           let window = match.contextWindow, window > 0 {
            return window
        }
        return defaultContextWindow
    }
}