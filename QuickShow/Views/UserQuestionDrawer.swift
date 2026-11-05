import SwiftUI

// MARK: - 用户提问抽屉通知事件（全键盘盲操支持）

extension Notification.Name {
    static let quickShowSubmitUserQuestions = Notification.Name("quickShowSubmitUserQuestions")
    static let quickShowSelectQuestionOption = Notification.Name("quickShowSelectQuestionOption")
    static let quickShowNavigateQuestion = Notification.Name("quickShowNavigateQuestion")
    static let quickShowDefocusQuestionCustomInput = Notification.Name("quickShowDefocusQuestionCustomInput")
}

// MARK: - 用户提问抽屉

/// AI 提问面板：每题 = header 短标签 + 问题文本 + 选项胶囊组（末尾内嵌自定义行内胶囊）；
/// 高度纪律：标题行与操作按钮恒可见，题目区走共享 DrawerBodyArea 预算
/// （整抽屉 ≤ 窗口 80%，未超出自适应紧凑包裹，超出锁在预算内滚动）；
/// 单选题严格互斥（选预选项即清空自定义，选自定义即清空预选项）；
/// 自定义输入为空时按 ESC 自动恢复原选中项，无缝退回选择题模式；
/// 数字键在打字模式下 100% 放行，绝不误触选项。
struct UserQuestionDrawerContent: View {
    let request: UserQuestionRequest
    /// 整抽屉高度预算（窗口内容高度的 80%），由 AIChatDrawerPanel 统一注入
    let heightBudget: CGFloat

    /// 各题选中态（question.id → 选中 option id 集合）。
    @State private var selections: [UUID: Set<UUID>] = [:]
    /// 单选题进入自定义前的历史选项记忆（用于取消自定义时秒级恢复，防漏选空提交）。
    @State private var previousSelectionsBeforeCustom: [UUID: Set<UUID>] = [:]
    /// 各题自定义自由文本（question.id → 自定义文本）。
    @State private var customTexts: [UUID: String] = [:]
    /// 当前正在行内编辑自定义的问题 ID（nil 表示无编辑态）。
    @State private var editingQuestionID: UUID? = nil
    /// 当前聚焦的题目索引（用于多题场景下的键盘焦点与数字键 1-9 路由）。
    @State private var focusedQuestionIndex: Int = 0
    /// 行内输入框激活状态。
    @FocusState private var focusedInputIsActive: Bool
    /// 顶部固定区（标题行 + 上留白）实测高度
    @State private var topChromeHeight: CGFloat = 0
    /// 底部固定区（操作按钮 + 下留白）实测高度
    @State private var bottomChromeHeight: CGFloat = 0

