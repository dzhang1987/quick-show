import Foundation

// MARK: - LaTeX 预处理转译流水线（Pipeline 模式）

enum MathLatexPipeline {

    /// 统一转译入口：执行有序流水线阶段
    static func transpile(_ latex: String) -> String {
        var result = latex

        // 阶段 1：基础命令族清洗与多重积分展开
        result = MathSyntaxSanitizer.sanitizeFractionsAndIntegrals(result)

        // 阶段 2：行距可选参数剥离
        result = MathSyntaxSanitizer.stripRowSpacingArgs(result)

        // 阶段 3：\substack 堆叠转 \atop 与 \pmod 展开
        result = MathArgumentRewriter.replaceSubstack(result)
        result = MathArgumentRewriter.replacePmod(result)

        // 阶段 4：cases 补列与环境映射（aligned / matrix / cases）
        result = MathEnvironmentMapper.padSingleColumnCases(result)
        result = MathEnvironmentMapper.mapEnvironments(result)

        // 阶段 5：参数感知替换（上下叠放 / x 箭头族 / 幻影 / 颜色 / 链接 / 粗体）
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\textcolor", argCount: 2, fallback: "") { args in
            "{\\color{\(args[0])} \(args[1])}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\overset", argCount: 2, fallback: "") { args in
            "{\(args[0]) \\atop \(args[1])}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\stackrel", argCount: 2, fallback: "") { args in
            "{\(args[0]) \\atop \(args[1])}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\underset", argCount: 2, fallback: "") { args in
            "{\(args[1]) \\atop \(args[0])}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\xrightarrow", argCount: 1, fallback: "\\longrightarrow") { args in
            "{\(args[0]) \\atop \\longrightarrow}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\xleftarrow", argCount: 1, fallback: "\\longleftarrow") { args in
            "{\(args[0]) \\atop \\longleftarrow}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\xleftrightarrow", argCount: 1, fallback: "\\longleftrightarrow") { args in
            "{\(args[0]) \\atop \\longleftrightarrow}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\xRightarrow", argCount: 1, fallback: "\\Longrightarrow") { args in
            "{\(args[0]) \\atop \\Longrightarrow}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\xLeftarrow", argCount: 1, fallback: "\\Longleftarrow") { args in
            "{\(args[0]) \\atop \\Longleftarrow}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\xhookrightarrow", argCount: 1, fallback: "\\longrightarrow") { args in
            "{\(args[0]) \\atop \\longrightarrow}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\xhookleftarrow", argCount: 1, fallback: "\\longleftarrow") { args in
            "{\(args[0]) \\atop \\longleftarrow}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\fcolorbox", argCount: 3, fallback: "\\colorbox") { args in
            "\\colorbox{\(args[1])}{\(args[2])}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\href", argCount: 2, fallback: "\\text") { args in
            "\\text{\(args[1])}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\phantom", argCount: 1, fallback: "") { _ in "" }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\hphantom", argCount: 1, fallback: "") { _ in "" }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\vphantom", argCount: 1, fallback: "") { _ in "" }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\tag", argCount: 1, fallback: "") { _ in "" }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\label", argCount: 1, fallback: "") { _ in "" }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\require", argCount: 1, fallback: "") { _ in "" }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\hl", argCount: 1, fallback: "") { args in
            "{\(args[0])}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\mathring", argCount: 1, fallback: "") { args in
            "{\\circ \\atop \(args[0])}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\genfrac", argCount: 6, fallback: "\\frac") { args in
            if args[0] == "(" && args[1] == ")" {
                return "\\binom{\(args[4])}{\(args[5])}"
            }
            return "\\frac{\(args[4])}{\(args[5])}"
        }
        result = result.replacingOccurrences(
            of: "\\\\kern\\s*-?\\d+(?:\\.\\d+)?[a-zA-Z]+",
            with: "",
            options: .regularExpression)
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\hspace", argCount: 1, fallback: "\\,") { _ in "\\," }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\boldsymbol", argCount: 1, fallback: "") { args in
            MathArgumentRewriter.argLeadsWithGreek(args[0]) ? "{\(args[0])}" : "\\mathbf{\(args[0])}"
        }
        result = MathArgumentRewriter.replaceCommandWithArgs(result, command: "\\pmb", argCount: 1, fallback: "") { args in
            MathArgumentRewriter.argLeadsWithGreek(args[0]) ? "{\(args[0])}" : "\\mathbf{\(args[0])}"
        }

        // 阶段 6：纯命令重命名表
        result = MathSyntaxSanitizer.renameCommands(result)

        // 阶段 7：\not 前缀否定
        result = MathSyntaxSanitizer.replaceNotPrefix(result)

        return result
    }
}

// MARK: - 兼容门面（无缝支持调用方现有写法）

enum MathLatexTranspiler {
    @inlinable
    static func transpile(_ latex: String) -> String {
        MathLatexPipeline.transpile(latex)
    }
}
