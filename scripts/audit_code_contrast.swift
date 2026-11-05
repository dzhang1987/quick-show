import Foundation

// MARK: - 代码高亮对比度审计（可复跑的可读性回归防线）
//
// 为什么需要它：语法色板来自第三方主题 CSS，各主题只为「它自己的底色」调过对比度。
// 我们把底色换成了自己的代码纸面，因此「这个主题在我们的纸面上是否可读」必须可度量、
// 可回归，而不是靠肉眼看一张截图。
//
// 数据来源全部是仓库真源，不复制任何色值：
// - 色板：解析 QuickShow/Utilities/MarkdownHighlighter.swift 里 CodeThemeCSS 的十六进制色值；
// - 纸面：解析 QuickShow/Utilities/DesignTokens.swift 里 Theme.CodePaper 的 ContrastColor 分量；
// - 校正算法：直接编译并调用 QuickShow/Utilities/ColorContrast.swift 的真实实现。
//
// 用法（与真实实现一起编译，避免复制算法）：
//   xcrun swiftc QuickShow/Utilities/ColorContrast.swift scripts/audit_code_contrast.swift -o /tmp/audit_code_contrast
//   (cd /tmp && ./audit_code_contrast)          # 或在仓库根目录运行，脚本按当前目录上溯定位真源
// 退出码：0 = 全部达标；1 = 存在达标失败（新增主题/改纸面后漂移会在此暴露）。

// MARK: 真源解析

struct ParsedTheme {
    let name: String
    let colors: [String]   // hex 列表（去重）
}

/// 仓库根：从当前目录向上找真源锚点（脚本可从仓库任意子目录运行）
func repoRoot() -> URL {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let marker = "QuickShow/Utilities/DesignTokens.swift"
    for _ in 0..<6 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(marker).path) { return dir }
        dir = dir.deletingLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

func read(_ relativePath: String) throws -> String {
    try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
}

/// 从 MarkdownHighlighter 的 CSS 常量里按「主题块」抓取色值。
func parseThemes() throws -> [ParsedTheme] {
    let source = try read("QuickShow/Utilities/MarkdownHighlighter.swift")
    // static let <name> = """ ... """
    // 匹配：static let <name> = """\n ...多行 CSS... """
    let pattern = "static let ([A-Za-z]+) = \"\"\"\n([\\s\\S]*?)\"\"\""
    let regex = try NSRegularExpression(pattern: pattern)
    let ns = source as NSString
    // 只取前景色：CSS 里的 `background` / `background-color` 是主题自带底色，
    // 渲染时已被剥离（见 MarkdownHighlighter.postProcess），不参与文字可读性判定。
    let hexRegex = try NSRegularExpression(
        pattern: "(?:color|color:)\\s*:\\s*(#[0-9a-fA-F]{6})"
    )

    var themes: [ParsedTheme] = []
    for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
        let name = ns.substring(with: match.range(at: 1))
        let body = ns.substring(with: match.range(at: 2))
        let bodyNS = body as NSString
        var hexes: [String] = []
        for hexMatch in hexRegex.matches(in: body, range: NSRange(location: 0, length: bodyNS.length)) {
            let hex = bodyNS.substring(with: hexMatch.range(at: 1)).uppercased()
            if !hexes.contains(hex) { hexes.append(hex) }
        }
        guard !hexes.isEmpty else { continue }
        themes.append(ParsedTheme(name: name, colors: hexes))
    }
    return themes
}

/// 从 DesignTokens 的 Theme.CodePaper 解析亮/暗两套纸面数值。
func parsePapers() throws -> (light: ContrastColor, dark: ContrastColor) {
    let source = try read("QuickShow/Utilities/DesignTokens.swift")
    let regex = try NSRegularExpression(
        pattern: #"static let (light|dark) = ContrastColor\(([\d.]+),\s*([\d.]+),\s*([\d.]+)\)"#
    )
    let ns = source as NSString
    var light: ContrastColor?
    var dark: ContrastColor?
    for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
        let name = ns.substring(with: match.range(at: 1))
        let values = (2...4).map { Double(ns.substring(with: match.range(at: $0))) ?? 0 }
        let color = ContrastColor(values[0], values[1], values[2])
        if name == "light" { light = color } else { dark = color }
    }
    guard let light, let dark else {
        throw NSError(domain: "audit", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "未能从 DesignTokens.swift 解析 Theme.CodePaper 纸面数值",
        ])
    }
    return (light, dark)
}

// MARK: 审计
// MARK: 审计入口

// @main：禁止顶层表达式（与 ColorContrast.swift 一起编译时，另一个文件不是 main.swift）
@main
struct CodeContrastAudit {
    static func main() throws {

        let minimum = 4.5   // Theme.Accessibility.minTextContrast（正文级，与令牌同值）
        let themes = try parseThemes()
        let papers = try parsePapers()

        print("代码高亮对比度审计（WCAG AA 正文下限 \(minimum):1）")
        print("纸面真源：亮色 \(papers.light.hex) / 暗色 \(papers.dark.hex)")
        print("")

        var failures = 0
        var audits = 0

        for theme in themes {
            // 主题名 → 纸面：浅色主题（atomOneLight）配亮纸面，其余配暗纸面
            let isLightTheme = theme.name.lowercased().contains("light")
            // 与 App 内一致：以「纸面叠在最亮背景」的合成值为参照（纸面带 12% 底透）
    let alpha = 0.88
    let nominal = isLightTheme ? papers.light : papers.dark
    let paper = nominal.blended(over: .white, alpha: alpha)
            print("主题 \(theme.name)（\(isLightTheme ? "亮色" : "暗色") 参照底 \(paper.hex)）")

            for hex in theme.colors {
                guard let source = ContrastColor(hex: hex) else { continue }
                let before = source.contrastRatio(to: paper)
                let after = source.adjusted(minimumContrast: minimum, against: paper)
                let afterRatio = after.contrastRatio(to: paper)
                audits += 1
                let ok = afterRatio >= minimum - 0.01
                if !ok { failures += 1 }
                let flag = ok ? "✓" : "✗"
                let action = before >= minimum
                    ? "原样保留"
                    : "校正 \(hex) → \(after.hex)"
                print(String(
                    format: "  %@ %@  校正前 %5.2f:1  校正后 %5.2f:1  %@",
                    flag, hex, before, afterRatio, action
                ))
            }
            print("")
        }

        print("—— 合计审计 \(audits) 个色值，未达标 \(failures) 个 ——")
        if failures > 0 { exit(1) }
    }
}
