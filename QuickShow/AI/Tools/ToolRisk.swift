import Foundation

// MARK: - 工具风险模型与能力作用域

/// 建议授权的作用域类型（供 UI 呈现智能快捷记忆）
enum PermissionScopeSuggestion: Equatable, Hashable, Sendable {
    /// 建议放行特定命令前缀（如 "git", "pnpm", "swift", "cargo"）
    case shellPrefix(prefix: String)
    /// 建议放行特定工作区目录（如当前工程根目录）
    case directoryPath(path: String)
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
        case .toolName(let name):
            return String(localized: "本会话总是允许")
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
    /// 本会话允许特定 Shell 命令前缀（如 "git", "pnpm"）
    case shellPrefix(prefix: String)
    /// 本会话允许特定根目录下的写入操作
    case directory(path: String)
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

/// 针对 run_shell 的语义分词与风险评估策略
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

        // 1. 破坏性硬门禁检查（全局命中即拦截）
        if let destructiveReason = checkDestructivePattern(command: trimmed) {
            return .destructive(reason: destructiveReason)
        }

        // 2. 检查多子命令链（如 ; && || |）
        let subCommands = splitCommands(trimmed)
        if subCommands.isEmpty {
            return .readOnly
        }

        // 3. 校验所有子命令是否均属于只读安全命令
        let allReadOnly = subCommands.allSatisfy { isSubCommandReadOnly($0) }
        if allReadOnly {
            return .readOnly
        }

        // 4. 提取首个有意义的主命令词作为建议前缀
        let prefix = extractPrimaryCommand(from: subCommands.first ?? trimmed)
        return .scopedMutation(suggestedScope: .shellPrefix(prefix: prefix))
    }

    // MARK: - 私有辅助解析

    /// 破坏性高危命令特征检测
    private func checkDestructivePattern(command: String) -> String? {
        let lower = command.lowercased()

        // 危险删除与擦除
        if lower.contains("rm -rf") || lower.contains("rm -fr") || lower.contains("rm -r") || lower.contains("srm ") {
            return String(localized: "包含递归强力删除文件指令 (rm -r)")
        }
        if lower.contains("mkfs") || lower.contains("diskutil erase") || lower.contains("diskutil partition") || lower.contains("dd if=") {
            return String(localized: "包含底层磁盘格式化或直写指令")
        }

        // 提权与身份切换
        if lower.contains("sudo ") || lower.contains("su -") || lower.contains("doas ") {
            return String(localized: "包含超级用户提权指令 (sudo)")
        }

        // 破坏性 Git 操作
        if lower.contains("git reset --hard") || lower.contains("git clean -f") || lower.contains("git clean -df") || lower.contains("git clean -fd") {
            return String(localized: "包含破坏性 Git 重置或清除工作区指令")
        }
        if lower.contains("git push") && (lower.contains("--force") || lower.contains(" -f ") || lower.hasSuffix(" -f")) {
            return String(localized: "包含 Git 强行覆盖远程分支指令 (push --force)")
        }
        if lower.contains("git branch -d") || lower.contains("git branch -d") {
            return String(localized: "包含强行删除 Git 分支指令")
        }

        // 危险系统配置篡改
        let sensitiveFiles = ["/etc/", "/system/", "/library/", "~/.zshrc", "~/.bash_profile", "~/.bashrc", "~/.ssh", ".git/config"]
        for sensitive in sensitiveFiles {
            if lower.contains(sensitive) && (lower.contains(">") || lower.contains("cp ") || lower.contains("mv ") || lower.contains("tee ")) {
                return String(localized: "尝试修改系统关键配置文件或目录")
            }
        }

        // 关机重启
        if lower.contains("reboot") || lower.contains("shutdown") || lower.contains("halt") || lower.contains("init 0") {
            return String(localized: "包含系统重启或关机指令")
        }

        return nil
    }

    /// 拆分复合命令语句（兼容 ; && || | 管道符）
    private func splitCommands(_ raw: String) -> [String] {
        let pattern = #";|&&|\|\||\|"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [raw]
        }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let modified = regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "\n")
        return modified
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 单个子命令是否为只读安全命令
    private func isSubCommandReadOnly(_ cmd: String) -> Bool {
        let tokens = cmd.split(separator: " ").map(String.init)
        guard let first = tokens.first?.lowercased() else { return true }

        // 基础只读系统命令
        let safeBasicCommands: Set<String> = [
            "pwd", "ls", "which", "whereis", "whoami", "uname", "date",
            "echo", "cat", "head", "tail", "grep", "egrep", "fgrep",
            "wc", "stat", "file", "find", "diff", "sw_vers", "system_profiler",
            "ps", "df", "du", "uptime", "basename", "dirname", "env", "printenv"
        ]
        if safeBasicCommands.contains(first) {
            // 注意：若命令中包含重定向写操作 (>) 则不是只读
            return !cmd.contains(">")
        }

        // Git 只读子命令
        if first == "git" && tokens.count >= 2 {
            let sub = tokens[1].lowercased()
            let safeGitSub: Set<String> = [
                "status", "diff", "log", "show", "branch", "tag", "remote",
                "rev-parse", "describe", "config", "stash"
            ]
            if safeGitSub.contains(sub) {
                // 如果是 git config，只允许读（不带赋值）
                if sub == "config" {
                    return !cmd.contains("=") && (cmd.contains("--get") || cmd.contains("-l") || cmd.contains("--list"))
                }
                // 如果是 git stash，只允许 list / show
                if sub == "stash" {
                    return tokens.contains("list") || tokens.contains("show")
                }
                return !cmd.contains(">")
            }
        }

        // 包管理与编译器只读版本/列表查询
        let safeVersionCheckers: Set<String> = [
            "node", "npm", "pnpm", "yarn", "bun", "cargo", "rustc",
            "swift", "xcodebuild", "python", "python3", "ruby", "go"
        ]
        if safeVersionCheckers.contains(first) {
            if tokens.contains("-v") || tokens.contains("--version") || tokens.contains("version") {
                return !cmd.contains(">")
            }
            if (first == "pnpm" || first == "npm" || first == "yarn") && (tokens.contains("list") || tokens.contains("ls") || tokens.contains("outdated")) {
                return !cmd.contains(">")
            }
            if first == "cargo" && (tokens.contains("check") || tokens.contains("clippy")) {
                return !cmd.contains(">")
            }
        }

        return false
    }

    /// 提取主命令名作为建议的前缀
    private func extractPrimaryCommand(from cmd: String) -> String {
        let tokens = cmd.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return "shell" }
        let clean = first.replacingOccurrences(of: "./", with: "")
        return clean.components(separatedBy: "/").last ?? clean
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

/// 管理会话临时放行规则并执行快速策略裁决
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

        // 4. 检查 Shell 前缀规则
        if tool.name == "run_shell", let command = arguments["command"] as? String {
            let tokens = command.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
            if let first = tokens.first {
                let clean = first.replacingOccurrences(of: "./", with: "")
                let prefix = clean.components(separatedBy: "/").last ?? clean
                if sessionRules.contains(.shellPrefix(prefix: prefix)) {
                    return true
                }
            }
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
