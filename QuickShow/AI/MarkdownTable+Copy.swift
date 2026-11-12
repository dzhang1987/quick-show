import Foundation

// MARK: - 表格复制 / 下载序列化（Markdown / TSV / CSV）

/// 行内 token 的复制序列化双路径：
/// - `copyPlainText`：剥离全部行内格式，仅保留可读文本（TSV / CSV 单元格用）；
/// - `copyMarkdown`：尽量重建常见行内语法（Markdown 源码表用）。
extension InlineToken {
    /// 纯文本路径：格式剥离、链接取文字、图片取 alt、公式取 LaTeX 源；
    /// 硬换行折为空格（保证 TSV / CSV 单行结构），脚注引用不产出噪音。
    var copyPlainText: String {
        switch self {
        case let .text(value):
            return value
        case let .code(value), let .kbd(value):
            return value
        case let .bold(inner), let .italic(inner),
             let .strikethrough(inner), let .underline(inner), let .highlight(inner),
             let .superscript(inner), let .`subscript`(inner):
            return inner.copyPlainText
        case let .link(text, _, _):
            return text.copyPlainText
        case let .math(latex):
            return latex
        case let .ruby(base, _, _):
            return base.copyPlainText
        case let .image(alt, _, _):
            return alt
        case .lineBreak:
            return " "
        case .footnoteRef:
            return ""
        }
    }

    /// Markdown 路径：重建粗体 / 斜体 / 代码 / 链接 / 公式等常见语法；
    /// 下划线 / 高亮 / 上下标 / 注音 / 按键以 HTML 行内标签保留（GFM 兼容）。
    var copyMarkdown: String {
        switch self {
        case let .text(value):
            return value
        case let .code(value):
            // 内容含反引号时用双反引号包裹（CommonMark 代码跨度规则）
            return value.contains("`") ? "`` \(value) ``" : "`\(value)`"
        case let .kbd(value):
            return "<kbd>\(value)</kbd>"
        case let .bold(inner):
            return "**\(inner.copyMarkdown)**"
        case let .italic(inner):
            return "*\(inner.copyMarkdown)*"
        case let .strikethrough(inner):
            return "~~\(inner.copyMarkdown)~~"
        case let .underline(inner):
            return "<u>\(inner.copyMarkdown)</u>"
        case let .highlight(inner):
            return "<mark>\(inner.copyMarkdown)</mark>"
        case let .`subscript`(inner):
            return "<sub>\(inner.copyMarkdown)</sub>"
        case let .superscript(inner):
            return "<sup>\(inner.copyMarkdown)</sup>"
        case let .link(text, url, title):
            if let title, !title.isEmpty {
                return "[\(text.copyMarkdown)](\(url) \"\(title)\")"
            }
            return "[\(text.copyMarkdown)](\(url))"
        case let .math(latex):
            return "$\(latex)$"
        case let .ruby(base, ruby, _):
            return "<ruby>\(base.copyMarkdown)<rt>\(ruby)</rt></ruby>"
        case let .image(alt, url, title):
            if let title, !title.isEmpty {
                return "![\(alt)](\(url) \"\(title)\")"
            }
            return "![\(alt)](\(url))"
        case .lineBreak:
            return "<br>"
        case let .footnoteRef(id):
            return "[^\(id)]"
        }
    }
}

extension Array where Element == InlineToken {
    var copyPlainText: String { map(\.copyPlainText).joined() }
    var copyMarkdown: String { map(\.copyMarkdown).joined() }
}

// MARK: - 表格级序列化

extension MarkdownTable {
    /// GFM Markdown 源码表：表头行 + 对齐分隔行 + 数据行；
    /// 单元格内竖线转义、硬换行 `<br>`（GFM 表格单元格约定）。
    var copyMarkdown: String {
        guard !headers.isEmpty else { return "" }
        var lines: [String] = []
        lines.append(markdownRow(headers))
        let separators = headers.indices.map { column -> String in
            switch alignment(at: column) {
            case .left: return ":---"
            case .center: return ":---:"
            case .right: return "---:"
            case nil: return "---"
            }
        }
        lines.append("| " + separators.joined(separator: " | ") + " |")
        for row in rows {
            lines.append(markdownRow(row))
        }
        return lines.joined(separator: "\n")
    }

    /// TSV（制表符分隔）：粘贴到 Excel / Numbers / 飞书 / WPS 直接落成真正的表格；
    /// 单元格内制表符 / 换行统一折为空格，保证行列结构。
    var copyTSV: String {
        guard !headers.isEmpty else { return "" }
        return ([headers] + rows)
            .map { row in row.map { $0.copyPlainText.tsvCell }.joined(separator: "\t") }
            .joined(separator: "\n")
    }

    /// CSV（RFC 4180）：含逗号 / 引号 / 换行的字段双引号包裹、内部引号 doubling；
    /// 行尾 CRLF，Excel / Numbers / 各类表格工具通用。
    var copyCSV: String {
        guard !headers.isEmpty else { return "" }
        return ([headers] + rows)
            .map { row in row.map { $0.copyPlainText.csvCell }.joined(separator: ",") }
            .joined(separator: "\r\n")
    }

    private func alignment(at column: Int) -> MarkdownTableAlignment? {
        guard column >= 0, column < alignments.count else { return nil }
        return alignments[column]
    }

    private func markdownRow(_ row: [[InlineToken]]) -> String {
        "| " + row.map { $0.copyMarkdown.markdownCell }.joined(separator: " | ") + " |"
    }
}

// MARK: - 单元格转义

private extension String {
    /// TSV 单元格：制表符 / 换行 → 空格，防破行列结构。
    var tsvCell: String {
        replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// CSV 单元格（RFC 4180）：特殊字符字段加引号、引号 doubling。
    var csvCell: String {
        guard contains(",") || contains("\"") || contains("\n") || contains("\r") else {
            return self
        }
        return "\"" + replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Markdown 表格单元格：竖线转义、硬换行 <br>。
    var markdownCell: String {
        replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "")
    }
}
