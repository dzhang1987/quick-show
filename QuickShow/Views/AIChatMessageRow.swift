// 从 AIChatView.swift 机械拆分：单条消息行及其行内子视图（操作钮 / 流式 / 思考 / 压缩边界 / 失败 / 中止）。

import AppKit
import Combine
import SwiftUI

struct ChatMessageRow: View, Equatable {
    let message: ChatMessage
    /// 是否已被压缩摘要化（纯显示态：驱动整行降档透明度；行内不直接消费，
    /// 参与 Equatable 判定使压缩落盘瞬间相关行重绘弱化）。
    let isSummarized: Bool
    /// 是否为最后一条可重新生成的助手消息（父视图计算，含流式中禁用语义）。
    let canRegenerate: Bool
    /// 是否为会话内最后一条 user 消息且可撤回/编辑（父视图计算，含生成中禁用语义）。
    let canEditLastRound: Bool
    /// 就地编辑态（由外部统一状态驱动：ESC 优先退出就地编辑）。
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCancelEdit: () -> Void
    let onRetry: () -> Void
    let onRegenerate: () -> Void
    /// 撤回最后一轮（数据层删除该轮并把文本+图片回填输入框）。
    let onWithdraw: () -> Void
    /// 编辑重发（就地编辑确认后回调新文本与图片附件）。
    let onEditResend: (String, [ChatImageAttachment]) -> Void
    let onTapImage: (ChatImageAttachment) -> Void

    /// 仅按内容与可用操作标记判定相等：闭包语义跨渲染一致，忽略其对 diff 的干扰，
    /// 使 .equatable() 能在流式期间跳过未变更行。
    static func == (lhs: ChatMessageRow, rhs: ChatMessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.isSummarized == rhs.isSummarized
            && lhs.canRegenerate == rhs.canRegenerate
            && lhs.canEditLastRound == rhs.canEditLastRound
            && lhs.isEditing == rhs.isEditing
    }

    @State private var rowHovered = false
    @State private var copied = false

    var body: some View {
        // 消息内容 + 下方紧凑操作行（紧贴正文底部 3pt；用户消息整体右对齐）
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .top, spacing: 0) {
                if message.role == .user { Spacer(minLength: Theme.Spacing.panel) }
                content
                // 2026-10 重设计：助手侧尾部 Spacer 已移除——正文/代码块右缘
                // 与用户气泡、输入坞统一到同一条右基准线（阅读列右缘，±0）
            }
            if showsActionRow {
                ChatMessageActionRow(
                    message: message,
                    canRegenerate: canRegenerate,
                    canEditLastRound: canEditLastRound,
                    copied: copied,
                    rowHovered: rowHovered,
                    onCopy: copyContent,
                    onRegenerate: onRegenerate,
                    onBeginEdit: onBeginEdit,
                    onWithdraw: onWithdraw
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { rowHovered = hovering }
        }
        .contextMenu { rowContextMenu }
    }

    /// 行级右键菜单：复制整条消息（图片消息复制其文本，若有）；
    /// 会话内最后一条 user 消息追加「编辑并重发 / 撤回该轮」。
    @ViewBuilder
    private var rowContextMenu: some View {
        if !message.content.isEmpty {
            Button { copyContent() } label: {
                Label("复制消息", systemImage: "square.on.square")
            }
        }
        if message.role == .user, canEditLastRound {
            if !message.content.isEmpty { Divider() }
            Button { onBeginEdit() } label: {
                Label("编辑并重发", systemImage: "pencil")
            }
            Button { onWithdraw() } label: {
                Label("撤回该轮", systemImage: "arrow.uturn.backward")
            }
        }
    }

