import Foundation

// MARK: - Shell 命令单元语义风险分析

/// 命令单元的语义级风险分析（消费 ShellCommandParser 的解析产物）。
/// 只读判定、破坏性检测与敏感目标判定在此收敛为唯一真源，
/// 供风险评估器与权限规则引擎共同复用，避免两套判定逻辑漂移。
enum ShellCommandRiskAnalyzer {

    // MARK: - 策展命令集（禁止散落魔法字符串）

    /// 基础只读系统环境探测与监控命令
    private static let basicReadOnlyCommands: Set<String> = [
        "pwd", "ls", "which", "whereis", "whoami", "uname", "date",
        "echo", "cat", "head", "tail", "grep", "egrep", "fgrep",
        "wc", "stat", "file", "diff", "sw_vers", "system_profiler",
        "ps", "df", "du", "uptime", "basename", "dirname", "printenv",
        "arch", "hostname", "id", "readlink", "realpath", "printf",
        "vm_stat", "ioreg", "netstat",
        "cd", "pushd", "popd", "type", "man", "jq", "awk", "lsof", "mdls"
    ]

    /// Git 只读子命令
    private static let safeGitSubcommands: Set<String> = [
        "status", "diff", "log", "show", "branch", "tag", "remote",
        "rev-parse", "describe", "stash", "blame", "reflog", "shortlog",
        "ls-files", "cat-file", "grep", "whatchanged", "count-objects"
    ]

    /// 版本与包管理只读查询命令
    private static let versionCheckCommands: Set<String> = [
        "node", "npm", "pnpm", "yarn", "bun", "cargo", "rustc",
        "swift", "xcodebuild", "python", "python3", "ruby", "go",
        "zsh", "bash", "sh", "deno", "php", "java"
    ]

    /// 支持只读列表/状态查询的脚本运行器
    private static let scriptRunners: Set<String> = ["pnpm", "npm", "yarn", "bun"]

    /// 提权命令词
    private static let privilegeEscalationWords: Set<String> = ["sudo", "doas", "su"]

    /// 电源控制破坏性命令词
    private static let powerControlWords: Set<String> = ["reboot", "shutdown", "halt", "poweroff"]

    /// find 中具执行/删除语义的开关
    private static let findDestructiveFlags: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir"]

    /// 写入类命令词（目标路径需做敏感检查）
    private static let fileWritingWords: Set<String> = ["cp", "mv", "tee"]

    /// 绝对路径下的敏感系统根目录（首段组件，小写比较）
    private static let sensitiveSystemRoots: Set<String> = ["etc", "system", "library", "private"]

