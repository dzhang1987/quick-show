import Foundation

// MARK: - 工具风险模型与能力作用域

/// 会话授权作用域：用户对「有界能力」授予本会话放行的粒度。
/// 授权只作用于有界表面（固定代码路径 / 目录边界 + 可撤销）；原始 Shell 永不进入本模型。
enum PermissionGrantScope: Equatable, Hashable, Sendable {
    /// 能力级：工具代码路径固定、影响可枚举（剪贴板 / 环境变量 / 位置 / 跨 Agent 发送等）
    case capability(toolName: String)
    /// 目录级：write_file 以目标目录为边界，每次写入有快照撤销收据
    case directory(path: String)

    /// 抽屉与授权列表的人类可读描述
    var displayTitle: String {
        switch self {
        case .capability(let toolName):
            let name = AIToolRegistry.shared.tool(named: toolName)?.displayName ?? toolName
            return String(localized: "使用「\(name)」")
        case .directory(let path):
            let folderName = URL(fileURLWithPath: path).lastPathComponent
            return String(localized: "写入目录「\(folderName)」")
        }
    }
}

/// 工具调用风险等级（四档：授权粒度匹配影响有界性）
enum ToolRiskLevel: Equatable, Sendable {
    /// 纯感知 / 只读操作：无副作用，100% 零审批自动放行
    case readOnly

    /// 有界敏感能力：首次询问一次会话授权；授权与拒绝都记忆，可见可撤销。
    case sessionGrantable(scope: PermissionGrantScope)

    /// 无界执行（原始 Shell）：静态规则无法证明影响，必须逐次确认，无会话通配。
    case requiresConfirmation

    /// 破坏性 / 逃逸高危操作：系统级破坏、关键配置篡改、越界提权，强制硬门禁审批
    case destructive(reason: String)

    /// 是否可以直接免审执行
    var isAutoApproved: Bool {
        if case .readOnly = self { return true }
        return false
    }

    /// 是否属于绝对破坏性操作（不可绕过硬门禁）
    var isDestructive: Bool {
        if case .destructive = self { return true }
        return false
    }

    /// 会话授权作用域（仅 sessionGrantable 档非 nil）
    var grantScope: PermissionGrantScope? {
        if case .sessionGrantable(let scope) = self { return scope }
        return nil
    }
}

// MARK: - 风险评估器协议（OCP 开闭原则）

/// AI 工具风险评估策略协议
protocol ToolRiskEvaluator: Sendable {
    /// 是否适用于当前工具调用
    func canEvaluate(toolName: String) -> Bool
    /// 计算风险等级
    func evaluateRisk(tool: AITool, arguments: [String: Any]) -> ToolRiskLevel
}

// MARK: - Shell 命令语义风险评估器

/// 针对 run_shell 的语义风险评估策略。
/// 基于 ShellCommandParser 的引号感知词法解析与 ShellCommandRiskAnalyzer 的结构化语义分析。
/// 分析结果只用于高危升级和影响说明；所有非空原始 Shell 都必须由用户逐次确认。
final class ShellSemanticRiskEvaluator: ToolRiskEvaluator {
    func canEvaluate(toolName: String) -> Bool {
        toolName == "run_shell"
    }

    func evaluateRisk(tool: AITool, arguments: [String: Any]) -> ToolRiskLevel {
        guard let command = arguments["command"] as? String else {
            return .destructive(reason: String(localized: "缺失待执行命令参数"))
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .requiresConfirmation
        }

        let units = ShellCommandParser.parseUnits(trimmed)
        guard !units.isEmpty else {
            return .requiresConfirmation
        }

        // 1. 破坏性硬门禁：任一命令单元命中，或未引用区域出现灾难字面量（$() 内嵌），整条拦截
        for unit in units {
            if let reason = ShellCommandRiskAnalyzer.destructiveReason(for: unit) {
                return .destructive(reason: reason)
            }
        }
        if let reason = ShellCommandRiskAnalyzer.catastrophicLiteralReason(in: trimmed) {
            return .destructive(reason: reason)
        }

        // 2. 原始 Shell 始终需要用户逐次确认。
        // 即使表面上是 pwd/cat/git status，/bin/zsh -lc 仍可通过参数、变量展开、命令替换、
        // 配置文件和解释器执行触达宿主环境。词法分析只用于高危升级与影响说明，不能作为授权依据。
        return .requiresConfirmation
    }
}

// MARK: - 文件写入风险评估器

/// 针对 write_file 的风险评估策略
final class FileRiskEvaluator: ToolRiskEvaluator {
    func canEvaluate(toolName: String) -> Bool {
        toolName == "write_file"
    }

