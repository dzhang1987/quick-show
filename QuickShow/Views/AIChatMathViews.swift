import SwiftUI
import AppKit
import SwiftMath

// MARK: - 数学公式光栅化（LaTeX → NSImage）
//
// 设计要点：
// - macOS 1.7.3 上 MTMathUILabel.intrinsicContentSize 返回哨兵值 (-1,-1) 不可用，
//   故本方案统一走「离屏光栅化成 NSImage + NSTextAttachment / NSImageView」路径，
//   绝不把 MTMathUILabel 直接放进视图树。
// - 光栅化会把颜色烤进位图：动态 NSColor 直接传入会在暗色下黑底黑字。
//   因此所有颜色必须先在 effectiveAppearance 下解析成固定 sRGB 分量，再参与缓存 key。
enum MathRasterizer {

    /// 缓存 key：latex + 字号 + 已解析为 sRGB 的颜色四分量 + 显示/行内模式。
    /// 颜色进 key 保证亮暗两套位图各自独立，切换模式不会串味。
    private struct CacheKey: Hashable {
        let latex: String
        let pointSize: CGFloat
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        let isDisplay: Bool
    }

    /// 光栅化结果：位图 + 逻辑尺寸 + 基线信息（ascent/descent 供行内基线对齐）。
    struct Rasterized {
        let image: NSImage
        let size: NSSize
        let ascent: CGFloat
        let descent: CGFloat
    }

    private static var cache: [CacheKey: Rasterized] = [:]

    /// 把 SwiftUI Color 在当前绘制外观下解析成固定 sRGB NSColor。
    /// appearance 为空时退回直接解析（无外观上下文时仅作兜底）。
    static func resolvedColor(_ color: Color, appearance: NSAppearance?) -> NSColor {
        var resolved = NSColor.labelColor
        let resolve = {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.labelColor
        }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(resolve)
        } else {
            resolve()
        }
        return resolved
    }

    /// SwiftUI colorScheme → 固定 appearance。
    /// 位图烤色后不会自动跟随明暗翻转，必须经 @Environment(\.colorScheme) 驱动
    /// updateNSView 重调（SwiftUI 只追踪环境依赖，不追踪 NSApp.effectiveAppearance），
    /// 再由此处换用对应 appearance 重新取色光栅化。
    static func appearance(for scheme: ColorScheme) -> NSAppearance {
        scheme == .dark
            ? NSAppearance(named: .darkAqua) ?? NSAppearance(named: .aqua)!
            : NSAppearance(named: .aqua)!
    }

    /// 公式 → 位图（唯一入口，带缓存）。解析失败返回 nil，由调用方降级显示原始 LaTeX。
    /// - Parameter isDisplay: 块级用 true（display 模式，分式/积分更舒展），行内用 false（text 模式）。
    static func rasterize(latex: String, pointSize: CGFloat, color: NSColor, isDisplay: Bool) -> Rasterized? {
        // 先转译再算缓存 key：转译结果稳定，缓存命中率更高；行内/块级共用此入口。
        let latex = MathLatexTranspiler.transpile(latex)
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let key = CacheKey(
            latex: latex,
            pointSize: pointSize,
            red: srgb.redComponent,
            green: srgb.greenComponent,
            blue: srgb.blueComponent,
            alpha: srgb.alphaComponent,
            isDisplay: isDisplay
        )
        if let cached = cache[key] { return cached }

        var renderer = MathImage(
            latex: latex,
            fontSize: pointSize,
            textColor: srgb,
            labelMode: isDisplay ? .display : .text,
            textAlignment: .center
        )
        let (error, image, layout) = renderer.asImage()
        guard error == nil, let image else { return nil }

        let result = Rasterized(
            image: image,
            size: image.size,
            ascent: layout?.ascent ?? pointSize * 0.8,
            // 兜底 descent：正数表示基线以下的深度（NSFont.descender 为负，取反）
            descent: layout?.descent ?? (-NSFont.systemFont(ofSize: pointSize).descender)
        )
        cache[key] = result
        return result
    }
}

