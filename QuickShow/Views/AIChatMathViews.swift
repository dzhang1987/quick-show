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
// 在送入光栅化前先做纯文本转译；转译仍在 parse 失败时走既有降级路径（等宽源码）：
//   - \dfrac / \tfrac / \cfrac → \frac（命令边界替换，避免误伤后续字母）
//   - \iint / \iiint            → 多个 \int 用负空格 \! 紧排
//   - \:                        → \,
//   - \substack{a \\ b}         → a \atop b（外层已有下标花括号时直接吐内容，否则补一层）
//   - \begin{cases} 单列        → 每行补一个 & 凑成两列（已是两列及以上不动）
//   - \pmod{X}                  → \;(mod X)（展开为普通文本模运算）
// 以下命令实测正常，保持原样：\qquad \quad \oint \vec \, \; \! \partial \lim \atop
//   \varphi \phi \equiv \nabla \times \psi \sin \pm \text（\varphi 实测支持，勿动）。
enum MathLatexTranspiler {

    static func transpile(_ latex: String) -> String {
        var result = latex
        // 1. 分数命令族：统一降级为 \frac（命令边界：后一个字符不是字母才替换）
        result = replaceCommand(result, command: "\\dfrac", with: "\\frac")
        result = replaceCommand(result, command: "\\tfrac", with: "\\frac")
        result = replaceCommand(result, command: "\\cfrac", with: "\\frac")
        // 2. 多重积分：拆成多个 \int，用 \! 负空格把积分号贴紧（长命令先替换，避免前缀误判）
        result = replaceCommand(result, command: "\\iiint", with: "\\int\\!\\!\\!\\int\\!\\!\\!\\int")
        result = replaceCommand(result, command: "\\iint", with: "\\int\\!\\!\\!\\int")
        // 3. 中等空格 \: 不支持，降级为 \,
        result = result.replacingOccurrences(of: "\\:", with: "\\,")
        // 4. \substack 堆叠转 \atop
        result = replaceSubstack(result)
        // 5. \pmod{X} 展开（SwiftMath 无 \pmod）
        result = replacePmod(result)
        // 6. 单列 cases 补列
        result = padSingleColumnCases(result)
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