// SubagentTaskTray.swift: 输入框上方浮动的并发专家任务监控托盘。
// 实时展示当前主会话正在后台并发执行的子 Agent 专家、动态动作与脉搏，
// 并支持中途追加输入的轻反馈提示，支持一键点击穿梭至对应子会话。

import AppKit
import SwiftUI

struct SubagentTaskTray: View {
    @ObservedObject var state: AIChatState
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared

    var body: some View {
        let parentSessionId = state.store.currentSessionId
        let activeTasks = parentSessionId != nil ? taskRegistry.runningTasks(parentSessionId: parentSessionId!) : []

        if !activeTasks.isEmpty || state.agentSteeringNotice != nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                // 1. 转发反馈轻提示（当用户追加输入成功分流给某个子 Agent 时显示）
                if let notice = state.agentSteeringNotice {
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
                        Capsule(style: .continuous)
                            .fill(Theme.Colors.accent.opacity(0.12))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Theme.Colors.accent.opacity(0.3), lineWidth: 0.5)
                    )
                    .transition(.opacity.combined(with: .scale(scale: Theme.Motion.toastScale)))
                }

                // 2. 活跃子任务卡片列表
                if !activeTasks.isEmpty {
                    VStack(spacing: Theme.Spacing.xs) {
                        ForEach(activeTasks) { task in
                            SubagentTaskCapsule(task: task) {
                                state.selectSession(id: task.childSessionId)
                            }
                            .transition(.opacity.combined(with: .scale(scale: Theme.Motion.toastScale)))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 单个子任务状态胶囊

private struct SubagentTaskCapsule: View {
    let task: AgentTaskRecord
    let onTap: () -> Void

    @State private var hovered = false

    private var iconName: String {
        switch task.subagentId {
        case "librarian": return "globe"
        case "coder": return "chevron.left.forwardslash.chevron.right"
        case "oracle": return "brain.head.profile"
        case "observer": return "eye"
        case "concierge": return "macbook.and.iphone"
        default: return "person.2.fill"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.md) {
                // 专家图标与指示动效
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: iconName)
                        .font(Theme.Typography.text(11, .semibold))
                        .foregroundColor(Theme.Colors.accent)

                    Text(task.subagentName)
                        .font(Theme.Typography.text(11, .semibold))
                        .foregroundColor(Theme.Colors.accent)
                }

                // 动态脉搏指示器
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 12, height: 12)

                // 实时动作描述
                Text(task.currentAction)
                    .font(Theme.Typography.text(11, .medium))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                // 跳转引导提示
                HStack(spacing: 2) {
                    Text(String(localized: "查看"))
                        .font(Theme.Typography.text(10))
                    Image(systemName: "chevron.right")
                        .font(Theme.Typography.text(8, .bold))
                }
                .foregroundColor(hovered ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                .opacity(hovered ? 1 : 0.6)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                Capsule(style: .continuous)
                    .fill(hovered ? Theme.Colors.iconHoverBg : Theme.Colors.surfaceTrack)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Theme.Colors.chatCapsuleRim, lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                hovered = isHovered
            }
        }
        .help("任务诉求：\(task.taskDescription)\n点击进入该子智能体专属会话，可在输入框追加要求或使用 @\(task.subagentId) 专门沟通。")
    }
}