// MARK: - LaTeX 预处理转译
//
// SwiftMath 1.7.3 实测不支持以下命令/写法（MTMathListBuilder.build 会失败），
// 在送入光栅化前先做纯文本转译；转译仍在 parse 失败时走既有降级路径（等宽源码）。
//
// ⚠ 关键机制约束（2026-10 实测坐实）：MTMathAtomFactory.atom(forCharacter:) 对
//   非 ASCII 输入字符（0x21–0x7E 之外，仅西里尔/重音字符豁免）一律返回 nil 并被
//   builder 静默丢弃——任何映射成裸 Unicode 字符的替换（∴ ⊄ ⊈ ∤ ↪ ⇌ 等）都会
//   渲染成 0×0 空图（\text{Unicode} 转义同死路）。因此所有替换目标必须构造为
//   supportedLatexSymbols 表内命令（291 个）的组合。
//
// 覆盖清单（2026-10 全面实测扩展，逐条经本地 SwiftMath 驱动 parse+render 验证）：
//   - 分数族：\dfrac \tfrac \cfrac → \frac；\dbinom \tbinom → \binom
//   - 多重积分：\iint \iiint \iiiint \oiint \oiiint → \int/\oint 负空格紧排
//   - 间距：\: \medspace \thinspace → \,；\neg*space 族 → \!；\hspace{X} → \,
//   - 算子族：\operatorname(\*) → \mathrm；\mathop 去壳；\substack → \atop；\pmod 展开
//   - 装饰去壳（内容零丢失）：\boxed \cancel \bcancel \xcancel \sout \overbrace \underbrace
//     \overleftarrow \overleftrightarrow \underleftarrow \underrightarrow \utilde \smash
//     \mathstrut \strut；\overrightarrow → \vec
//   - 上下叠放：\overset \stackrel → {上 \atop 下}；\underset → {主体 \atop 下}；
//     \xrightarrow 族 → {标注 \atop 长箭头}
//   - 定界符：\big/\Big/\bigg/\Bigg（含 l/r/m 变体）\middle 删除；\lvert/\rvert → |；
//     \lVert/\rVert → \Vert；行距可选参数 \\[2pt] → \\
//   - 环境：align(\*) → aligned；gather(ed)(\*)/multline(\*) → matrix；eqnarray → aligned；
//     dcases → cases；smallmatrix → matrix；array → matrix（剥离列格式、\hline 删除）；
//     aligned/split/eqalign 每行仅支持 2 列——0 列补尾 &、>1 列保留首个其余 \quad
//   - 逻辑：\implies → \Longrightarrow；\impliedby → \Longleftarrow；\therefore/\because →
//     \atop 三点构造；\nexists → \lnot\exists；否定关系（\nleq \nsubseteq \subsetneq 等）→
//     \lnot 前缀/语义等价命令；\not= → \ne；\not\in → \notin；其余 \not → ¬ 前缀
//   - 箭头近似：\longmapsto → \mapsto；hook/harpoon/弯箭头/波浪箭头/双头箭头 → 方向
//     等价的 \rightarrow/\leftarrow/\longrightarrow/\leftrightarrow 族
//   - 框/圈运算符：\boxplus → \oplus、\boxtimes → \otimes、\circledast → \odot 等（圆圈族近似）；
//     \triangledown → \nabla；\diamond → \cdot；\Join/\ltimes/\rtimes → \times
//   - 序关系：\leqslant → \leq；\preceq → \prec\!\!=；\vdash → \vert\!\!=
//   - 字体：\mathscr → \mathcal；\Bbb → \mathbb；\boldsymbol/\pmb → \mathbf（希腊内容去壳）；
//     \tiny…\Huge 由 vendored SwiftMath 内核补丁原生渲染（MTMathStyle.fontSizeScale 字号阶梯）；\scriptscriptstyle → \scriptstyle；\mbox/\textnormal → \text；\emph 去壳
//   - 颜色：\textcolor{c}{X} → {\color{c} X}（.textcolor display 分支有渲染陷阱，见参数感知步骤注释）
//   - 其他：\varkappa → \kappa；\digamma → F；\dddot → \ddot；\phantom 族/\tag{X}/\label{X}/
//     \require{X} 删除；\hl{X} 去壳；\href{u}{t} → \text{t}；\fcolorbox{a}{b}{X} → \colorbox{b}{X}；
//     单列 cases 补列
// 以下命令实测正常，保持原样：\qquad \quad \oint \vec \, \; \! \partial \lim \atop \varphi
//   \phi \equiv \nabla \times \psi \sin \pm \text \mathbb \mathcal \mathfrak \mathsf
//   \mathtt \mathbf \binom \left \right \langle \Vert \emptyset \square \angle \top
//   \longrightarrow \Longleftarrow \longleftrightarrow \scriptstyle \lnot \notin \ne
//   \models \triangle \oplus \otimes \odot \ominus \prec \succ \subset \supset
//   matrix/pmatrix/bmatrix/vmatrix/Vmatrix/cases/aligned/split/eqalign 环境。
enum MathLatexTranspiler {

