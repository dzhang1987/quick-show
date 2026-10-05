import SwiftUI
import AppKit

// MARK: - 输入坞抽屉（权限确认 / AI 提问）
//
// 设计目标（2026-10 拍板）：
// - 无缝一体：抽屉紧贴输入卡上沿、衔接处无间隙。玻璃面/圆角/描边/阴影由 AIChatView
//   的坞体连续容器统一施加（抽屉 + 输入卡共享同一个 Radius.groupCard 连续体），
//   本文件只提供抽屉「内容」，不再自带材质——抽屉是输入框"长出"的上半部分，不是独立弹窗。
// - 动画：从输入卡上沿向上滑入（.move(edge: .bottom) + opacity，0.25s easeOut，
//   由 AIChatView 在 request id 变化处统一施加），窗口 frame 不动、纯视图内布局
//   （规避整窗玻璃 + SwiftUI 测量链死锁，与监控看板绕开同一路径）。
// - ESC 语义：抽屉在场时 ESC 优先取消抽屉（权限 = 拒绝 / 提问 = 取消），
//   窗口层 / 视图层 / 按键监听三条链路均已前置（见 AIWindowManager 与 AIChatView）。
// - 状态本地化：选中态/自由输入文本存 @State；调用方给面板 .id(request.id)，
//   请求切换即整树重建、状态天然重置。
//
// 数据契约：只消费 ChatInteractionCenter 发布的 ChatDrawerRequest；
// resolve/submit/cancel 后逻辑层清空 request，抽屉随动画收起。

/// 抽屉视觉常量（本特性私有节拍：0.25s 滑入与 Motion tokens 现有档位皆不同，
/// 是否收编进 DesignTokens 留给设计系统统一决定，先就近收敛在本文件）。
enum AIChatDrawerMetrics {
    /// 抽屉滑入/滑出时长（easeOut）
    static let slideDuration: Double = 0.25
    /// 提问面板题目区限高（超出内部滚动；抽屉整体不把输入卡推出窗口）
    static let questionsMaxHeight: CGFloat = 260
    /// 权限面板完整参数区限高（超出内部滚动）
    static let argumentsMaxHeight: CGFloat = 160
    /// 统一输入条高度档（单行起步，随内容生长至上限后内部滚动）
    static let freeInputMinHeight: CGFloat = 22
    static let freeInputMaxHeight: CGFloat = 60
    /// 参数原文超过该长度即视为「长命令」，默认折叠为单行摘要
    static let argumentsShortLimit: Int = 120
}

// MARK: - 抽屉分派容器

/// 输入坞抽屉：按请求类型分派权限确认 / 用户提问两套面板。
/// 调用方负责 transition / 动画 / 玻璃容器 / .id 状态重置；本视图仅排版内容。
struct AIChatDrawerPanel: View {
    let request: ChatDrawerRequest

    var body: some View {
        switch request {
        case .toolConfirmation(let confirmation):
            ToolConfirmationDrawerContent(request: confirmation)
        case .userQuestions(let questions):
            UserQuestionDrawerContent(request: questions)
        }
    }
}

// MARK: - 权限确认抽屉

/// 危险工具权限确认：工具名徽章 + 参数代码块（长命令默认单行摘要、点击展开）+ 三按钮。
/// 三按钮语义：拒绝（次要）/ 执行（主要实心）/ 本会话总是允许（描边第三样式）；
/// ESC = 拒绝（窗口层/视图层链路统一走 resolveConfirmation(.denied)）。
private struct ToolConfirmationDrawerContent: View {
    let request: ToolConfirmationRequest

    /// 完整参数是否已展开（默认单行摘要）。
    @State private var argumentsExpanded = false
    /// 「完整参数」入口 hover 态。
    @State private var toggleHovered = false

    /// 美化后的完整参数（展开态展示）。
    private var prettyArguments: String { ToolJSONText.pretty(request.argumentsJSON) }

    /// 是否「长命令」：多行或超长 → 默认折叠为单行摘要 + 提供展开入口；
    /// 短参数直接完整展示，不制造无意义的折叠/展开切换。
    private var hasMoreArguments: Bool {
        let trimmed = request.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("\n") || trimmed.count > AIChatDrawerMetrics.argumentsShortLimit
    }