    /// 操作行渲染条件：
    /// - 助手：落定终态（done/aborted；失败态有独立重试卡片，流式期间不提供半截内容的复制入口）
    /// - 用户：有文本可复制，或是可撤回/编辑的最后一轮
    /// 就地编辑态一律隐藏（编辑操作由编辑气泡内按钮承担）。
    private var showsActionRow: Bool {
        if isEditing { return false }
        switch message.role {
        case .user:
            return !message.content.isEmpty || canEditLastRound
        case .assistant:
            switch message.state {
            case .done, .aborted:
                return true
            case .sending, .streaming, .failed:
                return false
            }
        case .system:
            return false
        }
    }

    private func copyContent() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)
        copied = true
        // 轻反馈：对勾短暂停留后复位
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .user:
            // 就地编辑态：气泡原地变为编辑器（仅最后一轮 user 消息可进入）
            if isEditing {
                MessageEditBubble(
                    message: message,
                    onCommit: { text, images in
                        onEditResend(text, images)
                    },
                    onCancel: onCancelEdit
                )
            } else {
                userBubble
            }
        case .assistant:
            assistantContent
        case .system:
            EmptyView()
        }
    }

    /// 用户消息：右对齐气泡，琥珀实底（chatUserBubble：亮色暖纸 / 暗色深琥珀随玻璃微光），
    /// 无描边（实底自身即容器，描边是廉价感来源），圆角 18 对话语言；
    /// 图片缩略图排在文本上方（点击放大），行距与 AI 正文同节奏（13pt + 6 ≈ 1.7 倍行高）。
    /// 文本启用选区复制（textSelection），与助手 Markdown 选区行为对齐。
    /// steering 注入的消息在气泡上方带「已转向」弱标记：纯图文无底色（比「已中止」标签更轻），
    /// 不抢气泡视觉重心，仅作来源可辨识记号。
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
            if message.isSteered == true {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "arrowshape.turn.up.right")
                        .font(Theme.Typography.text(10, .semibold))
                    Text("已转向")
                        .font(Theme.Typography.text(10, .semibold))
                }
                .foregroundColor(Theme.Colors.contentTertiary)
            }
            VStack(alignment: .trailing, spacing: Theme.Spacing.xl) {
                if !message.images.isEmpty {
                    MessageImageThumbs(images: message.images, onTap: onTapImage)
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(Theme.Typography.text(13))
                        .foregroundColor(Theme.Colors.contentPrimary)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.vertical, Theme.Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.userBubble, style: .continuous)
                    .fill(Theme.Colors.chatUserBubble)
            )
        }
    }

    /// 是否处于生成中（sending/streaming）：思考折叠区据此做流式节流与收尾全量同步。
    private var isLive: Bool {
        switch message.state {
        case .sending, .streaming: return true
        default: return false
        }
    }

    @ViewBuilder
    private var assistantContent: some View {
        // 思考折叠区（有 reasoning 时）→ 文本（无气泡铺底）→ 工具调用卡片纵向排列；
        // 一轮助手消息可能兼有文本与工具调用，纯工具调用轮（无文本）只渲染卡片、不留空文本段；
        // 卡片与正文同宽
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                ReasoningDisclosureView(reasoning: reasoning, isLive: isLive)
            }
            assistantTextPart
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                AIToolCallCardView(toolCalls: toolCalls)
                // 富内容卡片：工具结果携带 card 信封（如地图卡）时，紧随工具卡独立成卡渲染（与正文同宽），
                // 未携带信封的工具调用不产生任何占位
                ForEach(toolCalls, id: \.id) { record in
                    RichCardHostView(resultJSON: record.result ?? "")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 助手消息的文本部分（按状态分派）；纯工具调用消息（无文本）不渲染空文本段。
    @ViewBuilder
    private var assistantTextPart: some View {
        // 有工具调用且文本为空时跳过文本段（工具卡片单独成段）
        let skipsTextPart = message.content.isEmpty && !(message.toolCalls?.isEmpty ?? true)
        switch message.state {
        case .sending, .streaming:
            // 流式/首 token 等待：纯文本增量 + 块状光标（流结束后切完整 AST 渲染）；
            // hasReasoning 让空正文态决定是否补「思考中…」阶段词（有 reasoning 时折叠区已承载活性）
            StreamingMessageView(content: message.content, hasReasoning: !(message.reasoning?.isEmpty ?? true))
        case .failed(let errorText):
            // 失败态保留提示卡片（状态提示，非正文排版）
            FailedMessageView(errorText: errorText, onRetry: onRetry)
        case .done:
            // 落定态：完整块级 Markdown 渲染（AIChatMarkdownView）；
            // textSelection 支持按块选区复制（跨块选择与含公式段落不支持，见 MarkdownInlineText 结构限制）
            if !skipsTextPart {
                AssistantMarkdownView(content: message.content)
                    // 显式绑定消息身份：message.id 变化即重建视图，分批渲染游标随之重置。
                    .id(message.id)
                    .textSelection(.enabled)
                    // 白屏防线（勿动族）：落定态从流式视图结构性替换为完整渲染时，禁用从祖先
                    // （messageList 的 .animation(value: messages.count) 与行级 transition）传入的
                    // 隐式动画，防止 CA 事务竞态把内容层卡在近零透明度；无动画瞬时替换。
                    .transaction { $0.animation = nil }
            }
        case .aborted:
            // 中止：保留半截内容的富渲染 + 弱标记
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if !skipsTextPart {
                    AssistantMarkdownView(content: message.content)
                        .id(message.id)
                        .textSelection(.enabled)
                        // 白屏防线（勿动族）：同 .done 分支，结构性替换禁用祖先隐式动画，防 CA 事务竞态。
                        .transaction { $0.animation = nil }
                }
                AbortedTag()
            }
        }
    }
}

