import Combine
import SwiftUI

// 由 AIChatMarkdownView.swift 拆出：Markdown 块级渲染器（块顶距扩展 / 单块 / 列表 / 引用 / 表格 / 代码块 / 脚注区）。

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

// MARK: - 表格

/// 表格：表头行底色 + 表头下实线 + 数据行斑马纹 + 提亮描边卡片。
/// 用 VStack 行结构（而非 Grid）以便整行铺底色；列等宽，列间距 16。
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 表头：加粗 + 整行底色；每列按 alignments 设置对齐
            HStack(spacing: Theme.Spacing.card) {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { column, header in
                    MarkdownInlineText(
                        inlines: header,
                        bodyColor: Theme.Colors.contentPrimary,
                        baseSize: 12.5,
                        weight: .semibold,
                        explicitColor: Theme.Colors.contentPrimary
                    )
                    .multilineTextAlignment(textAlignment(at: column))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: frameAlignment(at: column))
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .background(Theme.Colors.chatTableHeader)

            // 表头下实线（提亮档，确保在斑马纹前清晰可辨）
            Rectangle()
                .fill(Theme.Colors.chatStrokeStrong)
                .frame(height: Theme.Layout.dividerHeight)

            // 数据行：偶数行斑马纹
            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: Theme.Spacing.card) {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        MarkdownInlineText(
                            inlines: cell,
                            bodyColor: Theme.Colors.contentPrimary,
                            baseSize: 12.5,
                            explicitColor: Theme.Colors.contentPrimary
                        )
                        .multilineTextAlignment(textAlignment(at: column))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: frameAlignment(at: column))
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.md)
                .background(rowIndex % 2 == 1 ? Theme.Colors.chatTableRowAlternate : Color.clear)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
    }

    /// 列对齐 → SwiftUI Frame Alignment（越界回退 leading）。
    private func frameAlignment(at column: Int) -> Alignment {
        switch alignment(at: column) {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }

    /// 列对齐 → 多行文本对齐。
    private func textAlignment(at column: Int) -> TextAlignment {
        switch alignment(at: column) {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }

    private func alignment(at column: Int) -> MarkdownTableAlignment? {
        guard column >= 0, column < table.alignments.count else { return nil }
        return table.alignments[column]
    }
}

// MARK: - 代码块

/// 围栏代码块：语言标签 + 等宽内容；hover 右上角渐显复制钮（成功变对勾轻反馈）。
/// 语法高亮：首帧立即纯色等宽渲染，同时后台计算高亮 AttributedString，完成后替换
/// （失败/不支持语言保持纯色）。高亮计算全程异步，绝不阻塞流式渲染。
struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.chatCodeBlockHeaderGap) {
            HStack(spacing: Theme.Spacing.lg) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(Theme.Typography.mono(10, .semibold))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
                Spacer(minLength: 0)
                // 布局稳定化：按钮常驻布局（header 行高度恒定），hover 仅切换透明度，
                // 不触发布局变化。
                // 显隐由 hovered 单独驱动；copied 仅是复制成功的瞬时内容反馈
                // （鼠标离开时按钮随 hovered 隐去，不会残留悬空的第二按钮）。
                Button(action: copyCode) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: copied ? "checkmark" : "square.on.square")
                            .font(Theme.Typography.text(9.5, .medium))
                        Text(copied ? "已复制" : "复制")
                            .font(Theme.Typography.text(9.5, .medium))
                    }
                    .foregroundColor(copied ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                            .fill(Theme.Colors.surfaceButton)
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
                .accessibilityHidden(!hovered)
            }
            .frame(minHeight: 14)

            // 高亮状态与渲染内聚于子视图（见 CodeBlockText）：hover 变化引起的
            // 父 body 重算会被 SwiftUI 子视图值 diff 短路，大段高亮文本永不重建。
            CodeBlockText(code: code, language: language)
        }
        // 2026-10 重设计：上下对称、左右一致（12/14，旧值 10/12 上下失衡、重心悬空）
        .padding(.horizontal, Theme.Layout.chatCodeBlockPaddingH)
        .padding(.vertical, Theme.Layout.chatCodeBlockPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(Theme.Colors.surfaceTrack)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
    }

    private func copyCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        copied = true
        // 轻反馈：对勾短暂停留后复位
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

/// 代码内容子视图：高亮状态（`highlighted`）与高亮渲染、高亮 task 全部内聚于此。
///
/// 状态半径原则：hover（复制按钮显隐）是 CodeBlockView 的状态，其变化触发父 body
/// 重算；本视图作为参数化子视图，参数（code/language）不变时 SwiftUI 值 diff 会
/// 短路父重算——本视图 body 不重跑，`Text(highlighted)`（大段 AttributedString，
/// 构造需解析 runs，成本高一个数量级）永不重建。滚动中 hover 进出风暴的重算成本
/// 由此被压缩到 header 一行（语言标签 + 小按钮）。
private struct CodeBlockText: View {
    let code: String
    let language: String?

    @Environment(\.colorScheme) private var colorScheme
    /// 后台高亮结果；nil = 尚未完成 / 不可用 / 降级纯色。
    @State private var highlighted: AttributedString?

    var body: some View {
        // 高亮版优先、否则降级为纯色等宽文本（现状行为）。
        // 代码块内不转 Markdown，纯等宽显示。
        // 长行不折行：横向滚动承载超长行——折行会破坏缩进结构、复制粘贴混入换行符。
        // 嵌套滚动安全：底层 NSScrollView 不消费垂直滚轮 delta（沿 responder chain 上传
        // 外层垂直滚动，滚轮鼠标体验与现状一致），仅消费水平 delta（shift+滚轮/双指横滑）；
        // 内容短于视口时贴 scroll origin（leading），与旧 frame(alignment: .leading) 等价。
        // fixedSize(horizontal: true)：水平按固有宽度布局（ScrollView 提议无限宽，双保险防
        // 折行）；vertical: false 服从容器高度（= 内容固有行高，无循环依赖）。
        ScrollView(.horizontal, showsIndicators: true) {
            Group {
                if let highlighted {
                    Text(highlighted)
                } else {
                    Text(code)
                        .font(Theme.Typography.mono(12.5))
                        .foregroundColor(Theme.Colors.contentPrimary)
                }
            }
            .lineSpacing(6)
            .fixedSize(horizontal: true, vertical: false)
        }
        .task(id: HighlightTask(code: code, language: language, darkMode: colorScheme == .dark)) {
            // 首帧保持纯色等宽（highlighted == nil）；后台计算高亮后替换。
            highlighted = nil
            let code = self.code
            let language = self.language
            let result = await Task.detached(priority: .utility) {
                MarkdownHighlighter.highlightSwiftUI(code, language: language, darkMode: colorScheme == .dark)
            }.value
            guard !Task.isCancelled else { return }
            highlighted = result
        }
    }

    /// 高亮 task 键：内容 / 语言 / 外观任一变化即重高亮（外观切换换主题，
    /// 流式期间 code 增长重算）。
    private struct HighlightTask: Equatable {
        let code: String
        let language: String?
        let darkMode: Bool
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