    /// 家目录敏感 shell 配置文件名
    private static let sensitiveShellConfigs: Set<String> = [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile"]

    // MARK: - 破坏性硬门禁

    /// 单元级破坏性检测（返回拦截原因，nil = 非破坏性）
    static func destructiveReason(for unit: ShellCommandUnit) -> String? {
        // 重定向写入敏感路径
        for target in unit.writingRedirectTargets where isSensitiveSystemPath(target) {
            return String(localized: "尝试写入系统关键配置或敏感文件")
        }

        let analysis = unit.forwardingAnalysis
        let word = analysis.word
        guard !word.isEmpty else { return nil }
        let remaining = analysis.remainingTokens
        let flags = remaining.filter(\.isFlag).map(\.text)
        let args = remaining.filter { !$0.isFlag }.map(\.text)

        // 提权与身份切换
        if privilegeEscalationWords.contains(word) {
            return String(localized: "包含超级用户提权指令 (\(word))")
        }
        // 递归删除
        if word == "rm", hasShortFlag(flags, matchingAny: "rR") || flags.contains("--recursive") {
            return String(localized: "包含递归强力删除文件指令 (rm -r)")
        }
        // 底层磁盘操作
        if word == "dd" {
            return String(localized: "包含底层磁盘直写指令 (dd)")
        }
        if word.hasPrefix("mkfs") {
            return String(localized: "包含底层磁盘格式化指令")
        }
        if word == "diskutil", let sub = args.first, sub.hasPrefix("erase") || sub.hasPrefix("partition") {
            return String(localized: "包含磁盘擦除或分区指令")
        }
        // 电源控制
        if powerControlWords.contains(word) {
            return String(localized: "包含系统重启或关机指令")
        }
        if word == "init", args.contains("0") {
            return String(localized: "包含系统关机指令 (init 0)")
        }

        // 破坏性 Git 操作（-d 与 -D 大小写语义不同，保持原样比较）
        if word == "git", let sub = args.first {
            if sub == "push", flags.contains(where: { $0 == "-f" || $0.hasPrefix("--force") }) {
                return String(localized: "包含 Git 强行覆盖远程分支指令 (push --force)")
            }
            if sub == "reset", flags.contains("--hard") {
                return String(localized: "包含破坏性 Git 重置指令 (reset --hard)")
            }
            if sub == "clean", hasShortFlag(flags, matchingAny: "f") {
                return String(localized: "包含清除 Git 工作区指令 (clean -f)")
            }
            if sub == "branch", hasShortFlag(flags, matchingAny: "D") {
                return String(localized: "包含强行删除 Git 分支指令 (branch -D)")
            }
        }

        // 写入类命令以敏感路径为目标（cp/mv 只看目标，tee 检查全部参数）
        if fileWritingWords.contains(word) {
            let targets = word == "tee" ? args : args.last.map { [$0] } ?? []
            for target in targets where isSensitiveSystemPath(target) {
                return String(localized: "尝试修改系统关键配置文件或目录")
            }
        }
        return nil
    }

    /// 未引用区域的灾难字面量兜底扫描（捕获 $() 命令替换内嵌的危险指令）
    static func catastrophicLiteralReason(in command: String) -> String? {
        let unquoted = ShellCommandParser.unquotedLiteralText(of: command)
        let range = NSRange(unquoted.startIndex..<unquoted.endIndex, in: unquoted)
        for (regex, reason) in compiledCatastrophicPatterns where regex.firstMatch(in: unquoted, range: range) != nil {
            return reason
        }
        return nil
    }

    /// 灾难字面量模式表（进程级编译缓存）
    private static let compiledCatastrophicPatterns: [(regex: NSRegularExpression, reason: String)] = [
        (#"\brm\s+(?:-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)\b"#, "包含递归强力删除文件指令 (rm -r)"),
        (#"\b(?:sudo|doas)\b"#, "包含超级用户提权指令 (sudo)"),
        (#"\bmkfs\b"#, "包含底层磁盘格式化指令"),
        (#"\bdd\s+if="#, "包含底层磁盘直写指令 (dd)"),
        (#"\bdiskutil\s+erase\b"#, "包含磁盘擦除指令"),
        (#"\bdiskutil\s+partition\b"#, "包含磁盘分区指令"),
        (#"\b(?:reboot|shutdown|halt|poweroff)\b"#, "包含系统重启或关机指令"),
        (#"\binit\s+0\b"#, "包含系统关机指令 (init 0)")
    ].compactMap { pattern, reason in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (regex, reason)
    }

    // MARK: - 只读判定

    /// 单元是否为纯只读操作（无真实文件写入、无变更副作用）
    static func isUnitReadOnly(_ unit: ShellCommandUnit) -> Bool {
        // 真实文件写入重定向
        if unit.hasFileWritingRedirection { return false }

        // 未引用区域的命令替换：执行语义静态不可见，保守降级为待审批
        if unit.tokens.contains(where: { !$0.isQuoted && $0.text.contains("$(") }) {
            return false
        }

        let analysis = unit.forwardingAnalysis
        let word = analysis.word
        // 空单元 / 纯环境变量赋值：无执行副作用
        guard !word.isEmpty else { return true }

        let remaining = analysis.remainingTokens
        let flags = remaining.filter(\.isFlag).map(\.text)
        let args = remaining.filter { !$0.isFlag }.map(\.text)

        switch word {
        case "sysctl":
            // -w 或键值赋值为写内核参数；其余为只读读取
            return !flags.contains("-w") && !unit.containsUnquotedToken { $0.contains("=") }
        case "pmset":
            // -g 为只读状态查询；其余参数为电源配置修改
            return flags.contains("-g")
        case "defaults":
            // read 为 macOS 偏好只读读取
            return args.contains { $0 == "read" || $0.hasPrefix("read") }
        case "sed":
            // -i / --in-place 为原地改写，其余为流式只读打印
            return !flags.contains { $0 == "-i" || $0.hasPrefix("--in-place") || (!$0.hasPrefix("--") && $0.dropFirst().contains("i")) }
        case "find":
            // find 的 -delete / -exec 系开关具删除与执行语义
            return !flags.contains(where: { findDestructiveFlags.contains($0) })
        default:
            break
        }

        if basicReadOnlyCommands.contains(word) { return true }

        if word == "git", let sub = args.first {
            guard safeGitSubcommands.contains(sub) else { return false }
            switch sub {
            case "config":
                // git config：仅允许读取形态（不带赋值）
                return !unit.containsUnquotedToken { $0.contains("=") }
                    && flags.contains { $0.hasPrefix("--get") || $0 == "-l" || $0 == "--list" }
            case "stash":
                // git stash：仅允许 list / show
                return args.contains("list") || args.contains("show")
            case "branch", "tag":
                // -d / -D 具删除语义（-D 已被破坏性硬门禁拦截，此处兜底 -d）
                return !hasShortFlag(flags, matchingAny: "dD")
            case "remote":
                // git remote 的 add/remove/rename 等子操作具仓库配置变更语义
                return !args.dropFirst().contains { ["add", "remove", "rm", "prune", "rename", "set-url"].contains($0) }
            default:
                return true
            }
        }

        if versionCheckCommands.contains(word) {
            // 版本查询
            if flags.contains("-v") || flags.contains("--version") || args.contains("version") {
                return true
            }
            // 包管理只读列表/状态查询
            if scriptRunners.contains(word),
               args.contains(where: { ["list", "ls", "outdated", "view"].contains($0) }) {
                return true
            }
            // cargo check / clippy：仅产生 target 缓存，无源码变更
            if word == "cargo", args.contains(where: { ["check", "clippy"].contains($0) }) {
                return true
            }
            // go 只读子命令
            if word == "go", args.contains(where: { ["version", "doc", "env"].contains($0) }) {
                return true
            }
        }
        return false
    }

    // MARK: - 敏感路径判定

    /// 路径是否指向系统敏感区域（组件级匹配，杜绝子串误命中）
    static func isSensitiveSystemPath(_ raw: String) -> Bool {
        for path in [raw, (raw as NSString).expandingTildeInPath] {
            let components = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard let first = components.first else { continue }

            // 绝对路径下的系统根目录
            if path.hasPrefix("/"), sensitiveSystemRoots.contains(first.lowercased()) {
                return true
            }
            // 凭据与密钥目录
            if components.contains(".ssh") || components.contains(".gnupg") {
                return true
            }
            // shell 配置文件
            if let last = components.last, sensitiveShellConfigs.contains(last) {
                return true
            }
            // Git 仓库配置
            if let gitIndex = components.firstIndex(of: ".git"),
               components.indices.contains(gitIndex + 1), components[gitIndex + 1] == "config" {
                return true
            }
        }
        return false
    }

    // MARK: - 私有辅助

    /// 短开关匹配：单破折短选项按字符集命中（POSIX 组合开关语义），长选项跳过
    private static func hasShortFlag(_ flags: [String], matchingAny letters: String) -> Bool {
        flags.contains { flag in
            guard !flag.hasPrefix("--") else { return false }
            let optionChars = flag.dropFirst()
            return letters.contains { optionChars.contains($0) }
        }
    }
}
