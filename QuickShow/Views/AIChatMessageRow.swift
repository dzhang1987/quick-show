// 从 AIChatView.swift 机械拆分：单条消息行及其行内子视图（操作钮 / 流式 / 思考 / 压缩边界 / 失败 / 中止）。

import AppKit
import Combine
import SwiftUI

struct ChatMessageRow: View, Equatable {
    let message: ChatMessage
    /// 回合聚合轨迹（仅在该 Assistant MessageGroup 内负责呈现过程栏的消息上非空）
    var turnTrace: AgentTurnTrace? = nil
    /// 本回合累积的全部工具调用（用于末条统一呈现伴生富卡片）
    var allGroupToolCalls: [ToolCallRecord] = []
    /// 是否已被压缩摘要化（纯显示态：驱动整行降档透明度；行内不直接消费，
    /// 参与 Equatable 判定使压缩落盘瞬间相关行重绘弱化）。
    let isSummarized: Bool
    /// 是否为最后一条可重新生成的助手消息（父视图计算，含流式中禁用语义）。
    let canRegenerate: Bool
    /// 是否为会话内最后一条 user 消息且可撤回/编辑（父视图计算，含生成中禁用语义）。
    let canEditLastRound: Bool
    /// 是否可利用已落定工具调用进行断点续跑
    var canResumeAfterTools: Bool = false
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
            && lhs.turnTrace == rhs.turnTrace
            && lhs.allGroupToolCalls == rhs.allGroupToolCalls
            && lhs.isSummarized == rhs.isSummarized
            && lhs.canRegenerate == rhs.canRegenerate
            && lhs.canEditLastRound == rhs.canEditLastRound
            && lhs.canResumeAfterTools == rhs.canResumeAfterTools
            && lhs.isEditing == rhs.isEditing
    }

    @State private var rowHovered = false
    @State private var copied = false

    var body: some View {
        Group {
            switch message.role {
            case .user:
                VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                    HStack(alignment: .top, spacing: 0) {
                        Spacer(minLength: Theme.Spacing.panel)
                        if isEditing {
                            MessageEditBubble(
                                message: message,
                                onTapImage: onTapImage,
                                onCommit: { text, images in
                                    onEditResend(text, images)
                                },
                                onCancel: onCancelEdit
                            )
                        } else {
                            userBubble
                        }
                    }
                    if showsActionRow {
                        actionRow
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            case .assistant:
                assistantContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .system:
                EmptyView()
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { rowHovered = hovering }
        }
        .contextMenu { rowContextMenu }
    }

    /// 统一常驻操作行组件
    @ViewBuilder
    private var actionRow: some View {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.transientFeedbackDuration) { copied = false }
    }


    /// 用户消息：右对齐气泡，微透流光自适应底板（Theme.Colors.userBubbleFill），
    /// 辅以与主题色同源的 0.5pt 精细微光受光 rim（Theme.Colors.userBubbleStroke），圆角 18 对话语言；
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
                    Text(String(localized: "中途插入"))
                        .font(Theme.Typography.text(10, .semibold))
                }
                .foregroundColor(Theme.Colors.contentTertiary)
            }
            userBubbleContent
        }
    }

    @ViewBuilder
    private var userBubbleContent: some View {
        if message.content.isEmpty && !message.images.isEmpty {
            // 纯图模式：极致轻盈，直接呈现带微光边框的圆角图卡，消除多余灰底厚边距
            MessageImageThumbs(images: message.images, onTap: onTapImage)
        } else {
            // 图文混排或纯文字模式：紧凑气泡，内部图文左对齐自然排版
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if !message.images.isEmpty {
                    MessageImageThumbs(images: message.images, onTap: onTapImage)
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(Theme.Typography.text(13))
                        .foregroundColor(Theme.Colors.userBubbleForeground)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, message.images.isEmpty ? Theme.Spacing.xxl : Theme.Spacing.lg)
            .padding(.vertical, message.images.isEmpty ? Theme.Spacing.xl : Theme.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.userBubble, style: .continuous)
                    .fill(Theme.Colors.userBubbleFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.userBubble, style: .continuous)
                            .strokeBorder(Theme.Colors.userBubbleStroke, lineWidth: 0.5)
                    )
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

    /// 生效的回合执行轨迹：优先使用父级传入的聚合轨迹，单消息孤立使用时回退自身提取
    private var effectiveTrace: AgentTurnTrace? {
        if let turnTrace {
            return turnTrace.isEmpty ? nil : turnTrace
        }
        return AgentTurnTrace.extract(from: [message], isStreaming: isLive)
    }

    /// 生效的伴生富卡片数据源：仅过滤出真正携带富卡片（如地图、文件预览）信封的工具调用，
    /// 严禁向外层 VStack 注入几十上百个空卡片节点（杜绝空节点 item spacing 累积产生数百 pt 巨大幽灵空白）
    private var actualRichCardToolCalls: [ToolCallRecord] {
        let candidates = !allGroupToolCalls.isEmpty ? allGroupToolCalls : (message.toolCalls ?? [])
        return candidates.filter { record in
            guard let result = record.result, !result.isEmpty else { return false }
            return RichCard.extract(fromToolResultJSON: result) != nil
        }
    }

    @ViewBuilder
    private var assistantContent: some View {
        // 中间纯过程消息（已被回合末条聚合，无独立正文）：静默零占位，彻底消除千层饼
        let isSilentIntermediate = (turnTrace == nil && message.content.isEmpty && !allGroupToolCalls.isEmpty)
        if !isSilentIntermediate {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                // 1. 思考与工具调用一体化过程轨迹（回合级聚合：多轮合一，去卡片化极简通透流）
                if let trace = effectiveTrace {
                    AgentProcessDisclosureView(
                        turnId: message.id,
                        trace: trace,
                        hasContent: !message.content.isEmpty
                    )
                }
                // 2. 最终结果正文
                assistantTextPart
                // 3. 伴生结果富卡片（仅当确实有地图等卡片时渲染，杜绝空节点占位撑开空白）
                if !actualRichCardToolCalls.isEmpty {
                    ForEach(actualRichCardToolCalls, id: \.id) { record in
                        RichCardHostView(resultJSON: record.result ?? "")
                    }
                }
                // 4. 底部统一操作栏
                if showsActionRow {
                    actionRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 助手消息的文本部分（按状态分派）；纯工具调用消息（无文本）不渲染空文本段。
    @ViewBuilder
    private var assistantTextPart: some View {
        // 有工具调用且文本为空时跳过文本段（工具卡片单独成段）
        let skipsTextPart = message.content.isEmpty && !(message.toolCalls?.isEmpty ?? true)
        switch message.state {
        case .sending, .streaming:
            // 流式/首 token 等待：纯文本增量 + 块状光标（流结束后切完整 AST 渲染）；
            // effectiveTrace 让空正文态决定是否补「思考中…」阶段词（有思考或工具时上方过程折叠栏已承载活性）
            StreamingMessageView(content: message.content, hasReasoning: effectiveTrace != nil)
        case .failed(let errorText):
            // 失败态保留提示卡片（状态提示，非正文排版）
            let retryTitle = canResumeAfterTools ? "继续回答" : "重试"
            FailedMessageView(errorText: errorText, retryTitle: retryTitle, onRetry: onRetry)
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
            // 中止：保留半截内容的富渲染（AbortedTag 统一收口至 actionRow 靠左紧凑展示）
            if !skipsTextPart {
                AssistantMarkdownView(content: message.content)
                    .id(message.id)
                    .textSelection(.enabled)
                    // 白屏防线（勿动族）：同 .done 分支，结构性替换禁用祖先隐式动画，防 CA 事务竞态。
                    .transaction { $0.animation = nil }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.transientFeedbackDuration) { copied = false }
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
                        Text(isCompacting ? String(localized: "正在压缩…") : String(localized: "已压缩历史对话（\(summarizedCount) 条）"))
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
                .help(isCompacting ? String(localized: "正在压缩历史对话…") : (expanded ? String(localized: "收起压缩摘要") : String(localized: "查看压缩摘要")))
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

/// 失败消息：错误色提示 + 重试按钮（重发最后一条 user 消息 或 断点续跑）。
struct FailedMessageView: View {
    let errorText: String
    var retryTitle: String = "重试"
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
            HStack {
                Spacer()
                Button(action: onRetry) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "arrow.clockwise")
                            .font(Theme.Typography.text(11, .semibold))
                        Text(retryTitle)
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
