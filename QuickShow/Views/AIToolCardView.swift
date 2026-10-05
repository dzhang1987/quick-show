import AppKit
import SwiftUI

// MARK: - AI 工具调用卡片
//
// 渲染数据源：ChatMessage.toolCalls（[ToolCallRecord]），由 ChatSessionStore 消息更新机制驱动刷新
// （工具执行时 status 实时流转 pending → running → done/failed/denied，本视图无需轮询）。
//
// 视觉原则：完全融入现有聊天气泡体系——
// - 卡片容器与助手文本气泡同款（chatAssistantBubble 底 + cardStroke 0.5pt 描边 + Radius.groupCard），
//   宽度与文本气泡一致（maxWidth .infinity，行内与气泡共用同一可用宽度）
// - 一条助手消息可能发起多个工具调用：一张卡片内多行条目（0.5pt 细线分隔），比多卡更紧凑
// - JSON（参数 / 结果）一律等宽小号渲染，复用 CodeBlockView 的内嵌底语言（surfaceBadge）
// - 本文件严禁新增设计令牌，全部走 DesignTokens 既有值

/// 工具调用卡片：一条助手消息的全部工具调用记录。
struct AIToolCallCardView: View {
    let toolCalls: [ToolCallRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(toolCalls.enumerated()), id: \.element.id) { index, record in
                // 条目间细若游丝的分隔线（与气泡/输入卡同款 0.5pt 语言）
                if index > 0 {
                    Rectangle()
                        .fill(Theme.Colors.cardStroke)
                        .frame(height: Theme.Layout.dividerHeight)
                        .padding(.horizontal, Theme.Spacing.xxl)
                }
                ToolCallRow(record: record)
                    .padding(.horizontal, Theme.Spacing.xxl)
                    .padding(.vertical, Theme.Spacing.xl)
            }
        }
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

// MARK: - 单个工具调用条目

/// 工具行展开态记忆（record.id 键控）：LazyVStack 反实例化重建（滚动回收）时恢复
/// 上次展开态，不回折叠——用户展开过的行高度 300~500pt，回落即 doc 塌缩（连环
/// 塌缩雪崩的贡献源，见 MarkdownImageCache 渲染高度记忆注释）。主线程读写。
private enum ToolCallExpansionMemory {
    private static var expandedById: [String: Bool] = [:]

    static func expanded(for record: ToolCallRecord) -> Bool? {
        expandedById[record.id]
    }

    static func note(_ expanded: Bool, for record: ToolCallRecord) {
        expandedById[record.id] = expanded
    }
}

/// 一条工具调用：头部行（工具名 + 状态徽标 + 展开箭头）常驻，点击展开参数与结果。
/// 默认折叠策略：失败 / 已拒绝默认展开（错误详情直接可见），其余默认折叠保持紧凑；
/// 运行中的条目状态落定到 failed/denied 时自动展开一次，暴露错误。
private struct ToolCallRow: View {
    let record: ToolCallRecord

    /// 展开 / 折叠（参数与结果区）。反实例化重建经 ToolCallExpansionMemory 恢复。
    @State private var expanded: Bool
    /// 长结果（>2000 字符）是否已展开完整内容。
    @State private var showFullResult = false

    /// 结果文本折叠上限：超出部分先截断，由「展开完整结果」释放。
    private static let resultTruncateLimit = 2000
    /// 参数文本展示上限：write_file 等参数可能携带大段内容，卡片内只保留头部。
    private static let argumentsPreviewLimit = 600