/// 流式消息：增量 Markdown 渲染（节流）+ 闪烁块状光标。
/// 与落定态一致无气泡，流式→定稿不再发生排版/颜色跳变。
/// 两级表达：① 无正文且无 reasoning = 光标 + 弱化阶段词「思考中…」（首 token 等待）；
/// ② 无正文但有 reasoning = 不渲染任何占位，活性由上方的思考折叠区摘要行实时更新承担
/// （避免孤儿光标噪声）；③ 有正文增量后 = 光标跟随文尾，无状态词。
struct StreamingMessageView: View {
    let content: String
    /// 是否已有思考过程（reasoning 折叠区由外层 assistantContent 承载，此处只做空态取舍）。
    let hasReasoning: Bool

    var body: some View {
        if !content.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                StreamingMarkdownContentView(content: content)
                // 光标跟随文尾（置于内容块尾行下方左侧，模拟文尾 caret）
                BlinkingCaret()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !hasReasoning {
            HStack(spacing: Theme.Spacing.sm) {
                BlinkingCaret()
                Text("思考中…")
                    .font(Theme.Typography.text(Theme.Typography.footnote))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }
        }
    }
}

/// 闪烁块状光标：▌ 以线性节拍闪烁（近似系统 caret；只闪光标，不呼吸整行，避免视觉噪声）。
struct BlinkingCaret: View {
    @State private var lit = false

    var body: some View {
        Text("▌")
            .font(Theme.Typography.text(Theme.Typography.body))
            .foregroundColor(Theme.Colors.contentSecondaryStrong)
            .opacity(lit ? 1 : 0)
            .onAppear {
                withAnimation(.linear(duration: Theme.Motion.caretBlink).repeatForever(autoreverses: true)) {
                    lit = true
                }
            }
    }
}

// MARK: - 思考过程折叠卡片（10行默认展开 + 跟随输出 + Markdown排版 + 视觉分层）

