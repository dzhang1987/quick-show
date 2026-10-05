import SwiftUI

// MARK: - 用户提问抽屉

/// AI 提问面板：每题 = header 短标签 + 问题文本 + 选项胶囊组（单选互斥 / 多选开关态）；
/// 底部统一输入条（自由答案，⏎ 只换行不提交，提交统一走按钮）+ 取消/提交按钮。
/// 提交校验：至少一题有选中项、或统一输入条非空，才可提交。
struct UserQuestionDrawerContent: View {
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