    init(record: ToolCallRecord) {
        self.record = record
        // 展开态记忆优先（反实例化重建恢复）；无记忆（首见）用默认策略
        let remembered = ToolCallExpansionMemory.expanded(for: record)
        _expanded = State(initialValue: remembered
            ?? (record.status == .failed || record.status == .denied))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header
            if expanded {
                expandedBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 状态落定到失败 / 拒绝时自动展开（用户无需多点一次才能看到错误）
        .onChange(of: record.status) { status in
            if status == .failed || status == .denied, !expanded {
                setExpanded(true)
            }
        }
    }

    /// 展开态写入口（@State + 外置记忆同步，反实例化重建恢复用）。
    private func setExpanded(_ value: Bool) {
        ToolCallExpansionMemory.note(value, for: record)
        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { expanded = value }
    }

    // MARK: 头部行

    /// 中文展示名：注册表按蛇形名查询；查不到（未知工具 / 旧会话记录）时降级为蛇形名原文。
    /// 查表为 19 项 first 线性查找，渲染期成本可忽略。
    private var displayName: String {
        AIToolRegistry.shared.tool(named: record.name)?.displayName ?? record.name
    }

    private var header: some View {
        Button {
            setExpanded(!expanded)
        } label: {
            HStack(spacing: Theme.Spacing.lg) {
                // 主标题：中文展示名（正文常规字族，中文不走等宽）
                Text(displayName)
                    .font(Theme.Typography.text(12, .medium))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                // 蛇形名降为次要等宽小字：与协议层 / 日志对照用；
                // 主标题已是蛇形名（降级路径）时不重复展示
                if displayName != record.name {
                    Text(record.name)
                        .font(Theme.Typography.mono(10))
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .lineLimit(1)
                }
                ToolStatusBadge(status: record.status)
                Image(systemName: "chevron.right")
                    .font(Theme.Typography.text(9, .semibold))
                    .foregroundColor(Theme.Colors.contentTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "收起详情" : "展开参数与结果")
    }

    // MARK: 展开区（参数 + 结果）

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // ask_user 专属呈现：调参侧显示问过的问题摘要，结果侧显示用户答案
            // （结构化解析失败时回退通用 JSON 块，不丢原文）
            if record.name == AskUserToolPayload.toolName,
               let summary = AskUserToolPayload.parseArguments(record.arguments) {
                AskUserQuestionsBlock(summary: summary)
            } else {
                argumentsBlock
            }
            if let result = record.result {
                if record.name == AskUserToolPayload.toolName {
                    AskUserAnswersBlock(result: result, status: record.status)
                } else {
                    ToolCallResultBlock(
                        result: result,
                        status: record.status,
                        showFullResult: $showFullResult,
                        truncateLimit: Self.resultTruncateLimit
                    )
                }
            }
        }
        .transition(.opacity)
    }

    /// 参数区：JSON 原文等宽小号，超出预览长度截断（完整内容模型侧已持有，卡片只需可辨）。
    private var argumentsBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("参数")
                .font(Theme.Typography.text(10, .semibold))
                .foregroundColor(Theme.Colors.contentTertiary)
            if record.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("（无参数）")
                    .font(Theme.Typography.mono(11))
                    .foregroundColor(Theme.Colors.contentTertiary)
            } else {
                Text(previewText(record.arguments, limit: Self.argumentsPreviewLimit))
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

    /// 截断预览：JSON 美化后超长发省略号。
    private func previewText(_ raw: String, limit: Int) -> String {
        let pretty = ToolJSONText.pretty(raw)
        guard pretty.count > limit else { return pretty }
        return String(pretty.prefix(limit)) + " …"
    }
}

// MARK: - 结果区

/// 结果区：failed/denied 先给一行用户可读错误摘要，再附完整 JSON；
/// JSON 等宽渲染、限高可滚动，超过 2000 字符先截断、可展开完整结果。
private struct ToolCallResultBlock: View {
    let result: String
    let status: ToolCallStatus
    @Binding var showFullResult: Bool
    let truncateLimit: Int

    @State private var hovered = false
    @State private var copied = false

