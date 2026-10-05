import Combine
import SwiftUI

// 由 AIChatMarkdownView.swift 拆出：Markdown 块级渲染器（块顶距扩展 / 单块 / 列表 / 引用 / 脚注区）。
// 表格渲染器见 MarkdownTableView.swift，代码块渲染器见 MarkdownCodeBlock.swift。

extension MarkdownBlock {
    /// 块顶距：间距节奏的唯一来源。
    /// 标题前大幅拉开（h1 26 / h2 20 / h3 16）形成成组锚点；
    /// 标题后收紧为 8（after 为标题时），让标题与紧随内容成组；
    /// 其余内容块（段落/列表/引用/表格/代码块）之间统一 16。
    func topSpacing(after previous: MarkdownBlock) -> CGFloat {
        if case .heading = previous { return Theme.Spacing.lg }      // 8：标题后收紧成组
        switch self {
        case let .heading(level, _):
            // 标题前间距随层级递减成组锚点：26 / 20 / 16 / 14 / 12 / 10
            switch level {
            case 1: return Theme.Spacing.section + Theme.Spacing.lg  // 26：一级标题成组锚点
            case 2: return Theme.Spacing.divider                     // 20
            case 3: return Theme.Spacing.card                        // 16
            case 4: return Theme.Spacing.xxxl                        // 14
            case 5: return Theme.Spacing.xxl                         // 12
            default: return Theme.Spacing.xl                         // 10：h6
            }
        default:
            return Theme.Spacing.card                                // 16：段落/列表/引用/表格/代码块
        }
    }
}

// MARK: - 单个块

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, inlines):
            headingView(level: level, inlines: inlines)

        case let .paragraph(inlines):
            MarkdownInlineText(inlines: inlines)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .mathBlock(latex):
            mathBlockView(latex)

        case .horizontalRule:
            // 水平分隔线：通栏细线，视觉语言对齐 h1 底部分隔线
            Rectangle()
                .fill(Theme.Colors.cardStroke)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Theme.Layout.dividerHeight)

        case let .orderedList(items):
            MarkdownListView(items: items, ordered: true)

        case let .unorderedList(items):
            MarkdownListView(items: items, ordered: false)

        case let .blockquote(inner):
            MarkdownBlockquoteView(blocks: inner)

        case let .table(table):
            MarkdownTableView(table: table)

        case let .codeBlock(language, code):
            CodeBlockView(language: language, code: code)

        case let .footnoteDefinition(_, _):
            // 顶层脚注定义已由 AssistantMarkdownView 抽出到文档末尾统一渲染；
            // 嵌套（如引用块内）定义在此跳过，不在原位置留下占位。
            EmptyView()
        }
    }

    /// 标题：h1 18 bold + 减弱底部分隔线；h2 16 / h3 14 / h4 13 / h5 12.5 / h6 12 semibold；均 contentPrimary。
    /// h4 与正文同号（13）：靠 semibold + contentPrimary 与正文（regular / primary 0.80）区分，对齐 GitHub 语义。
    @ViewBuilder
    private func headingView(level: Int, inlines: [InlineToken]) -> some View {
        switch level {
        case 1:
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                headingText(inlines: inlines, size: 18, weight: .bold)
                Rectangle()
                    .fill(Theme.Colors.cardStroke)
                    .frame(height: Theme.Layout.dividerHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case 2:
            headingText(inlines: inlines, size: 16, weight: .semibold)
        case 3:
            headingText(inlines: inlines, size: 14, weight: .semibold)
        case 4:
            headingText(inlines: inlines, size: 13, weight: .semibold)
        case 5:
            headingText(inlines: inlines, size: 12.5, weight: .semibold)
        default:
            headingText(inlines: inlines, size: 12, weight: .semibold)
        }
    }

    /// 统一标题排版：contentPrimary + 显式字号字重、行距 2、自适应高度。
    private func headingText(inlines: [InlineToken], size: CGFloat, weight: Font.Weight) -> some View {
        MarkdownInlineText(
            inlines: inlines,
            bodyColor: Theme.Colors.contentPrimary,
            baseSize: size,
            weight: weight,
            explicitColor: Theme.Colors.contentPrimary
        )
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 块级公式：异步视图（首帧占位 + 后台光栅化淡入），居中展示（display 模式 14pt）。
    private func mathBlockView(_ latex: String) -> some View {
        AsyncMathBlockView(latex: latex, fontSize: 14, color: Theme.Colors.contentPrimary)
    }
}

// MARK: - 列表

private struct MarkdownListView: View {
    let items: [MarkdownListItem]
    /// 本级有序性：由容器块（orderedList / unorderedList）决定。
    let ordered: Bool
    /// 嵌套深度：0 为顶层，用于切换无序圆点样式（• / ◦）。
    var depth: Int = 0

    var body: some View {
        // 列表项间 8：大间距节奏，提升扫读性（对标 CC 列表呼吸感）
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                MarkdownListItemRow(item: item, ordered: ordered, depth: depth)
            }
        }
    }
}

