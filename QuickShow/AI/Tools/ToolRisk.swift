import Foundation

// MARK: - 工具风险模型与能力作用域

/// 建议授权的作用域类型（供 UI 呈现智能快捷记忆）
enum PermissionScopeSuggestion: Equatable, Hashable, Sendable {
    /// 建议放行特定命令前缀（如 "git", "pnpm", "swift", "cargo"）
    case shellPrefix(prefix: String)
    /// 建议放行特定工作区目录（如当前工程根目录）
    case directoryPath(path: String)
    /// 建议放行策展目录内的常见构建/测试/检查命令（swift build、pnpm test 等）
    case devCommands
    /// 常规工具级放行
    case toolName(name: String)

    /// 用户界面展示文案（如「本会话允许 "git *"」）
    var displayTitle: String {
        switch self {
        case .shellPrefix(let prefix):
            return String(localized: "允许 \"\(prefix) *\" 本会话放行")
        case .directoryPath(let path):
            let folderName = URL(fileURLWithPath: path).lastPathComponent
            return String(localized: "允许目录 \"\(folderName)\" 本会话写入")
        case .devCommands:
            return String(localized: "本会话信任常见构建/测试命令")
        case .toolName(let name):
            return String(localized: "本会话总是允许 \"\(name)\"")
        }
    }
}

/// 工具调用风险等级
enum ToolRiskLevel: Equatable, Sendable {
    /// 纯感知 / 只读操作：无副作用，100% 零审批自动放行
    case readOnly

    /// 受控变更操作：在特定白名单目录或特定命令空间内的写入/执行，可被规则记忆放行
    case scopedMutation(suggestedScope: PermissionScopeSuggestion)

    /// 破坏性 / 逃逸高危操作：系统级破坏、关键配置篡改、越界提权，强制硬门禁审批，不可被通配规则静默绕过
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
}

// MARK: - 权限授权规则

/// 权限规则类型（会话级）
enum PermissionRule: Hashable, Sendable {
    /// 本会话允许特定工具全量执行
    case tool(name: String)
    /// 本会话允许特定 Shell 命令前缀（如 "git", "pnpm"；匹配经词法解析后的每个命令单元执行词）
    case shellPrefix(prefix: String)
    /// 本会话允许特定根目录下的写入操作
    case directory(path: String)
    /// 本会话信任策展目录内的常见构建/测试/检查命令
    case devCommands
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
/// 基于 ShellCommandParser 的引号感知词法解析与 ShellCommandRiskAnalyzer 的结构化语义分析，
/// 只读直通、破坏性硬门禁、受控变更作用域建议三者均以命令单元为单位判定。
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
            return .readOnly
        }

        let units = ShellCommandParser.parseUnits(trimmed)
        guard !units.isEmpty else {
            return .readOnly
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

        // 2. 所有命令单元均为只读 → 免审直通
        let unitReadonlyStates = units.map { ShellCommandRiskAnalyzer.isUnitReadOnly($0) }
        if unitReadonlyStates.allSatisfy({ $0 }) {
            return .readOnly
        }

        // 3. 受控变更：以首个非只读单元推导建议作用域
        guard let mutatingUnit = zip(units, unitReadonlyStates).first(where: { !$0.1 })?.0 else {
            return .scopedMutation(suggestedScope: .shellPrefix(prefix: "shell"))
        }
        if DevCommandCatalog.isTrusted(unit: mutatingUnit) {
            return .scopedMutation(suggestedScope: .devCommands)
        }
        let word = mutatingUnit.forwardingAnalysis.word
        return .scopedMutation(suggestedScope: .shellPrefix(prefix: word.isEmpty ? "shell" : word))
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

        // 提取目录作为建议的作用域
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let directory = url.deletingLastPathComponent().path
        return .scopedMutation(suggestedScope: .directoryPath(path: directory))
    }
}

// MARK: - 默认静态风险评估器

