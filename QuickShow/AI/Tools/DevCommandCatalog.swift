import Foundation

// MARK: - 低风险开发命令目录

/// 「本会话信任开发命令」作用域的策展清单。
/// 仅收录构建、测试、检查类命令与子命令，明确排除：
/// - 依赖安装（install / add：会执行任意 postinstall 脚本）
/// - 项目运行与常驻服务（dev / serve / start）
/// - 任意代码执行入口（run app / node script.js）
/// 命中目录并不意味着免审，仅当用户在确认抽屉中授予 devCommands 作用域后才放行。
enum DevCommandCatalog {
    /// 可执行词 → 允许的主子命令集合；空集合 = 任意参数均视为可信（仅限纯检查型命令）
    private static let trustedCommands: [String: Set<String>] = [
        "swift": ["build", "test"],
        "xcodebuild": ["build", "test"],
        "pnpm": ["build", "test", "lint", "typecheck", "run"],
        "npm": ["test", "lint", "run"],
        "yarn": ["build", "test", "lint"],
        "bun": ["build", "test", "lint", "run"],
        "cargo": ["build", "test", "check", "clippy", "doc"],
        "go": ["build", "test", "vet", "fmt"],
        "gradle": ["build", "test"],
        "mvn": ["test", "compile", "package"],
        "pytest": [],
        "jest": [],
        "vitest": [],
        "tsc": [],
        "eslint": [],
        "swiftlint": [],
        "rubocop": [],
        "ruff": ["check"]
    ]

    /// run-script 间接转发（如 pnpm run build）允许的次级脚本名
    private static let trustedRunScripts: Set<String> = ["build", "test", "lint", "typecheck"]

    /// 支持 run 间接转发的脚本运行器
    private static let scriptRunners: Set<String> = ["pnpm", "npm", "yarn", "bun"]

    /// 目录收录的可执行词集合（供作用域建议时判断）
    static var commandWords: Set<String> {
        Set(trustedCommands.keys)
    }

    /// 判断一条命令单元是否命中可信开发命令
    static func isTrusted(unit: ShellCommandUnit) -> Bool {
        guard let word = unit.executableWord,
              let allowedSubcommands = trustedCommands[word] else {
            return false
        }

        // 纯检查型命令（任意参数可信）
        if allowedSubcommands.isEmpty { return true }

        guard let subcommand = unit.primarySubcommand else { return false }
        if allowedSubcommands.contains(subcommand) { return true }

        // run-script 间接转发：pnpm run build → 次级词必须同样可信
        if subcommand == "run", scriptRunners.contains(word) {
            return firstNonFlagToken(after: "run", in: unit.tokens).map { trustedRunScripts.contains($0) } ?? false
        }
        return false
    }

    /// 在词元序列中定位指定文本后的首个非开关词元
    private static func firstNonFlagToken(after text: String, in tokens: [ShellToken]) -> String? {
        var passedTarget = false
        for token in tokens {
            if !passedTarget {
                if !token.isQuoted, token.text == text {
                    passedTarget = true
                }
                continue
            }
            if !token.isFlag, !token.isEnvAssignment {
                return token.text
            }
        }
        return nil
    }
}
