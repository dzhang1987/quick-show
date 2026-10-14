// SubagentTopNavBar.swift: 子智能体会话专用的极简顶栏导航。
// 遵循 macOS 原生克制美学，左侧极简返回，居中展示当前子任务真实诉求并支持极速下拉/快捷键切换。

import AppKit
import SwiftUI

struct SubagentTopNavBar: View {
    @ObservedObject var state: AIChatState
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared

    let onNavigateUp: () -> Void
    let onSelectPeer: (UUID) -> Void

    @State private var isBackHovered = false

    private var currentSession: ChatSession? {
        state.store.currentSession
    }

    private var peerSessions: [ChatSession] {
        guard let current = currentSession,
              let parentId = current.parentSessionId else { return [] }
        return state.store.childSessions(of: parentId)
    }

    private var currentIndex: Int {
        guard let current = currentSession else { return 0 }
        return peerSessions.firstIndex(where: { $0.id == current.id }) ?? 0
    }

    private var currentTopic: String {
        guard let current = currentSession else { return String(localized: "子智能体") }
        return taskTopic(for: current)
    }

    private var currentIconName: String {
        guard let current = currentSession else { return "person.2.fill" }
        if let agentId = current.agentId, let agent = AIAgentStore.shared.agent(for: agentId) {
            return agent.iconName
        }
        let task = taskRegistry.task(childSessionId: current.id)
        switch task?.subagentId {
        case "librarian": return "globe"
        case "coder": return "chevron.left.forwardslash.chevron.right"
        case "oracle": return "brain.head.profile"
        case "observer": return "eye"
        case "concierge": return "macbook.and.iphone"
        default: return "sparkles"
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // 1. 左侧：极简返回主会话（纯原生风格，带轻 hover 底与快捷键指示）
            Button(action: onNavigateUp) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(Theme.Typography.text(11, .bold))
                    Text("主会话")
                        .font(Theme.Typography.text(11, .medium))
                    Text("⌘↑")
                        .font(Theme.Typography.text(9, .medium))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
                .foregroundColor(isBackHovered ? Theme.Colors.contentPrimary : Theme.Colors.contentSecondaryStrong)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isBackHovered ? Theme.Colors.iconHoverBg : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isBackHovered = $0 }
            .help("返回主 Agent 会话 (⌘↑)")

            Spacer(minLength: 0)

            // 2. 中间：当前子任务紧凑标题与原生下拉切换菜单
            Menu {
                ForEach(Array(peerSessions.enumerated()), id: \.element.id) { index, peer in
                    let isCurrent = peer.id == currentSession?.id
                    Button {
                        onSelectPeer(peer.id)
                    } label: {
                        let topic = taskTopic(for: peer)
                        Text("\(isCurrent ? "✓ " : "")\(index + 1). \(topic)")
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: currentIconName)
                        .font(Theme.Typography.text(10, .medium))
                        .foregroundColor(Theme.Colors.accent)

                    Text(currentTopic)
                        .font(Theme.Typography.text(11, .semibold))
                        .foregroundColor(Theme.Colors.contentPrimary)
                        .lineLimit(1)

                    if peerSessions.count > 1 {
                        Text("(\(currentIndex + 1)/\(peerSessions.count))")
                            .font(Theme.Typography.text(10, .medium))
                            .foregroundColor(Theme.Colors.contentTertiary)

                        Image(systemName: "chevron.down")
                            .font(Theme.Typography.text(8, .bold))
                            .foregroundColor(Theme.Colors.contentTertiary)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.Colors.surfaceTrack.opacity(0.8))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Theme.Colors.chatCapsuleRim, lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("同级子智能体列表 (点击切换，或使用 ⌘← / ⌘→)")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.card)
        .frame(height: Theme.Layout.chatTopBarHeight)
    }

    // MARK: - 提取子任务真实核心诉求（杜绝一律显示“知识检索”等空洞重名）

    private func taskTopic(for session: ChatSession) -> String {
        let task = taskRegistry.task(childSessionId: session.id)
        let agentName = task?.subagentName ?? AIAgentStore.shared.agent(for: session.agentId ?? "")?.name ?? "子专家"
        let rawDesc = task?.taskDescription ?? session.title
        let topic = ChatSessionStore.summarizeTitle(from: rawDesc, maxLength: 10, fallback: agentName)
        if topic == agentName || topic.isEmpty {
            return agentName
        }
        return "\(agentName) · \(topic)"
    }
}
