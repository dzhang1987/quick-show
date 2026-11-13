import Foundation

// MARK: - 工具执行会话上下文 (基于 Swift 结构化并发 TaskLocal 隔离)

enum ToolExecutionContext {
    /// 当前异步任务链条中发起工具调用的真实会话 ID（彻底隔离 UI 前台选中态，消除并发漂移）
    @TaskLocal static var currentSessionId: UUID?
}

// MARK: - 工具执行器

/// AI 工具执行器：串联注册表、危险确认、超时与统一结果序列化。
/// 执行入口为 async 非隔离，可被后台对话回路直接调用；
/// 危险确认经 ChatInteractionCenter 发布输入坞抽屉请求（原 NSAlert 已移除），
/// 涉及 MainActor 状态的操作用 await 桥接。
final class AIToolExecutor {
    static let shared = AIToolExecutor()

    /// 单轮对话内工具调用轮数上限（供对话回路层读取）。
    /// 达到「上限 - 2」轮时回路先注入软限制收尾提示，引导模型自行收敛；
    /// 真正达到上限才硬截断并落说明文本。
    static let maxToolRounds = 16

    /// 单次工具执行超时秒数
    static let executionTimeout: TimeInterval = 30

    private init() {}

    /// 执行一次工具调用：
    /// 1) 工具不存在或被禁用 → failed（error 说明）
    /// 2) isDangerous → 经输入坞抽屉请求用户确认，取消/无 UI → denied
    /// 3) 执行超时 30 秒 → failed；交互工具（isInteractive）豁免超时，无限静候
    /// 4) 正常返回 → done，resultJSON 为工具返回文本（若工具未按 ok/error 包装则包一层）
    func execute(call: ToolCallRequest) async -> ToolExecutionResult {
        let registry = AIToolRegistry.shared

        // 1) 存在性校验
        guard let tool = registry.tool(named: call.name) else {
            return makeFailure(call, message: "工具不存在：\(call.name)")
        }
        let executionMode = SettingsStore.currentExecutionMode
        let sourceSessionID = ToolExecutionContext.currentSessionId

        // schema 下发只影响模型可见性，不能充当安全边界；执行入口必须再次按真实来源会话复验角色白名单。
        if executionMode == .single {
            let multiAgentInternalTools: Set<String> = ["launch_subagents", "send_message"]
            if multiAgentInternalTools.contains(call.name) {
                return makeFailure(call, message: "单 Agent 模式下未启用多智能体协同调度工具：\(call.name)")
            }
        } else {
            let allowed = await MainActor.run { () -> Bool in
                guard let sourceSessionID,
                      let session = ChatSessionStore.shared.session(id: sourceSessionID) else {
                    return false
                }
                let agent: AIAgent?
                if let agentID = session.agentId {
                    agent = AIAgentStore.shared.agent(for: agentID)
                } else {
                    agent = AIAgentStore.shared.activeAgent
                }
                return registry.isToolAllowed(call.name, for: agent, mode: executionMode)
            }
            guard allowed else {
                return makeFailure(call, message: "当前智能体未获授权使用工具：\(call.name)")
            }
        }
        // 启用校验：存在但被禁用同样失败
        guard registry.enabledTools().contains(where: { $0.name == call.name }) else {
            return makeFailure(call, message: "工具已被禁用：\(call.name)")
        }

        // 2) 参数解析（危险确认的摘要也依赖解析结果）
        let arguments: [String: Any]
        do {
            arguments = try Self.parseArguments(call.argumentsJSON)
        } catch {
            return makeFailure(call, message: "参数解析失败：\(error.localizedDescription)")
        }

        // 3) 动态风险评估与分级授权（静默 / 会话授权 / 逐次 / 硬门禁）
        let risk = ToolRiskClassifier.shared.evaluateRisk(tool: tool, arguments: arguments)
        if !risk.isAutoApproved {
            let decision = await authorizeExecution(
                tool: tool,
                argumentsJSON: call.argumentsJSON,
                risk: risk,
                sourceSessionID: sourceSessionID
            )
            if case .denied(let message) = decision {
                return ToolExecutionResult(
                    callID: call.id,
                    name: call.name,
                    argumentsJSON: call.argumentsJSON,
                    resultJSON: Self.encodeJSON(["ok": false, "error": message]),
                    status: .denied
                )
            }
        }

        // 4) 执行：交互工具（如 ask_user）挂起等待用户操作，无限静候、豁免超时；
        //    其余工具带 30 秒超时执行。
        do {
            let raw: String
            if tool.isInteractive {
                raw = try await tool.execute(arguments: arguments)
            } else {
                raw = try await Self.runWithTimeout(seconds: Self.executionTimeout) {
                    try await tool.execute(arguments: arguments)
                }
            }
            return ToolExecutionResult(
                callID: call.id,
                name: call.name,
                argumentsJSON: call.argumentsJSON,
                resultJSON: Self.normalizeResult(raw),
                status: .done
            )
        } catch is ToolTimeoutError {
            return makeFailure(call, message: "工具执行超时（\(Int(Self.executionTimeout)) 秒）")
        } catch {
            return makeFailure(call, message: error.localizedDescription)
        }
    }

