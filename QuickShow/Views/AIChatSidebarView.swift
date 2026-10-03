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
    /// 正在流式生成中的会话集合（驱动呼吸点显隐；点击呼吸点中止该会话）。
    var streamingSessionIds: Set<UUID>
    /// 后台生成完成但尚未查看的会话集合（切回会话由数据层自动清除，侧栏只读）。
    var unreadSessionIds: Set<UUID>
    /// 中止指定会话的流式生成。
    let onAbortStreaming: (UUID) -> Void
    let onSelect: (UUID) -> Void
    let onNewSession: () -> Void

    @State private var searchText = ""
    @State private var renamingText = ""
    /// 全局单悬停令牌：同一时刻至多一行处于 hover。
    /// 行内私有 @State hovered 在流式重排/重建时可能丢失 onHover(exit) 导致残留双高亮，
    /// 故提升到父级：enter 覆盖式赋值天然单悬停，exit 仅匹配自身 id 时清除（防乱序），
    /// 行销毁（Lazy 滚出视口）由 SessionRowView.onDisappear 兜底清除。
    @State private var hoveredSessionId: UUID?
    /// 分组 id 序列基线（onAppear 初始化；与 hoveredSessionId 的 stale 清理联动，见 body.onChange）。
    @State private var lastGroupedIDSequence: [UUID] = []
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 分组展平的会话 id 序列：结构变化检测用。只取 id，不触碰 messages 大数组，
    /// O(n) 轻量（n=会话数），可承受流式 50ms 扇出触发的每次 onChange 比较。
    private var groupedIDSequence: [UUID] {
        store.groupedSessions().flatMap { $0.sessions.map(\.id) }
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
        .onAppear {
            lastGroupedIDSequence = groupedIDSequence
        }
        .onChange(of: searchFocusRequest) { _ in
            searchFocused = true
        }
        .onChange(of: store.sessions) { _ in
            // stale hover 清理：仅在「分组结构变化」（id 展平序列不同）时清除悬停令牌。
            // 消息追加/标题摘要/touch 更新序列不变 → 保留 hover（流式 50ms 冲刷不闪烁）；
            // 重排/新增/删除序列变化 → 位移行可能收不到 onHover(exit)，主动清除
            // （行仍在则鼠标微动即恢复；行已删则必须清）。
            let sequence = groupedIDSequence
            guard sequence != lastGroupedIDSequence else { return }
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                hoveredSessionId = nil
            }
            lastGroupedIDSequence = sequence
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
            isStreaming: streamingSessionIds.contains(session.id),
            isUnread: unreadSessionIds.contains(session.id),
            isHovered: hoveredSessionId == session.id,
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
            onDelete: { store.deleteSession(id: session.id) },
            onAbort: { onAbortStreaming(session.id) },
            // 单悬停：enter 覆盖式置位（新 enter 自动顶掉旧行残留）；exit 仅匹配自身才清除
            onHoverStart: {
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                    hoveredSessionId = session.id
                }
            },
            onHoverEnd: { id in
                guard hoveredSessionId == id else { return }
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                    hoveredSessionId = nil
                }
            }
        )
    }
}

// MARK: - 会话行

private struct SessionRowView: View {
    let session: ChatSession
    let isSelected: Bool
    let isRenaming: Bool
    /// 该会话正在流式生成：标题前显示呼吸点，点击中止。
    let isStreaming: Bool
    /// 该会话有后台完成未读的新回复：行尾显示静止圆点，切回自动清除。
    let isUnread: Bool
    /// 全局单悬停下发的 hover 态（父级保证至多一行为 true）。
    let isHovered: Bool
    @Binding var renamingText: String
    var renameFocused: FocusState<Bool>.Binding
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onBeginRename: () -> Void
    /// commit = true 提交改名；false 取消。
    let onCommitRename: (Bool) -> Void
    let onDelete: () -> Void
    /// 中止该会话的流式生成。
    let onAbort: () -> Void
    /// hover 进入：父级置 hoveredSessionId = 本行 id。
    let onHoverStart: () -> Void
    /// hover 退出 / 行销毁兜底：父级仅当 hoveredSessionId 仍为该 id 时清除。
    let onHoverEnd: (UUID) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if session.pinned {
                Image(systemName: "pin.fill")
                    .font(Theme.Typography.text(8.5))
                    .foregroundColor(Theme.Colors.accent.opacity(0.85))
            }

            // 生成中呼吸点：pin 图标之后、标题之前；点击即中止该会话生成
            if isStreaming {
                BreathingDot(onAbort: onAbort)
            }

            if isRenaming {
                // 行内重命名：⏎ 提交；ESC 由 AIChatView 按键监听消费后走 onCommitRename(false)
                TextField("会话标题", text: $renamingText)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.text(12))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .focused(renameFocused)
                    // 挂载即请求焦点：结构上确定（视图已就位，无需延迟），
                    // 与 onBeginRename 里的 async 聚焦兜底幂等共存
                    .onAppear { renameFocused.wrappedValue = true }
                    .onSubmit { onCommitRename(true) }
            } else {
                Text(session.title)
                    .font(Theme.Typography.text(12, isSelected ? .medium : .regular))
                    // hover 语言 = 仅文字提亮（不加背景），与选中的 accent 色块拉开层级，
                    // 从根上避免「两块近似色背景并存 = 双选中」的误读
                    .foregroundColor(isSelected || isHovered
                                     ? Theme.Colors.contentPrimary
                                     : Theme.Colors.contentSecondaryStrong)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            // 完成未读点：行尾、⋯ 菜单之前；静止，与呼吸点靠动效区分
            if isUnread {
                Circle()
                    .fill(Theme.Colors.accent)
                    .frame(width: 5, height: 5)
            }

            // hover / 选中态渐显的 ⋯ 菜单
            if !isRenaming, isHovered || isSelected {
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
                // 背景色块专属选中态；hover 不再铺背景（文字提亮 + ⋯ 渐显已足够表达）
                .fill(isSelected ? Theme.Colors.accent.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            if hovering { onHoverStart() }
            else { onHoverEnd(session.id) }
        }
        // Lazy 滚动销毁时 onHover(exit) 可能不触发：行消失即兜底清除自身悬停令牌
        .onDisappear { onHoverEnd(session.id) }
    }
}

// MARK: - 生成中呼吸点

/// 生成中状态点：6pt accent 圆，1.2s 透明度呼吸；点击即中止该会话生成。
/// 与静止的未读点靠动效区分；hover 提亮放大 + pointing hand 光标 + tooltip 表达可点。
private struct BreathingDot: View {
    let onAbort: () -> Void

    @State private var breathing = false
    @State private var hovered = false

    var body: some View {
        Button(action: onAbort) {
            Circle()
                .fill(Theme.Colors.accent)
                .frame(width: 6, height: 6)
                .opacity(breathing ? 0.4 : 1.0)
                .scaleEffect(hovered ? 1.3 : 1.0)
                // ≥16pt 点击热区（视觉仍 6pt，不撑高行高：行内 ⋯ 菜单已 18pt）
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        // 视图被卸载时若 hover 仍未退出（如生成结束点消失），补一次 pop 防止光标卡住
        .onDisappear {
            if hovered { NSCursor.pop() }
        }
        .help("点击中止生成")
    }
}
