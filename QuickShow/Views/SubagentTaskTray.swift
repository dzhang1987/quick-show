// SubagentTaskTray.swift: 输入坞左上方浮动的并发专家任务监控与穿梭面板。
// 参考 opencode 现代 AI 交互哲学设计：
// 1. 收起态：极致收敛为极简药丸胶囊 [⬡ N subagents]，悬浮在输入坞左上方，不侵占阅读与打字视口；
// 2. 展开态：点击向上优雅弹出 Subagents 任务卡片，清晰呈现并发专家的专属角色、任务诉求、运行状态与穿透箭头；
// 3. 历史可追溯：子任务完成后不销毁，只要当前会话存在派生的子专家，随时可一键展开穿梭回溯；
// 4. 转向提示：当用户中途追加指令分流时，保持 3 秒轻量 Toast 气泡反馈。

import AppKit
import SwiftUI

// MARK: - 统一子智能体展示模型

struct SubagentDisplayItem: Identifiable, Equatable {
    let id: UUID // childSessionId
    let subagentId: String
    let subagentName: String
    let title: String
    let isRunning: Bool
    let currentAction: String?
    let taskRecord: AgentTaskRecord?

    static func == (lhs: SubagentDisplayItem, rhs: SubagentDisplayItem) -> Bool {
        lhs.id == rhs.id
            && lhs.isRunning == rhs.isRunning
            && lhs.currentAction == rhs.currentAction
            && lhs.title == rhs.title
    }
}

// MARK: - 主托盘容器

struct SubagentTaskTray: View {
    @ObservedObject var state: AIChatState
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared

    @State private var isExpanded: Bool = false

    private var currentSession: ChatSession? {
        state.store.currentSession
    }

    private var isChildSession: Bool {
        currentSession?.parentSessionId != nil
    }

    private var rootSessionId: UUID? {
        currentSession?.parentSessionId ?? state.store.currentSessionId
    }

    /// 聚合当前主会话下的所有子智能体项（包括运行中的活跃任务与已落盘的子会话）
    private var subagentItems: [SubagentDisplayItem] {
        guard let rootId = rootSessionId else { return [] }

        let activeTasks = taskRegistry.runningTasks(parentSessionId: rootId)
        let childSessions = state.store.childSessions(of: rootId)

        var result: [SubagentDisplayItem] = []
        var seenIds = Set<UUID>()

        // 1. 优先从 childSessions 恢复（保持原始派发顺序与历史记录）
        for session in childSessions {
            seenIds.insert(session.id)
            let active = activeTasks.first { $0.childSessionId == session.id }
            let isRunning = active != nil || session.taskStatus == .running
            let agentId = session.agentId ?? active?.subagentId ?? "orchestrator"
            let agentName = AIAgentStore.shared.agent(for: agentId)?.name ?? active?.subagentName ?? String(localized: "智能体专家")
            let title = (active?.taskDescription.isEmpty == false) ? active!.taskDescription : session.title

            result.append(SubagentDisplayItem(
                id: session.id,
                subagentId: agentId,
                subagentName: agentName,
                title: title,
                isRunning: isRunning,
                currentAction: active?.currentAction,
                taskRecord: active
            ))
        }

        // 2. 补齐刚刚启动但尚未完全写入 childSessions 的活跃任务
        for task in activeTasks where !seenIds.contains(task.childSessionId) {
            result.append(SubagentDisplayItem(
                id: task.childSessionId,
                subagentId: task.subagentId,
                subagentName: task.subagentName,
                title: task.taskDescription,
                isRunning: true,
                currentAction: task.currentAction,
                taskRecord: task
            ))
        }

        return result
    }

    private var hasRunning: Bool {
        subagentItems.contains { $0.isRunning }
    }

    var body: some View {
        let items = subagentItems
        let hasNotice = state.agentSteeringNotice != nil
        let hasSubagents = !items.isEmpty

        if hasNotice || hasSubagents {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // 1. 转向反馈轻提示（当用户追加输入成功分流给某个子 Agent 时浮现，3 秒后自动淡出）
                if let notice = state.agentSteeringNotice {
                    steeringNoticeView(notice: notice)
                }

                // 2. 展开态：向上滑出的 Subagents 抽屉卡片面板（参考 opencode 截图 2）
                if isExpanded && hasSubagents {
                    SubagentsDrawerCard(
                        items: items,
                        currentSessionId: currentSession?.id,
                        onSelect: { childId in
                            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                                isExpanded = false
                            }
                            state.selectSession(id: childId)
                        },
                        onAbort: { childId in
                            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                                AgentCoordinator.shared.abortSubagent(childSessionId: childId)
                            }
                        },
                        onClose: {
                            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                                isExpanded = false
                            }
                        }
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                }

                // 3. 收起态：输入坞左上方极简药丸胶囊 [⬡ N subagents]（参考 opencode 截图 1）
                if hasSubagents {
                    SubagentsPillButton(
                        count: items.count,
                        hasRunning: hasRunning,
                        isExpanded: isExpanded,
                        onTap: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                isExpanded.toggle()
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - 转向反馈轻气泡
    @ViewBuilder
    private func steeringNoticeView(notice: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(Theme.Typography.text(10, .bold))
                .foregroundColor(Theme.Colors.accent)
            Text(notice)
                .font(Theme.Typography.text(11, .medium))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            ZStack {
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                Capsule(style: .continuous)
                    .fill(Theme.Colors.chatNavFloatFill)
                Capsule(style: .continuous)
                    .fill(Theme.Colors.accent.opacity(0.12))
            }
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Theme.Colors.accent.opacity(0.3), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .scale(scale: Theme.Motion.toastScale)))
    }
}