    /// 美化后的完整结果文本。
    private var prettyResult: String { ToolJSONText.pretty(result) }
    /// 是否超长（需折叠 + 展开入口）。
    private var isTruncatable: Bool { prettyResult.count > truncateLimit }
    /// 当前展示的文本（折叠态只取前 2000 字符）。
    private var displayedResult: String {
        if isTruncatable && !showFullResult {
            return String(prettyResult.prefix(truncateLimit)) + " …"
        }
        return prettyResult
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.lg) {
                Text("结果")
                    .font(Theme.Typography.text(10, .semibold))
                    .foregroundColor(Theme.Colors.contentTertiary)
                Spacer(minLength: 0)
                // hover 渐显复制钮（与 CodeBlockView 同一语言）
                if hovered || copied {
                    Button(action: copyResult) {
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
                    .transition(.opacity)
                }
            }
            .frame(minHeight: 14)

            // 失败 / 拒绝：先给一行可读摘要（从 {"ok":false,"error":...} 提取）
            if showsErrorSummary, let error = ToolJSONText.errorMessage(from: result) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    Image(systemName: status == .denied ? "hand.raised" : "xmark.octagon")
                        .font(Theme.Typography.text(10, .semibold))
                    Text(error)
                        .font(Theme.Typography.text(11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(status == .denied
                                 ? Theme.Colors.contentTertiary
                                 : Theme.Colors.statusWarning)
            }

            // 完整 JSON：等宽、限高可滚动
            ScrollView(.vertical, showsIndicators: false) {
                Text(displayedResult)
                    .font(Theme.Typography.mono(11))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.lg)
            }
            .frame(maxHeight: showFullResult ? 260 : 180, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.surfaceBadge)
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
            }

            // 超长结果的展开 / 收起入口
            if isTruncatable {
                Button {
                    withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                        showFullResult.toggle()
                    }
                } label: {
                    Text(showFullResult ? "收起结果" : "展开完整结果（\(prettyResult.count) 字符）")
                        .font(Theme.Typography.text(10, .medium))
                        .foregroundColor(Theme.Colors.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 是否展示错误摘要行（仅失败 / 已拒绝两态）。
    private var showsErrorSummary: Bool {
        status == .failed || status == .denied
    }

    private func copyResult() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prettyResult, forType: .string)
        copied = true
        // 轻反馈：对勾短暂停留后复位
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - 状态徽标

/// 状态徽标：胶囊底 + 图标 + 文案，五态视觉区分——
/// pending 灰「排队中」/ running 强调色 spinner「执行中」/ done 绿「完成」/
/// failed 红「失败」/ denied 灰「已拒绝」。
private struct ToolStatusBadge: View {
    let status: ToolCallStatus

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if status == .running {
                // 执行中：小 spinner（缩到与徽标文字同高）
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: iconName)
                    .font(Theme.Typography.text(9, .semibold))
            }
            Text(label)
                .font(Theme.Typography.text(10, .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
        .overlay(Capsule(style: .continuous).stroke(color.opacity(0.28), lineWidth: 0.5))
    }

    private var label: String {
        switch status {
        case .pending: return "排队中"
        case .running: return "执行中"
        case .done: return "完成"
        case .failed: return "失败"
        case .denied: return "已拒绝"
        }
    }

    private var iconName: String {
        switch status {
        case .pending: return "hourglass"
        case .running: return ""      // spinner 占位，不走图标
        case .done: return "checkmark"
        case .failed: return "xmark"
        case .denied: return "hand.raised"
        }
    }

    private var color: Color {
        switch status {
        case .pending: return Theme.Colors.contentTertiary
        case .running: return Theme.Colors.accent
        case .done: return Theme.Colors.statusGood
        case .failed: return Theme.Colors.statusWarning
        case .denied: return Theme.Colors.contentTertiary
        }
    }
}

// MARK: - JSON 文本辅助

/// 工具调用参数 / 结果的 JSON 文本处理：美化（键排序 + 缩进）与错误摘要提取。
enum ToolJSONText {
    /// JSON 美化：解析成功则按排序键 + 2 空格缩进重排；非 JSON 原文返回。
    static func pretty(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: prettyData, encoding: .utf8) else {
            return raw
        }
        return text
    }

    /// 从统一结果包装 {"ok":false,"error":"..."} 中提取用户可读错误文案。
    static func errorMessage(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? String,
              !error.isEmpty else {
            return nil
        }
        return error
    }
}

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
private struct AskUserQuestionsBlock: View {
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
private struct AskUserAnswersBlock: View {
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