/// 思考过程（reasoning）折叠卡：
/// - 默认展开（约 10 行限高滚动区，内容少时自适应贴合不留空，超出时内滚）；落定后保持展开，可随时手动点击标题收起为单行摘要；
/// - 流式期间随输出实时自动贴底滚动展示（跟随输出展示）；
/// - 支持完整块级 Markdown 排版（段落、列表、代码块、引用、数学公式、表格），通过专有 ReasoningMarkdownView 渲染；
/// - 样式层级区别于正文：轻量内凹卡片背景 + 0.5pt 细描边 + 左侧引导细竖线 + 11.5pt 字号与次级文字色阶，代码块走紧凑模式（不启动 Mermaid WebView 预览）。
struct ReasoningDisclosureView: View {
    let reasoning: String
    /// 是否仍在生成中：节流门控期间中间帧可丢，收尾帧必须全量（防止末尾增量被门控吞掉）。
    let isLive: Bool

    @State private var expanded = true
    @State private var rendered: String = ""
    @State private var lastRenderAt: Date = .distantPast
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { expanded.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "brain")
                        .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                        .foregroundColor(isLive ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                    Text(isLive ? String(localized: "思考中…") : String(localized: "思考过程"))
                        .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                        .foregroundColor(isLive ? Theme.Colors.accent : Theme.Colors.contentSecondaryStrong)
                    if !expanded {
                        Text(summary)
                            .font(Theme.Typography.text(Theme.Typography.footnote))
                            .foregroundColor(Theme.Colors.contentTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: Theme.Spacing.sm)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(Theme.Typography.text(Theme.Typography.micro, .medium))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? String(localized: "收起思考过程") : String(localized: "展开思考过程"))

            if expanded {
                Rectangle()
                    .fill(Theme.Colors.cardStroke)
                    .frame(height: Theme.Layout.dividerHeight)
                    .padding(.horizontal, Theme.Spacing.md)

                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                        .fill(isLive ? Theme.Colors.accent.opacity(0.45) : Theme.Colors.contentTertiary.opacity(0.35))
                        .frame(width: 2.5)
                        .padding(.vertical, 2)

                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                if rendered.isEmpty && isLive {
                                    HStack(spacing: Theme.Spacing.sm) {
                                        BlinkingCaret()
                                        Text("思考中…")
                                            .font(Theme.Typography.text(Theme.Typography.footnote))
                                            .foregroundColor(Theme.Colors.contentTertiary)
                                    }
                                    .padding(.vertical, 2)
                                } else {
                                    ReasoningMarkdownView(content: rendered, useCache: !isLive)
                                    if isLive {
                                        BlinkingCaret()
                                    }
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id("reasoningBottomAnchor")
                            }
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(key: ReasoningHeightPreferenceKey.self, value: geo.size.height)
                                }
                            )
                        }
                        .frame(height: contentHeight > 0 ? min(contentHeight, Theme.Layout.reasoningMaxHeight) : nil)
                        .frame(maxHeight: Theme.Layout.reasoningMaxHeight)
                        .onPreferenceChange(ReasoningHeightPreferenceKey.self) { h in
                            if h > 0 { contentHeight = h }
                        }
                        .onChange(of: rendered) { _ in
                            if isLive && expanded {
                                DispatchQueue.main.async {
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        proxy.scrollTo("reasoningBottomAnchor", anchor: .bottom)
                                    }
                                }
                            }
                        }
                        .onChange(of: expanded) { isExpanded in
                            if isExpanded && isLive {
                                DispatchQueue.main.async {
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        proxy.scrollTo("reasoningBottomAnchor", anchor: .bottom)
                                    }
                                }
                            }
                        }
                        .onAppear {
                            if isLive && expanded {
                                DispatchQueue.main.async {
                                    proxy.scrollTo("reasoningBottomAnchor", anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.md)
                .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(Theme.Colors.surfaceInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .stroke(Theme.Colors.cardStroke, lineWidth: 0.5)
        )
        .onAppear {
            rendered = reasoning
            lastRenderAt = Date()
        }
        .onChange(of: reasoning) { newValue in
            let now = Date()
            guard now.timeIntervalSince(lastRenderAt) >= 0.08 else { return }
            lastRenderAt = now
            rendered = newValue
        }
        // 收尾对账：生成结束时无论门控窗口如何都渲染全量，防止末尾增量被节流吞掉
        .onChange(of: isLive) { live in
            if !live { rendered = reasoning }
        }
    }

    /// 摘要：取最近一个非空段落（流式期间摘要行随增量实时更新，单行截断）。
    private var summary: String {
        let paragraphs = rendered
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paragraphs.last ?? String(localized: "思考中…")
    }
}

// MARK: - 思考内容高度偏好键

private struct ReasoningHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 思考专有 Markdown 渲染器

struct ReasoningMarkdownView: View {
    let content: String
    var useCache: Bool = true

    var body: some View {
        let blocks = MarkdownASTCache.blocks(for: content, useCache: useCache)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                ReasoningBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReasoningBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, inlines):
            let size: CGFloat = level <= 2 ? 12.5 : 12.0
            MarkdownInlineText(
                inlines: inlines,
                bodyColor: Theme.Colors.contentPrimary.opacity(0.85),
                baseSize: size,
                weight: .semibold,
                explicitColor: Theme.Colors.contentPrimary.opacity(0.85)
            )
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

        case let .paragraph(inlines):
            MarkdownInlineText(
                inlines: inlines,
                bodyColor: Theme.Colors.contentSecondaryStrong,
                baseSize: 11.5,
                weight: .regular
            )
            .lineSpacing(3.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

        case let .orderedList(items):
            ReasoningListView(items: items, ordered: true)

        case let .unorderedList(items):
            ReasoningListView(items: items, ordered: false)

        case let .codeBlock(language, code):
            // 思考过程内的代码块统一走紧凑代码框（10.5pt 等宽，不启动 Mermaid WebView 预览）
            ReasoningCodeBlockView(language: language, code: code)

        case let .blockquote(blocks):
            ReasoningBlockquoteView(blocks: blocks)

        case let .mathBlock(latex):
            AsyncMathBlockView(latex: latex, fontSize: 12, color: Theme.Colors.contentSecondaryStrong)

        case .horizontalRule:
            Rectangle()
                .fill(Theme.Colors.cardStroke)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Theme.Layout.dividerHeight)

        case let .table(table):
            MarkdownTableView(table: table)

        case let .alert(_, blocks):
            ReasoningBlockquoteView(blocks: blocks)

        case let .details(summary, blocks, _):
            VStack(alignment: .leading, spacing: 4) {
                MarkdownInlineText(
                    inlines: summary,
                    bodyColor: Theme.Colors.contentPrimary,
                    baseSize: 11.5,
                    weight: .medium
                )
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                    ReasoningBlockView(block: b)
                }
            }

        case let .definitionList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    MarkdownInlineText(
                        inlines: item.term,
                        bodyColor: Theme.Colors.contentPrimary,
                        baseSize: 11.5,
                        weight: .semibold
                    )
                    ForEach(Array(item.definitions.enumerated()), id: \.offset) { _, def in
                        MarkdownInlineText(
                            inlines: def,
                            bodyColor: Theme.Colors.contentSecondaryStrong,
                            baseSize: 11.5,
                            weight: .regular
                        )
                        .padding(.leading, 12)
                    }
                }
            }

        case .footnoteDefinition:
            EmptyView()
        }
    }
}

