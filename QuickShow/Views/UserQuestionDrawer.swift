import SwiftUI

// MARK: - 用户提问抽屉通知事件（全键盘盲操支持）

extension Notification.Name {
    static let quickShowSubmitUserQuestions = Notification.Name("quickShowSubmitUserQuestions")
    static let quickShowSelectQuestionOption = Notification.Name("quickShowSelectQuestionOption")
    static let quickShowNavigateQuestion = Notification.Name("quickShowNavigateQuestion")
}

// MARK: - 用户提问抽屉

/// AI 提问面板：每题 = header 短标签 + 问题文本 + 选项胶囊组（单选互斥 / 多选开关态）；
/// 底部统一输入条（自由答案，⏎ 只换行不提交，提交统一走按钮）+ 取消/提交按钮。
/// 提交校验：至少一题有选中项、或统一输入条非空，才可提交。
struct UserQuestionDrawerContent: View {
    let request: UserQuestionRequest

    /// 各题选中态（question.id → 选中 option id 集合）。
    @State private var selections: [UUID: Set<UUID>] = [:]
    /// 当前聚焦的题目索引（用于多题场景下的键盘焦点与数字键 1-9 路由）。
    @State private var focusedQuestionIndex: Int = 0
    /// 自由输入框是否获得焦点（防止进入抽屉时自动抢占光标）
    @FocusState private var isCustomInputFocused: Bool
    /// 底部统一输入条的自由文本。
    /// 语义决定：提交时同一段文本写入**每一题**的 customText——
    /// 单题场景即该题自定义答案（直觉正确）；多题场景视为对整组提问的整体补充，
    /// 模型按题阅读答案时每题都能读到（信息冗余优于丢失）。
    @State private var customText = ""
    /// 题目区自然高度测量（用于自适应，消除多余空白）
    @State private var questionsContentHeight: CGFloat = 0

    init(request: UserQuestionRequest) {
        self.request = request
        // 单选题默认预选第一项（推荐项），使用户可直接敲回车秒级确认
        var initialSelections: [UUID: Set<UUID>] = [:]
        for question in request.questions {
            if !question.multiple, let firstOption = question.options.first {
                initialSelections[question.id] = [firstOption.id]
            }
        }
        _selections = State(initialValue: initialSelections)
        _focusedQuestionIndex = State(initialValue: 0)
    }

    /// 可提交判据：任一题有选中项，或统一输入条有非空白内容。
    private var canSubmit: Bool {
        let hasSelection = selections.values.contains { !$0.isEmpty }
        return hasSelection || !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            // 标题行：弱化小标题 + 多题计数与切换提示（单题不显示计数）
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "questionmark.circle")
                    .font(Theme.Typography.text(Theme.Typography.footnote, .semibold))
                    .foregroundColor(Theme.Colors.accent)
                Text("需要你的回答")
                    .font(Theme.Typography.text(Theme.Typography.callout, .semibold))
                    .foregroundColor(Theme.Colors.contentPrimary)
                Spacer(minLength: 0)
                if request.questions.count > 1 {
                    Text("第 \(focusedQuestionIndex + 1)/\(request.questions.count) 题 · Tab/↑↓ 切换")
                        .font(Theme.Typography.text(Theme.Typography.caption))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
            }

            // 题目区：自适应内容高度；超出最大高度时启用内部滚动，未超出时紧凑包裹，消除虚空
            questionsSection

            freeInputBar

