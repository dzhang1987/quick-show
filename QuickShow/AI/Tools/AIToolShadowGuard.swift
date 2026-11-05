import Foundation

// MARK: - 旁路大模型安全守卫（Shadow Guardrail）

/// 旁路智能安全守卫的三档裁决结果
enum ShadowGuardVerdict: Equatable, Sendable {
    /// 纯只读感知操作
    case readonly
    /// 工作区内低风险受控变更（构建/测试/检查/项目内可逆文件生成）
    case lowRiskMutation
    /// 需人工审批（有风险、超时或不可判定时同样按此档处理）
    case needsApproval

    /// 是否可免审自动放行
    var isAutoApprovable: Bool {
        self != .needsApproval
    }
}

/// 旁路智能安全守卫（AIToolShadowGuard）
/// 职责：当本地静态规则无法确认命令安全（且未触发破坏性硬门禁）时，
/// 异步唤起轻量级后台大模型对命令语义进行三档裁决（只读 / 低危变更 / 需人工审批），
/// 实现常见开发命令的智能免审放行；同会话内裁决结果缓存，重复命令零延迟。
final class AIToolShadowGuard: @unchecked Sendable {
    static let shared = AIToolShadowGuard()

    /// 默认单次旁路审核超时上限（秒），超时后静默降级为人工确认抽屉
    private static let defaultAuditTimeoutSeconds: TimeInterval = 5.0

    /// 会话内裁决缓存：命令文本 → 裁决结果（纯内存，随会话重置清空）
    private let cacheLock = NSLock()
    private var verdictCache: [String: ShadowGuardVerdict] = [:]

    private init() {}

    // MARK: - 配置（UserDefaults 可调）

    /// 是否开启旁路智能审计（默认开启）
    var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "ai.security.shadowGuard.enabled") == nil {
            return true
        }
        return defaults.bool(forKey: "ai.security.shadowGuard.enabled")
    }

    /// 单次旁路审核超时上限（秒）；可经 `ai.security.shadowGuard.timeoutSeconds` 调整
    var auditTimeoutSeconds: TimeInterval {
        let configured = UserDefaults.standard.double(forKey: "ai.security.shadowGuard.timeoutSeconds")
        return configured > 0 ? configured : Self.defaultAuditTimeoutSeconds
    }

    /// 审计专用模型 ID（可选）；设置后用轻量快速模型裁决，回落当前激活模型
    private var auditModelId: String? {
        UserDefaults.standard.string(forKey: "ai.security.shadowGuard.modelId")
    }

    // MARK: - 对外审计入口

    /// 对受控变更/未知风险工具调用进行旁路智能审核。
    /// 返回 true = 只读或工作区内低危变更，可免审放行；false = 需回退人工确认。
    /// 同会话内相同命令文本命中缓存直接返回，不重复请求大模型。
    func auditForAutoApproval(tool: AITool, arguments: [String: Any]) async -> Bool {
        guard isEnabled else { return false }

        // 目前针对 run_shell 进行复杂语义分析
        guard tool.name == "run_shell", let command = arguments["command"] as? String else {
            return false
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // 1. 会话缓存命中：直接裁决
        if let cached = cachedVerdict(for: trimmed) {
            return cached.isAutoApprovable
        }

        // 2. 旁路大模型审计
        do {
            let verdict = try await runWithTimeout(seconds: auditTimeoutSeconds) {
                await self.performLLMAudit(command: trimmed)
            }
            cacheVerdict(verdict, for: trimmed)
            return verdict.isAutoApprovable
        } catch {
            qsDebugLog("AIToolShadowGuard 审计超时或异常，降级人工确认: \(error.localizedDescription)")
            return false
        }
    }

    /// 清空会话裁决缓存（随会话切换/新对话调用）
    func resetSessionCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        verdictCache.removeAll()
    }

    // MARK: - 私有大模型审计实现

    private func performLLMAudit(command: String) async -> ShadowGuardVerdict {
        let systemPrompt = """
        你是操作系统安全审查员。请把待执行的 Shell 命令严格裁决为以下三档之一：
        - readonly：纯只读感知——仅读取系统状态、查询信息、打印输出，无任何写入操作（允许输出丢弃至 /dev/null 与流合并）。
        - low_risk：受控低风险变更——在项目目录内进行构建、测试、代码检查、生成构建产物、可逆的文件生成或修改；不包含提权、不修改系统配置或内核参数、不外发数据、不进行大范围删除、不修改项目外的敏感文件（如 ~/.ssh、shell 配置、/etc）。
        - needs_approval：其余情况——无法安全自动放行的一切操作。

        输出格式：必须严格且仅输出单个合法 JSON 对象，严禁输出任何额外解释、文字或 Markdown 标记。
        示例：{"verdict":"readonly"} 或 {"verdict":"low_risk"} 或 {"verdict":"needs_approval","reason":"覆盖系统配置"}
        """
        let userPrompt = "待审核 Shell 命令:\n\(command)"

        let messages = [
            ChatCompletionMessage(role: "system", content: systemPrompt),
            ChatCompletionMessage(role: "user", content: userPrompt)
        ]

        let options = AIChatRequestOptions(
            modelId: auditModelId, // nil = 回落当前服务商的激活模型；可配置轻量快速模型
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
            return parseVerdict(from: responseText) ?? .needsApproval
        } catch {
            qsDebugLog("AIToolShadowGuard LLM 请求失败: \(error.localizedDescription)")
            return .needsApproval
        }
    }

    // MARK: - 裁决缓存

    private func cachedVerdict(for command: String) -> ShadowGuardVerdict? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return verdictCache[command]
    }

    private func cacheVerdict(_ verdict: ShadowGuardVerdict, for command: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        verdictCache[command] = verdict
    }

    // MARK: - 裁决解析

    /// 从大模型文本中鲁棒提取三档裁决（无法判定时返回 nil，按需审批处理）
    func parseVerdict(from text: String) -> ShadowGuardVerdict? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. 尝试直接反序列化
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let verdict = Self.verdict(fromJSONObject: object) {
            return verdict
        }

        // 2. 尝试提取包含花括号的 JSON 块
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start < end {
            let jsonSub = String(trimmed[start...end])
            if let data = jsonSub.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let verdict = Self.verdict(fromJSONObject: object) {
                return verdict
            }
        }

        // 3. 启发式文本匹配兜底
        let lower = trimmed.lowercased()
        if lower.contains("needs_approval") { return .needsApproval }
        if lower.contains("low_risk") { return .lowRiskMutation }
        if lower.contains("readonly") || lower.contains("read_only") { return .readonly }
        return nil
    }

    /// 从 JSON 对象提取裁决值
    private static func verdict(fromJSONObject object: [String: Any]) -> ShadowGuardVerdict? {
        guard let raw = object["verdict"] as? String else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "readonly": return .readonly
        case "low_risk", "low_risk_mutation", "lowRisk": return .lowRiskMutation
        case "needs_approval", "deny": return .needsApproval
        default: return nil
        }
    }

    // MARK: - 超时竞速辅助

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
