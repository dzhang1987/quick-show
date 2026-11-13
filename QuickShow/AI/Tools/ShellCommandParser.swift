import Foundation

// MARK: - Shell 词法解析（引号感知）
// 权限风险评估的确定性底座：把原始命令文本解析为结构化的命令单元序列，
// 使只读判定与破坏性检测基于「命令词 + 参数 + 引号 + 重定向」进行结构分析，
// 而非对原文做字符串包含猜测。

/// 单个 Shell 词元
struct ShellToken: Equatable, Sendable {
    /// 词元文本（引号包裹的内容保留原样，不含定界引号本身）
    let text: String
    /// 是否包含引号包裹区域（引号内内容不参与命令词/危险模式的字面量匹配）
    let isQuoted: Bool

    /// 是否为环境变量前缀（形如 KEY=VALUE，且未被引号包裹）
    var isEnvAssignment: Bool {
        !isQuoted && !text.isEmpty && Self.envAssignmentRegex.firstMatch(
            in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) != nil
    }

    /// 是否为命令行开关参数（以 - 开头且未被引号包裹）
    var isFlag: Bool {
        !isQuoted && text.hasPrefix("-") && text.count > 1
    }

    /// KEY=VALUE 前缀匹配正则（进程级缓存，避免逐词元重复编译）
    private static let envAssignmentRegex = (try? NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*="#))!
}

/// 命令重定向描述
struct ShellRedirection: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// 覆盖写目标文件（>）
        case overwrite(target: String)
        /// 追加写目标文件（>>）
        case append(target: String)
        /// 流丢弃至 /dev/null（无害）
        case devNull
        /// 文件描述符合并（2>&1 / 1>&2 / >&2 等，无真实文件目标）
        case fdMerge
    }

    let kind: Kind

    /// 是否构成对真实文件的写入（排除 /dev/null 与流合并）
    var isFileWriting: Bool {
        switch kind {
        case .overwrite, .append: return true
        case .devNull, .fdMerge: return false
        }
    }

    /// 写入目标路径（非文件写入时为 nil）
    var writingTarget: String? {
        switch kind {
        case .overwrite(let target), .append(let target): return target
        case .devNull, .fdMerge: return nil
        }
    }
}

/// 一条原子命令单元（以 ; && || | 分隔的管道片段）
struct ShellCommandUnit: Equatable, Sendable {
    /// 词元序列（含命令词与参数）
    let tokens: [ShellToken]
    /// 该单元的重定向列表
    let redirections: [ShellRedirection]

    /// 是否包含对真实文件的写入重定向
    var hasFileWritingRedirection: Bool {
        redirections.contains { $0.isFileWriting }
    }

    /// 全部写入重定向的目标路径
    var writingRedirectTargets: [String] {
        redirections.compactMap { $0.writingTarget }
    }

    /// 归一化命令词：剥离环境变量前缀与透明转发（env / xargs 之外的常规命令词），
    /// 去掉 ./ 前缀并取路径最后一段。
    /// 返回 nil 表示该单元为空。
    var executableWord: String? {
        for token in tokens {
            if token.isEnvAssignment { continue }
            return Self.normalize(token.text)
        }
        return nil
    }

    /// 透明转发解析：env / xargs 会透传其后首个真实命令词。
    /// 返回 (透传后的命令词, 其余词元)；无透明转发时命令词保持原样。
    var forwardingAnalysis: (word: String, remainingTokens: [ShellToken]) {
        var cursor = 0

        // 1. 剥离环境变量前缀
        while cursor < tokens.count, tokens[cursor].isEnvAssignment {
            cursor += 1
        }
        guard cursor < tokens.count else { return ("", []) }

        // 2. 逐层剥离 env / xargs 透明包装器（含绝对路径与占用下一参数的选项）。
        // 支持 env → xargs → 真实命令等嵌套组合；无法识别的选项停止在保守结果，不推断免审。
        while cursor < tokens.count, !tokens[cursor].isQuoted {
            let wrapper = Self.normalize(tokens[cursor].text)
            if wrapper == "env" {
                cursor += 1
                cursor = Self.skipWrapperOptions(
                    in: tokens,
                    from: cursor,
                    optionsWithOperand: Self.envOptionsWithOperand,
                    alsoSkippingAssignments: true
                )
                continue
            }
            if wrapper == "xargs" {
                cursor += 1
                cursor = Self.skipWrapperOptions(
                    in: tokens,
                    from: cursor,
                    optionsWithOperand: Self.xargsOptionsWithOperand,
                    alsoSkippingAssignments: false
                )
                continue
            }
            break
        }

        guard cursor < tokens.count else { return ("", []) }
        let word = Self.normalize(tokens[cursor].text)
        let remaining = Array(tokens[(cursor + 1)...])
        return (word, remaining)
    }