    static func transpile(_ latex: String) -> String {
        var result = latex
        // 1. 分数命令族：统一降级为 \frac（命令边界：后一个字符不是字母才替换）
        result = replaceCommand(result, command: "\\dfrac", with: "\\frac")
        result = replaceCommand(result, command: "\\tfrac", with: "\\frac")
        result = replaceCommand(result, command: "\\cfrac", with: "\\frac")
        // 2. 多重积分：拆成多个 \int/\oint，用 \! 负空格把积分号贴紧（长命令先替换）
        result = replaceCommand(result, command: "\\iiiint", with: "\\int\\!\\!\\!\\int\\!\\!\\!\\int\\!\\!\\!\\int")
        result = replaceCommand(result, command: "\\oiiint", with: "\\oint\\!\\!\\oint\\!\\!\\oint")
        result = replaceCommand(result, command: "\\oiint", with: "\\oint\\!\\!\\oint")
        result = replaceCommand(result, command: "\\iiint", with: "\\int\\!\\!\\!\\int\\!\\!\\!\\int")
        result = replaceCommand(result, command: "\\iint", with: "\\int\\!\\!\\int")
        // 3. 中等空格 \: 不支持，降级为 \,
        result = result.replacingOccurrences(of: "\\:", with: "\\,")
        // 4. 行距可选参数 \\[2pt] → \\（先于 substack/cases 的按 \\ 行拆分；
        //    长度格式校验避免误吞行首字面 [）
        result = stripRowSpacingArgs(result)
        // 5. \substack 堆叠转 \atop
        result = replaceSubstack(result)
        // 6. \pmod{X} 展开（SwiftMath 无 \pmod）
        result = replacePmod(result)
        // 7. 单列 cases 补列
        result = padSingleColumnCases(result)
        // 8. 环境映射（align→aligned / gather→matrix / array→matrix 等）
        //    + aligned 族列数收敛（SwiftMath 每行仅支持 2 列）
        result = mapEnvironments(result)
        // 9. 参数感知替换（上下叠放 / x 箭头族 / 幻影 / 颜色框 / 链接 / 行距 / 粗体符号）
        // \textcolor → \color 开关形式：MTTypesetter 的 .textcolor display 分支存在
        // 致命陷阱（前驱原子非 nil + 内层渲染出空 displayAtoms 时 subDisplays[0] 越界；
        // 内层含 \color/\colorbox 时 subDisplay 类型强转崩溃，实测 2026-10），
        // 而 .color 分支无下标/强转，语义等价（c 色应用于 X），故统一改道。
        result = replaceCommandWithArgs(result, command: "\\textcolor", argCount: 2, fallback: "") { args in
            "{\\color{\(args[0])} \(args[1])}"
        }
        result = replaceCommandWithArgs(result, command: "\\overset", argCount: 2, fallback: "") { args in
            "{\(args[0]) \\atop \(args[1])}"
        }
        result = replaceCommandWithArgs(result, command: "\\stackrel", argCount: 2, fallback: "") { args in
            "{\(args[0]) \\atop \(args[1])}"
        }
        result = replaceCommandWithArgs(result, command: "\\underset", argCount: 2, fallback: "") { args in
            "{\(args[1]) \\atop \(args[0])}"
        }
        result = replaceCommandWithArgs(result, command: "\\xrightarrow", argCount: 1, fallback: "\\longrightarrow") { args in
            "{\(args[0]) \\atop \\longrightarrow}"
        }
        result = replaceCommandWithArgs(result, command: "\\xleftarrow", argCount: 1, fallback: "\\longleftarrow") { args in
            "{\(args[0]) \\atop \\longleftarrow}"
        }
        result = replaceCommandWithArgs(result, command: "\\xleftrightarrow", argCount: 1, fallback: "\\longleftrightarrow") { args in
            "{\(args[0]) \\atop \\longleftrightarrow}"
        }
        result = replaceCommandWithArgs(result, command: "\\xRightarrow", argCount: 1, fallback: "\\Longrightarrow") { args in
            "{\(args[0]) \\atop \\Longrightarrow}"
        }
        result = replaceCommandWithArgs(result, command: "\\xLeftarrow", argCount: 1, fallback: "\\Longleftarrow") { args in
            "{\(args[0]) \\atop \\Longleftarrow}"
        }
        result = replaceCommandWithArgs(result, command: "\\xhookrightarrow", argCount: 1, fallback: "\\longrightarrow") { args in
            "{\(args[0]) \\atop \\longrightarrow}"
        }
        result = replaceCommandWithArgs(result, command: "\\xhookleftarrow", argCount: 1, fallback: "\\longleftarrow") { args in
            "{\(args[0]) \\atop \\longleftarrow}"
        }
        result = replaceCommandWithArgs(result, command: "\\fcolorbox", argCount: 3, fallback: "\\colorbox") { args in
            "\\colorbox{\(args[1])}{\(args[2])}"
        }
        result = replaceCommandWithArgs(result, command: "\\href", argCount: 2, fallback: "\\text") { args in
            "\\text{\(args[1])}"
        }
        result = replaceCommandWithArgs(result, command: "\\phantom", argCount: 1, fallback: "") { _ in "" }
        result = replaceCommandWithArgs(result, command: "\\hphantom", argCount: 1, fallback: "") { _ in "" }
        result = replaceCommandWithArgs(result, command: "\\vphantom", argCount: 1, fallback: "") { _ in "" }
        result = replaceCommandWithArgs(result, command: "\\tag", argCount: 1, fallback: "") { _ in "" }
        // MathJax 风格指令：\label{X} 编号引用 / \require{X} 扩展加载声明 → 无视觉内容，删除
        result = replaceCommandWithArgs(result, command: "\\label", argCount: 1, fallback: "") { _ in "" }
        result = replaceCommandWithArgs(result, command: "\\require", argCount: 1, fallback: "") { _ in "" }
        // \hl{X}（MathJax 高亮，SwiftMath 无）：去壳保留内容
        result = replaceCommandWithArgs(result, command: "\\hl", argCount: 1, fallback: "") { args in
            "{\(args[0])}"
        }
        // \mathring{X}（环重音，无命令无字形）：\circ 置于上方的 \atop 构造
        result = replaceCommandWithArgs(result, command: "\\mathring", argCount: 1, fallback: "") { args in
            "{\\circ \\atop \(args[0])}"
        }
        // \genfrac{ld}{rd}{rule}{style}{num}{den}（泛型分式，SwiftMath 无）：
        // 圆括号定界 → \binom，其余 → \frac（定界符/线宽/样式降级，分子分母保留）
        result = replaceCommandWithArgs(result, command: "\\genfrac", argCount: 6, fallback: "\\frac") { args in
            if args[0] == "(" && args[1] == ")" {
                return "\\binom{\(args[4])}{\(args[5])}"
            }
            return "\\frac{\(args[4])}{\(args[5])}"
        }
        // \kern 维度（SwiftMath 无；\mkern 仅为序列化输出格式、解析器不收输入）：
        // 整段删除（间距损失、内容保留）
        result = result.replacingOccurrences(
            of: "\\\\kern\\s*-?\\d+(?:\\.\\d+)?[a-zA-Z]+",
            with: "",
            options: .regularExpression)
        result = replaceCommandWithArgs(result, command: "\\hspace", argCount: 1, fallback: "\\,") { _ in "\\," }
        result = replaceCommandWithArgs(result, command: "\\boldsymbol", argCount: 1, fallback: "") { args in
            argLeadsWithGreek(args[0]) ? "{\(args[0])}" : "\\mathbf{\(args[0])}"
        }
        result = replaceCommandWithArgs(result, command: "\\pmb", argCount: 1, fallback: "") { args in
            argLeadsWithGreek(args[0]) ? "{\(args[0])}" : "\\mathbf{\(args[0])}"
        }
        // 10. 纯命令重命名/删除（边界安全，详见 commandRenames 表）
        result = renameCommands(result)
        // 11. \not 前缀否定
        result = replaceNotPrefix(result)
        return result
    }