// MARK: - 极简药丸胶囊按钮 (SubagentsPillButton)

private struct SubagentsPillButton: View {
    let count: Int
    let hasRunning: Bool
    let isExpanded: Bool
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.xs) {
                // 专属多边形网格图标或运行中微型脉搏
                if hasRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "circle.grid.2x2.fill")
                        .font(Theme.Typography.text(10, .semibold))
                        .foregroundColor(Theme.Colors.accent)
                }

                Text("\(count) subagents")
                    .font(Theme.Typography.text(11, .medium))
                    .foregroundColor(hovered ? Theme.Colors.contentPrimary : Theme.Colors.contentSecondaryStrong)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(Theme.Typography.text(8, .bold))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 4.5)
            .background(
                ZStack {
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                    Capsule(style: .continuous)
                        .fill(Theme.Colors.chatNavFloatFill)
                    if hovered {
                        Capsule(style: .continuous)
                            .fill(Theme.Colors.iconHoverBg)
                    }
                }
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(hovered ? Theme.Colors.accent.opacity(0.35) : Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(Theme.Shadow.dockContactOpacity * 0.5), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                hovered = isHovering
            }
        }
        .help(isExpanded ? String(localized: "收起并发子任务") : String(localized: "展开并发子任务列表"))
    }
}

// MARK: - 展开态：抽屉卡片面板 (SubagentsDrawerCard)

private struct SubagentsDrawerCard: View {
    let items: [SubagentDisplayItem]
    let currentSessionId: UUID?
    let onSelect: (UUID) -> Void
    let onAbort: (UUID) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部标题行
            HStack {
                Text(String(localized: "Subagents"))
                    .font(Theme.Typography.text(12, .semibold))
                    .foregroundColor(Theme.Colors.contentPrimary)

                Text("(\(items.count))")
                    .font(Theme.Typography.text(11, .medium))
                    .foregroundColor(Theme.Colors.contentTertiary)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(Theme.Typography.text(9, .bold))
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .fill(Theme.Colors.surfaceTrack)
                        )
                }
                .buttonStyle(.plain)
                .help(String(localized: "收起"))
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)

            Rectangle()
                .fill(Theme.Colors.cardStroke.opacity(0.6))
                .frame(height: Theme.Layout.dividerHeight)

            // 子任务滚动列表（限高最大 240pt）
            ScrollView(.vertical, showsIndicators: items.count > 4) {
                VStack(spacing: 1) {
                    ForEach(items) { item in
                        SubagentItemRow(
                            item: item,
                            isCurrent: item.id == currentSessionId,
                            onTap: { onSelect(item.id) },
                            onAbort: { onAbort(item.id) }
                        )
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
            .frame(maxHeight: 240)
        }
        .frame(maxWidth: 340)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.Colors.chatNavFloatFill)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(Theme.Shadow.dockContactOpacity * 1.5), radius: 6, y: 3)
        .shadow(color: .black.opacity(Theme.Shadow.dockAmbientOpacity * 1.5), radius: 12, y: 6)
    }
}

// MARK: - 单个子智能体任务列表行 (SubagentItemRow)

private struct SubagentItemRow: View {
    let item: SubagentDisplayItem
    let isCurrent: Bool
    let onTap: () -> Void
    let onAbort: () -> Void

    @State private var hovered = false
    @State private var abortHovered = false

    private var iconName: String {
        AgentRoleRegistry.shared.trayIcon(for: item.subagentId, fallback: "sparkles")
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.sm) {
                // 1. 角色图标底座
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.Colors.accent.opacity(0.12))
                        .frame(width: 24, height: 24)

                    Image(systemName: iconName)
                        .font(Theme.Typography.text(11, .semibold))
                        .foregroundColor(Theme.Colors.accent)
                }

                // 2. 标题与动作状态
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(item.title)
                            .font(Theme.Typography.text(11.5, .medium))
                            .foregroundColor(Theme.Colors.contentPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if isCurrent {
                            Text(String(localized: "当前"))
                                .font(Theme.Typography.text(9, .semibold))
                                .foregroundColor(Theme.Colors.accent)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Theme.Colors.accent.opacity(0.12))
                                .cornerRadius(3)
                        }
                    }

                    if let action = item.currentAction, item.isRunning {
                        Text(action)
                            .font(Theme.Typography.text(10))
                            .foregroundColor(Theme.Colors.contentTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: Theme.Spacing.sm)

                // 3. 运行中指示 / 中止 / 穿透箭头
                if item.isRunning {
                    if hovered {
                        Button(action: onAbort) {
                            Image(systemName: "xmark")
                                .font(Theme.Typography.text(8, .bold))
                                .foregroundColor(abortHovered ? Theme.Colors.contentPrimary : Theme.Colors.contentTertiary)
                                .frame(width: 16, height: 16)
                                .background(
                                    Circle()
                                        .fill(abortHovered ? Theme.Colors.iconHoverBg : Theme.Colors.surfaceTrack)
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { abortHovered = $0 }
                        .help(String(localized: "中止该子任务"))
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.65)
                            .frame(width: 12, height: 12)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(Theme.Typography.text(9, .semibold))
                    .foregroundColor(hovered ? Theme.Colors.accent : Theme.Colors.contentTertiary.opacity(0.6))
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered ? Theme.Colors.iconHoverBg : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                hovered = isHovering
            }
        }
    }
}
