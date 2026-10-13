import Foundation

// MARK: - 带参命令重写与参数感知提取

enum MathArgumentRewriter {

    private static let greekCommandNames: Set<String> = [
        "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta",
        "vartheta", "iota", "kappa", "varkappa", "lambda", "mu", "nu", "xi", "pi", "varpi",
        "rho", "varrho", "sigma", "varsigma", "tau", "upsilon", "phi", "varphi", "chi", "psi",
        "omega", "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi",
        "Psi", "Chi", "Omega", "digamma",
    ]

    /// 扫描 `\substack{...}`，转为 `\atop` 堆叠
    static func replaceSubstack(_ source: String) -> String {
        let chars = Array(source)
        let marker = Array("\\substack")
        var out = ""
        var index = 0
        while index < chars.count {
            if MathBalancedParser.matches(chars, at: index, pattern: marker),
               index + marker.count < chars.count,
               chars[index + marker.count] == "{",
               let bodyEnd = MathBalancedParser.matchingBrace(chars, openIndex: index + marker.count) {
                let bodyStart = index + marker.count + 1
                let stacked = replaceTopLevelDoubleBackslash(String(chars[bodyStart..<bodyEnd]))
                let alreadyGrouped = index > 0 && chars[index - 1] == "{"
                if alreadyGrouped {
                    out.append(stacked)
                } else {
                    out.append("{")
                    out.append(stacked)
                    out.append("}")
                }
                index = bodyEnd + 1
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    private static func replaceTopLevelDoubleBackslash(_ body: String) -> String {
        let chars = Array(body)
        var out = ""
        var depth = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "{" { depth += 1; out.append(char); index += 1; continue }
            if char == "}" { depth -= 1; out.append(char); index += 1; continue }
            if depth == 0, char == "\\", index + 1 < chars.count, chars[index + 1] == "\\" {
                out.append(" \\atop ")
                index += 2
                while index < chars.count, chars[index] == " " { index += 1 }
                continue
            }
            out.append(char)
            index += 1
        }
        return out
    }

    /// 展开 `\pmod{...}` 为 `\;(\text{mod}~X)`
    static func replacePmod(_ source: String) -> String {
        let chars = Array(source)
        let marker = Array("\\pmod")
        var out = ""
        var index = 0
        while index < chars.count {
            if MathBalancedParser.matches(chars, at: index, pattern: marker),
               index + marker.count < chars.count,
               chars[index + marker.count] == "{",
               let bodyEnd = MathBalancedParser.matchingBrace(chars, openIndex: index + marker.count) {
                let bodyStart = index + marker.count + 1
                let inner = String(chars[bodyStart..<bodyEnd])
                out.append("\\;(\\text{mod}~")
                out.append(inner)
                out.append(")")
                index = bodyEnd + 1
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    /// 扫描 `\command{a}{b}…`（argCount 个花括号组），整段替换为 transform(参数组)。
    static func replaceCommandWithArgs(
        _ source: String,
        command: String,
        argCount: Int,
        fallback: String,
        transform: ([String]) -> String
    ) -> String {
        let chars = Array(source)
        let pattern = Array(command)
        var out = ""
        var index = 0
        while index < chars.count {
            if MathBalancedParser.matches(chars, at: index, pattern: pattern) {
                let after = index + pattern.count
                if after >= chars.count || !chars[after].isLetter {
                    var argIndex = after
                    var args: [String] = []
                    var argsEnd = after
                    var ok = true
                    for _ in 0..<argCount {
                        while argIndex < chars.count, chars[argIndex] == " " { argIndex += 1 }
                        if argIndex < chars.count, chars[argIndex] == "{",
                           let close = MathBalancedParser.matchingBrace(chars, openIndex: argIndex) {
                            args.append(String(chars[(argIndex + 1)..<close]))
                            argIndex = close + 1
                            argsEnd = argIndex
                        } else {
                            ok = false
                            break
                        }
                    }
                    if ok {
                        out.append(transform(args))
                        index = argsEnd
                    } else {
                        out.append(fallback)
                        index = after
                    }
                    continue
                }
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    /// 检测参数首 token 是否希腊字母
    static func argLeadsWithGreek(_ arg: String) -> Bool {
        var index = arg.startIndex
        while index < arg.endIndex, arg[index] == " " { index = arg.index(after: index) }
        guard index < arg.endIndex else { return false }
        let first = arg[index]
        if first == "\\" {
            var name = ""
            var cursor = arg.index(after: index)
            while cursor < arg.endIndex, arg[cursor].isLetter {
                name.append(arg[cursor])
                cursor = arg.index(after: cursor)
            }
            return greekCommandNames.contains(name)
        }
        if let scalar = first.unicodeScalars.first {
            return (0x0370...0x03FF).contains(scalar.value) || (0x1D670...0x1D716).contains(scalar.value)
        }
        return false
    }
}
