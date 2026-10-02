import SwiftUI

// MARK: - 布局常量（AI 窗专属，未入全局令牌）

enum AIChatLayout {
    /// 会话窄栏宽度（AIWindowManager 窗口加宽联动也引用此值）。
    static let sidebarWidth: CGFloat = 216
}

// MARK: - 会话窄栏

/// 左侧会话栏：顶部搜索框（⌘F 聚焦）→ 分组列表（置顶/今天/昨天/过去 7 天/更早）→ 底部新对话。
/// 搜索态切换为扁平结果列表；无会话/无结果各有空态文案。
struct AIChatSidebarView: View {
    @ObservedObject var store: ChatSessionStore
    /// ⌘F 聚焦令牌：父视图递增，本栏观察变化后聚焦搜索框。
    var searchFocusRequest: Int
    /// 重命名进行中的会话 id（父视图持有：ESC 优先取消重命名而非关窗）。
    @Binding var renamingSessionId: UUID?
    let onSelect: (UUID) -> Void
    let onNewSession: () -> Void

    @State private var searchText = ""
    @State private var renamingText = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.top, Theme.Spacing.xxl)
                .padding(.bottom, Theme.Spacing.lg)

            sessionList

            // 底部新对话按钮
            Rectangle()
                .fill(Theme.Colors.cardStroke)
                .frame(height: Theme.Layout.dividerHeight)
            Button(action: onNewSession) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "plus")
                        .font(Theme.Typography.text(11, .semibold))
                    Text("新对话")
                        .font(Theme.Typography.text(12, .medium))
                    Spacer(minLength: 0)
                    Text("⌘N")
                        .font(Theme.Typography.mono(9.5))
                        .foregroundColor(Theme.Colors.idleText)
                }
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.vertical, Theme.Spacing.xl)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("新建会话（⌘N）")
        }
        .frame(width: AIChatLayout.sidebarWidth)
        .frame(maxHeight: .infinity)
        // 侧栏底板：比主区深半档的轻纱层（低透明度令整窗玻璃折射从侧栏透出，分区
        // 靠深浅差；选中/hover 语言在玻璃上同样成立，见 SessionRowView）
        .background(Theme.Colors.chatSidebarBase)
        .onChange(of: searchFocusRequest) { _ in
            searchFocused = true
        }
    }

    // MARK: - 搜索框

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Typography.text(11, .medium))
                .foregroundColor(Theme.Colors.idleText)
            TextField("搜索会话", text: $searchText)
                .textFieldStyle(.plain)
                .font(Theme.Typography.text(12))
                .foregroundColor(Theme.Colors.contentPrimary)
                .focused($searchFocused)
            if isSearching {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Typography.text(11))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                // 深底板上 0.02 的 surfaceInset 不可辨，提到轨道档（0.06）
                .fill(Theme.Colors.surfaceTrack)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                // 聚焦环：单一琥珀强调色（全窗强调色统一走 accent）
                .stroke(
                    searchFocused ? Theme.Colors.accent.opacity(0.55) : Theme.Colors.chatStrokeStrong,
                    lineWidth: 0.5
                )
        )
    }

    // MARK: - 会话列表

    @ViewBuilder
    private var sessionList: some View {
        if isSearching {
            let results = store.search(searchText)
            if results.isEmpty {
                emptyState(icon: "magnifyingglass", text: "没有匹配的会话")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        ForEach(results) { session in
                            sessionRow(session)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        } else if store.sessions.isEmpty {
            emptyState(icon: "bubble.left.and.bubble.right", text: "暂无对话\n⌘N 开启第一段对话")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    ForEach(store.groupedSessions()) { group in
                        Text(group.title)
                            .font(Theme.Typography.text(Theme.Typography.caption, .semibold))
                            .foregroundColor(Theme.Colors.idleText)
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.top, Theme.Spacing.lg)
                            .padding(.bottom, Theme.Spacing.xs)
                        ForEach(group.sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.xs)
            }
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: Theme.Spacing.xl) {
            Image(systemName: icon)
                .font(Theme.Typography.text(18))
                .foregroundColor(Theme.Colors.idleText.opacity(0.7))
            Text(text)
                .font(Theme.Typography.text(11.5))
                .foregroundColor(Theme.Colors.idleText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 单个会话行

    private func sessionRow(_ session: ChatSession) -> some View {
        SessionRowView(
            session: session,
            isSelected: store.currentSessionId == session.id,
            isRenaming: renamingSessionId == session.id,
            renamingText: $renamingText,
            renameFocused: $renameFocused,
            onSelect: { onSelect(session.id) },
            onTogglePin: { store.togglePin(id: session.id) },
            onBeginRename: {
                renamingText = session.title
                renamingSessionId = session.id
                // 延迟一帧聚焦：等行内 TextField 随重命名态挂载后再下发放大镜焦点
                DispatchQueue.main.async { renameFocused = true }
            },
            onCommitRename: { commit in
                if commit {
                    let title = renamingText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        store.renameSession(id: session.id, title: title)
                    }
                }
                renamingSessionId = nil
            },
            onDelete: { store.deleteSession(id: session.id) }
        )
    }
}

// MARK: - 会话行

private struct SessionRowView: View {
    let session: ChatSession
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renamingText: String
    var renameFocused: FocusState<Bool>.Binding
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onBeginRename: () -> Void
    /// commit = true 提交改名；false 取消。
    let onCommitRename: (Bool) -> Void
    let onDelete: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if session.pinned {
                Image(systemName: "pin.fill")
                    .font(Theme.Typography.text(8.5))
                    .foregroundColor(Theme.Colors.accent.opacity(0.85))
            }

            if isRenaming {
                // 行内重命名：⏎ 提交；ESC 由 AIChatView 按键监听消费后走 onCommitRename(false)
                TextField("会话标题", text: $renamingText)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.text(12))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .focused(renameFocused)
                    .onSubmit { onCommitRename(true) }
            } else {
                Text(session.title)
                    .font(Theme.Typography.text(12, isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? Theme.Colors.contentPrimary : Theme.Colors.contentSecondaryStrong)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            // hover / 选中态渐显的 ⋯ 菜单
            if !isRenaming, hovered || isSelected {
                Menu {
                    Button(session.pinned ? "取消置顶" : "置顶", action: onTogglePin)
                    Button("重命名", action: onBeginRename)
                    Divider()
                    // 危险操作隔离分组，红色呈现（对齐桌面端惯例）
                    Button("删除", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(Theme.Typography.text(10, .semibold))
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .fill(isSelected
                      ? Theme.Colors.accent.opacity(0.14)
                      : (hovered ? Theme.Colors.surfaceButton : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
    }
}
