// MARK: - 数学公式 latex 收集（会话预热用）

/// 遍历 Markdown 块级 AST 收集公式 latex：块级/行内分列，便于按各自展示模式预热缓存。
enum MathLatexCollector {
    struct Collected {
        var display: [String]
        var inline: [String]
    }

    /// 收集所有块级 + 行内公式 latex（去重、保持首次出现顺序）。
    static func collectMathLatex(blocks: [MarkdownBlock]) -> [String] {
        let collected = collect(blocks: blocks)
        var seen = Set<String>()
        return (collected.display + collected.inline).filter { seen.insert($0).inserted }
    }

    /// 仅块级公式 latex（display 模式预热用）。
    static func collectBlockMathLatex(blocks: [MarkdownBlock]) -> [String] {
        collect(blocks: blocks).display
    }

    /// 仅行内公式 latex（text 模式预热用）。
    static func collectInlineMathLatex(blocks: [MarkdownBlock]) -> [String] {
        collect(blocks: blocks).inline
    }

    /// 单次遍历：块级入 display、行内入 inline；各自去重保序。
    static func collect(blocks: [MarkdownBlock]) -> Collected {
        var display: [String] = []
        var inline: [String] = []
        var seenDisplay = Set<String>()
        var seenInline = Set<String>()

        func addDisplay(_ latex: String) {
            if seenDisplay.insert(latex).inserted { display.append(latex) }
        }
        func addInline(_ latex: String) {
            if seenInline.insert(latex).inserted { inline.append(latex) }
        }
        func walkInlineTokens(_ tokens: [InlineToken]) {
            for token in tokens {
                switch token {
                case let .math(latex): addInline(latex)
                case let .bold(inner), let .italic(inner),
                     let .strikethrough(inner), let .underline(inner),
                     let .highlight(inner), let .subscript(inner),
                     let .superscript(inner):
                    walkInlineTokens(inner)
                case let .link(text, _, _): walkInlineTokens(text)
                case .text, .code, .image, .lineBreak, .footnoteRef: break
                }
            }
        }
        /// 列表项内容已改为块数组，嵌套子列表以块形式出现，递归交给 walkBlocks。
        func walkItem(_ item: MarkdownListItem) {
            walkBlocks(item.blocks)
        }
        func walkBlocks(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case let .heading(_, inlines), let .paragraph(inlines):
                    walkInlineTokens(inlines)
                case let .mathBlock(latex):
                    addDisplay(latex)
                case let .orderedList(items), let .unorderedList(items):
                    items.forEach(walkItem)
                case let .blockquote(inner):
                    walkBlocks(inner)
                case let .table(table):
                    table.headers.forEach(walkInlineTokens)
                    for row in table.rows { row.forEach(walkInlineTokens) }
                case let .footnoteDefinition(_, inlines):
                    walkInlineTokens(inlines)
                case .codeBlock, .horizontalRule:
                    break
                }
            }
        }
        walkBlocks(blocks)
        return Collected(display: display, inline: inline)
    }
}