struct ReasoningListView: View {
    let items: [MarkdownListItem]
    let ordered: Bool
    var depth: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                ReasoningListItemRow(item: item, ordered: ordered, depth: depth)
            }
        }
    }
}

struct ReasoningListItemRow: View {
    let item: MarkdownListItem
    let ordered: Bool
    var depth: Int = 0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            marker
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case let .orderedList(subItems):
                        ReasoningListView(items: subItems, ordered: true, depth: depth + 1)
                            .padding(.leading, 16)
                    case let .unorderedList(subItems):
                        ReasoningListView(items: subItems, ordered: false, depth: depth + 1)
                            .padding(.leading, 16)
                    default:
                        ReasoningBlockView(block: block)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(item.taskState == true ? 0.55 : 1)
        }
    }

    @ViewBuilder
    private var marker: some View {
        if let state = item.taskState {
            Image(systemName: state ? "checkmark.circle.fill" : "circle")
                .font(Theme.Typography.text(11, .medium))
                .foregroundColor(state ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                .frame(minWidth: 12, alignment: .trailing)
        } else if ordered {
            Text("\(item.number ?? 1).")
                .font(Theme.Typography.mono(10.5))
                .foregroundColor(Theme.Colors.contentTertiary)
                .frame(minWidth: 12, alignment: .trailing)
        } else {
            Text(depth == 0 ? "•" : "◦")
                .font(Theme.Typography.text(11, .medium))
                .foregroundColor(Theme.Colors.contentTertiary)
                .frame(minWidth: 12, alignment: .trailing)
        }
    }
}