    /// 工具中文展示名（注册表查不到时省略，徽章已承担蛇形名展示）。
    private var displayName: String? {
        AIToolRegistry.shared.tool(named: request.toolName)?.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            // 标题行：工具名徽章（等宽小字）+ 请求执行权限；右端附中文展示名
            HStack(spacing: Theme.Spacing.lg) {
                Text(request.toolName)
                    .font(Theme.Typography.mono(Theme.Typography.mini, .medium))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                            .fill(Theme.Colors.surfaceBadge)
                    )
                Text("请求执行权限")
                    .font(Theme.Typography.text(Theme.Typography.callout, .semibold))
                    .foregroundColor(Theme.Colors.contentPrimary)
                Spacer(minLength: 0)
                if let displayName, displayName != request.toolName {
                    Text(displayName)
                        .font(Theme.Typography.text(Theme.Typography.caption))
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .lineLimit(1)
                }
            }

            argumentsBlock

            // 按钮行：消极在左、积极在右（拒绝远离主操作区）
            HStack(spacing: Theme.Spacing.lg) {
                DrawerActionButton(title: "拒绝", style: .secondary) {
                    ChatInteractionCenter.shared.resolveConfirmation(.denied)
                }
                Spacer(minLength: 0)
                DrawerActionButton(title: "本会话总是允许", style: .outlined) {
                    ChatInteractionCenter.shared.resolveConfirmation(.alwaysAllowThisSession)
                }
                DrawerActionButton(title: "执行", style: .primary) {
                    ChatInteractionCenter.shared.resolveConfirmation(.executeOnce)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.top, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.xl)
    }

    // MARK: 参数代码块

    /// 参数区：等宽小号 + 内嵌深色底（与工具卡参数区同一语言）。
    /// 长命令折叠态单行摘要（点击整块或右上「完整参数」展开）；展开态多行可滚动、限高。
    private var argumentsBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.lg) {
                Text("参数")
                    .font(Theme.Typography.text(Theme.Typography.mini, .semibold))
                    .foregroundColor(Theme.Colors.contentTertiary)
                Spacer(minLength: 0)
                if hasMoreArguments {
                    Button {
                        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                            argumentsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(argumentsExpanded ? "收起" : "完整参数")
                                .font(Theme.Typography.text(Theme.Typography.mini, .medium))
                            Image(systemName: "chevron.right")
                                .font(Theme.Typography.text(8, .semibold))
                                .rotationEffect(.degrees(argumentsExpanded ? 90 : 0))
                        }
                        .foregroundColor(toggleHovered ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { toggleHovered = hovering }
                    }
                    .help(argumentsExpanded ? "收起参数" : "展开查看完整参数")
                }
            }

            Group {
                if argumentsExpanded {
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(prettyArguments)
                            .font(Theme.Typography.mono(Theme.Typography.footnote))
                            .foregroundColor(Theme.Colors.contentSecondaryStrong)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: AIChatDrawerMetrics.argumentsMaxHeight, alignment: .top)
                } else {
                    Text(request.summary)
                        .font(Theme.Typography.mono(Theme.Typography.footnote))
                        .foregroundColor(Theme.Colors.contentSecondaryStrong)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.surfaceBadge)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous))
            .onTapGesture {
                // 点击代码块本身同样切换展开（仅长命令可展开时）
                guard hasMoreArguments else { return }
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                    argumentsExpanded.toggle()
                }
            }
        }
    }
}

// MARK: - 用户提问抽屉

/// AI 提问面板：每题 = header 短标签 + 问题文本 + 选项胶囊组（单选互斥 / 多选开关态）；
/// 底部统一输入条（自由答案，⏎ 只换行不提交，提交统一走按钮）+ 取消/提交按钮。
/// 提交校验：至少一题有选中项、或统一输入条非空，才可提交。
private struct UserQuestionDrawerContent: View {
    let request: UserQuestionRequest

