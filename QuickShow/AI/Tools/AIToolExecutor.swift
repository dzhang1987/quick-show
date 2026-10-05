import Foundation

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

        // 3) 危险工具：执行前经用户确认
        if tool.isDangerous {
            let confirmed = await confirmDangerousExecution(tool: tool, argumentsJSON: call.argumentsJSON)
            guard confirmed else {
                return ToolExecutionResult(
                    callID: call.id,
                    name: call.name,
                    argumentsJSON: call.argumentsJSON,
                    resultJSON: Self.encodeJSON(["ok": false, "error": "用户已拒绝执行该工具"]),
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

    // MARK: - 危险确认

    /// 经输入坞抽屉请求危险工具确认（原 NSAlert 逻辑已整体移除）。
    /// 流程：会话记忆命中 → 直接放行；否则发布请求并挂起等待 UI 响应。
    /// 返回 true = 允许执行，false = 拒绝。
    /// 会话记忆以「工具名 + 参数原文」为键，`.alwaysAllowThisSession` 时写入。
    @MainActor
    private func confirmDangerousExecution(tool: AITool, argumentsJSON: String) async -> Bool {
        let center = ChatInteractionCenter.shared

        // 1) 会话内已允许同一命令：直接放行，不再打扰用户
        if center.isSessionAllowed(toolName: tool.name, argumentsJSON: argumentsJSON) {
            return true
        }

        // 2) 发布抽屉请求并挂起（summary 由交互中心按单行摘要规则生成；无 UI 时中心兜底 .denied）
        let outcome = await center.requestToolConfirmation(
            toolName: tool.name,
            argumentsJSON: argumentsJSON
        )
        switch outcome {
        case .denied:
            return false
        case .executeOnce:
            return true
        case .alwaysAllowThisSession:
            center.rememberSessionAllowed(toolName: tool.name, argumentsJSON: argumentsJSON)
            return true
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