    /// 主子命令：命令词之后的首个非开关词元（用于 git/pnpm 等多态命令的语义分流）
    var primarySubcommand: String? {
        for token in tokens.dropFirst() {
            if token.isFlag || token.isEnvAssignment { continue }
            return token.text
        }
        return nil
    }

    /// 开关参数集合（保持原文大小写，git branch -d 与 -D 语义不同）
    var flagTokens: [String] {
        tokens.filter { $0.isFlag }.map { $0.text }
    }

    /// 是否含有未被引号包裹、且包含指定子串的词元
    func containsUnquotedToken(where match: (String) -> Bool) -> Bool {
        tokens.contains { !$0.isQuoted && match($0.text) }
    }

    private static let envOptionsWithOperand: Set<String> = [
        "-u", "--unset", "-C", "--chdir", "-S", "--split-string"
    ]

    private static let xargsOptionsWithOperand: Set<String> = [
        "-E", "--eof", "-I", "--replace", "-L", "--max-lines",
        "-n", "--max-args", "-P", "--max-procs", "-s", "--max-chars",
        "-a", "--arg-file", "-d", "--delimiter"
    ]

    /// 跳过透明包装器的开关、开关操作数，以及 env 的 KEY=VALUE 前缀。
    /// `--option=value` 与 `-I{}` 已自带操作数，不额外吞掉下一词元。
    private static func skipWrapperOptions(
        in tokens: [ShellToken],
        from start: Int,
        optionsWithOperand: Set<String>,
        alsoSkippingAssignments: Bool
    ) -> Int {
        var cursor = start
        while cursor < tokens.count {
            let token = tokens[cursor]
            if alsoSkippingAssignments, token.isEnvAssignment {
                cursor += 1
                continue
            }
            guard token.isFlag else { break }
            let consumesNext = optionsWithOperand.contains(token.text)
            cursor += 1
            if consumesNext, cursor < tokens.count {
                cursor += 1
            }
        }
        return cursor
    }

    private static func normalize(_ raw: String) -> String {
        let cleaned = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
        return cleaned.components(separatedBy: "/").last ?? cleaned
    }
}

// MARK: - Shell 命令解析器

/// Shell 命令词法解析器：引号感知 + 命令单元拆分 + 重定向归类。
/// 覆盖日常风险审查所需的语法面（引号 / 转义 / ; && || | / > >> 2> &> 2>&1 / env 前缀），
/// 不追求完整 POSIX 语法（子 shell、heredoc 按普通文本处理）。
enum ShellCommandParser {