    // MARK: - 结果封装

    private func makeFailure(_ call: ToolCallRequest, message: String) -> ToolExecutionResult {
        ToolExecutionResult(
            callID: call.id,
            name: call.name,
            argumentsJSON: call.argumentsJSON,
            resultJSON: Self.encodeJSON(["ok": false, "error": message]),
            status: .failed
        )
    }

    /// 统一 JSON 序列化（键排序，保证输出稳定）
    static func encodeJSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"结果序列化失败\"}"
        }
        return text
    }

    /// 工具返回文本若非 {"ok":...} 包装，则统一包为 {"ok":true,"data":...}
    private static func normalizeResult(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["ok"] != nil {
            return trimmed
        }
        return encodeJSON(["ok": true, "data": raw])
    }

    /// 参数原文解析：空串视为无参 {}
    private static func parseArguments(_ json: String) throws -> [String: Any] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8) else {
            throw ToolExecutionError("参数不是合法的 UTF-8 文本")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw ToolExecutionError("参数必须是 JSON 对象")
        }
        return dict
    }

    // MARK: - 分级授权裁决

    /// 授权裁决：proceed = 允许本次执行；denied = 拒绝（附用户可读原因）。
    private enum AuthorizationDecision {
        case proceed
        case denied(message: String)
    }

    /// 分级授权：
    /// - sessionGrantable：先查会话授权记忆（granted → 静默放行；denied → 静默拒绝，不反复询问）；
    ///   undecided → 抽屉问一次，「本会话允许」/ ⌘⏎ 记录授权，拒绝记录拒绝；
    /// - requiresConfirmation / destructive：逐次抽屉，无记忆（Shell 无通配、高危硬门禁）。
    /// 模型不能批准自己的操作：裁决只来自宿主确定性代码与用户确认。
    @MainActor
    private func authorizeExecution(
        tool: AITool,
        argumentsJSON: String,
        risk: ToolRiskLevel,
        sourceSessionID: UUID?
    ) async -> AuthorizationDecision {
        let grantStore = ToolPermissionGrantStore.shared
        let sessionID = sourceSessionID ?? ChatSessionStore.shared.currentSessionId

        if let scope = risk.grantScope {
            switch grantStore.decision(for: scope, sessionID: sessionID) {
            case .granted:
                return .proceed
            case .denied:
                return .denied(message: "用户已在本会话拒绝\(scope.displayTitle)，请改用其他方式完成任务，或提示用户在顶栏授权列表重新开启")
            case .undecided:
                break
            }
        }

        let outcome = await ChatInteractionCenter.shared.requestToolConfirmation(
            toolName: tool.name,
            argumentsJSON: argumentsJSON,
            riskLevel: risk,
            sourceSessionID: sourceSessionID,
            suggestedScope: risk.grantScope
        )
        switch outcome {
        case .denied:
            if let scope = risk.grantScope {
                grantStore.recordDenial(scope: scope, sessionID: sessionID)
            }
            return .denied(message: "用户已拒绝执行该工具")
        case .executeOnce:
            return .proceed
        case .grantSession:
            if let scope = risk.grantScope {
                grantStore.recordGrant(scope: scope, sessionID: sessionID)
            }
            return .proceed
        }
    }

    // MARK: - 超时控制

    /// 竞速执行：operation 先完成则取其结果；超时则返回 ToolTimeoutError。
    /// 采用一次性 continuation 闸门，超时后立即返回（不等待挂起的 operation）。
    private static func runWithTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate(continuation)
            Task {
                do {
                    gate.finish(.success(try await operation()))
                } catch {
                    gate.finish(.failure(error))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                gate.finish(.failure(ToolTimeoutError()))
            }
        }
    }
}

/// 超时标记错误
struct ToolTimeoutError: LocalizedError {
    var errorDescription: String? { "工具执行超时" }
}

/// 一次性 continuation 闸门：保证结果只 resume 一次（成功 / 抛错 / 超时竞态安全）
private final class ContinuationGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(with: result)
    }
}