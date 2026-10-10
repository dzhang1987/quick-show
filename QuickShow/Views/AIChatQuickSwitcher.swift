import AppKit
import Combine
import SwiftUI

// MARK: - 快速会话切换与全局搜索面板（Quick Switcher）

/// 居中悬浮的快速会话切换器（Spotlight / Command Palette 风格，默认 ⌘P 唤出）。
/// - 无需展开左侧边栏，不改变窗口尺寸，不破坏中央阅读与输入心流；
/// - 空输入时展示最近活跃会话，默认聚焦于第 2 项（上一个会话），敲击 ⌘P + ⏎ 即可实现极速 A/B 切换；
/// - 输入关键字时支持全文匹配（会话标题 + 历史消息正文），并展示命中消息的上下文摘要；
/// - 全键盘操作闭环：↑/↓/Tab 导航，⏎ 确认跳转，ESC 退出并归还焦点给主输入框；
/// - 键鼠解耦：鼠标滚轮自由滚动不被回弹抗衡，hover 仅展示行级提亮，不抢夺键盘选择索引。
struct AIChatQuickSwitcher: View {
    @ObservedObject var store: ChatSessionStore
    var streamingSessionIds: Set<UUID>
    var unreadSessionIds: Set<UUID>
    let onSelectSession: (UUID) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var selectedIndex = 0
    /// 仅由键盘导航显式触发的滚动目标，滚轮自主滚动时不触发 scrollTo 抗衡
    @State private var scrollToTargetID: UUID?
    @FocusState private var searchFieldFocused: Bool

    private var matches: [ChatSessionStore.SearchMatch] {
        store.searchWithSnippets(searchText)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            
            Rectangle()
                .fill(Theme.Colors.cardStroke)
                .frame(height: Theme.Layout.dividerHeight)

            resultsList
                .frame(maxHeight: 320)

            Rectangle()
                .fill(Theme.Colors.cardStroke)
                .frame(height: Theme.Layout.dividerHeight)

            hintFooter
        }
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Colors.chatNavFloatFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 24, x: 0, y: 12)
        .onAppear {
            initializeSelection()
            DispatchQueue.main.async {
                searchFieldFocused = true
            }
        }
        .onChange(of: searchText) { _ in
            if isSearching {
                selectedIndex = 0
                scrollToTargetID = matches.first?.session.id
            } else {
                initializeSelection()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiChatQuickSwitcherUp)) { _ in
            navigateSelection(direction: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiChatQuickSwitcherDown)) { _ in
            navigateSelection(direction: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiChatQuickSwitcherSelect)) { _ in
            commitCurrentSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiChatQuickSwitcherDelete)) { _ in
            deleteCurrentSelection()
        }
    }

    // MARK: - 顶部搜索框

    private var searchHeader: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Typography.text(13, .medium))
                .foregroundColor(Theme.Colors.accent)

            TextField("快速切换或搜索会话…", text: $searchText)
                .textFieldStyle(.plain)
                .font(Theme.Typography.text(13.5))
                .foregroundColor(Theme.Colors.contentPrimary)
                .focused($searchFieldFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Typography.text(12))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            } else {
                Text("⌘P")
                    .font(Theme.Typography.mono(9.5))
                    .foregroundColor(Theme.Colors.idleText)
                    .padding(.horizontal, Theme.Spacing.chip)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(Theme.Colors.surfaceBadge)
                    )
            }
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.lg)
    }

    // MARK: - 结果列表

    private var resultsList: some View {
        ScrollViewReader { proxy in
            if matches.isEmpty {
                VStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                        .font(Theme.Typography.text(18))
                        .foregroundColor(Theme.Colors.idleText)
                        .padding(.top, Theme.Spacing.xl)
                    Text("未找到匹配的会话")
                        .font(Theme.Typography.text(12))
                        .foregroundColor(Theme.Colors.idleText)
                        .padding(.bottom, Theme.Spacing.xl)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: Theme.Spacing.xxs) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                            let isSelected = index == selectedIndex
                            let isCurrent = match.session.id == store.currentSessionId
                            let isStreaming = streamingSessionIds.contains(match.session.id)
                            let isUnread = unreadSessionIds.contains(match.session.id)

                            SwitcherRow(
                                match: match,
                                isSelected: isSelected,
                                isCurrent: isCurrent,
                                isStreaming: isStreaming,
                                isUnread: isUnread,
                                onSelect: {
                                    onSelectSession(match.session.id)
                                    onDismiss()
                                }
                            )
                            .id(match.session.id)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.sm)
                }
                .onChange(of: scrollToTargetID) { targetId in
                    guard let targetId else { return }
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(targetId, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - 底部快捷键提示条

    private var hintFooter: some View {
        HStack(spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.xs) {
                keyCap("↑")
                keyCap("↓")
                Text("选择")
                    .font(Theme.Typography.text(10))
                    .foregroundColor(Theme.Colors.idleText)
            }

            HStack(spacing: Theme.Spacing.xs) {
                keyCap("⏎")
                Text("切换")
                    .font(Theme.Typography.text(10))
                    .foregroundColor(Theme.Colors.idleText)
            }

            HStack(spacing: Theme.Spacing.xs) {
                keyCap("⌃D")
                Text("删除")
                    .font(Theme.Typography.text(10))
                    .foregroundColor(Theme.Colors.idleText)
            }

            HStack(spacing: Theme.Spacing.xs) {
                keyCap("esc")
                Text("关闭")
                    .font(Theme.Typography.text(10))
                    .foregroundColor(Theme.Colors.idleText)
            }

            Spacer(minLength: 0)

            if !matches.isEmpty {
                Text("\(matches.count) 个会话")
                    .font(Theme.Typography.mono(9.5))
                    .foregroundColor(Theme.Colors.idleText)
            }
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Colors.surfaceInset)
    }

    private func keyCap(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.mono(9.5, .medium))
            .foregroundColor(Theme.Colors.contentSecondaryStrong)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Theme.Colors.surfaceBadge)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Theme.Colors.cardStroke, lineWidth: 0.5)
            )
    }

    // MARK: - 交互控制

    private func initializeSelection() {
        if matches.count >= 2 {
            selectedIndex = 1
            scrollToTargetID = matches[1].session.id
        } else {
            selectedIndex = 0
            scrollToTargetID = matches.first?.session.id
        }
    }

    private func navigateSelection(direction: Int) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        selectedIndex = (selectedIndex + direction + count) % count
        scrollToTargetID = matches[selectedIndex].session.id
    }

    private func commitCurrentSelection() {
        guard matches.indices.contains(selectedIndex) else { return }
        let targetId = matches[selectedIndex].session.id
        onSelectSession(targetId)
        onDismiss()
    }

    private func deleteCurrentSelection() {
        guard matches.indices.contains(selectedIndex) else { return }
        let targetId = matches[selectedIndex].session.id
        withAnimation(.easeOut(duration: 0.15)) {
            store.deleteSession(id: targetId)
        }
        let remainingCount = max(0, matches.count - 1)
        if remainingCount > 0 {
            selectedIndex = min(selectedIndex, remainingCount - 1)
            DispatchQueue.main.async {
                if matches.indices.contains(selectedIndex) {
                    scrollToTargetID = matches[selectedIndex].session.id
                }
            }
        } else {
            selectedIndex = 0
            scrollToTargetID = nil
        }
    }
}