struct ReasoningCodeBlockView: View {
    let language: String?
    let code: String

    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 顶栏：语言标签 + 紧凑复制钮
            HStack(spacing: Theme.Spacing.sm) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(Theme.Typography.mono(9.5, .medium))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
                Spacer(minLength: 0)
                Button(action: copyCode) {
                    HStack(spacing: 2) {
                        Image(systemName: copied ? "checkmark" : "square.on.square")
                            .font(Theme.Typography.text(9, .medium))
                        Text(copied ? String(localized: "已复制") : String(localized: "复制"))
                            .font(Theme.Typography.text(9, .medium))
                    }
                    .foregroundColor(copied ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Theme.Colors.surfaceButton)
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
            }
            .frame(minHeight: 12)

            // 代码等宽横滚
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(Theme.Typography.mono(10.5))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    .lineSpacing(3)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.Colors.surfaceTrack.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong.opacity(0.5), lineWidth: 0.5)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

struct ReasoningBlockquoteView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                ReasoningBlockView(block: child)
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Theme.Colors.accent.opacity(0.35))
                .frame(width: 2)
        }
    }
}

// MARK: - 压缩标记折叠卡

/// 上下文压缩边界卡：会话流内的章节标记（不参与消息选中/上下文菜单交互，独立 struct 天然隔离）。
/// - 收起态：居中弱化胶囊行（⟲ + 「已压缩早期对话（N 条）」+ micro chevron），
///   surfaceBadge 底 + contentTertiary 灰字，总高 ≈24pt，与「已中止」标记同档弱化；
/// - 展开态：摘要全文（footnote 正文 + 3pt 行距 + 正常阅读色），上下各一条两端羽化的
///   0.5pt 细边线收束——ReasoningDisclosureView 的折叠气质，但更轻（不限高不内滚，
///   摘要语义上远短于原文，纵向让位给外层会话流滚动）；
/// - 压缩中：「⟲ 正在压缩…」，不可点、无 chevron，仅靠文案表达进行中（不加旋转/脉冲动画）。
struct CompactionBoundaryCard: View {
    let isCompacting: Bool
    let summarizedCount: Int
    let summary: String

