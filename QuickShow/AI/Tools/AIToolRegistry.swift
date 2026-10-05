import AppKit
import Foundation

// MARK: - 工具执行策略

/// 工具执行策略：决定工具调用在会话回路中可与其他工具并发执行，还是必须逐个串行。
/// 默认串行（保守）；仅经确认「纯读、无共享可变状态」的工具才标注为 parallelSafe。
enum ToolExecutionPolicy {
    /// 纯读、无共享可变状态：可与其他并行安全工具同时执行。
    case parallelSafe
    /// 有副作用或共享可变状态：必须逐个串行执行。
    case serial
}

// MARK: - 工具分类

/// 内置工具分类：设置页分组与展示用。
/// `rawValue` 稳定，`allCases` 即固定分组顺序（剪贴板/系统状态/文件/环境变量/联网/地图/用户互动）。
enum ToolCategory: String, CaseIterable {
    case clipboard
    case system
    case files
    case environment
    case web
    case map
    /// 用户互动类（如 ask_user）：挂在分组序最后
    case interaction

    /// 分组中文名
    var label: String {
        switch self {
        case .clipboard: return "剪贴板"
        case .system: return "系统状态"
        case .files: return "文件"
        case .environment: return "环境变量"
        case .web: return "联网"
        case .map: return "地图"
        case .interaction: return "用户互动"
        }
    }
}

// MARK: - AI 工具协议

/// AI 工具协议：内置工具统一实现，由 AIToolExecutor 调度执行。
/// displayName / category 仅供 UI 展示，不参与模型调用：发给模型的 name/schema
/// 与执行链路保持 snake_case 原样，`ai.tools.enabled` 落盘仍是蛇形名数组（存量零迁移）。
protocol AITool {
    /// snake_case 工具名
    var name: String { get }
    /// 用户界面展示名（中文，如「网页搜索」）；协议层/JSON 仍用蛇形 name
    var displayName: String { get }
    /// 工具分类（设置页分组依据）
    var category: ToolCategory { get }
    /// 给模型看的功能说明（中文）
    var description: String { get }
    /// OpenAI function calling 的 JSON Schema（object 结构）
    var parametersSchema: [String: Any] { get }
    /// 危险工具执行前需用户确认
    var isDangerous: Bool { get }
    /// 执行策略：parallelSafe = 可并行；serial = 必须串行（默认）。
    var executionPolicy: ToolExecutionPolicy { get }
    /// 是否交互工具：需挂起等待用户操作（如 ask_user）。经协议要求声明以获得动态派发，
    /// 执行器对 true 的工具豁免超时（无限静候用户）。
    var isInteractive: Bool { get }
    /// 执行工具，返回结果 JSON 文本；抛错时由执行器封装为 failed 结果
    func execute(arguments: [String: Any]) async throws -> String
}

extension AITool {
    /// 默认非危险：仅明确标注的工具需要用户确认
    var isDangerous: Bool { false }
    /// 默认串行：未明确标注为并行安全的工具一律保守串行，避免并发副作用。
    var executionPolicy: ToolExecutionPolicy { .serial }
    /// 默认非交互：仅需挂起等待用户操作的工具体（如 ask_user）标注 true，
    /// 执行器对其豁免超时（无限静候用户）。
    var isInteractive: Bool { false }
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
            RunShellTool(),
            GeocodeTool(),
            SearchPlacesTool(),
            PlanRouteTool(),
            ShowMapTool(),
            MyLocationTool(),
            AskUserTool()
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

    /// 查询指定工具名的执行策略；未知工具名返回 .serial（保守处理）。
    func executionPolicy(for toolName: String) -> ToolExecutionPolicy {
        tool(named: toolName)?.executionPolicy ?? .serial
    }

    /// 全部工具按分类分组：固定组序（ToolCategory.allCases），组内保持注册顺序；
    /// 空分类不返回。供设置页分组渲染。
    func toolsGroupedByCategory() -> [(category: ToolCategory, tools: [AITool])] {
        let grouped = Dictionary(grouping: tools, by: { $0.category })
        return ToolCategory.allCases.compactMap { category in
            guard let items = grouped[category], !items.isEmpty else { return nil }
            return (category, items)
        }
    }
}