/// 保底策略：依据工具本身的静态属性进行分级
final class DefaultToolRiskEvaluator: ToolRiskEvaluator {
    func canEvaluate(toolName: String) -> Bool {
        true // 兜底策略，全量匹配
    }

    func evaluateRisk(tool: AITool, arguments: [String: Any]) -> ToolRiskLevel {
        if !tool.isDangerous {
            return .readOnly
        }
        return .scopedMutation(suggestedScope: .toolName(name: tool.name))
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
        return .readOnly
    }
}

// MARK: - 会话权限规则引擎（ToolPermissionPolicyEngine）

/// 管理会话临时放行规则并执行快速策略裁决。
/// run_shell 的规则匹配基于词法解析后的命令单元：复合命令（含 cd/管道串联）逐单元判定，
/// 每个非只读单元的执行词命中前缀规则、或命中 devCommands 策展目录，整条命令才放行。
final class ToolPermissionPolicyEngine: @unchecked Sendable {
    static let shared = ToolPermissionPolicyEngine()

    private let lock = NSLock()
    /// 当前活跃会话的放行规则集合（纯内存，随会话切换/新建清空）
    private var sessionRules: Set<PermissionRule> = []

    private init() {}

    /// 检查指定工具与参数是否已被规则放行
    func isAllowed(tool: AITool, arguments: [String: Any], risk: ToolRiskLevel) -> Bool {
        // 1. 只读操作始终放行
        if risk.isAutoApproved {
            return true
        }

        // 2. 破坏性操作绝不通过通配规则跳过
        if risk.isDestructive {
            return false
        }

        lock.lock()
        defer { lock.unlock() }

        // 3. 检查常规工具全量规则
        if sessionRules.contains(.tool(name: tool.name)) {
            return true
        }

        // 4. Shell 命令：逐命令单元匹配（引号感知，复合命令不再只看首个 token）
        if tool.name == "run_shell", let command = arguments["command"] as? String {
            var prefixRules: Set<String> = []
            for case .shellPrefix(let prefix) in sessionRules {
                prefixRules.insert(prefix)
            }
            let trustsDevCommands = sessionRules.contains(.devCommands)

            for unit in ShellCommandParser.parseUnits(command) {
                if ShellCommandRiskAnalyzer.isUnitReadOnly(unit) { continue }
                let word = unit.forwardingAnalysis.word
                // 执行词为空的写语义单元（纯重定向）无法被任何规则覆盖
                guard !word.isEmpty else { return false }
                if prefixRules.contains(word) { continue }
                if trustsDevCommands && DevCommandCatalog.isTrusted(unit: unit) { continue }
                return false
            }
            return true
        }

        // 5. 检查目录作用域规则
        if tool.name == "write_file", let path = arguments["path"] as? String {
            let expanded = (path as NSString).expandingTildeInPath
            for rule in sessionRules {
                if case .directory(let dirPath) = rule {
                    if expanded == dirPath || expanded.hasPrefix(dirPath + "/") {
                        return true
                    }
                }
            }
        }

        return false
    }

    /// 记录一条放行规则
    func recordRule(_ rule: PermissionRule) {
        lock.lock()
        defer { lock.unlock() }
        sessionRules.insert(rule)
    }

    /// 根据建议作用域一键记录放行规则
    func recordScopeSuggestion(_ suggestion: PermissionScopeSuggestion) {
        switch suggestion {
        case .shellPrefix(let prefix):
            recordRule(.shellPrefix(prefix: prefix))
        case .directoryPath(let path):
            recordRule(.directory(path: path))
        case .devCommands:
            recordRule(.devCommands)
        case .toolName(let name):
            recordRule(.tool(name: name))
        }
    }

    /// 获取当前生效的规则列表（供 UI 展示）
    func activeRules() -> [PermissionRule] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessionRules)
    }

    /// 获取当前生效规则数量
    var activeRulesCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessionRules.count
    }

    /// 清空会话规则
    func resetRules() {
        lock.lock()
        defer { lock.unlock() }
        sessionRules.removeAll()
    }
}
