import AppKit
import Foundation

// MARK: - AI 工具协议

/// AI 工具协议：内置工具统一实现，由 AIToolExecutor 调度执行
protocol AITool {
    /// snake_case 工具名
    var name: String { get }
    /// 给模型看的功能说明（中文）
    var description: String { get }
    /// OpenAI function calling 的 JSON Schema（object 结构）
    var parametersSchema: [String: Any] { get }
    /// 危险工具执行前需用户确认
    var isDangerous: Bool { get }
    /// 执行工具，返回结果 JSON 文本；抛错时由执行器封装为 failed 结果
    func execute(arguments: [String: Any]) async throws -> String
}

extension AITool {
    /// 默认非危险：仅明确标注的工具需要用户确认
    var isDangerous: Bool { false }
}

// MARK: - 协议层模型

/// 工具调用状态（会话持久化模型复用，定义在此处全局唯一）
enum ToolCallStatus: String, Codable {
    case pending    // 已收到调用请求未执行
    case running    // 执行中
    case done       // 执行成功
    case failed     // 执行抛错
    case denied     // 用户拒绝执行
}

/// 一次工具调用请求（协议层解析产物）
struct ToolCallRequest {
    let id: String          // 协议层 tool call id
    let name: String
    let argumentsJSON: String  // 参数 JSON 原文
}

/// 工具执行结果
struct ToolExecutionResult {
    let callID: String
    let name: String
    let argumentsJSON: String
    let resultJSON: String     // 统一为 {"ok":true,"data":...} 或 {"ok":false,"error":"..."}
    let status: ToolCallStatus
}

/// 工具执行错误：由工具实现抛出，执行器统一封装为 failed 结果
struct ToolExecutionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - 工具注册表

/// AI 工具注册表：集中持有全部内置工具，并按用户配置提供启用集合
final class AIToolRegistry {
    static let shared = AIToolRegistry()

    /// UserDefaults 键：启用的工具名数组（[String]）
    static let enabledToolsKey = "ai.tools.enabled"

    /// 默认关闭的工具名：run_shell 可执行任意命令、风险最高，键缺失时默认禁用。
    /// 其余工具（含同样 isDangerous 的 write_file，执行前仍会弹窗确认）默认启用。
    private static let defaultDisabledToolNames: Set<String> = ["run_shell"]

    /// 全部已注册工具
    private let tools: [AITool]

    private init() {
        // 内置工具统一在此注册；新增工具只需在数组中追加一行
        tools = [
            ReadClipboardTool(),
            WriteClipboardTool(),
            SystemStatusTool(),
            ListRunningAppsTool(),
            OpenAppTool(),
            ReadFileTool(),
            WriteFileTool(),
            GetEnvTool(),
            SetEnvTool(),
            ListEnvTool(),
            QuickShowStateTool(),
            WebSearchTool(),
            FetchURLTool(),
            RunShellTool()
        ]
    }

    /// 全部已注册工具（含默认关闭的 run_shell）
    func allTools() -> [AITool] { tools }

    /// 按配置启用的工具：读取 UserDefaults 键 "ai.tools.enabled"（[String] 工具名数组），
    /// 键不存在时默认除危险工具 run_shell 外全部启用
    func enabledTools() -> [AITool] {
        guard let names = UserDefaults.standard.stringArray(forKey: Self.enabledToolsKey) else {
            return tools.filter { !Self.defaultDisabledToolNames.contains($0.name) }
        }
        let enabled = Set(names)
        return tools.filter { enabled.contains($0.name) }
    }

    /// 按名查找（含未启用，用于执行校验时判断“存在但被禁用”）
    func tool(named name: String) -> AITool? {
        tools.first { $0.name == name }
    }
}