import SwiftUI

// MARK: - 助手消息 Markdown 完整渲染

/// 助手落定消息：消费 MarkdownParser 的完整块级 AST。
/// 视觉层次原则（2026-10 排版专项，对标 DeepSeek / Claude Code 对话排版）：
/// - 无气泡：正文直接铺在玻璃材质上左对齐、无内边距，层级全靠字号/字重/留白表达
/// - 三级排版：h1 18 bold（附减弱底部分隔线）/ h2 16 semibold / h3 14 semibold，均 contentPrimary；
///   正文与列表降两档（primary 0.80），与加粗档（contentPrimary semibold）肉眼可分
/// - 间距节奏：块间距不由 VStack 统一值承担，改为每块自带顶距——
///   标题前 26/20/16（与上文拉开成组），标题后 8（与紧随内容成组），内容块之间 16，首块无顶距
/// - 行高：正文/列表/代码 lineSpacing 6（13pt ≈ 1.7 倍）；列表项间 8、嵌套子项间 6
/// - 引号归一：成对 ASCII 直引号显示为「」（仅 text token，代码/链接不受影响）
struct AssistantMarkdownView: View, Equatable {
    let content: String
    /// 是否读写解析缓存。落定态（done/aborted）恒为 true；流式中间态（内容每 250ms 增长）
    /// 传 false 完全旁路缓存——否则每个中间态都成为新 key 写入并 FIFO 逐出落定消息的有用缓存。
    var useCache: Bool = true

    // MARK: - 解析缓存（落定态重渲染加速）

    // MarkdownParser.parse 是无状态纯函数（同输入同输出）。切会话会使 LazyVStack 身份
    // 全量重建，历史消息的 Markdown（含 LaTeX）被重新解析——超长会话即卡死。以 content
    // 为 key 缓存 AST，命中直接复用；落定态 content 稳定，key 高频命中。
    //
    // 线程安全说明：SwiftUI 视图 body 恒在主线程渲染（本视图不跨隔离域传递），静态缓存的
    // 读写全部发生在主线程串行渲染路径上，无需加锁。若未来改为 off-main 渲染或开启严格
    // 并发检查，可整体替换为 NSCache<NSString, NSArray>（其线程安全由 Foundation 保证）。
    private static var cache: [String: [MarkdownBlock]] = [:]
    /// FIFO 插入序：Markdown 落定后 key 稳定，命中即复用，无需真 LRU 的复杂度。
    private static var cacheOrder: [String] = []
    /// 条目数上限。
    private static let cacheEntryLimit = 64
    /// 内容总字符预算，防内存无界膨胀。
    private static let cacheCharBudget = 600_000
    /// 当前缓存内容的总字符数（预算淘汰用）。
    private static var cacheCharTotal = 0

    /// 取 content 的块级 AST。
    /// - useCache == false：完全旁路缓存直接解析（不读不写），供流式中间态使用。
    /// - useCache == true：命中读缓存；未命中解析后写入，并按 FIFO 做条数/字符预算淘汰。
    private static func parsedBlocks(for content: String, useCache: Bool) -> [MarkdownBlock] {
        guard useCache else { return MarkdownParser.parse(content) }
        if let cached = cache[content] { return cached }
        let blocks = MarkdownParser.parse(content)
        cache[content] = blocks
        cacheOrder.append(content)
        cacheCharTotal += content.count
        while cacheOrder.count > cacheEntryLimit || cacheCharTotal > cacheCharBudget {
            guard !cacheOrder.isEmpty else { break }
            let oldest = cacheOrder.removeFirst()
            if cache.removeValue(forKey: oldest) != nil {
                cacheCharTotal -= oldest.count
            }
        }
        return blocks
    }

    var body: some View {
        let blocks = Self.parsedBlocks(for: content, useCache: useCache)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block)
                    .padding(.top, index == 0 ? 0 : block.topSpacing(after: blocks[index - 1]))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension MarkdownBlock {
    /// 块顶距：间距节奏的唯一来源。
    /// 标题前大幅拉开（h1 26 / h2 20 / h3 16）形成成组锚点；
    /// 标题后收紧为 8（after 为标题时），让标题与紧随内容成组；
    /// 其余内容块（段落/列表/引用/表格/代码块）之间统一 16。
    func topSpacing(after previous: MarkdownBlock) -> CGFloat {
        if case .heading = previous { return Theme.Spacing.lg }      // 8：标题后收紧成组
        switch self {
        case let .heading(level, _):
            switch level {
            case 1: return Theme.Spacing.section + Theme.Spacing.lg  // 26：一级标题成组锚点
            case 2: return Theme.Spacing.divider                     // 20
            default: return Theme.Spacing.card                       // 16
            }
        default:
            return Theme.Spacing.card                                // 16：段落/列表/引用/表格/代码块
        }
    }
}

// MARK: - 单个块

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    /// 块级公式降级预检的取色外观：跟随环境 colorScheme（NSApp.effectiveAppearance
    /// 不被 SwiftUI 追踪，明暗翻转后分支判定会与位图脱节）。
    @Environment(\.colorScheme) private var colorScheme

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