    /// 解析命令为原子命令单元序列（空命令返回空数组）
    static func parseUnits(_ command: String) -> [ShellCommandUnit] {
        var units: [ShellCommandUnit] = []
        var tokens: [ShellToken] = []
        var redirections: [ShellRedirection] = []

        var characters = Array(command)
        var index = 0
        var currentToken = ""
        var currentTokenQuoted = false

        func finishToken() {
            defer { currentToken = ""; currentTokenQuoted = false }
            guard !currentToken.isEmpty else { return }
            tokens.append(ShellToken(text: currentToken, isQuoted: currentTokenQuoted))
        }

        func finishUnit() {
            finishToken()
            guard !(tokens.isEmpty && redirections.isEmpty) else { return }
            units.append(ShellCommandUnit(tokens: tokens, redirections: redirections))
            tokens = []
            redirections = []
        }

        /// 解析自当前位置起的重定向操作符（调用时 index 指向 '>'）
        func parseRedirection() {
            // 消费 '>'
            index += 1
            let isAppend = index < characters.count && characters[index] == ">"
            if isAppend { index += 1 }

            // 跳过空格
            while index < characters.count, characters[index] == " " { index += 1 }

            // 文件描述符合并：2>&1 / 1>&2 / >&2
            if index < characters.count, characters[index] == "&" {
                index += 1
                while index < characters.count, characters[index].isNumber { index += 1 }
                redirections.append(ShellRedirection(kind: .fdMerge))
                return
            }

            // 读取目标文件词元（支持紧跟与空格分隔两种形态，允许引号）
            var target = ""
            if index < characters.count, characters[index] == "\"" || characters[index] == "'" {
                let quote = characters[index]
                index += 1
                while index < characters.count, characters[index] != quote {
                    target.append(characters[index])
                    index += 1
                }
                if index < characters.count { index += 1 }
            } else {
                while index < characters.count,
                      characters[index] != " ", characters[index] != ";",
                      characters[index] != "|", characters[index] != "&" {
                    target.append(characters[index])
                    index += 1
                }
            }

            if target == "/dev/null" {
                redirections.append(ShellRedirection(kind: .devNull))
            } else {
                let kind: ShellRedirection.Kind = isAppend ? .append(target: target) : .overwrite(target: target)
                redirections.append(ShellRedirection(kind: kind))
            }
        }

        while index < characters.count {
            let char = characters[index]

            // 引号区域：原样收集内容，标记 quoted
            if char == "'" || char == "\"" {
                currentTokenQuoted = true
                let quote = char
                index += 1
                while index < characters.count, characters[index] != quote {
                    currentToken.append(characters[index])
                    index += 1
                }
                if index < characters.count { index += 1 }
                continue
            }

            // 反斜杠转义（引号外）：保留下一字符原样
            if char == "\\" {
                index += 1
                if index < characters.count {
                    currentToken.append(characters[index])
                    index += 1
                }
                continue
            }

            // 空白：词元边界
            if char == " " || char == "\t" {
                finishToken()
                index += 1
                continue
            }

            // 重定向前缀：2> / >（数字紧贴 > 时作为流前缀消费）
            if char == ">" {
                // 当前词元恰为数字（如 "2"）：作为流前缀，不构成命令词元
                if currentToken == "2" || currentToken == "1" {
                    currentToken = ""
                    currentTokenQuoted = false
                } else {
                    finishToken()
                }
                parseRedirection()
                continue
            }

            // &> 整体重定向前缀（在通用 & 分隔符之前处理）
            if char == "&", index + 1 < characters.count, characters[index + 1] == ">" {
                finishToken()
                index += 1
                parseRedirection()
                continue
            }

            // 命令分隔符与管道：单元边界（含换行与后台符）
            if char == ";" || char == "|" || char == "&" || char == "\n" || char == "\r" {
                // && / || 双字符操作符
                if index + 1 < characters.count, characters[index + 1] == char {
                    index += 2
                } else {
                    index += 1
                }
                finishUnit()
                continue
            }

            currentToken.append(char)
            index += 1
        }

        finishUnit()
        return units
    }

    /// 提取未被引号包裹的字面量文本（引号区域整体替换为空格），
    /// 供灾难性模式的兜底扫描使用（能命中 $() 命令替换内嵌的危险词）。
    static func unquotedLiteralText(of command: String) -> String {
        var result = ""
        var characters = Array(command)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if char == "'" || char == "\"" {
                let quote = char
                index += 1
                while index < characters.count, characters[index] != quote {
                    index += 1
                }
                if index < characters.count { index += 1 }
                result.append(" ")
                continue
            }
            if char == "\\" {
                index += 1
                if index < characters.count {
                    result.append(characters[index])
                    index += 1
                }
                continue
            }
            result.append(char)
            index += 1
        }
        return result
    }
}
