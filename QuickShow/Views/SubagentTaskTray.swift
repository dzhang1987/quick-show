// SubagentTaskTray.swift: 输入框上方浮动的并发专家任务监控托盘。
// 实时展示当前主会话正在后台并发执行的子 Agent 专家、动态动作与脉搏，
// 并支持中途追加输入的轻反馈提示，支持一键点击穿梭至对应子会话。

import AppKit
import SwiftUI

struct SubagentTaskTray: View {
    @ObservedObject var state: AIChatState
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared

    private var currentSession: ChatSession? {
        state.store.currentSession
    }

    private var isChildSession: Bool {
        currentSession?.parentSessionId != nil
    }

    private var rootSessionId: UUID? {
        currentSession?.parentSessionId ?? state.store.currentSessionId
    }

    var body: some View {
        // 仅在有活跃的后台子任务运行，或有转发转向提示时显示托盘
        let activeTasks = rootSessionId != nil ? taskRegistry.runningTasks(parentSessionId: rootSessionId!) : []
        let otherActiveTasks = isChildSession ? activeTasks.filter { $0.childSessionId != currentSession?.id } : activeTasks

        let hasContent = !otherActiveTasks.isEmpty || state.agentSteeringNotice != nil

        if hasContent {
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

                // 2. 活跃子任务卡片列表（在子会话展示其他后台同伴；在主会话展示所有并发任务）
                if !otherActiveTasks.isEmpty {
                    VStack(spacing: Theme.Spacing.xs) {
                        ForEach(otherActiveTasks) { task in
                            SubagentTaskCapsule(
                                task: task,
                                onTap: {
                                    state.selectSession(id: task.childSessionId)
                                },
                                onAbort: {
                                    withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                                        AgentCoordinator.shared.abortSubagent(childSessionId: task.childSessionId)
                                    }
                                }
                            )
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
    var onAbort: (() -> Void)? = nil

    @State private var hovered = false
    @State private var isCloseHovered = false

    private var iconName: String {
        AgentRoleRegistry.shared.trayIcon(for: task.subagentId, fallback: "person.2.fill")
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // 主体区域：点击进入子会话
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 悬停时显现的中止/清理微按钮（对齐 QueuedMessageCardRow 设计语言）
            if hovered {
                Button {
                    onAbort?()
                } label: {
                    Image(systemName: "xmark")
                        .font(Theme.Typography.text(9, .bold))
                        .foregroundColor(isCloseHovered ? Theme.Colors.contentPrimary : Theme.Colors.contentTertiary)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle()
                                .fill(isCloseHovered ? Theme.Colors.iconHoverBg : Theme.Colors.surfaceTrack)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isCloseHovered = $0 }
                .help("中止并清理此子任务")
                .transition(.opacity.combined(with: .scale(scale: Theme.Motion.toastScale)))
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            ZStack {
                // 100% 实底垫底，彻底物理阻断下层正文 Markdown 文字透出
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
                .strokeBorder(hovered ? Theme.Colors.accent.opacity(0.4) : Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
        .contentShape(Capsule(style: .continuous))
        .onHover { isHovered in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                hovered = isHovered
            }
        }
        .contextMenu {
            Button("查看子会话详情") {
                onTap()
            }
            Divider()
            Button(role: .destructive) {
                onAbort?()
            } label: {
                Label("中止子任务", systemImage: "xmark.circle")
            }
        }
        .help("任务诉求：\(task.taskDescription)\n点击进入该子智能体专属会话，可在输入框追加要求或使用 @\(task.subagentId) 专门沟通。")
    }
}