private struct MarkdownListItemRow: View {
    let item: MarkdownListItem
    let ordered: Bool
    var depth: Int = 0

    /// 嵌套子列表缩进：对齐到父项文本起点（标记列 14 + 间距 8）。
    private static let nestedIndent: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
            marker
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                    itemBlock(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 已勾选任务：内容整体弱化一档（AttributedString 显式前景色无法被外层
            // foregroundColor 覆盖，故用 opacity 做颜色弱化）。
            .opacity(item.taskState == true ? 0.55 : 1)
        }
    }

    /// 行首标记列：任务勾选框 / 有序序号 / 无序圆点（等宽右对齐保持多行对齐）。
    @ViewBuilder
    private var marker: some View {
        if let state = item.taskState {
            Image(systemName: state ? "checkmark.circle.fill" : "circle")
                .font(Theme.Typography.text(12.5, .medium))
                .foregroundColor(state ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                .frame(minWidth: 14, alignment: .trailing)
        } else if ordered {
            Text("\(item.number ?? 1).")
                .font(Theme.Typography.mono(12))
                .foregroundColor(Theme.Colors.contentTertiary)
                .frame(minWidth: 14, alignment: .trailing)
        } else {
            Text(depth == 0 ? "•" : "◦")
                .font(Theme.Typography.text(13, .medium))
                .foregroundColor(Theme.Colors.contentTertiary)
                .frame(minWidth: 14, alignment: .trailing)
        }
    }

    /// 列表项块内容：嵌套子列表缩进一级并携带深度递归；其余块沿用统一块渲染。
    @ViewBuilder
    private func itemBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .orderedList(items):
            MarkdownListView(items: items, ordered: true, depth: depth + 1)
                .padding(.leading, Self.nestedIndent)
        case let .unorderedList(items):
            MarkdownListView(items: items, ordered: false, depth: depth + 1)
                .padding(.leading, Self.nestedIndent)
        default:
            MarkdownBlockView(block: block)
        }
    }
}

// MARK: - 引用块

private struct MarkdownBlockquoteView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            // 左竖线：弱化强调色，克制不抢戏
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Theme.Colors.accent.opacity(0.55))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                    MarkdownBlockView(block: child)
                }
            }
            // 引用内容整体弱化一档，与竖线共同传达「引述」语义
            .foregroundColor(Theme.Colors.contentSecondaryStrong)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .fill(Theme.Colors.surfaceBadge)
        )
    }
}

// MARK: - 脚注区

/// 文档末尾脚注区：细分隔线 + 小字号（11）编号列表（序号 + 定义内容行内渲染）。
/// 由 `AssistantMarkdownView` 聚合顶层 footnoteDefinition 后统一渲染。
struct MarkdownFootnoteSection: View {
    let footnotes: [AssistantMarkdownView.FootnoteEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Rectangle()
                .fill(Theme.Colors.cardStroke)
                .frame(height: Theme.Layout.dividerHeight)
            ForEach(Array(footnotes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                    Text(note.id)
                        .font(Theme.Typography.text(11, .semibold))
                        .foregroundColor(Theme.Colors.accent)
                        .frame(minWidth: 16, alignment: .trailing)
                    MarkdownInlineText(
                        inlines: note.inlines,
                        bodyColor: Theme.Colors.contentTertiary,
                        baseSize: 11
                    )
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