    /// 标题：h1 18 bold + 减弱底部分隔线；h2 16 semibold；h3 14 semibold；均 contentPrimary。
    @ViewBuilder
    private func headingView(level: Int, inlines: [InlineToken]) -> some View {
        switch level {
        case 1:
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                MarkdownInlineText(
                    inlines: inlines,
                    bodyColor: Theme.Colors.contentPrimary,
                    baseSize: 18,
                    weight: .bold,
                    explicitColor: Theme.Colors.contentPrimary
                )
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                Rectangle()
                    .fill(Theme.Colors.cardStroke)
                    .frame(height: Theme.Layout.dividerHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case 2:
            MarkdownInlineText(
                inlines: inlines,
                bodyColor: Theme.Colors.contentPrimary,
                baseSize: 16,
                weight: .semibold,
                explicitColor: Theme.Colors.contentPrimary
            )
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            MarkdownInlineText(
                inlines: inlines,
                bodyColor: Theme.Colors.contentPrimary,
                baseSize: 14,
                weight: .semibold,
                explicitColor: Theme.Colors.contentPrimary
            )
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 块级公式：居中展示（display 模式 14pt），上下 4pt 呼吸；
    /// 光栅化失败时降级为等宽原始 LaTeX 文本。
    @ViewBuilder
    private func mathBlockView(_ latex: String) -> some View {
        let nsColor = MathRasterizer.resolvedColor(Theme.Colors.contentPrimary, appearance: MathRasterizer.appearance(for: colorScheme))
        if MathRasterizer.rasterize(latex: latex, pointSize: 14, color: nsColor, isDisplay: true) != nil {
            MathBlockView(latex: latex, fontSize: 14, color: Theme.Colors.contentPrimary)
                .padding(.vertical, Theme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            Text(latex)
                .font(Theme.Typography.mono(13))
                .foregroundColor(Theme.Colors.contentPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 列表

private struct MarkdownListView: View {
    let items: [MarkdownListItem]

    var body: some View {
        // 列表项间 8：大间距节奏，提升扫读性（对标 CC 列表呼吸感）
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
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
                MarkdownInlineText(inlines: item.inlines)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 一层嵌套子项：缩进对齐到父项文本起点；子项间 6（略小于顶层 8）
            if !item.children.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                            Text(child.ordered ? "\(child.number ?? 1)." : "◦")
                                .font(child.ordered
                                      ? Theme.Typography.mono(12)
                                      : Theme.Typography.text(13))
                                .foregroundColor(Theme.Colors.contentTertiary)
                                .frame(minWidth: 14, alignment: .trailing)
                            MarkdownInlineText(inlines: child.inlines)
                                .lineSpacing(6)
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
                    MarkdownInlineText(
                        inlines: header,
                        bodyColor: Theme.Colors.contentPrimary,
                        baseSize: 12.5,
                        weight: .semibold,
                        explicitColor: Theme.Colors.contentPrimary
                    )
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
                        MarkdownInlineText(
                            inlines: cell,
                            bodyColor: Theme.Colors.contentPrimary,
                            baseSize: 12.5,
                            explicitColor: Theme.Colors.contentPrimary
                        )
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
                .lineSpacing(6)
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

    /// bodyColor：纯文本/行内代码的颜色——正文与列表降两档（primary 0.80），
    /// 与加粗档（contentPrimary 纯白/纯黑）肉眼可分区分开；标题、表格等调用处显式传 contentPrimary。
    /// 加粗递归时把基色提为 contentPrimary（而非事后整段覆盖），嵌套链接的 accent 得以保留。
    static func render(_ tokens: [InlineToken], bodyColor: Color = Color.primary.opacity(0.80)) -> AttributedString {
        var result = AttributedString()
        for token in tokens {
            switch token {
            case let .text(value):
                var piece = AttributedString(normalizeQuotes(value))
                piece.foregroundColor = bodyColor
                result.append(piece)
            case let .code(value):
                var piece = AttributedString(value)
                piece.font = Theme.Typography.mono(12.5)
                piece.foregroundColor = bodyColor
                piece.backgroundColor = Theme.Colors.surfaceTrack
                result.append(piece)
            case let .bold(inner):
                var piece = render(inner, bodyColor: Theme.Colors.contentPrimary)
                piece.font = Theme.Typography.text(baseSize, .semibold)
                result.append(piece)
            case let .italic(inner):
                var piece = render(inner, bodyColor: bodyColor)
                piece.font = Theme.Typography.text(baseSize).italic()
                result.append(piece)
            case let .link(label, url):
                var piece = render(label, bodyColor: bodyColor)
                piece.foregroundColor = Theme.Colors.accent
                piece.underlineStyle = .single
                if let linkURL = URL(string: url) {
                    piece.link = linkURL
                }
                result.append(piece)
            case let .math(value):
                // SwiftUI AttributedString 无法内嵌图片；含公式的路径统一改走 MarkdownInlineNS。
                // 此处仅作兜底：以等宽文本显示原始 LaTeX（正常渲染不会触达）。
                var piece = AttributedString(value)
                piece.font = Theme.Typography.mono(12)
                piece.foregroundColor = bodyColor
                result.append(piece)
            }
        }
        // 统一基础字体（行内覆盖（代码/加粗等）已在上面设定，这里只设默认值）
        result.font = Theme.Typography.text(baseSize)
        return result
    }

    /// 成对 ASCII 直引号归一为中文引号「」（未配对的单个 " 保留原样）。
    /// 仅供显示层调用（text token 与流式纯文本），绝不触碰行内代码/代码块/链接 URL；
    /// 不改原始文本，复制/重发内容不受影响。
    static func normalizeQuotes(_ text: String) -> String {
        guard text.contains("\"") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var isOpen = false
        var remaining = text[...]
        while let first = remaining.first {
            let after = remaining.dropFirst()
            if first == "\"" {
                if !isOpen, after.contains("\"") {
                    result.append("「")   // 存在后续配对：开引号
                    isOpen = true
                } else if isOpen {
                    result.append("」")   // 处于开引状态：合引号
                    isOpen = false
                } else {
                    result.append(first)  // 未配对的单个 "，原样保留
                }
            } else {
                result.append(first)
            }
            remaining = after
        }
        return result
    }
}