    /// 各题选中态（question.id → 选中 option id 集合）。
    @State private var selections: [UUID: Set<UUID>] = [:]
    /// 底部统一输入条的自由文本。
    /// 语义决定：提交时同一段文本写入**每一题**的 customText——
    /// 单题场景即该题自定义答案（直觉正确）；多题场景视为对整组提问的整体补充，
    /// 模型按题阅读答案时每题都能读到（信息冗余优于丢失）。
    @State private var customText = ""

    /// 可提交判据：任一题有选中项，或统一输入条有非空白内容。
    private var canSubmit: Bool {
        let hasSelection = selections.values.contains { !$0.isEmpty }
        return hasSelection || !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            // 标题行：弱化小标题 + 多题计数（单题不显示计数）
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "questionmark.circle")
                    .font(Theme.Typography.text(Theme.Typography.footnote, .semibold))
                    .foregroundColor(Theme.Colors.accent)
                Text("需要你的回答")
                    .font(Theme.Typography.text(Theme.Typography.callout, .semibold))
                    .foregroundColor(Theme.Colors.contentPrimary)
                Spacer(minLength: 0)
                if request.questions.count > 1 {
                    Text("共 \(request.questions.count) 题")
                        .font(Theme.Typography.text(Theme.Typography.caption))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
            }

            // 题目区：多题限高内部滚动（抽屉整体不顶穿窗口）
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxxl) {
                    ForEach(request.questions) { question in
                        questionBlock(question)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: AIChatDrawerMetrics.questionsMaxHeight)

            freeInputBar

            // 按钮行：消极在左、积极在右
            HStack(spacing: Theme.Spacing.lg) {
                DrawerActionButton(title: "取消", style: .secondary) {
                    ChatInteractionCenter.shared.cancelQuestions()
                }
                Spacer(minLength: 0)
                DrawerActionButton(title: "提交答案", style: .primary, enabled: canSubmit) {
                    submit()
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.top, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.xl)
    }

    // MARK: 单题区块

    /// 单题：header 短标签（弱化小字 + 单选/多选提示）+ 问题文本 + 选项胶囊流式组。
    private func questionBlock(_ question: UserQuestion) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Text(question.header)
                    .font(Theme.Typography.text(Theme.Typography.caption, .semibold))
                    .foregroundColor(Theme.Colors.contentTertiary)
                    .lineLimit(1)
                Text(question.multiple ? "多选" : "单选")
                    .font(Theme.Typography.text(Theme.Typography.micro))
                    .foregroundColor(Theme.Colors.contentTertiary.opacity(0.75))
            }

            Text(question.question)
                .font(Theme.Typography.text(Theme.Typography.body))
                .foregroundColor(Theme.Colors.contentPrimary)
                .fixedSize(horizontal: false, vertical: true)

            DrawerOptionFlowLayout(spacing: Theme.Spacing.md) {
                ForEach(question.options) { option in
                    DrawerOptionCapsule(
                        option: option,
                        selected: selections[question.id]?.contains(option.id) == true
                    ) {
                        toggleOption(option.id, for: question)
                    }
                }
            }
        }
    }

    /// 选项开关：多选 = toggle；单选 = 互斥替换（再点已选中项可取消，留出「纯自定义答案」通路）。
    private func toggleOption(_ optionID: UUID, for question: UserQuestion) {
        var current = selections[question.id] ?? []
        if question.multiple {
            if current.contains(optionID) {
                current.remove(optionID)
            } else {
                current.insert(optionID)
            }
        } else {
            current = current.contains(optionID) ? [] : [optionID]
        }
        selections[question.id] = current
    }

    // MARK: 统一输入条与提交

    /// 底部统一输入条：自由答案入口（与已选项一并提交）。
    /// ⏎ 只换行不提交（TextEditor 默认行为），提交统一走按钮。
    private var freeInputBar: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $customText)
                .scrollContentBackground(.hidden)
                .font(Theme.Typography.text(Theme.Typography.body))
                .foregroundColor(Theme.Colors.contentPrimary)
                .frame(minHeight: AIChatDrawerMetrics.freeInputMinHeight,
                       maxHeight: AIChatDrawerMetrics.freeInputMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
            if customText.isEmpty {
                Text("输入自定义答案…")
                    .font(Theme.Typography.text(Theme.Typography.body))
                    .foregroundColor(Theme.Colors.idleText)
                    // 补偿 TextEditor 默认文本内边距，placeholder 与光标对齐
                    .padding(.leading, Theme.Spacing.chip)
                    .padding(.top, Theme.Spacing.xxs)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .fill(Theme.Colors.surfaceInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .stroke(Theme.Colors.cardStroke, lineWidth: 0.5)
        )
    }

    /// 提交：按题组装答案集（选中项 + 统一自由文本），唤醒逻辑层挂起。
    private func submit() {
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        var answers: [UUID: QuestionAnswer] = [:]
        for question in request.questions {
            answers[question.id] = QuestionAnswer(
                selectedOptionIDs: selections[question.id] ?? [],
                customText: trimmed
            )
        }
        ChatInteractionCenter.shared.submitQuestions(
            UserQuestionResponse(requestID: request.id, answers: answers)
        )
    }
}

