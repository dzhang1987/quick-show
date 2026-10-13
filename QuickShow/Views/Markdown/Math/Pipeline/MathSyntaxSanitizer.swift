import Foundation

// MARK: - 基础语法清洗与命令别名映射

enum MathSyntaxSanitizer {

    /// 纯文本命令重命名/删除表（replaceCommand 边界安全：命令后一字符非字母才替换）。
    /// 同族长命令在前；值为空串 = 删除命令、保留其花括号参数（去壳，内容零丢失）。
    private static let commandRenames: [(from: String, to: String)] = [
        // operatorname 族（带 * 先行）
        ("\\operatorname*", "\\mathrm"),
        ("\\operatorname", "\\mathrm"),
        // 字体族
        ("\\mathscr", "\\mathcal"),
        ("\\Bbb", "\\mathbb"),
        ("\\scriptscriptstyle", "\\scriptstyle"),
        // 二元族
        ("\\dbinom", "\\binom"), ("\\tbinom", "\\binom"),
        // 文本族
        ("\\mbox", "\\text"), ("\\textnormal", "\\text"), ("\\emph", ""),
        // 间距族
        ("\\medspace", "\\,"), ("\\thinspace", "\\,"),
        ("\\negthickspace", "\\!"), ("\\negmedspace", "\\!"), ("\\negthinspace", "\\!"),
        // 大定界符前缀族（长在前；\bigcup 等真命令由字母边界豁免）
        ("\\Biggl", ""), ("\\Biggr", ""), ("\\biggl", ""), ("\\biggr", ""),
        ("\\Bigg", ""), ("\\bigg", ""),
        ("\\Bigl", ""), ("\\Bigr", ""), ("\\Bigm", ""),
        ("\\bigl", ""), ("\\bigr", ""), ("\\bigm", ""),
        ("\\Big", ""), ("\\big", ""), ("\\middle", ""),
        // 定界符名
        ("\\lvert", "|"), ("\\rvert", "|"),
        ("\\lVert", "\\Vert"), ("\\rVert", "\\Vert"),
        // 装饰去壳族
        ("\\overbrace", ""), ("\\underbrace", ""),
        ("\\overleftarrow", ""), ("\\overleftrightarrow", ""),
        ("\\underleftarrow", ""), ("\\underrightarrow", ""), ("\\utilde", ""),
        ("\\boxed", ""), ("\\cancel", ""), ("\\bcancel", ""), ("\\xcancel", ""), ("\\sout", ""),
        ("\\smash", ""), ("\\mathop", ""),
        ("\\mathstrut", ""), ("\\strut", ""),
        ("\\overrightarrow", "\\vec"),
        // 符号
        ("\\blacksquare", "\\square"), ("\\measuredangle", "\\angle"),
        // 逻辑符号
        ("\\implies", "\\Longrightarrow"), ("\\impliedby", "\\Longleftarrow"),
        ("\\therefore", "{{\\cdot}\\atop{\\cdot\\,\\cdot}}"),
        ("\\because", "{{\\cdot\\,\\cdot}\\atop{\\cdot}}"),
        ("\\nexists", "\\lnot\\exists"), ("\\nmid", "\\lnot\\mid"),
        ("\\nparallel", "\\lnot\\parallel"),
        ("\\varnothing", "\\emptyset"),
        // 否定关系
        ("\\nleq", "\\lnot\\leq"), ("\\ngeq", "\\lnot\\geq"), ("\\nless", "\\lnot<"), ("\\ngtr", "\\lnot>"),
        ("\\nsubseteq", "\\lnot\\subseteq"), ("\\nsupseteq", "\\lnot\\supseteq"),
        ("\\nsubset", "\\lnot\\subset"), ("\\nsupset", "\\lnot\\supset"),
        ("\\subsetneq", "\\subset"), ("\\supsetneq", "\\supset"),
        ("\\ncong", "\\lnot\\cong"), ("\\nsim", "\\lnot\\sim"), ("\\napprox", "\\lnot\\approx"),
        // 斜线/带等号序关系
        ("\\leqslant", "\\leq"), ("\\geqslant", "\\geq"),
        ("\\preceq", "\\prec\\!\\!="), ("\\succeq", "\\succ\\!\\!="),
        ("\\vdash", "\\vert\\!\\!="), ("\\dashv", "=\\!\\!\\vert"),
        // 关系别名
        ("\\lt", "<"), ("\\gt", ">"),
        // 点
        ("\\dots", "\\ldots"), ("\\dotsc", "\\ldots"), ("\\dotsb", "\\ldots"),
        ("\\dotsm", "\\ldots"), ("\\dotso", "\\ldots"),
        // 箭头近似
        ("\\longmapsto", "\\mapsto"),
        ("\\hookrightarrow", "\\rightarrow"), ("\\hookleftarrow", "\\leftarrow"),
        ("\\twoheadrightarrow", "\\rightarrow"), ("\\twoheadleftarrow", "\\leftarrow"),
        ("\\rightharpoonup", "\\rightarrow"), ("\\rightharpoondown", "\\rightarrow"),
        ("\\leftharpoonup", "\\leftarrow"), ("\\leftharpoondown", "\\leftarrow"),
        ("\\rightleftharpoons", "\\leftrightarrow"),
        ("\\curvearrowright", "\\rightarrow"), ("\\curvearrowleft", "\\leftarrow"),
        ("\\rightsquigarrow", "\\longrightarrow"), ("\\leftsquigarrow", "\\longleftarrow"),
        ("\\leadsto", "\\longrightarrow"),
        ("\\circlearrowright", "\\rightarrow"), ("\\circlearrowleft", "\\leftarrow"),
        // 框/圈运算符
        ("\\boxplus", "\\oplus"), ("\\boxtimes", "\\otimes"),
        ("\\boxminus", "\\ominus"), ("\\boxdot", "\\odot"),
        ("\\circledast", "\\odot"), ("\\circledcirc", "\\circ"),
        // 形状
        ("\\triangledown", "\\nabla"),
        ("\\diamond", "\\cdot"), ("\\Diamond", "\\cdot"),
        ("\\Join", "\\times"), ("\\join", "\\times"),
        ("\\ltimes", "\\times"), ("\\rtimes", "\\times"),
        // 三阶导数重音
        ("\\dddot", "\\ddot"), ("\\ddddot", "\\ddot"),
        // 取模
        ("\\bmod", "\\;\\mathrm{mod}\\;"), ("\\mod", "\\ \\mathrm{mod}\\ "),
        // 希腊变体
        ("\\varkappa", "\\kappa"), ("\\digamma", "F"),
        // 矩阵行线
        ("\\hline", ""), ("\\hdashline", ""),
    ]

