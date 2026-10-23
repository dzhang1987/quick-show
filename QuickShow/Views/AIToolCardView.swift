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
        EmbeddedToolCallListView(toolCalls: toolCalls)
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

/// 内嵌式工具调用列表：专供 AgentProcessDisclosureView 等复合容器内嵌渲染。
/// 消除独立外层大白底卡片与硬边框，直接融入父级背景。
struct EmbeddedToolCallListView: View {
    let toolCalls: [ToolCallRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(toolCalls.enumerated()), id: \.element.id) { index, record in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.Colors.cardStroke.opacity(0.6))
                        .frame(height: Theme.Layout.dividerHeight)
                        .padding(.horizontal, Theme.Spacing.md)
                }
                ToolCallRow(record: record)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 单个工具调用条目

/// 工具行展开态记忆（record.id 键控）：LazyVStack 反实例化重建（滚动回收）时恢复
/// 上次展开态，不回折叠——用户展开过的行高度 300~500pt，回落即 doc 塌缩（连环
/// 塌缩雪崩的贡献源，见 MarkdownImageCache 渲染高度记忆注释）。主线程读写。
enum ToolCallExpansionMemory {
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
struct ToolCallRow: View {
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
            HStack(spacing: Theme.Spacing.md) {
                // 主标题：中文展示名（正文常规字族，字号与色阶更克制）
                Text(displayName)
                    .font(Theme.Typography.text(11.5, .medium))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
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
                if let taskId = extractTaskId(from: record), let uuid = UUID(uuidString: taskId) {
                    Button {
                        ChatSessionStore.shared.currentSessionId = uuid
                    } label: {
                        HStack(spacing: 3) {
                            Text("查看子会话")
                                .font(Theme.Typography.text(10, .medium))
                            Image(systemName: "arrow.up.right.square")
                                .font(Theme.Typography.text(9))
                        }
                        .foregroundColor(Theme.Colors.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.Colors.accent.opacity(0.12))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("切换到该子智能体的独立会话")
                }
                ToolStatusBadge(status: record.status)
                Image(systemName: "chevron.right")
                    .font(Theme.Typography.text(8, .semibold))
                    .foregroundColor(Theme.Colors.contentTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? String(localized: "收起详情") : String(localized: "展开参数与结果"))
    }

    private func extractTaskId(from record: ToolCallRecord) -> String? {
        guard let result = record.result, let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["task_id"] as? String
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
                Text(record.status == .pending ? "（正在组织调度参数…）" : "（无参数）")
                    .font(Theme.Typography.mono(11))
                    .foregroundColor(Theme.Colors.contentTertiary)
            } else {
                Text(previewText(record.arguments, limit: Self.argumentsPreviewLimit))
                    .font(Theme.Typography.mono(11))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Layout.chatCodeBlockPaddingH)
                    .padding(.vertical, Theme.Layout.chatCodeBlockPaddingV)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
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
            Text("结果")
                .font(Theme.Typography.text(10, .semibold))
                .foregroundColor(Theme.Colors.contentTertiary)

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

            // 完整 JSON：等宽、限高可滚动（结构与普通代码块一致：Header 行 + Content 垂直流）
            VStack(alignment: .leading, spacing: Theme.Layout.chatCodeBlockHeaderGap) {
                HStack(spacing: Theme.Spacing.lg) {
                    Text("json")
                        .font(Theme.Typography.mono(10, .semibold))
                        .foregroundColor(Theme.Colors.contentTertiary)
                    Spacer(minLength: 0)
                    CodeCopyButton(textToCopy: { prettyResult }, isHovered: hovered)
                }
                .frame(minHeight: 14)

                AdaptiveScrollBox(
                    axes: .vertical,
                    maxHeight: showFullResult ? 260 : Theme.Layout.chatMetaBlockMaxHeight,
                    showsIndicators: false
                ) {
                    Text(displayedResult)
                        .font(Theme.Typography.mono(11))
                        .foregroundColor(Theme.Colors.contentSecondaryStrong)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Layout.chatCodeBlockPaddingH)
            .padding(.vertical, Theme.Layout.chatCodeBlockPaddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
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
                    Text(showFullResult ? String(localized: "收起结果") : String(localized: "展开完整结果（\(prettyResult.count) 字符）"))
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
}

// MARK: - 状态徽标

/// 状态徽标：五态视觉区分——
/// pending 灰「排队中」/ running 强调色 spinner「执行中」/ done 极简灰「完成」/
/// failed 警示色「失败」/ denied 灰「已拒绝」。
/// 成功态降噪：去除亮绿底胶囊与描边，避免多工具列表形成刺眼的排状绿灯。
struct ToolStatusBadge: View {
    let status: ToolCallStatus

    /// 是否为静默状态（成功态/排队态降噪：无药丸边框与亮色底，融入背景）
    private var isQuiet: Bool {
        status == .done || status == .pending || status == .denied
    }

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
                    .font(Theme.Typography.text(8.5, .semibold))
            }
            Text(label)
                .font(Theme.Typography.text(10, .regular))
        }
        .foregroundColor(color)
        .padding(.horizontal, isQuiet ? Theme.Spacing.xs : Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xxs)
        .background {
            if !isQuiet {
                Capsule(style: .continuous).fill(color.opacity(0.12))
            }
        }
        .overlay {
            if !isQuiet {
                Capsule(style: .continuous).stroke(color.opacity(0.28), lineWidth: 0.5)
            }
        }
    }

    private var label: String {
        switch status {
        case .pending: return String(localized: "排队中")
        case .running: return String(localized: "执行中")
        case .done: return String(localized: "完成")
        case .failed: return String(localized: "失败")
        case .denied: return String(localized: "已拒绝")
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
        case .done: return Theme.Colors.contentTertiary
        case .failed: return Theme.Colors.statusWarning
        case .denied: return Theme.Colors.contentTertiary
        }
    }
}