// MARK: - 选项胶囊

/// 选项胶囊：视觉沿用坞内微胶囊语言（surfaceTrack 底 + chatCapsuleRim 0.5pt 描边），
/// 选中态换 accent 档（0.12 底 + 0.45 描边 + ✓，与状态徽标同一克制语言）；
/// hover 提亮。选项说明文字经 tooltip 展示（胶囊保持单行紧凑）。
private struct DrawerOptionCapsule: View {
    let option: UserQuestionOption
    let selected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(Theme.Typography.text(Theme.Typography.micro, .bold))
                }
                Text(option.label)
                    .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                    .lineLimit(1)
            }
            .foregroundColor(
                selected
                    ? Theme.Colors.accent
                    : (hovered ? Theme.Colors.iconHover : Theme.Colors.contentSecondaryStrong)
            )
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        selected
                            ? Theme.Colors.accent.opacity(0.12)
                            : (hovered ? Theme.Colors.iconHoverBg : Theme.Colors.surfaceTrack)
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        selected ? Theme.Colors.accent.opacity(0.45) : Theme.Colors.chatCapsuleRim,
                        lineWidth: 0.5
                    )
            )
            .contentShape(Capsule(style: .continuous))
            .animation(.easeOut(duration: Theme.Motion.contentFade), value: selected)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
        .help(option.description.map { "\(option.label)\n\($0)" } ?? option.label)
    }
}

// MARK: - 抽屉按钮

/// 抽屉操作按钮三样式：primary（accent 实心，主操作）/ secondary（surfaceButton 底，消极操作）
/// / outlined（描边，第三样式）。禁用态 = chatSendDisabledFill 底 + 弱化字（发送钮同款语言）。
private struct DrawerActionButton: View {
    enum Style {
        case primary
        case secondary
        case outlined
    }

    let title: String
    let style: Style
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.text(Theme.Typography.body, .medium))
                .foregroundColor(foregroundColor)
                .padding(.horizontal, Theme.Spacing.card)
                .padding(.vertical, Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                        .fill(fillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
    }

    private var fillColor: Color {
        switch style {
        case .primary:
            if !enabled { return Theme.Colors.chatSendDisabledFill }
            return hovered ? Theme.Colors.accent.opacity(0.85) : Theme.Colors.accent
        case .secondary:
            return hovered ? Theme.Colors.iconHoverBg : Theme.Colors.surfaceButton
        case .outlined:
            return hovered ? Theme.Colors.iconHoverBg : Color.clear
        }
    }

    private var strokeColor: Color {
        switch style {
        case .outlined:
            return Theme.Colors.badgeStroke
        default:
            return Color.clear
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            // 与发送钮同款：强调色底上取深色对比最稳；禁用态降弱化字
            return enabled ? Color.black.opacity(0.72) : Theme.Colors.contentTertiary
        case .secondary:
            return Theme.Colors.contentPrimary
        case .outlined:
            return hovered ? Theme.Colors.contentPrimary : Theme.Colors.contentSecondaryStrong
        }
    }
}

// MARK: - 选项流式布局

/// 选项胶囊流式行：子视图放不下时换行（与附件 FlowRow 同款极简实现，
/// 因 FlowRow 为附件模块私有，此处按抽屉语义独立一份，不跨模块借私有类型）。
private struct DrawerOptionFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
