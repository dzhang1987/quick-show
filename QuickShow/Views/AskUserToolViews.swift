import Foundation
import SwiftUI

// MARK: - ask_user 问答存档（专属呈现）
//
// ask_user 的调用与结果不做通用 JSON 展示：
// - 调参侧 = 问过的问题摘要（问题数 / 每题选项数与单多选）
// - 结果侧 = 用户答案（每题选中项 + 自由输入，紧凑列表）；取消/拒绝 = 「用户取消」
// 解析失败一律回退通用 JSON 块（调用方分支保证），不丢原文。

/// ask_user 调参/结果 JSON 的结构化解析（与 AskUserTool 的序列化格式对齐）。
enum AskUserToolPayload {
    static let toolName = "ask_user"

    /// 单题摘要（参数侧）
    struct QuestionSummary {
        let header: String
        let optionCount: Int
        let multiple: Bool
    }

    /// 单题答案（结果侧）
    struct QuestionAnswerEntry {
        let question: String
        let selected: [String]
        let custom: String
    }

    /// 解析调参：{"questions":[{question,header,options:[...],multiple}]}
    /// 任一题结构不合规即整体失败（回退通用 JSON 块），避免半解析的误导性摘要。
    static func parseArguments(_ raw: String) -> [QuestionSummary]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawQuestions = object["questions"] as? [[String: Any]],
              !rawQuestions.isEmpty else {
            return nil
        }
        var summaries: [QuestionSummary] = []
        for raw in rawQuestions {
            guard let question = raw["question"] as? String,
                  let options = raw["options"] as? [[String: Any]] else {
                return nil
            }
            // header 缺省与工具侧同规则：取问题前 12 字
            let header = (raw["header"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? String(question.prefix(12))
            summaries.append(QuestionSummary(
                header: header,
                optionCount: options.count,
                multiple: (raw["multiple"] as? Bool) ?? false
            ))
        }
        return summaries
    }

    /// 解析结果：{"ok":true,"answers":[{question,selected:[...],custom}]}
    /// ok == false（用户取消）或结构不合规返回 nil（调用方分别走「用户取消」/ 通用块）。
    static func parseAnswers(_ raw: String) -> [QuestionAnswerEntry]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["ok"] as? Bool) == true,
              let rawAnswers = object["answers"] as? [[String: Any]] else {
            return nil
        }
        return rawAnswers.map { raw in
            QuestionAnswerEntry(
                question: (raw["question"] as? String) ?? "",
                selected: (raw["selected"] as? [String]) ?? [],
                custom: ((raw["custom"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// 是否用户取消（{"ok":false,...}；denied 状态同语义）。
    static func isCancelled(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (object["ok"] as? Bool) == false
    }
}

/// 调参侧：问题摘要块（标题层级与通用「参数」块一致，内容换为结构化摘要）。
struct AskUserQuestionsBlock: View {
    let summary: [AskUserToolPayload.QuestionSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("问题摘要")
                .font(Theme.Typography.text(10, .semibold))
                .foregroundColor(Theme.Colors.contentTertiary)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("共 \(summary.count) 个问题")
                    .font(Theme.Typography.text(11, .medium))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                ForEach(Array(summary.enumerated()), id: \.offset) { index, item in
                    Text("\(index + 1). \(item.header)（\(item.optionCount) 个选项 · \(item.multiple ? "多选" : "单选")）")
                        .font(Theme.Typography.mono(11))
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.surfaceBadge)
            )
        }
    }
}

/// 结果侧：用户答案块（每题 = 问题弱化行 + 选中项 + 自由输入）；取消时单行「用户取消」。
struct AskUserAnswersBlock: View {
    let result: String
    let status: ToolCallStatus

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("用户答案")
                .font(Theme.Typography.text(10, .semibold))
                .foregroundColor(Theme.Colors.contentTertiary)

            if status == .denied || AskUserToolPayload.isCancelled(result) {
                // 取消 / 拒绝：单行弱化（与通用 denied 摘要同一语言）
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "hand.raised")
                        .font(Theme.Typography.text(10, .semibold))
                    Text("用户取消")
                        .font(Theme.Typography.text(11))
                }
                .foregroundColor(Theme.Colors.contentTertiary)
            } else if let answers = AskUserToolPayload.parseAnswers(result) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(Array(answers.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(entry.question)
                                .font(Theme.Typography.text(11))
                                .foregroundColor(Theme.Colors.contentTertiary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                            if !entry.selected.isEmpty {
                                HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                                    Image(systemName: "checkmark")
                                        .font(Theme.Typography.text(9, .bold))
                                        .foregroundColor(Theme.Colors.accent)
                                        .padding(.top, 1)
                                    Text(entry.selected.joined(separator: "、"))
                                        .font(Theme.Typography.text(11, .medium))
                                        .foregroundColor(Theme.Colors.contentSecondaryStrong)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if !entry.custom.isEmpty {
                                Text("补充：\(entry.custom)")
                                    .font(Theme.Typography.text(11))
                                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if entry.selected.isEmpty && entry.custom.isEmpty {
                                Text("（未作答）")
                                    .font(Theme.Typography.text(11))
                                    .foregroundColor(Theme.Colors.contentTertiary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                        .fill(Theme.Colors.surfaceBadge)
                )
            } else {
                // ok == true 但 answers 结构异常：回退原文（等宽小号，不丢信息）
                Text(ToolJSONText.pretty(result))
                    .font(Theme.Typography.mono(11))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                            .fill(Theme.Colors.surfaceBadge)
                    )
            }
        }
    }
}