    private static let notPrefixRenames: [(follow: String, to: String)] = [
        ("\\subseteq", "\\lnot\\subseteq"), ("\\supseteq", "\\lnot\\supseteq"),
        ("\\subset", "\\lnot\\subset"), ("\\supset", "\\lnot\\supset"),
        ("\\equiv", "\\lnot\\equiv"),
        ("\\leq", "\\lnot\\leq"), ("\\geq", "\\lnot\\geq"), ("\\le", "\\lnot\\leq"), ("\\ge", "\\lnot\\geq"),
        ("\\in", "\\notin"),
    ]

    /// 统一清洗分数族与多重积分
    static func sanitizeFractionsAndIntegrals(_ source: String) -> String {
        var result = source
        // 分数族
        result = MathBalancedParser.replaceCommand(result, command: "\\dfrac", with: "\\frac")
        result = MathBalancedParser.replaceCommand(result, command: "\\tfrac", with: "\\frac")
        result = MathBalancedParser.replaceCommand(result, command: "\\cfrac", with: "\\frac")
        // 多重积分
        result = MathBalancedParser.replaceCommand(result, command: "\\iiiint", with: "\\int\\!\\!\\!\\int\\!\\!\\!\\int\\!\\!\\!\\int")
        result = MathBalancedParser.replaceCommand(result, command: "\\oiiint", with: "\\oint\\!\\!\\oint\\!\\!\\oint")
        result = MathBalancedParser.replaceCommand(result, command: "\\oiint", with: "\\oint\\!\\!\\oint")
        result = MathBalancedParser.replaceCommand(result, command: "\\iiint", with: "\\int\\!\\!\\!\\int\\!\\!\\!\\int")
        result = MathBalancedParser.replaceCommand(result, command: "\\iint", with: "\\int\\!\\!\\int")
        // 中等空格
        result = result.replacingOccurrences(of: "\\:", with: "\\,")
        return result
    }

    /// `\\[2pt]` / `\\[1em]` 等行距可选参数 → `\\`。
    static func stripRowSpacingArgs(_ source: String) -> String {
        let chars = Array(source)
        var out = ""
        var index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count, chars[index + 1] == "\\" {
                out.append("\\\\")
                index += 2
                if index < chars.count, chars[index] == "[",
                   let close = MathBalancedParser.findPattern(chars, pattern: Array("]"), from: index + 1) {
                    let inner = String(chars[(index + 1)..<close])
                    if isLengthSpec(inner) {
                        index = close + 1
                        while index < chars.count, chars[index] == " " { index += 1 }
                    }
                }
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    private static func isLengthSpec(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let units = ["pt", "em", "ex", "mm", "cm", "bp", "in", "mu", "pc", "dd", "cc", "sp"]
        for unit in units where trimmed.hasSuffix(unit) {
            let numeric = String(trimmed.dropLast(unit.count))
            return !numeric.isEmpty
                && numeric.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
        }
        return false
    }

    /// 应用纯命令重命名表
    static func renameCommands(_ source: String) -> String {
        var result = source
        for (from, to) in commandRenames {
            result = MathBalancedParser.replaceCommand(result, command: from, with: to)
        }
        return result
    }

    /// `\not` 前缀否定映射
    static func replaceNotPrefix(_ source: String) -> String {
        let chars = Array(source)
        let pattern = Array("\\not")
        var out = ""
        var index = 0
        while index < chars.count {
            if MathBalancedParser.matches(chars, at: index, pattern: pattern),
               index + pattern.count < chars.count, !chars[index + pattern.count].isLetter {
                var cursor = index + pattern.count
                while cursor < chars.count, chars[cursor] == " " { cursor += 1 }
                if cursor < chars.count, chars[cursor] == "=" {
                    out.append("\\ne")
                    index = cursor + 1
                    continue
                }
                var matched = false
                for (follow, to) in notPrefixRenames {
                    let followChars = Array(follow)
                    if MathBalancedParser.matches(chars, at: cursor, pattern: followChars),
                       cursor + followChars.count >= chars.count
                        || !chars[cursor + followChars.count].isLetter {
                        out.append(to)
                        index = cursor + followChars.count
                        matched = true
                        break
                    }
                }
                if matched { continue }
                out.append("\\lnot")
                index = index + pattern.count
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }
}
