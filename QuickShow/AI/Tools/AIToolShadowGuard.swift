import Foundation

// MARK: - 旁路大模型安全守卫（Shadow Guardrail）

/// 旁路智能安全守卫（AIToolShadowGuard）
/// 职责：当本地静态规则无法 100% 确认命令为只读（且未触发破坏性硬门禁）时，
/// 异步唤起轻量级后台大模型对命令语义进行快速裁决，实现未知安全命令的智能免审放行。
final class AIToolShadowGuard: Sendable {
    static let shared = AIToolShadowGuard()

    /// 单次旁路审核超时上限（秒），超时后静默降级为人工确认抽屉
    private let auditTimeoutSeconds: TimeInterval = 2.0

    private init() {}

    /// 是否开启旁路智能审计（默认开启）
    var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "ai.security.shadowGuard.enabled") == nil {
            return true
        }
        return defaults.bool(forKey: "ai.security.shadowGuard.enabled")
    }

    /// 对受控变更/未知风险工具调用进行旁路智能审核
    /// 返回 true = 确认为只读安全操作，可免审放行；false = 有风险、超时或不可判定，回退人工确认
    func auditForAutoApproval(tool: AITool, arguments: [String: Any]) async -> Bool {
        guard isEnabled else { return false }

        // 目前主要针对 run_shell 进行复杂语义分析
        guard tool.name == "run_shell", let command = arguments["command"] as? String else {
            return false
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        do {
            return try await runWithTimeout(seconds: auditTimeoutSeconds) {
                await self.performLLMAudit(command: trimmed)
            }
        } catch {
            qsDebugLog("AIToolShadowGuard 审计超时或异常，降级人工确认: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 私有大模型审计实现

    private func performLLMAudit(command: String) async -> Bool {
        let systemPrompt = """
你是一个底层操作系统安全审查员。请严格评估待执行的 Shell 命令。
审查标准：该命令是否仅用于「只读感知、环境探测、状态查询、只读计算」（如查看系统信息、硬件状态、内存、电池、只读打印等），且【完全没有】以下任何副作用：
1. 写入、修改、删除、移动或覆盖真实文件（允许丢弃流至 /dev/null 或 2>&1 等流重定向）；
2. 更改系统配置、网络设置、内核参数或持久化状态；
3. 系统关机、重启、强制杀死关键系统服务；
4. 提权、密码凭据读取、外部恶意数据外发。

输出格式：必须严格且仅输出单个合法 JSON 对象，严禁输出任何额外解释、文字或 Markdown 标记。
示例：{"is_safe": true} 或 {"is_safe": false, "reason": "修改了配置"}
"""
        let userPrompt = "待审核 Shell 命令:\n\(command)"

        let messages = [
            ChatCompletionMessage(role: "system", content: systemPrompt),
            ChatCompletionMessage(role: "user", content: userPrompt)
        ]

        let options = AIChatRequestOptions(
            modelId: nil, // 回落当前服务商的激活模型
            thinkingLevel: .off, // 关闭思考以获得最低延迟
            agentId: nil,
            disableTools: true // 强制不携带工具声明，杜绝循环调用
        )

        do {
            let responseText = try await AIChatService.shared.complete(
                messages: messages,
                options: options,
                maxTokens: 60
            )
            return parseAuditDecision(from: responseText)
        } catch {
            qsDebugLog("AIToolShadowGuard LLM 请求失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 从大模型文本中鲁棒提取 JSON 裁决
    func parseAuditDecision(from text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // 1. 尝试直接反序列化
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let isSafe = obj["is_safe"] as? Bool {
            return isSafe
        }

        // 2. 尝试提取包含花括号的 JSON 块
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start < end {
            let jsonSub = String(trimmed[start...end])
            if let data = jsonSub.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let isSafe = obj["is_safe"] as? Bool {
                return isSafe
            }
        }

        // 3. 启发式正则/文本包含匹配
        let lower = trimmed.lowercased()
        if (lower.contains("\"is_safe\": true") || lower.contains("\"is_safe\":true")) && !lower.contains("\"is_safe\": false") && !lower.contains("\"is_safe\":false") {
            return true
        }

        return false
    }

    /// 超时竞速辅助
    private func runWithTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ToolTimeoutError()
            }
            guard let first = try await group.next() else {
                throw ToolTimeoutError()
            }
            group.cancelAll()
            return first
        }
    }
}