    func evaluateRisk(tool: AITool, arguments: [String: Any]) -> ToolRiskLevel {
        guard let path = arguments["path"] as? String else {
            return .destructive(reason: String(localized: "缺失写入路径参数"))
        }

        let lower = path.lowercased()

        // 敏感系统文件硬门禁拦截
        let sensitivePrefixes = [
            "/etc", "/system", "/library", "/usr", "/bin", "/sbin",
            "~/.ssh", "~/.gnupg", "~/.zshrc", "~/.bash_profile", "~/.bashrc"
        ]
        for prefix in sensitivePrefixes {
            if lower.hasPrefix(prefix) || lower.contains("/.git/config") || lower.contains("/.ssh/") {
                return .destructive(reason: String(localized: "禁止写入系统敏感或密钥配置：\(path)"))
            }
        }

        // 有界 + 可撤销：目录级会话授权（首次写入问一次，同目录后续静默 + 逐次撤销收据）
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .deletingLastPathComponent().path
        return .sessionGrantable(scope: .directory(path: directory))
    }
}

// MARK: - Web 访问风险评估器

/// 普通公开信息检索直接执行；只有明显携带凭证或访问本机/内网目标时才打断用户。
final class WebAccessRiskEvaluator: ToolRiskEvaluator {
    func canEvaluate(toolName: String) -> Bool {
        toolName == "web_search" || toolName == "fetch_url"
    }

    func evaluateRisk(tool: AITool, arguments: [String: Any]) -> ToolRiskLevel {
        if tool.name == "web_search" {
            let query = arguments["query"] as? String ?? ""
            return SensitiveTextRedactor.containsSensitiveValue(in: query)
                ? .requiresConfirmation
                : .readOnly
        }

        let rawURL = arguments["url"] as? String ?? ""
        guard !SensitiveTextRedactor.containsSensitiveValue(in: rawURL),
              PublicWebAccessPolicy.isPublicHTTPURL(rawURL) else {
            return .requiresConfirmation
        }
        return .readOnly
    }
}

// MARK: - 敏感能力风险评估器

/// 这些工具会读取新的个人数据或改变宿主状态，但代码路径固定、影响有界：
/// 归入会话授权档——首次询问一次，授权/拒绝均记忆，顶栏可见可撤销。
final class SensitiveCapabilityRiskEvaluator: ToolRiskEvaluator {
    private static let approvalRequiredTools: Set<String> = [
        "read_clipboard", "write_clipboard", "list_running_apps", "open_app",
        "read_file", "preview_file",
        "get_env", "set_env", "list_env",
        "geocode", "search_places", "plan_route", "my_location",
        "launch_subagents", "send_message"
    ]

    func canEvaluate(toolName: String) -> Bool {
        Self.approvalRequiredTools.contains(toolName)
    }

    func evaluateRisk(tool: AITool, arguments: [String: Any]) -> ToolRiskLevel {
        .sessionGrantable(scope: .capability(toolName: tool.name))
    }
}

// MARK: - 默认静态风险评估器

/// 保底策略：依据工具本身的静态属性进行分级
final class DefaultToolRiskEvaluator: ToolRiskEvaluator {
    func canEvaluate(toolName: String) -> Bool {
        true // 兜底策略，全量匹配
    }

    func evaluateRisk(tool: AITool, arguments: [String: Any]) -> ToolRiskLevel {
        switch tool.authorizationPolicy {
        case .deterministicReadOnly:
            return .readOnly
        case .requiresConfirmation:
            return .requiresConfirmation
        }
    }
}

// MARK: - 集中风险分类器（ToolRiskClassifier）

/// 工具风险分类管理器（策略注册分发中心）
final class ToolRiskClassifier: @unchecked Sendable {
    static let shared = ToolRiskClassifier()

    /// 评估策略链表（按优先级由高到低排列）
    private let evaluators: [ToolRiskEvaluator]

    private init() {
        self.evaluators = [
            ShellSemanticRiskEvaluator(),
            FileRiskEvaluator(),
            WebAccessRiskEvaluator(),
            SensitiveCapabilityRiskEvaluator(),
            DefaultToolRiskEvaluator()
        ]
    }

    /// 评估给定工具调用的风险等级
    func evaluateRisk(tool: AITool, arguments: [String: Any]) -> ToolRiskLevel {
        for evaluator in evaluators {
            if evaluator.canEvaluate(toolName: tool.name) {
                return evaluator.evaluateRisk(tool: tool, arguments: arguments)
            }
        }
        // 防御性兜底：即使未来评估器链被重构或配置为空，也绝不静默放行未知工具。
        return .requiresConfirmation
    }
}