    @State private var expanded = false
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            // 分界线语义（2026-10 升级）：胶囊不再是孤立徽章，两侧羽化细线贯穿阅读列，
            // 与行级降档（线上方 = 已摘要化区域、整行弱化）共同构成「章节分界」——
            // 用户扫读时一眼可见模型视角的分叉点。
            HStack(spacing: Theme.Spacing.xl) {
                featheredDivider
                Button {
                    withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { expanded.toggle() }
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                        Text(isCompacting ? String(localized: "正在压缩…") : String(localized: "已压缩早期对话（\(summarizedCount) 条）"))
                            .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                        if !isCompacting {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(Theme.Typography.text(Theme.Typography.micro, .medium))
                        }
                    }
                    // 单行钉死：两侧羽化细线是无限弹性填充，会把胶囊可用宽挤窄导致文案折行
                    //（回归实拍：「已压缩早期对话／（N 条）」两行）。fixedSize 让胶囊取理想
                    // 单行宽，宽度余量由细线吸收——章节分界语义下「线让位于字」。
                    .fixedSize()
                    .foregroundColor(isCompacting
                                     ? Theme.Colors.idleText
                                     : (hovered ? Theme.Colors.contentSecondaryStrong : Theme.Colors.contentTertiary))
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.chip)
                    .background(
                        Capsule(style: .continuous)
                            .fill(!isCompacting && hovered ? Theme.Colors.iconHoverBg : Theme.Colors.surfaceBadge)
                    )
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isCompacting)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
                }
                .help(isCompacting ? String(localized: "正在压缩早期对话…") : (expanded ? String(localized: "收起压缩摘要") : String(localized: "查看压缩摘要")))
                featheredDivider
            }

            if expanded, !isCompacting, !summary.isEmpty {
                VStack(spacing: 0) {
                    featheredDivider
                    Text(summary)
                        .font(Theme.Typography.text(Theme.Typography.footnote))
                        .foregroundColor(Theme.Colors.contentSecondaryStrong)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Spacing.lg)
                    featheredDivider
                }
                .padding(.top, Theme.Spacing.lg)
                .transition(.opacity)
            }
        }
        // 分界行随 VStack 撑满阅读列（细线向两侧延展）；上下补一点呼吸，
        // 使组内插入时上下节奏（xl=10 + xs）与组间章节感平衡
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xs)
    }

    /// 两端羽化的 0.5pt 细边线（窗口分割线同款渐变语言，水平方向）；
    /// 分界行内左右各一条，maxWidth 均分胶囊两侧的剩余空间。
    private var featheredDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.0),
                        Color.primary.opacity(Theme.Colors.dividerOpacity),
                        Color.primary.opacity(0.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Layout.dividerHeight)
    }
}

/// 流式 Markdown 增量渲染：把高频 token 触发的重解析节流到 ≤4Hz（250ms 时间门控）。
/// - rendered 仅在距上次渲染 ≥250ms 时更新；被跳过的中间帧不补渲染。
/// - 收尾帧完整性由 streaming→done/aborted 后切换的 AssistantMarkdownView 全量渲染保证。
/// - 未闭合 `$$`/`**` 短暂显示源码属预期，不做特殊处理。
struct StreamingMarkdownContentView: View {
    let content: String

    @State private var rendered: String = ""
    @State private var lastRenderAt: Date = .distantPast

    var body: some View {
        AssistantMarkdownView(content: rendered, useCache: false)
            .onAppear {
                rendered = content
                lastRenderAt = Date()
            }
            .onChange(of: content) { newValue in
                let now = Date()
                guard now.timeIntervalSince(lastRenderAt) >= 0.25 else { return }
                lastRenderAt = now
                rendered = newValue
            }
    }
}

/// 失败消息：错误色提示 + 重试按钮（重发最后一条 user 消息）。
struct FailedMessageView: View {
    let errorText: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.text(12))
                    .foregroundColor(Theme.Colors.statusWarning)
                Text(errorText)
                    .font(Theme.Typography.text(12))
                    .foregroundColor(Theme.Colors.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: onRetry) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.Typography.text(11, .semibold))
                    Text("重试")
                        .font(Theme.Typography.text(11, .semibold))
                }
                .foregroundColor(Theme.Colors.contentPrimary)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.vertical, Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                        .fill(Theme.Colors.surfaceButton)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .fill(Theme.Colors.statusWarning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .stroke(Theme.Colors.statusWarning.opacity(0.28), lineWidth: 0.5)
        )
    }
}

/// 「已中止」弱标记。
struct AbortedTag: View {
    var body: some View {
        Text("已中止")
            .font(Theme.Typography.text(10.5, .medium))
            .foregroundColor(Theme.Colors.contentTertiary)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.surfaceBadge)
            )
    }
}