    // MARK: 命令边界替换

    /// 替换命令名时要求后一个字符不是字母（命令边界），避免 `\dfracX` 之类被误伤。
    private static func replaceCommand(_ source: String, command: String, with replacement: String) -> String {
        let chars = Array(source)
        let pattern = Array(command)
        var out = ""
        out.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            if matches(chars, at: index, pattern: pattern) {
                let after = index + pattern.count
                if after >= chars.count || !chars[after].isLetter {
                    out.append(contentsOf: replacement)
                    index = after
                    continue
                }
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    // MARK: \substack → \atop

    /// 扫描 `\substack{...}`，按花括号计数找到配对 `}`，
    /// 内部**顶层** `\\` 替换为 ` \atop `（嵌套花括号内的 `\\` 不动）。
    ///
    /// 括号配对推演：`\substack` 命令连同其外层花括号整体视为一个分组。
    /// - `_{\substack{A \\ B}}`：`\substack` 前一个字符是 `{` → 直接吐内容，
    ///   得 `_{A \atop B}`（单层花括号，下标分组正确）。
    /// - 独立 `\substack{A \\ B}`：前一个字符不是 `{` → 补一层花括号，
    ///   得 `{A \atop B}`，保证 \atop 分组不被上下文吞并。
    private static func replaceSubstack(_ source: String) -> String {
        let chars = Array(source)
        let marker = Array("\\substack")
        var out = ""
        var index = 0
        while index < chars.count {
            if matches(chars, at: index, pattern: marker),
               index + marker.count < chars.count,
               chars[index + marker.count] == "{",
               let bodyEnd = matchingBrace(chars, openIndex: index + marker.count) {
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

    /// 顶层（花括号深度 0）的 `\\` → ` \atop `。
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
                continue
            }
            out.append(char)
            index += 1
        }
        return out
    }

    // MARK: \pmod{X} 展开

    /// 扫描 `\pmod{...}`，按花括号计数找配对 `}`，整体替换为 `\;(\text{mod}~X)`。
    /// SwiftMath 1.7.3 实测 `\pmod` 报 "Invalid command \pmod"；
    /// 而 `\;`、`\text{...}`、`~` 均实测可用。`\varphi` 实测支持，此处不做映射。
    private static func replacePmod(_ source: String) -> String {
        let chars = Array(source)
        let marker = Array("\\pmod")
        var out = ""
        var index = 0
        while index < chars.count {
            if matches(chars, at: index, pattern: marker),
               index + marker.count < chars.count,
               chars[index + marker.count] == "{",
               let bodyEnd = matchingBrace(chars, openIndex: index + marker.count) {
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

    // MARK: 单列 cases 补列

    /// 扫描 `\begin{cases}` … `\end{cases}`（区分大小写）；内容无 `&` 时按顶层 `\\` 拆行，
    /// 每个非空行尾补 ` &` 凑成两列；已含 `&`（两列及以上）整体不动。
    private static func padSingleColumnCases(_ source: String) -> String {
        let chars = Array(source)
        let beginTag = Array("\\begin{cases}")
        let endTag = Array("\\end{cases}")
        var out = ""
        var index = 0
        while index < chars.count {
            if matches(chars, at: index, pattern: beginTag) {
                let bodyStart = index + beginTag.count
                if let endIndex = findPattern(chars, pattern: endTag, from: bodyStart) {
                    let body = String(chars[bodyStart..<endIndex])
                    out.append(contentsOf: beginTag)
                    out.append(body.contains("&") ? body : padCaseRows(body))
                    out.append(contentsOf: endTag)
                    index = endIndex + endTag.count
                    continue
                }
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    /// 按顶层 `\\` 拆分 cases 行，非空行尾补 ` &`，再用 `\\` 拼回。
    private static func padCaseRows(_ body: String) -> String {
        let chars = Array(body)
        var rows: [String] = []
        var current = ""
        var depth = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "{" { depth += 1; current.append(char); index += 1; continue }
            if char == "}" { depth -= 1; current.append(char); index += 1; continue }
            if depth == 0, char == "\\", index + 1 < chars.count, chars[index + 1] == "\\" {
                rows.append(current)
                current = ""
                index += 2
                continue
            }
            current.append(char)
            index += 1
        }
        rows.append(current)
        let padded = rows.map { row -> String in
            row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? row : row + " &"
        }
        return padded.joined(separator: "\\\\")
    }

    // MARK: 纯命令重命名表

    /// 纯文本命令重命名/删除表（replaceCommand 边界安全：命令后一字符非字母才替换）。
    /// 同族长命令在前（双保险）；值为空串 = 删除命令、保留其花括号参数（去壳，内容零丢失）。
    /// 仅收录实测 parse 失败的命令；实测可用命令（\bigcup/\bigcap/\bigvee 等 \big 前缀族）
    /// 由边界检查天然豁免，勿凭直觉加表项。
    private static let commandRenames: [(from: String, to: String)] = [
        // operatorname 族（带 * 先行）
        ("\\operatorname*", "\\mathrm"),
        ("\\operatorname", "\\mathrm"),
        // 字体族
        ("\\mathscr", "\\mathcal"),
        ("\\Bbb", "\\mathbb"),
        ("\\scriptscriptstyle", "\\scriptstyle"),
        // 字号族（\tiny~\Huge 交由 vendored SwiftMath 内核补丁原生渲染，MTMathStyle.fontSizeScale）
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
        // 逻辑符号（∴/∵ 无命令无字形：\atop 三点构造；
        // 否定类一律 \lnot 前缀 + 基础关系——Unicode 否定形会被 builder ASCII 门静默丢弃成 0×0 空图）
        ("\\implies", "\\Longrightarrow"), ("\\impliedby", "\\Longleftarrow"),
        ("\\therefore", "{{\\cdot}\\atop{\\cdot\\,\\cdot}}"),
        ("\\because", "{{\\cdot\\,\\cdot}\\atop{\\cdot}}"),
        ("\\nexists", "\\lnot\\exists"), ("\\nmid", "\\lnot\\mid"),
        ("\\nparallel", "\\lnot\\parallel"),
        ("\\varnothing", "\\emptyset"),
        // 否定关系（裸命令形态；\not 前缀形态见 replaceNotPrefix）
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
        // 箭头近似（SwiftMath 仅基础箭头族；hook/harpoon/弯箭头/波浪箭头统一降级为方向等价的基础箭头）
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
        // 框/圈运算符（无命令无字形：降级为语义最近的圆圈运算符族）
        ("\\boxplus", "\\oplus"), ("\\boxtimes", "\\otimes"),
        ("\\boxminus", "\\ominus"), ("\\boxdot", "\\odot"),
        ("\\circledast", "\\odot"), ("\\circledcirc", "\\circ"),
        // 形状（▽ 与 ∇ 几乎同形；菱形降级为几何点）
        ("\\triangledown", "\\nabla"),
        ("\\diamond", "\\cdot"), ("\\Diamond", "\\cdot"),
        ("\\Join", "\\times"), ("\\join", "\\times"),
        ("\\ltimes", "\\times"), ("\\rtimes", "\\times"),
        // 三阶导数重音
        ("\\dddot", "\\ddot"), ("\\ddddot", "\\ddot"),
        // 取模（SwiftMath 无 \bmod/\mod）：罗马体 mod + 间距
        ("\\bmod", "\\;\\mathrm{mod}\\;"), ("\\mod", "\\ \\mathrm{mod}\\ "),
        // 希腊变体
        ("\\varkappa", "\\kappa"), ("\\digamma", "F"),
        // 矩阵行线
        ("\\hline", ""), ("\\hdashline", ""),
    ]

    private static func renameCommands(_ source: String) -> String {
        var result = source
        for (from, to) in commandRenames {
            result = replaceCommand(result, command: from, with: to)
        }
        return result
    }

    // MARK: 行距可选参数剥离

    /// `\\[2pt]` / `\\[1em]` 等行距可选参数 → `\\`。
    /// 仅在方括号内容形如「数字+单位」时剥离，避免误吞行首字面 `[`。
    private static func stripRowSpacingArgs(_ source: String) -> String {
        let chars = Array(source)
        var out = ""
        var index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count, chars[index + 1] == "\\" {
                out.append("\\\\")
                index += 2
                if index < chars.count, chars[index] == "[",
                   let close = findPattern(chars, pattern: Array("]"), from: index + 1) {
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

    /// 行距长度格式：数字（可带小数点/负号）+ TeX 长度单位。
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

    // MARK: 环境映射

    /// 环境名映射：SwiftMath 未知环境改到语义最近的支持环境。
    /// matrix 族列数不限、内容居中（gather/array 的合理近似）；aligned/eqalign/split
    /// 每行恰 2 列（随后列数收敛）。含定界花括号的整串精确匹配，无前缀误吞。
    private static let envRenames: [(from: String, to: String)] = [
        ("align", "aligned"), ("align*", "aligned"),
        ("alignat", "aligned"), ("alignat*", "aligned"),
        ("eqnarray", "aligned"),
        ("gather", "matrix"), ("gather*", "matrix"), ("gathered", "matrix"),
        ("multline", "matrix"), ("multline*", "matrix"),
        ("dcases", "cases"),
        ("smallmatrix", "matrix"),
        ("array", "matrix"),
    ]

    private static func mapEnvironments(_ source: String) -> String {
        // 1. array 的 begin 标签 + 列格式先行剥离改名（改名后无法与原生 matrix 区分）
        var result = stripArrayColumnSpec(source)
        // 2. begin/end 标签通用改名（含 \end{array} 收尾）
        for (from, to) in envRenames {
            result = result.replacingOccurrences(of: "\\begin{\(from)}", with: "\\begin{\(to)}")
            result = result.replacingOccurrences(of: "\\end{\(from)}", with: "\\end{\(to)}")
        }
        // 3. aligned 族列数收敛
        result = collapseAlignedColumns(result)
        return result
    }

    /// `\begin{array}{cc|c}` → `\begin{matrix}`（列格式剥离；无列格式时仅改名）。
    private static func stripArrayColumnSpec(_ source: String) -> String {
        let chars = Array(source)
        let beginTag = Array("\\begin{array}")
        var out = ""
        var index = 0
        while index < chars.count {
            if matches(chars, at: index, pattern: beginTag) {
                var after = index + beginTag.count
                while after < chars.count, chars[after] == " " || chars[after] == "\n" { after += 1 }
                if after < chars.count, chars[after] == "{",
                   let specEnd = matchingBrace(chars, openIndex: after) {
                    out.append(contentsOf: "\\begin{matrix}")
                    index = specEnd + 1
                } else {
                    out.append(contentsOf: "\\begin{matrix}")
                    index = index + beginTag.count
                }
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    /// aligned/split/eqalign（含由 align/eqnarray 映射而来）每行仅支持 2 列：
    /// 0 列补尾 ` &`；>1 个 & 保留首个、其余替换为 \quad（列间内容转行内排布，内容零丢失）。
    /// 体内含嵌套环境时整体跳过（保守降级，避免内层 &/行拆分误伤）。
    private static let twoColumnEnvironments = ["aligned", "eqalign", "split"]

    private static func collapseAlignedColumns(_ source: String) -> String {
        let chars = Array(source)
        let beginTag = Array("\\begin{")
        var out = ""
        var index = 0
        while index < chars.count {
            if matches(chars, at: index, pattern: beginTag) {
                var nameIndex = index + beginTag.count
                var name = ""
                while nameIndex < chars.count, chars[nameIndex] != "}" {
                    name.append(chars[nameIndex])
                    nameIndex += 1
                }
                if nameIndex < chars.count, twoColumnEnvironments.contains(name) {
                    let bodyStart = nameIndex + 1
                    let endTag = Array("\\end{\(name)}")
                    if let endIndex = findPattern(chars, pattern: endTag, from: bodyStart) {
                        let body = String(chars[bodyStart..<endIndex])
                        if !body.contains("\\begin{") {
                            out.append(contentsOf: beginTag)
                            out.append(name)
                            out.append("}")
                            out.append(collapseColumns(inBody: body))
                            out.append(contentsOf: endTag)
                            index = endIndex + endTag.count
                            continue
                        }
                    }
                }
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    private static func collapseColumns(inBody body: String) -> String {
        splitRowsTopLevel(body).map { row -> String in
            let ampersands = topLevelAmpersandCount(row)
            if ampersands == 0 { return row + " &" }
            if ampersands > 1 { return replaceAmpersandsAfterFirst(row) }
            return row
        }.joined(separator: "\\\\")
    }

    /// 按顶层 `\\` 拆行（花括号深度 >0 时不拆；行距可选参数已前置剥离）。
    private static func splitRowsTopLevel(_ body: String) -> [String] {
        let chars = Array(body)
        var rows: [String] = []
        var current = ""
        var depth = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "{" { depth += 1; current.append(char); index += 1; continue }
            if char == "}" { depth -= 1; current.append(char); index += 1; continue }
            if depth == 0, char == "\\", index + 1 < chars.count, chars[index + 1] == "\\" {
                rows.append(current)
                current = ""
                index += 2
                while index < chars.count, chars[index] == " " { index += 1 }
                continue
            }
            current.append(char)
            index += 1
        }
        rows.append(current)
        return rows
    }

    private static func topLevelAmpersandCount(_ row: String) -> Int {
        var depth = 0
        var count = 0
        for char in row {
            if char == "{" { depth += 1 } else if char == "}" { depth -= 1 }
            else if char == "&", depth == 0 { count += 1 }
        }
        return count
    }

    /// 保留首个顶层 &，其余替换为 \quad。
    private static func replaceAmpersandsAfterFirst(_ row: String) -> String {
        let chars = Array(row)
        var out = ""
        var depth = 0
        var ampersandsSeen = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "{" { depth += 1; out.append(char); index += 1; continue }
            if char == "}" { depth -= 1; out.append(char); index += 1; continue }
            if char == "&", depth == 0 {
                ampersandsSeen += 1
                if ampersandsSeen == 1 {
                    out.append(char)
                } else {
                    // 首尾留空格：紧贴下一字符会产生 \quadb 之类畸形命令
                    out.append(" \\quad ")
                }
                index += 1
                continue
            }
            out.append(char)
            index += 1
        }
        return out
    }

    // MARK: 参数感知替换

    /// 扫描 `\command{a}{b}…`（argCount 个花括号组），整段替换为 transform(参数组)。
    /// 组不足（裸命令/畸形）时替换为 fallback（只消费命令本身）。
    /// 组间允许空白；组内花括号按深度配对提取原始内容。
    private static func replaceCommandWithArgs(
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
            if matches(chars, at: index, pattern: pattern) {
                let after = index + pattern.count
                // 命令边界：后一个字符不是字母
                if after >= chars.count || !chars[after].isLetter {
                    var argIndex = after
                    var args: [String] = []
                    var argsEnd = after
                    var ok = true
                    for _ in 0..<argCount {
                        while argIndex < chars.count, chars[argIndex] == " " { argIndex += 1 }
                        if argIndex < chars.count, chars[argIndex] == "{",
                           let close = matchingBrace(chars, openIndex: argIndex) {
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

    // MARK: 希腊引导检测（\boldsymbol 分流用）

    /// 参数首 token 是否希腊字母（\alpha…\Omega 或 Unicode 希腊区）：
    /// \mathbf 对希腊内容 parse 失败，需走去壳路径。
    private static let greekCommandNames: Set<String> = [
        "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta",
        "vartheta", "iota", "kappa", "varkappa", "lambda", "mu", "nu", "xi", "pi", "varpi",
        "rho", "varrho", "sigma", "varsigma", "tau", "upsilon", "phi", "varphi", "chi", "psi",
        "omega", "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi",
        "Psi", "Chi", "Omega", "digamma",
    ]

    private static func argLeadsWithGreek(_ arg: String) -> Bool {
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

    // MARK: \not 前缀否定

    /// \not 后接命令的精确映射（长命令在前；否定语义用 \lnot 前缀 + 基础关系构造，
    /// Unicode 否定形会被 builder ASCII 门丢弃成 0×0 空图）。
    private static let notPrefixRenames: [(follow: String, to: String)] = [
        ("\\subseteq", "\\lnot\\subseteq"), ("\\supseteq", "\\lnot\\supseteq"),
        ("\\subset", "\\lnot\\subset"), ("\\supset", "\\lnot\\supset"),
        ("\\equiv", "\\lnot\\equiv"),
        ("\\leq", "\\lnot\\leq"), ("\\geq", "\\lnot\\geq"), ("\\le", "\\lnot\\leq"), ("\\ge", "\\lnot\\geq"),
        ("\\in", "\\notin"),
    ]

    /// `\not` 前缀否定：常见组合精确映射（\not= → \ne 等），其余降级为 ¬ 前缀
    /// （\lnot 保留原关系，语义可读）。命令边界保护 \not\int 等畸形输入不误吞。
    private static func replaceNotPrefix(_ source: String) -> String {
        let chars = Array(source)
        let pattern = Array("\\not")
        var out = ""
        var index = 0
        while index < chars.count {
            if matches(chars, at: index, pattern: pattern),
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
                    if matches(chars, at: cursor, pattern: followChars),
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

    // MARK: 通用扫描辅助

    /// 在 chars 的 index 处是否精确匹配 pattern。
    private static func matches(_ chars: [Character], at index: Int, pattern: [Character]) -> Bool {
        guard index + pattern.count <= chars.count else { return false }
        for offset in 0..<pattern.count where chars[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    /// 从 from 起查找 pattern 首次出现的位置。
    private static func findPattern(_ chars: [Character], pattern: [Character], from: Int) -> Int? {
        var index = from
        while index < chars.count {
            if matches(chars, at: index, pattern: pattern) { return index }
            index += 1
        }
        return nil
    }

    /// openIndex 指向 `{`，返回配对 `}` 的下标（含嵌套花括号计数）。
    private static func matchingBrace(_ chars: [Character], openIndex: Int) -> Int? {
        guard openIndex < chars.count, chars[openIndex] == "{" else { return nil }
        var depth = 0
        var index = openIndex
        while index < chars.count {
            if chars[index] == "{" {
                depth += 1
            } else if chars[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }
}

// MARK: - 行内公式 Attachment

/// NSTextAttachment 构造：图片 + bounds（基线对齐）。
enum InlineMathAttachment {
    static func make(latex: String, pointSize: CGFloat, color: NSColor) -> NSTextAttachment? {
        guard let raster = MathRasterizer.rasterize(
            latex: latex, pointSize: pointSize, color: color, isDisplay: false
        ) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = raster.image
        // y = -descent：把图片整体下压 descent 深度，使公式基线与整行文本基线重合
        attachment.bounds = CGRect(
            x: 0,
            y: -raster.descent,
            width: raster.size.width,
            height: raster.size.height
        )
        return attachment
    }
}

// MARK: - 块级公式视图

/// 块级公式：包 NSImageView，display 模式光栅化，等比缩放不下溢。
/// 失败降级由调用方处理（本视图 image 为 nil 时不显示内容）。
struct MathBlockView: NSViewRepresentable {
    let latex: String
    var fontSize: CGFloat = 14
    var color: Color = Color.primary

    /// 明暗翻转追踪：SwiftUI 环境变化才触发 updateNSView 重调（读 NSApp.effectiveAppearance
    /// 不被追踪，外观切换后旧位图会钉死），翻转后经缓存 key（含颜色分量）自动换新位图。
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        let nsColor = MathRasterizer.resolvedColor(color, appearance: MathRasterizer.appearance(for: colorScheme))
        let raster = MathRasterizer.rasterize(
            latex: latex, pointSize: fontSize, color: nsColor, isDisplay: true
        )
        view.image = raster?.image
    }
}

// MARK: - 含行内公式的段落视图

/// 含行内公式的段落：包 NSTextField（wrapsLabel），NSAttributedString 内嵌 NSTextAttachment。
/// 通过 sizeThatFits 把 proposed width 设为 preferredMaxLayoutWidth 后重新测量高度。
struct MathParagraphView: NSViewRepresentable {
    let inlines: [InlineToken]
    var baseSize: CGFloat = 13
    var weight: Font.Weight = .regular
    var color: Color = Color.primary.opacity(0.80)

    /// 明暗翻转追踪：同 MathBlockView，环境驱动 updateNSView 重调后重新取色光栅化；
    /// 原先读 field.effectiveAppearance 依赖视图已挂入窗口，且翻转不触发刷新。
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: NSAttributedString())
        field.isEditable = false
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.isBezeled = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let nsColor = MathRasterizer.resolvedColor(color, appearance: MathRasterizer.appearance(for: colorScheme))
        let nsFont = MarkdownInlineNS.font(size: baseSize, weight: MarkdownInlineNS.nsWeight(weight))
        field.attributedStringValue = MarkdownInlineNS.renderNS(
            inlines,
            baseFont: nsFont,
            baseColor: nsColor,
            baseSize: baseSize
        )
        field.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        // 无宽度建议时交回系统；有宽度则钉死换行宽度后重新测量高度。
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        nsView.preferredMaxLayoutWidth = width
        nsView.invalidateIntrinsicContentSize()
        nsView.layoutSubtreeIfNeeded()
        let height = nsView.fittingSize.height
        return CGSize(width: width, height: max(height, nsView.intrinsicContentSize.height))
    }
}

// MARK: - NSAttributedString 行内渲染（镜像 MarkdownInline.render 语义）

/// 行内 token → NSAttributedString（供含公式的段落使用）。
/// 语义严格对齐 SwiftUI 版 MarkdownInline.render：
/// text→引号归一 + baseColor/baseFont；code→等宽 + surfaceTrack 底；
/// bold→semibold + labelColor；italic→斜体；link→accent + 下划线；math→NSTextAttachment。
enum MarkdownInlineNS {

    /// SwiftUI Font.Weight → AppKit NSFont.Weight。
    static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    /// 正文字体（SF Pro）。
    static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// 等宽字体（SF Mono），对应 Theme.Typography.mono。
    static func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// 行内代码底色：surfaceTrack = Color.primary.opacity(0.06) 的 NSColor 近似。
    private static var codeBackground: NSColor {
        NSColor.labelColor.withAlphaComponent(0.06)
    }

    /// accent 的 NSColor 近似：优先取当前主题 accent 解析值，失败退回系统 linkColor。
    private static var accentColor: NSColor {
        MathRasterizer.resolvedColor(Theme.Colors.accent, appearance: NSApp.effectiveAppearance)
    }

    static func renderNS(
        _ tokens: [InlineToken],
        baseFont: NSFont,
        baseColor: NSColor,
        baseSize: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        render(into: result, tokens: tokens, baseFont: baseFont, baseColor: baseColor, baseSize: baseSize)
        return result
    }

    private static func render(
        into result: NSMutableAttributedString,
        tokens: [InlineToken],
        baseFont: NSFont,
        baseColor: NSColor,
        baseSize: CGFloat
    ) {
        for token in tokens {
            switch token {
            case let .text(value):
                let piece = NSAttributedString(
                    string: MarkdownInline.normalizeQuotes(value),
                    attributes: [.font: baseFont, .foregroundColor: baseColor]
                )
                result.append(piece)

            case let .code(value):
                let piece = NSAttributedString(
                    string: value,
                    attributes: [
                        .font: monoFont(size: 12.5),
                        .foregroundColor: baseColor,
                        .backgroundColor: codeBackground,
                    ]
                )
                result.append(piece)

            case let .bold(inner):
                // 加粗档提为 labelColor（contentPrimary），与 SwiftUI 版一致
                render(
                    into: result,
                    tokens: inner,
                    baseFont: font(size: baseSize, weight: .semibold),
                    baseColor: .labelColor,
                    baseSize: baseSize
                )

            case let .italic(inner):
                let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                render(
                    into: result,
                    tokens: inner,
                    baseFont: italicFont,
                    baseColor: baseColor,
                    baseSize: baseSize
                )

            case let .link(label, url):
                let start = result.length
                render(into: result, tokens: label, baseFont: baseFont, baseColor: baseColor, baseSize: baseSize)
                let range = NSRange(location: start, length: result.length - start)
                if range.length > 0 {
                    result.addAttribute(.foregroundColor, value: accentColor, range: range)
                    result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                    if let linkURL = URL(string: url) {
                        result.addAttribute(.link, value: linkURL, range: range)
                    }
                }

            case let .math(latex):
                if let attachment = InlineMathAttachment.make(latex: latex, pointSize: baseSize, color: baseColor) {
                    result.append(NSAttributedString(attachment: attachment))
                } else {
                    // 解析失败：降级显示原始 LaTeX 文本
                    result.append(NSAttributedString(
                        string: latex,
                        attributes: [.font: monoFont(size: 12), .foregroundColor: baseColor]
                    ))
                }
            }
        }
    }
}

// MARK: - SwiftUI 统一行内入口

/// 行内文本统一入口：无公式时走原 SwiftUI AttributedString 路径（与改动前 100% 等价）；
/// 含公式（含嵌套在粗体/斜体/链接内的公式）时改走 NSTextField + NSTextAttachment 路径。
struct MarkdownInlineText: View {
    let inlines: [InlineToken]
    var bodyColor: Color = Color.primary.opacity(0.80)
    var baseSize: CGFloat = 13
    var weight: Font.Weight = .regular
    var explicitColor: Color? = nil

    var body: some View {
        if inlines.containsMath {
            MathParagraphView(
                inlines: inlines,
                baseSize: baseSize,
                weight: weight,
                color: explicitColor ?? bodyColor
            )
        } else {
            plainText
        }
    }

    /// 非公式路径：严格复刻各调用点原有的 Text + font(+foregroundColor) modifier 组合。
    @ViewBuilder
    private var plainText: some View {
        let base = Text(MarkdownInline.render(inlines, bodyColor: bodyColor))
            .font(Theme.Typography.text(baseSize, weight))
        if let explicitColor {
            base.foregroundColor(explicitColor)
        } else {
            base
        }
    }
}

// MARK: - 公式检测（递归）

private extension Array where Element == InlineToken {
    /// 是否含公式 token（递归粗体/斜体/链接内部）。
    var containsMath: Bool { contains { $0.containsMath } }
}

private extension InlineToken {
    var containsMath: Bool {
        switch self {
        case .math:
            return true
        case let .bold(inner), let .italic(inner):
            return inner.containsMath
        case let .link(text, _):
            return text.containsMath
        case .text, .code:
            return false
        }
    }
}