    init(request: UserQuestionRequest, heightBudget: CGFloat) {
        self.request = request
        self.heightBudget = heightBudget
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

    /// 题目区可用高度 = 整抽屉预算 − 头尾固定区；
    /// 保底 bodyMinHeight：窗口被压到极小时仍留可读空间（固定区已吃掉大半预算的兜底）。
    private var questionsAvailableHeight: CGFloat {
        max(AIChatDrawerMetrics.bodyMinHeight, heightBudget - topChromeHeight - bottomChromeHeight)
    }

    /// 可提交判据：任一题有选中项，或任一题有非空白自定义内容。
    private var canSubmit: Bool {
        let hasSelection = selections.values.contains { !$0.isEmpty }
        let hasCustom = customTexts.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return hasSelection || hasCustom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 固定区（顶部）：标题行恒可见
            headerRow
                .padding(.bottom, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.xxl)
                .measureDrawerHeight(into: $topChromeHeight)

            // 正文区（题目）：自然高度未超预算紧凑包裹，超出锁在预算内滚动
            questionsSection

            // 固定区（底部）：操作按钮恒可见（消极在左、积极在右）
            actionButtonsRow
                .padding(.top, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xl)
                .measureDrawerHeight(into: $bottomChromeHeight)
        }
        .padding(.horizontal, Theme.Spacing.section)
        .escapeResponder(
            id: "question_custom_input",
            isActive: editingQuestionID != nil
        ) {
            cancelEditingIfEmpty()
            return true
        }
        .onAppear {
            // 抽屉展开时默认不让输入框持焦，确保进入时属于纯键盘盲操模式
            focusedInputIsActive = false
            editingQuestionID = nil
            ChatInteractionCenter.shared.isQuestionInlineEditing = false
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onDisappear {
            ChatInteractionCenter.shared.isQuestionInlineEditing = false
        }
        .onChange(of: editingQuestionID) { newID in
            ChatInteractionCenter.shared.isQuestionInlineEditing = (newID != nil)
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
            cancelEditingIfEmpty()
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                focusedQuestionIndex = nextIndex
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickShowDefocusQuestionCustomInput)) { _ in
            cancelEditingIfEmpty()
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickShowSelectQuestionOption)) { note in
            // 如果当前正处于行内打字编辑状态，坚决放行打字，不响应数字切换
            guard editingQuestionID == nil else { return }

            guard let index = note.userInfo?["index"] as? Int,
                  focusedQuestionIndex >= 0 && focusedQuestionIndex < request.questions.count else { return }
            let currentQuestion = request.questions[focusedQuestionIndex]
            if index >= 0 && index < currentQuestion.options.count {
                let targetOption = currentQuestion.options[index]
                selectOption(targetOption.id, for: currentQuestion)
            } else if index == currentQuestion.options.count {
                // 命中了末尾自定义胶囊（第 N+1 项）
                startEditingCustom(for: currentQuestion, index: focusedQuestionIndex)
            }
        }
    }

    // MARK: 固定区（标题 / 操作）

    /// 标题行：弱化小标题 + 多题计数与切换提示（单题不显示计数）
    private var headerRow: some View {
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
    }

    /// 操作按钮行：消极在左、积极在右
    private var actionButtonsRow: some View {
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

    // MARK: 题目区自适应排版

    private var questionsContent: some View {
        VStack(alignment: .leading, spacing: request.questions.count > 1 ? Theme.Spacing.md : Theme.Spacing.xxxl) {
            ForEach(Array(request.questions.enumerated()), id: \.element.id) { index, question in
                questionBlock(question, index: index)
                    .id(question.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 题目区正文：高度预算由共享 DrawerBodyArea 统一裁决；多题切换时滚动定位到当前题
    private var questionsSection: some View {
        DrawerBodyArea(availableHeight: questionsAvailableHeight) { scrollProxy in
            questionsContent
                .padding(.bottom, Theme.Spacing.xl) // 保留底线充裕内边距与呼吸感
                .onChange(of: focusedQuestionIndex) { newIndex in
                    guard newIndex >= 0 && newIndex < request.questions.count else { return }
                    withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                        scrollProxy.scrollTo(request.questions[newIndex].id, anchor: .center)
                    }
                }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            cancelEditingIfEmpty()
        }
    }

    // MARK: 单题区块

    /// 单题：header 短标签（弱化小字 + 单选/多选提示）+ 问题文本 + 选项胶囊流式组（含行内自定义胶囊）。
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
                        selectOption(option.id, for: question)
                    }
                }

                // 末尾自定义行内胶囊（第 N+1 项，高度与常规胶囊一致，零垂直膨胀）
                DrawerCustomOptionCapsule(
                    prefixNumber: (!isMultiQuestion || isFocused) ? (question.options.count + 1) : nil,
                    customText: Binding(
                        get: { customTexts[question.id] ?? "" },
                        set: { customTexts[question.id] = $0 }
                    ),
                    isEditing: editingQuestionID == question.id,
                    isFocused: $focusedInputIsActive,
                    onStartEditing: {
                        startEditingCustom(for: question, index: index)
                    },
                    onClear: {
                        clearCustomInput(for: question)
                    },
                    onSubmit: {
                        if canSubmit {
                            submit()
                        }
                    },
                    onCancel: {
                        cancelEditingIfEmpty()
                    }
                )
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
            cancelEditingIfEmpty()
            if isMultiQuestion && focusedQuestionIndex != index {
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                    focusedQuestionIndex = index
                }
            }
        }
    }

    // MARK: - 交互与互斥逻辑

    /// 选择常规选项：
    /// 单选下：互斥清空自定义回答与编辑态；
    /// 多选下：toggle 开关态，不影响自定义。
    private func selectOption(_ optionID: UUID, for question: UserQuestion) {
        cancelEditingIfEmpty()

        if let idx = request.questions.firstIndex(where: { $0.id == question.id }),
           request.questions.count > 1 && focusedQuestionIndex != idx {
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                focusedQuestionIndex = idx
            }
        }

        var current = selections[question.id] ?? []
        if question.multiple {
            if current.contains(optionID) {
                current.remove(optionID)
            } else {
                current.insert(optionID)
            }
        } else {
            // 单选严格互斥：选中目标选项，同时彻底清空自定义答案
            current = [optionID]
            customTexts[question.id] = ""
            if editingQuestionID == question.id {
                editingQuestionID = nil
            }
        }
        selections[question.id] = current
    }

    /// 激活自定义输入：
    /// 单选下：清空所有预选选项（严格互斥），并记忆当前选项用于取消时恢复；
    /// 多选下：保留已有选项。
    private func startEditingCustom(for question: UserQuestion, index: Int) {
        if request.questions.count > 1 && focusedQuestionIndex != index {
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                focusedQuestionIndex = index
            }
        }

        // 单选严格互斥：激活自定义即取消所有预选项，同时记忆先前选项以便 ESC 取消时秒级恢复
        if !question.multiple {
            if let current = selections[question.id], !current.isEmpty {
                previousSelectionsBeforeCustom[question.id] = current
            } else if let first = question.options.first {
                previousSelectionsBeforeCustom[question.id] = [first.id]
            }
            selections[question.id] = []
        }

        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
            editingQuestionID = question.id
        }
        ChatInteractionCenter.shared.isQuestionInlineEditing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedInputIsActive = true
        }
    }

    /// 清空某题自定义输入并收起，单选题自动恢复先前的选项
    private func clearCustomInput(for question: UserQuestion) {
        customTexts[question.id] = ""
        ChatInteractionCenter.shared.isQuestionInlineEditing = false
        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
            if editingQuestionID == question.id {
                editingQuestionID = nil
            }
            if !question.multiple {
                if let prev = previousSelectionsBeforeCustom[question.id], !prev.isEmpty {
                    selections[question.id] = prev
                } else if let first = question.options.first {
                    selections[question.id] = [first.id]
                }
            }
        }
        focusedInputIsActive = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// 若当前编辑框为空，失焦收起并恢复单选题先前选中的选项；已有内容时收拢为胶囊态
    private func cancelEditingIfEmpty() {
        focusedInputIsActive = false
        ChatInteractionCenter.shared.isQuestionInlineEditing = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        if let editingID = editingQuestionID {
            let text = customTexts[editingID] ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                    editingQuestionID = nil
                    // 恢复该单选题进入自定义前选中的选项（如推荐项 1），防漏选空提交
                    if let question = request.questions.first(where: { $0.id == editingID }), !question.multiple {
                        if let prev = previousSelectionsBeforeCustom[editingID], !prev.isEmpty {
                            selections[editingID] = prev
                        } else if let first = question.options.first {
                            selections[editingID] = [first.id]
                        }
                    }
                }
            } else {
                // 已有非空内容：按 ESC 退出光标并收拢为选中胶囊态，保持盲操
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                    editingQuestionID = nil
                }
            }
        }
    }

    // MARK: 提交

    /// 提交：按题组装答案集（选中项 + 各题专属自由文本），唤醒逻辑层挂起。
    private func submit() {
        var answers: [UUID: QuestionAnswer] = [:]
        for question in request.questions {
            let custom = (customTexts[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            answers[question.id] = QuestionAnswer(
                selectedOptionIDs: selections[question.id] ?? [],
                customText: custom
            )
        }
        ChatInteractionCenter.shared.submitQuestions(
            UserQuestionResponse(requestID: request.id, answers: answers)
        )
    }
}