            // 按钮行：消极在左、积极在右
            HStack(spacing: Theme.Spacing.lg) {
                DrawerActionButton(title: String(localized: "取消"), shortcut: "ESC", style: .secondary) {
                    ChatInteractionCenter.shared.cancelQuestions()
                }
                Spacer(minLength: 0)
                DrawerActionButton(title: String(localized: "提交答案"), shortcut: "⏎", style: .primary, enabled: canSubmit) {
                    submit()
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.top, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.xl)
        .onPreferenceChange(DrawerQuestionsHeightPreferenceKey.self) { height in
            questionsContentHeight = height
        }
        .onAppear {
            // 抽屉展开时默认不让输入框持焦，确保进入时属于纯键盘盲操模式
            isCustomInputFocused = false
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickShowSubmitUserQuestions)) { _ in
            if canSubmit {
                submit()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickShowNavigateQuestion)) { note in
            guard let step = note.userInfo?["step"] as? Int, !request.questions.isEmpty else { return }
            let total = request.questions.count
            let nextIndex = (focusedQuestionIndex + step + total) % total
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                focusedQuestionIndex = nextIndex
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickShowSelectQuestionOption)) { note in
            guard let index = note.userInfo?["index"] as? Int,
                  focusedQuestionIndex >= 0 && focusedQuestionIndex < request.questions.count else { return }
            let currentQuestion = request.questions[focusedQuestionIndex]
            if index >= 0 && index < currentQuestion.options.count {
                let targetOption = currentQuestion.options[index]
                toggleOption(targetOption.id, for: currentQuestion)
            }
        }
    }

    // MARK: 题目区自适应排版

    private var questionsContent: some View {
        VStack(alignment: .leading, spacing: request.questions.count > 1 ? Theme.Spacing.md : Theme.Spacing.xxxl) {
            ForEach(Array(request.questions.enumerated()), id: \.element.id) { index, question in
                questionBlock(question, index: index)
                    .id(question.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DrawerQuestionsHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        )
    }

    @ViewBuilder
    private var questionsSection: some View {
        Group {
            if questionsContentHeight > AIChatDrawerMetrics.questionsMaxHeight {
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        questionsContent
                    }
                    .frame(height: AIChatDrawerMetrics.questionsMaxHeight)
                    .onChange(of: focusedQuestionIndex) { newIndex in
                        guard newIndex >= 0 && newIndex < request.questions.count else { return }
                        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                            scrollProxy.scrollTo(request.questions[newIndex].id, anchor: .center)
                        }
                    }
                }
            } else {
                questionsContent
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 点击题目区空白处：退出底部输入框焦点，切回选择题盲操模式
            isCustomInputFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    // MARK: 单题区块

    /// 单题：header 短标签（弱化小字 + 单选/多选提示）+ 问题文本 + 选项胶囊流式组。
    /// 多题模式下包裹聚焦容器卡片，未聚焦时去除选项数字标号，聚焦时高亮并显示 1-9 快捷标号。
    private func questionBlock(_ question: UserQuestion, index: Int) -> some View {
        let isMultiQuestion = request.questions.count > 1
        let isFocused = (index == focusedQuestionIndex)

        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                if isMultiQuestion {
                    Text("Q\(index + 1)")
                        .font(Theme.Typography.mono(Theme.Typography.micro, .bold))
                        .foregroundColor(isFocused ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                        .padding(.horizontal, Theme.Spacing.chip)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.inlineCode, style: .continuous)
                                .fill(isFocused ? Theme.Colors.accent.opacity(0.12) : Theme.Colors.surfaceBadge)
                        )
                }
                Text(question.header)
                    .font(Theme.Typography.text(Theme.Typography.caption, .semibold))
                    .foregroundColor(isFocused ? Theme.Colors.contentPrimary : Theme.Colors.contentTertiary)
                    .lineLimit(1)
                Text(question.multiple ? String(localized: "多选") : String(localized: "单选"))
                    .font(Theme.Typography.text(Theme.Typography.micro))
                    .foregroundColor(Theme.Colors.contentTertiary.opacity(0.75))
                Spacer(minLength: 0)
                if isMultiQuestion && isFocused {
                    Text("按 1-9 选答案")
                        .font(Theme.Typography.text(Theme.Typography.micro))
                        .foregroundColor(Theme.Colors.accent.opacity(0.85))
                }
            }

            Text(question.question)
                .font(Theme.Typography.text(Theme.Typography.body))
                .foregroundColor(Theme.Colors.contentPrimary)
                .fixedSize(horizontal: false, vertical: true)

            DrawerOptionFlowLayout(spacing: Theme.Spacing.md) {
                ForEach(Array(question.options.enumerated()), id: \.element.id) { optIndex, option in
                    DrawerOptionCapsule(
                        option: option,
                        prefixNumber: (!isMultiQuestion || isFocused) ? (optIndex + 1) : nil,
                        selected: selections[question.id]?.contains(option.id) == true
                    ) {
                        // 点击选项胶囊：如果输入框持焦则立即释放焦点
                        isCustomInputFocused = false
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        if isMultiQuestion && focusedQuestionIndex != index {
                            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                                focusedQuestionIndex = index
                            }
                        }
                        toggleOption(option.id, for: question)
                    }
                }
            }
        }
        .padding(isMultiQuestion ? Theme.Spacing.lg : 0)
        .background(
            Group {
                if isMultiQuestion {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(isFocused ? Theme.Colors.surfaceCard : Theme.Colors.surfaceInset)
                }
            }
        )
        .overlay(
            Group {
                if isMultiQuestion {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(
                            isFocused ? Theme.Colors.accent.opacity(0.35) : Theme.Colors.cardStroke,
                            lineWidth: isFocused ? 1.0 : 0.5
                        )
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            isCustomInputFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
            if isMultiQuestion && focusedQuestionIndex != index {
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                    focusedQuestionIndex = index
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

    /// 底部统一输入条：自由答案入口（与已选项一并提交）。固定 2 行高度，超出内部滚动。
    /// ⏎ 只换行不提交（TextEditor 默认行为），提交统一走按钮。
    private var freeInputBar: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $customText)
                .focused($isCustomInputFocused)
                .scrollContentBackground(.hidden)
                // 隐藏垂直滚动条：超出 2 行的内容仍可滚轮内部滚动
                .scrollIndicators(.never)
                .font(Theme.Typography.text(Theme.Typography.body))
                .foregroundColor(Theme.Colors.contentPrimary)
                .frame(height: AIChatDrawerMetrics.freeInputHeight)
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
                .fill(isCustomInputFocused ? Theme.Colors.surfaceCard : Theme.Colors.surfaceInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .stroke(
                    isCustomInputFocused ? Theme.Colors.accent.opacity(0.4) : Theme.Colors.cardStroke,
                    lineWidth: isCustomInputFocused ? 1.0 : 0.5
                )
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

// MARK: - 内部高度测量键

private struct DrawerQuestionsHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
