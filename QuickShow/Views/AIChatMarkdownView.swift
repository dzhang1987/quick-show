import SwiftUI

// MARK: - 助手消息 Markdown 完整渲染

/// 助手落定消息：消费 MarkdownParser 的完整块级 AST。
/// 视觉层次原则（2026-10 专项）：
/// - 三级排版：标题加大加粗拉开字号字重梯度（h1 附底部分隔线），正文 contentPrimary 保底可读，
///   引用/辅助内容降一档灰度
/// - 间距节奏：块间距不由 VStack 统一值承担，改为每块自带顶距——
///   标题前 18/14/10（与上文拉开成组），表格/代码块前 12，段落/列表/引用前 10，首块无顶距
/// - 容器：气泡底 = chatAssistantBubble（比主区亮一档）+ 0.5pt 描边，圆角 12
struct AssistantMarkdownView: View {
    let content: String

    var body: some View {
        let blocks = MarkdownParser.parse(content)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block)
                    .padding(.top, index == 0 ? 0 : block.topSpacing)
            }
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .fill(Theme.Colors.chatAssistantBubble)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .stroke(Theme.Colors.cardStroke, lineWidth: 0.5)
        )
    }
}

private extension MarkdownBlock {
    /// 块顶距：间距节奏的唯一来源（标题前拉开成组，内容块前紧凑跟随）。
    var topSpacing: CGFloat {
        switch self {
        case let .heading(level, _):
            switch level {
            case 1: return Theme.Spacing.section      // 18：一级标题成组锚点
            case 2: return Theme.Spacing.xxxl         // 14
            default: return Theme.Spacing.xl          // 10
            }
        case .table, .codeBlock:
            return Theme.Spacing.xxl                  // 12：容器块前后呼吸
        default:
            return Theme.Spacing.xl                   // 10：段落/列表/引用
        }
    }
}

// MARK: - 单个块

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, inlines):
            headingView(level: level, inlines: inlines)

        case let .paragraph(inlines):
            Text(MarkdownInline.render(inlines))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .orderedList(items):
            MarkdownListView(items: items)

        case let .unorderedList(items):
            MarkdownListView(items: items)

        case let .blockquote(inner):
            MarkdownBlockquoteView(blocks: inner)

        case let .table(table):
            MarkdownTableView(table: table)

        case let .codeBlock(language, code):
            CodeBlockView(language: language, code: code)
        }
    }

    /// 标题：h1 17 bold + 底部分隔线；h2 15 semibold；h3 13.5 semibold 降一档灰度。
    @ViewBuilder
    private func headingView(level: Int, inlines: [InlineToken]) -> some View {
        switch level {
        case 1:
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(MarkdownInline.render(inlines))
                    .font(Theme.Typography.text(17, .bold))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle()
                    .fill(Theme.Colors.chatStrokeStrong)
                    .frame(height: Theme.Layout.dividerHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case 2:
            Text(MarkdownInline.render(inlines))
                .font(Theme.Typography.text(15, .semibold))
                .foregroundColor(Theme.Colors.contentPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            Text(MarkdownInline.render(inlines))
                .font(Theme.Typography.text(13.5, .semibold))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 列表

private struct MarkdownListView: View {
    let items: [MarkdownListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                MarkdownListItemRow(item: item)
            }
        }
    }
}

private struct MarkdownListItemRow: View {
    let item: MarkdownListItem

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                // 标记列：无序圆点 / 有序序号，等宽右对齐保持多行对齐
                Text(item.ordered ? "\(item.number ?? 1)." : "•")
                    .font(item.ordered
                          ? Theme.Typography.mono(12)
                          : Theme.Typography.text(13, .medium))
                    .foregroundColor(Theme.Colors.contentTertiary)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(MarkdownInline.render(item.inlines))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 一层嵌套子项：缩进对齐到父项文本起点
            if !item.children.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                            Text(child.ordered ? "\(child.number ?? 1)." : "◦")
                                .font(child.ordered
                                      ? Theme.Typography.mono(12)
                                      : Theme.Typography.text(13))
                                .foregroundColor(Theme.Colors.contentTertiary)
                                .frame(minWidth: 14, alignment: .trailing)
                            Text(MarkdownInline.render(child.inlines))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.leading, 22)
            }
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
            // 表头：加粗 + 整行底色
            HStack(spacing: Theme.Spacing.card) {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
                    Text(MarkdownInline.render(header))
                        .font(Theme.Typography.text(12.5, .semibold))
                        .foregroundColor(Theme.Colors.contentPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownInline.render(cell))
                            .font(Theme.Typography.text(12.5))
                            .foregroundColor(Theme.Colors.contentPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
}

// MARK: - 代码块

/// 围栏代码块：语言标签 + 等宽内容；hover 右上角渐显复制钮（成功变对勾轻反馈）。
struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.lg) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(Theme.Typography.mono(10, .semibold))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
                Spacer(minLength: 0)
                if hovered || copied {
                    Button(action: copyCode) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
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
                    .transition(.opacity)
                }
            }
            .frame(minHeight: 14)

            // 代码块内不转 Markdown，纯等宽显示（长行自然换行，避免嵌套横向滚动）
            Text(code)
                .font(Theme.Typography.mono(12.5))
                .foregroundColor(Theme.Colors.contentPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.xl)
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

// MARK: - 行内渲染

/// 行内 token → AttributedString（粗体 / 斜体 / 行内代码 / 可点击链接 / 纯文本）。
/// 供段落、标题、列表项、表格单元格、引用块共用。
enum MarkdownInline {
    /// 正文基准字号。
    static let baseSize: CGFloat = 13

    static func render(_ tokens: [InlineToken]) -> AttributedString {
        var result = AttributedString()
        for token in tokens {
            switch token {
            case let .text(value):
                result.append(AttributedString(value))
            case let .code(value):
                var piece = AttributedString(value)
                piece.font = Theme.Typography.mono(12.5)
                piece.backgroundColor = Theme.Colors.surfaceTrack
                result.append(piece)
            case let .bold(inner):
                var piece = render(inner)
                piece.font = Theme.Typography.text(baseSize, .bold)
                result.append(piece)
            case let .italic(inner):
                var piece = render(inner)
                piece.font = Theme.Typography.text(baseSize).italic()
                result.append(piece)
            case let .link(label, url):
                var piece = render(label)
                piece.foregroundColor = Theme.Colors.accent
                piece.underlineStyle = .single
                if let linkURL = URL(string: url) {
                    piece.link = linkURL
                }
                result.append(piece)
            }
        }
        // 统一基础字体与正文色（行内覆盖（代码/加粗等）已在上面设定，这里只设默认值）
        result.font = Theme.Typography.text(baseSize)
        result.foregroundColor = Theme.Colors.contentPrimary
        return result
    }
}