// MARK: - 单行视图

private struct SwitcherRow: View {
    let match: ChatSessionStore.SearchMatch
    let isSelected: Bool
    let isCurrent: Bool
    let isStreaming: Bool
    let isUnread: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Theme.Spacing.md) {
                // 左侧状态指示
                leadingIndicator

                // 中间主信息区（标题与消息摘录）
                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(match.session.title)
                            .font(Theme.Typography.text(12.5, isSelected ? .medium : .regular))
                            .foregroundColor(isSelected || isHovered ? Theme.Colors.contentPrimary : Theme.Colors.contentSecondaryStrong)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if isCurrent {
                            Text("当前")
                                .font(Theme.Typography.text(9.5, .medium))
                                .foregroundColor(Theme.Colors.accent)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Theme.Colors.accent.opacity(0.12))
                                )
                        }
                    }

                    if let snippet = match.matchedSnippet {
                        HStack(spacing: 3) {
                            Image(systemName: "text.quote")
                                .font(Theme.Typography.text(9))
                                .foregroundColor(Theme.Colors.accent.opacity(0.8))
                            Text(snippet)
                                .font(Theme.Typography.text(10.5))
                                .foregroundColor(Theme.Colors.contentTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else if let lastMsg = match.session.messages.last?.content {
                        let preview = lastMsg
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !preview.isEmpty {
                            Text(preview)
                                .font(Theme.Typography.text(10.5))
                                .foregroundColor(Theme.Colors.idleText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }

                Spacer(minLength: 4)

                // 右侧时间与未读指示
                HStack(spacing: Theme.Spacing.xs) {
                    if isUnread {
                        Circle()
                            .fill(Theme.Colors.accent)
                            .frame(width: 5, height: 5)
                    }

                    Text(formatRelativeDate(match.session.updatedAt))
                        .font(Theme.Typography.text(10))
                        .foregroundColor(Theme.Colors.idleText)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, match.matchedSnippet != nil ? 7.5 : 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.previewCapsule, style: .continuous)
                    .fill(
                        isSelected
                            ? Theme.Colors.accent.opacity(0.14)
                            : (isHovered ? Theme.Colors.surfaceButton : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if match.session.pinned {
            Image(systemName: "pin.fill")
                .font(Theme.Typography.text(9.5))
                .foregroundColor(Theme.Colors.accent.opacity(0.85))
                .frame(width: 14)
        } else if isStreaming {
            Circle()
                .fill(Theme.Colors.accent)
                .frame(width: 6, height: 6)
                .frame(width: 14)
        } else {
            Image(systemName: "bubble.left")
                .font(Theme.Typography.text(10.5))
                .foregroundColor(isSelected ? Theme.Colors.contentPrimary : Theme.Colors.idleText)
                .frame(width: 14)
        }
    }

    private func formatRelativeDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return String(localized: "昨天")
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d"
            return formatter.string(from: date)
        }
    }
}
