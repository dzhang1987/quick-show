// 从 AIChatView.swift 机械拆分：单会话消息列表（视图树保活单元）。

import AppKit
import Combine
import SwiftUI

// MARK: - 单会话消息列表（视图树保活单元）

/// 单会话消息列表：每个常驻会话一份完整独立的 ScrollViewReader+ScrollView+LazyVStack，
/// 滚动位置/贴底跟随/首挂载态全部私有化随视图树保活——切会话只切 opacity，零身份重建。
/// 由父级 AIChatView 的 LRU 常驻集合（residentSessionIds）驱动挂载/卸载。
@MainActor
struct SessionMessageList: View {
    let sessionId: UUID
    let isActive: Bool
    /// 会话门面（读取本会话流式状态、发起重试）；更新由父级重渲染驱动。
    let state: AIChatState
    /// 本会话消息（父级传入；隐藏会话无需独立订阅 store）。
    let messages: [ChatMessage]
    let onTapImage: (ChatImageAttachment) -> Void
    @Binding var scrollSnapshots: [UUID: ScrollSnapshot]
    let scrollCoordinator: ChatScrollCoordinator
    /// 输入坞实测总高（父级统一传入）：尾部留白与浏览导航的底部预算同步叠加，
    /// 随坞体向上生长动态跟随。生长区只属于当前活跃会话的输入坞，但 pendingQueue
    /// 本就按会话隔离读取，高度值对全部常驻实例统一应用（非活跃会话 opacity=0 不可见）。
    let dockTotalHeight: CGFloat

    private let bottomAnchorID = "aiChat.bottom"

    /// 本会话首载装载态：冷启动与 LRU 重挂载时抑制入场动画，防窗口上屏竞态白屏。
    @State private var isInitialHistoryLoad = true
    /// 贴底跟随态（pinned）：true = 自动跟随最新内容，false = 用户自由浏览。
    /// 写路径单一（见 ChatScrollCoordinator）：用户输入回底/发送跳底 → true；
    /// 用户输入离底 → false。内容高度变化永不直接改写本态。
    @State private var isPinned = true
    /// 浏览导航（刻度轨/回底钮）显隐镜像：unpinned 且离底超过
    /// `Theme.Layout.chatNavRevealDistance` 才为 true（真源在 coordinator，本回调同步）。
    /// 与 isPinned（跟随态）刻意解耦：上滚一点点时跟随照常暂停，但 UI 不冒出来。
    @State private var isNavVisible = false
    /// 真实视口顶部消息 id（由行级几何信号驱动，替代不可靠的 visibleMessageIDs）：
    /// 切走时作为恢复锚点，刻度轨「当前条」判定也据此定位。
    @State private var topVisibleMessageID: UUID?
    /// 消息分组缓存（messages 未变则复用上次分组；见 MessageGroupingCache）。
    @State private var groupingCache = MessageGroupingCache()
    /// 已消费的跳底信号时间戳（消费式标记）：挂载/重建时对照 state.scrollJumpRequests，
    /// 存在「新于挂载时刻」的未消费信号即补跳——瞬时发布-订阅事件在视图不在场（空会话
    /// EmptyView / 发送白屏重建窗口）时不再丢失。
    @State private var lastConsumedJumpRequest: Date?
    /// 本实例挂载时刻：补消费跳底信号的时效判据（LRU 重挂载时字典里的旧信号早于挂载，
    /// 不补跳，走快照恢复）。
    @State private var mountedAt = Date()
    /// 行级实测高度缓存（message.id → 行高）：**手动虚拟化的高度真源**——行离开视口
    /// 窗口时切换为等高占位（高度 = 本缓存），回窗口时切实渲染（高度 = 实测），
    /// 两者恒等 → document 高度恒稳。替换 LazyVStack 的黑盒行估算（macOS 13 上
    /// 回收远行的估算归零/失准，每次实例化-回收结算出 ~14000pt 的 doc 骤变 =
    /// 「上滚跳过数条消息」的最终根因，日志定证：塌缩瞬间零子视图回退事件）。
    /// 由行级几何信号（updateRowFrames）回写；@State 写入在 preference 回调
    /// （渲染周期合法路径），首帧 nil = 全实渲染（首见全量，秒开诉求已按用户决策放弃）。
    @State private var rowHeights: [UUID: CGFloat] = [:]
    /// 行高缓存对应的内容列宽（回写行高时的实测宽度）：**行高是列宽的函数**——文字折行
    /// 点数、图片等比缩放后的高度都随列宽变化。列宽一变，旧缓存高度即失效：占位高度
    /// ≠ 新宽度下的实渲染高度，「占位 = 实测」恒等式破裂 → 滚动虚拟化切换时 doc 高度
    /// 抖动（列宽变化期尤为明显）。触发源：窗口 resize、⌘B 侧栏展开时主列补偿导致的
    /// 720↔719.5 断点翻转（见 ChatReadingColumn）、冷启动首帧宽度上报修正。
    @State private var cachedColumnWidth: CGFloat?
    /// 虚拟化窗口（实渲染行集合）：视口 ±2 屏内的行实渲染，窗口外等高占位。
    /// 由行级几何信号每帧维护；切换高度恒等（占位 = 缓存 = 实测）。
    @State private var virtualWindowIds: Set<UUID> = []
    /// 虚拟化窗口半径（屏数）：视口上方 2 屏 + 下方 2 屏——滚动惯性预热带。
    private let virtualWindowScreens: CGFloat = 2
    /// 底部容差区高度（pt）：与 ChatScrollCoordinator.bottomTolerance 同源——容差哨兵
    /// 嵌在坞区留白内部，置于真正底部上方此距离。
    private let bottomTolerance: CGFloat = 18

    private var isStreamingSession: Bool { state.isStreaming(sessionId: sessionId) }

    // ⚠️ 刻意移除「首帧骨架 → 下一 runloop 再建真实内容」的两段式切换。
    // 原因：骨架把真实内容推迟到一个独立的 CA 事务，与历史冷启动白屏同源——
    // 内容首建提交若落在窗口级淡入/NSGlassEffectView 隐式动画窗口内，内容层会卡在
    // 近零透明度（CHANGELOG: 消息行近零透明度、白屏 + 幽灵残影）；且该状态随常驻视图
    // 保留，重选会话不重建 → 永久白屏。首帧轻量化已由 AssistantMarkdownView 的分批
    // 渐进渲染（首批仅 24 块）与公式异步/预热保证，骨架的额外延迟已冗余且有害。
    var body: some View {
        if messages.isEmpty {
            // 空会话在 ZStack 中不渲染内容；空态欢迎页/引导页由外层 overlay 承担。
            EmptyView()
        } else {
            scrollContent
        }
    }

    private var scrollContent: some View {
        // 外层 GeometryReader 提供视口高度（= ScrollView 可视高度），与底部锚点几何共同
        // 判定「锚点底边距视口底的距离」。macOS 13 无滚动偏移 API，这是替代不可靠的
        // onAppear/onDisappear 哨兵的可靠感知层。
        GeometryReader { viewport in
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // 手动虚拟化容器（VStack 全行常驻）：LazyVStack 在 macOS 13 上回收远行
                // 的高度估算归零/失准，实例化-回收的「估算↔真实」差一次性结算成 doc 骤变
                // （日志定证 -14306 → 视口瞬移 14053 = 上滚跳消息的最终根因）。改为
                // VStack + 行内「实渲染 ↔ 等高占位」切换（ChatVirtualRow）：占位高度 =
                // 实测缓存高度，切换高度恒等 → doc 恒稳。间距语义与 LazyVStack 一致。
                VStack(alignment: .leading, spacing: Theme.Spacing.chatGroupGap) {
                    ForEach(MessageListDerivations.groupedMessages(cache: groupingCache, messages: messages)) { group in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                            ForEach(group.messages) { message in
                                // 压缩边界卡：组内行级插入（边界无论落组间/组内都正确；再次压缩
                                // 边界上移时数据驱动自然移位）。插在边界消息之前；边界 id 为 nil
                                // （未指定/已不存在/转换失败）时落在首条消息前 = 会话流最顶部。
                                // id 与边界绑定：边界变化即新视图，展开态不带入新位置（默认收起）。
                                if showsCompactionCard,
                                   (message.id == compactionBoundaryMessageId
                                    || (compactionBoundaryMessageId == nil
                                        && message.id == messages.first?.id)) {
                                    CompactionBoundaryCard(
                                        isCompacting: state.isCompacting,
                                        summarizedCount: state.compactionInfo?.summarizedCount ?? 0,
                                        summary: state.compactionInfo?.summary ?? ""
                                    )
                                    .id("compaction.\(compactionBoundaryMessageId?.uuidString ?? "top")")
                                }
                                ChatVirtualRow(
                                    messageId: message.id,
                                    rowHeights: $rowHeights,
                                    inWindow: virtualWindowIds.contains(message.id)
                                ) {
                                    // 已压缩行降档：id ∈ summarizedMessageIDs 的行整行降到可读下限档
                                    // 透明度——「模型视角已分叉」由此可扫读；原文仍是阅读资产，
                                    // 不折叠不隐藏。opacity 不改布局，虚拟化等高占位机制不受影响；
                                    // contentFade 渐变让压缩完成瞬间的区域弱化本身就是反馈。
                                    let isSummarized = state.compactionInfo?.summarizedIDs.contains(message.id.uuidString) ?? false
                                    ChatMessageRow(
                                        message: message,
                                        isSummarized: isSummarized,
                                        canRegenerate: message.id == lastRegeneratableAssistantId,
                                        canEditLastRound: message.id == lastEditableUserMessageId,
                                        onRetry: { if isActive { state.retryLast() } },
                                        onRegenerate: { if isActive { state.retryLast() } },
                                        onWithdraw: { if isActive { state.withdrawLastRound() } },
                                        onEditResend: { text, images in
                                            if isActive { state.editAndResendLast(text: text, images: images) }
                                        },
                                        onTapImage: onTapImage
                                    )
                                    .equatable()
                                    .opacity(isSummarized ? Theme.Colors.summarizedRowOpacity : 1)
                                    .animation(.easeOut(duration: Theme.Motion.contentFade), value: isSummarized)
                                    .transition(isInitialHistoryLoad
                                        ? .identity
                                        : .opacity.combined(with: .offset(y: Theme.Motion.messageArriveOffset)))
                                }
                                // 行级几何信号：挂在外层（实渲染/占位统一上报本行 frame）——
                                // 供父级算出真实「视口首个可见消息」+ 虚拟化窗口判定 + 行高回写。
                                // preference 每帧全量重算，诚实反映当前行集合。
                                .background(
                                    GeometryReader { rowGeo in
                                        Color.clear.preference(
                                            key: MessageRowFramePreference.self,
                                            value: [message.id: rowGeo.frame(in: .named(scrollSpaceName))]
                                        )
                                    }
                                )
                                .id(message.id)
                            }
                        }
                    }
                    // 尾部整体作为 LazyVStack 的单个子视图：把原先 4 个尾部子项的 4×36pt 组间距收敛为
                    // 1 个，其余 3×36 的叠加被消除。
                    //
                     // 间距算术：本子视图与「末条消息组」之间仍有 1×chatGroupGap(36)。
                     // 尾部总留白 = dockTotalHeight（实测坞高）+ 呼吸缝 10：
                     // 36 + (坞高+10−18−36) + 18 + 1 = 坞高+11——滚到底时末条消息底边停在坞顶
                     // 上方 11pt 完整可见；再往上滚则自然穿入玻璃坞下被实时 blur 采样（真穿透）。
                    // （与坞体真实高度解耦，工具行动态变化自动跟随；2026-10 静态预算时代的
                    // 末条被压/遮挡断层由实测坞高单一真实来源根治。）
                    VStack(spacing: 0) {
                        // 坞区让位留白：实测坞总高 + 呼吸缝，扣除外层组间距(36)
                        // 与容差带(18)——两者分别由本子视图外/内承担，此处只补差额。
                        // 留白随坞体生长/收缩平滑过渡（与坞内动画同时长）；pinned 时由
                        // coordinator 的内容高度路径自动保持贴底，unpinned 不受干扰
                        // （用户阅读位置主权最高）。
                        Color.clear
                            .frame(height: max(dockTotalHeight + Theme.Layout.chatDockTailBreathing - bottomTolerance - Theme.Spacing.chatGroupGap, 0))
                            .animation(.easeOut(duration: Theme.Motion.contentFade), value: dockTotalHeight)
                        // 容差带（18pt，嵌入坞区留白内部）
                        Color.clear
                            .frame(height: bottomTolerance)
                        // 底部锚点：仅供 scrollToBottom 的 proxy 回退路径定位
                        // （LazyVStack 尾部锚点；AppKit 直滚为主路径）。
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                }
                .animation(isInitialHistoryLoad ? nil : .easeOut(duration: Theme.Motion.contentFade),
                           value: messages.count)
                .padding(.top, Theme.Spacing.section)
                .chatReadingColumn()
                // AppKit 滚动桥：必须挂在 ScrollView 内容闭包内部（此处是内容根视图），
                // 才能经 enclosingScrollView 解析到本会话底层 NSScrollView（见 ChatScrollBridgeView）。
                .background(ChatScrollBridgeView(sessionId: sessionId, coordinator: scrollCoordinator))
            }
            .coordinateSpace(name: scrollSpaceName)
            // 真穿透（2026-10 再设计）：底缘渐隐带 mask 已退役——滚动内容不再在坞顶收没，
            // 而是自然穿入玻璃坞下方，由坞体（26+ Liquid Glass / <26 ultraThinMaterial）
            // 实时 blur 采样透出模糊内容。尾部留白保证末条消息可完整滚到坞顶上方（见上）。
            .animation(.easeOut(duration: Theme.Motion.contentFade), value: dockTotalHeight)
            // 首帧视口自适应：把视口高度注入环境，供消息内 AssistantMarkdownView 估算「一屏块数」。
            .environment(\.chatViewportHeight, viewport.size.height)
            // 行级几何 → 真实视口顶部消息：每帧全量上报已实现行 frame，算出与视口相交且
            // minY 最靠上（最贴近视口顶）的行；仅在结果变化时写状态（去抖，避免每帧 setState）。
            .onPreferenceChange(MessageRowFramePreference.self) { frames in
                updateRowFrames(frames, viewportHeight: viewport.size.height)
            }
            .onAppear {
                seedVirtualWindowIfNeeded()
                bindScrollCoordinator()
                // 首帧布局完成后的下一 runloop：补消费跳底信号（空会话首建/重建窗口期
                // 发布的瞬时信号不再丢失）→ 恢复位置（snapshot 锚点 / 贴底）→ 解除装载态。
                // 解除装载态走显式空动画事务（历史白屏防线，勿动）。此路径仅在
                // 挂载 / LRU 重挂载时执行；常驻切回不再联动 restoreScroll（见 onChange(isActive)）。
                DispatchQueue.main.async {
                    consumePendingJumpRequest(proxy)
                    restoreScroll(proxy)
                    withAnimation(nil) { isInitialHistoryLoad = false }
                }
            }
            // 卸载：兜底保存快照 + 注销 coordinator 注册。覆盖「同 runloop 连续切换、中间会话
            // 以 isActive=false 首次建树导致 onChange(of: isActive) 不触发、无快照」的反例。
            // 正常失活（非卸载）由 onChange(isActive=false) 保存；saveSnapshot 幂等，重复无害。
            .onDisappear {
                saveSnapshot()
                scrollCoordinator.unbind(sessionId: sessionId)
            }
            // 用户发送 → 无条件跳底并恢复跟随（消费式跳底信号，见 send()/scrollJumpRequests）：
            // **非动画**——发送帧已有 LazyVStack 行入场 transition + count 动画并发，再叠加
            // AppKit animator 滚动动画会重现历史「CA 事务竞态卡近零透明度」白屏（发送后
            // 整屏白屏直到首 token 才恢复的根因）。跳底发生在内容插入前的瞬间，无感无动画。
            // onChange 值类型为 Date?（字典下标返回可选，Equatable 合法）；值未变化不触发。
            .onChange(of: state.scrollJumpRequests[sessionId]) { _ in
                guard isActive else { return }
                lastConsumedJumpRequest = state.scrollJumpRequests[sessionId]
                scrollCoordinator.setPinned(sessionId, true)
                scrollToBottom(proxy, animated: false)
                // 保险补滚：信号触发时新插入行可能尚未完成布局，下一 runloop 布局落定后再贴底一次。
                DispatchQueue.main.async {
                    if isActive, isPinned { scrollToBottom(proxy, animated: false) }
                }
            }
            // 流式/渐进增量的跟随不再走本层（无 0.12s 节流路径）：documentView 高度变化由
            // ChatScrollCoordinator 的 frame 通知路径逐帧程序化贴底（pinned 时），与布局
            // 同步、零追赶误差——本层只保留流式结束的收尾动画（无插入动画并发，安全）。
            .onChange(of: isStreamingSession) { streaming in
                if !streaming, isActive, isPinned { scrollToBottom(proxy, animated: true) }
            }
            // 活跃态切换：只保存快照，**不做任何 restoreScroll、不注销注册**。
            // 常驻视图的 NSScrollView 偏移天然保留；激活时无条件 restoreScroll 是唯一破坏源
            // （会把用户强制拉走）。位置恢复只发生在挂载/LRU 重挂载的 onAppear。
            // pinned 会话若在隐藏期间并行生成，coordinator 的 frame 路径持续贴底。
            .onChange(of: isActive) { active in
                if !active { saveSnapshot() }
            }
            // 浏览导航（2026-10 重设计：竖排双↓胶囊簇 → 刻度轨三件套 → Dock 放大刻度轨）：
            // 显隐 = isNavVisible（unpinned 且离底超过 chatNavRevealDistance）且活跃，
            // 0.15s 淡入淡出；贴底或门槛内隐藏。**显隐与 pin 解耦**：上滚一点点
            // （门槛内）跟随照常暂停但不冒 UI；越过门槛才浮现，滚回门槛内即淡出。
            // 两件套各自挂 overlay（浮于滚动内容之上，真穿透后内容与坞/导航同层互不遮罩）：
            // ① 右缘刻度轨：贴窗口右内缘、垂直居中于内容区（扣坞区），每条用户消息一枚 tick，
            //   静止紧凑密排、光标接近时按余弦钟形衰减放大推开（详见 ChatTickRail）；
            // ② ↓ 回底钮：坞正上方、右缘贴统一右基准线。
            .overlay(alignment: .trailing) {
                if isNavVisible, isActive, !tickItems.isEmpty {
                    ChatTickRail(items: tickItems) { messageId in
                        // 程序化遮蔽：0.2s 动画期间的逐帧 bounds 变化不计为用户滚动
                        // （点 tick 跳转属于「浏览」而非「滚动」，pin 态由落点几何自然决定）
                        scrollCoordinator.withProgrammaticScope(sessionId, window: 0.35) {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(messageId, anchor: .top) }
                        }
                    }
                    .padding(.trailing, Theme.Layout.chatTickTrailing)
                    .padding(.bottom, dockTotalHeight)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if isNavVisible, isActive {
                    toBottomButton(proxy)
                        .padding(.bottom, dockTotalHeight + Theme.Layout.chatNavDockGap)
                        .animation(.easeOut(duration: Theme.Motion.contentFade), value: dockTotalHeight)
                        .chatReadingColumn(alignment: .trailing)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isNavVisible)
        }
        }
    }

    // MARK: - 滚动协调器接线

    /// 挂载时注册（常驻期间保持，不随 isActive 切换注销——隐藏会话并行流式时
    /// coordinator 的 frame 路径仍需读 pin 真源保持贴底）：
    /// pin 真源在 coordinator（class 内即时读写）——@State isPinned 降级为纯 UI 镜像
    /// （跟随逻辑判定），由本闭包同步；isNavVisible 是浏览导航显隐的第二镜像
    /// （离底距离门槛判定，与 pin 解耦）。日志实证：@State 经通知回调写入后同帧
    /// 读取拿到旧值（「解除跟随后仍被逐帧贴底拽回」根因），判定路径必须读 class 真源。
    private func bindScrollCoordinator() {
        scrollCoordinator.bind(
            sessionId: sessionId,
            onPinnedChange: { pinned in
                isPinned = pinned
            },
            onNavVisibilityChange: { visible in
                isNavVisible = visible
            }
        )
    }

    /// 冷启动/LRU 重挂载时预置虚拟化窗口：ChatVirtualRow 改为「未测量且窗口外 =
    /// 估算占位」后，空 virtualWindowIds 意味着首帧全行占位——geometry 反馈循环虽能
    /// 在 1-2 帧后收敛，但预置可让 frame 1 直接命中视口行、减少可见闪烁。
    private func seedVirtualWindowIfNeeded() {
        guard virtualWindowIds.isEmpty, !messages.isEmpty else { return }
        let snapshot = scrollSnapshots[sessionId]
        let pinned = snapshot?.isPinned ?? true
        if !pinned,
           let anchor = snapshot?.topVisibleMessageID,
           let idx = messages.firstIndex(where: { $0.id == anchor }) {
            let lo = max(0, idx - 7)
            let hi = min(messages.count, idx + 8)
            virtualWindowIds = Set(messages[lo..<hi].map(\.id))
        } else {
            virtualWindowIds = Set(messages.suffix(15).map(\.id))
        }
    }

    /// 消费式跳底信号补消费：挂载/重建时 state.scrollJumpRequests 里存在「新于挂载时刻」
    /// 的未消费信号即补跳底（瞬时发布-订阅事件在视图不在场的窗口期不再丢失——空会话
    /// 首条发送时 EmptyView 无挂载点、发送白屏重建期间同理）。旧于挂载时刻的信号
    /// （LRU 重挂载）跳过，走快照恢复。
    private func consumePendingJumpRequest(_ proxy: ScrollViewProxy) {
        guard let pending = state.scrollJumpRequests[sessionId],
              pending != lastConsumedJumpRequest,
              pending > mountedAt else { return }
        lastConsumedJumpRequest = pending
        scrollCoordinator.setPinned(sessionId, true)
        scrollToBottom(proxy, animated: false)
    }

    // MARK: - 快照

    /// 切走/卸载时保存：真实视口顶部消息 id（几何信号维护）+ 当前 pinned 态。
    /// 防御：无锚点时保留上一份有效锚点，避免 restoreScroll 因 topID=nil 退回贴底。
    /// **pinned 必须读 coordinator 真源**——@State 镜像写入延迟一帧可见，读镜像会
    /// 存到旧值（实测：切走时存 isPinned=true → 切回走贴底分支 = 位置记忆失效）。
    /// 同时落盘（跨重启记忆，低频写）。
    private func saveSnapshot() {
        // 诚实锚点：由行级几何信号维护的真实视口顶部消息；无则保留上一份有效锚点。
        let previousAnchor = scrollSnapshots[sessionId]?.topVisibleMessageID
        scrollSnapshots[sessionId] = ScrollSnapshot(
            topVisibleMessageID: topVisibleMessageID ?? previousAnchor,
            isPinned: scrollCoordinator.isPinnedState(of: sessionId)
        )
        state.store.persistScrollPositions(
            scrollSnapshots.mapValues {
                ChatSessionStore.PersistedScrollPosition(
                    topMessageID: $0.topVisibleMessageID, isPinned: $0.isPinned
                )
            }
        )
    }

    /// 行级几何 → 真实视口顶部消息 + 手动虚拟化窗口维护：
    /// - 顶部消息：取与视口相交（maxY>0 且 minY<viewportHeight）且 minY 最小（最贴近视口顶）
    ///   的行；无相交行（极端：视口落在尾部留白内）时退化为最靠近视口顶的行（maxY 最大者）。
    /// - 虚拟化：视口 ±N 屏内的行进窗口（实渲染集合，变化时写 state 触发行切换）；
    ///   窗口内行（= 实渲染行）高度回写缓存（变化 >0.5pt 才写，去抖）——占位行的
    ///   frame.height 即缓存值本身，天然无变化。
    private func updateRowFrames(_ frames: [UUID: CGRect], viewportHeight: CGFloat) {
        guard viewportHeight > 0, !frames.isEmpty else { return }
        // 列宽变化即整体失效行高缓存：行 frame 宽度统一 = 内容列宽，任取一行即可代表。
        // 清空后 virtualWindowIds 内的行（视口 ±2 屏）仍实渲染、按新宽度回写缓存；
        // 窗口外行切换为估算占位（100pt），进入窗口时再实渲染重测。
        let probeWidth = frames.values.first?.width ?? 0
        if cachedColumnWidth == nil || abs((cachedColumnWidth ?? probeWidth) - probeWidth) > 1 {
            rowHeights.removeAll()
            cachedColumnWidth = probeWidth
        }
        var bestID: UUID?
        var bestMinY = CGFloat.greatestFiniteMagnitude
        for (id, frame) in frames where frame.maxY > 0 && frame.minY < viewportHeight {
            if frame.minY < bestMinY {
                bestMinY = frame.minY
                bestID = id
            }
        }
        // 无相交行（极端：视口落在尾部留白内）：退化为最靠近视口顶的行（maxY 最大者）。
        let resolved = bestID ?? frames.max(by: { $0.value.maxY < $1.value.maxY })?.key
        if resolved != topVisibleMessageID { topVisibleMessageID = resolved }

        // 虚拟化窗口：视口 ±N 屏（滚动惯性预热带）。
        let lowerBound = -virtualWindowScreens * viewportHeight
        let upperBound = (1 + virtualWindowScreens) * viewportHeight
        var ids: Set<UUID> = []
        ids.reserveCapacity(frames.count)
        for (id, frame) in frames where frame.maxY >= lowerBound && frame.minY <= upperBound {
            ids.insert(id)
            if abs((rowHeights[id] ?? -1) - frame.height) > 0.5 {
                rowHeights[id] = frame.height
            }
        }
        if ids != virtualWindowIds { virtualWindowIds = ids }
    }

    /// 挂载（首次 / LRU 重挂载）时恢复（唯一调用点：ScrollView.onAppear）：
    /// - 有非贴底快照且锚点仍在 → 无动画定位到锚点顶部，保持阅读位置；
    /// - 否则 → 无动画贴底并恢复跟随（含「离开时贴底」与「首次打开无快照」）。
    /// proxy.scrollTo 的定位在程序化遮蔽窗内执行：若桥的 observer 已装，随后的
    /// bounds 变化不会被误判为用户滚动（防 pin 态被 restore 误翻转）。
    private func restoreScroll(_ proxy: ScrollViewProxy) {
        if let snapshot = scrollSnapshots[sessionId],
           !snapshot.isPinned,
           let topID = snapshot.topVisibleMessageID,
           messages.contains(where: { $0.id == topID }) {
            scrollCoordinator.setPinned(sessionId, false)
            scrollCoordinator.withProgrammaticScope(sessionId, window: 0.35) {
                proxy.scrollTo(topID, anchor: .top)
            }
        } else {
            scrollCoordinator.setPinned(sessionId, true)
            scrollToBottom(proxy, animated: false)
        }
    }

    /// 本实例的滚动坐标空间名：按 sessionId 隔离，多个常驻会话并存时不互相污染。
    private var scrollSpaceName: String { "chatScroll.\(sessionId.uuidString)" }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        // AppKit 直滚（coordinator 程序化仲裁内，遮蔽窗覆盖动画时长）：SwiftUI proxy.scrollTo
        // 对 LazyVStack 尾部锚点不可靠（视口远离底部时锚点未实例化/新行布局竞态，scrollTo
        // 无声失败）；程序化设置 clip view 偏移与用户滚轮同一条 AppKit 路径，且被 coordinator
        // 遮蔽窗排除在「用户输入」之外。
        if scrollCoordinator.scrollPinnedToBottom(sessionId: sessionId, animated: animated) {
            return
        }
        // 桥未就绪回退：proxy 路径同样开程序化遮蔽窗（observer 可能已随桥挂载）。
        if animated {
            scrollCoordinator.withProgrammaticScope(sessionId, window: 0.28) {
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(bottomAnchorID, anchor: .bottom) }
            }
        } else {
            scrollCoordinator.withProgrammaticScope(sessionId) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    // MARK: - 浏览导航（刻度轨 + 预览胶囊 + 回底钮；unpinned 浏览态显示）

    // topVisibleMessageID 现为 @State，由行级几何信号（updateRowFrames）维护，见上方声明。

    /// 刻度轨数据源：当前会话全部用户消息；超过 chatTickMaxCount 时按视口取样——
    /// 以「当前条」锚点为中心保留前后各半（密度主由轨内自适应 pitch 承担，取样仅作极端兜底）。
    private var tickMessages: [ChatMessage] {
        MessageListDerivations.tickMessages(messages: messages,
                                            currentTickMessageId: currentTickMessageId)
    }

    /// 当前查看的用户消息 tick：视口锚点（含自身）所属的最近一条用户消息，
    /// 随滚动经行级几何信号实时更新；无锚点时兜底取最后一条用户消息。
    private var currentTickMessageId: UUID? {
        MessageListDerivations.currentTickMessageId(messages: messages,
                                                    topVisibleMessageID: topVisibleMessageID)
    }

    /// 刻度轨条目：采样后用户消息 → 轨渲染模型（预览文本预裁剪、当前条标记）。
    private var tickItems: [ChatTickRail.Item] {
        MessageListDerivations.tickItems(messages: messages,
                                         currentTickMessageId: currentTickMessageId)
    }

    /// ↓ 回到底部：浏览态显示；坞正上方、右缘贴统一右基准线；
    /// 点击回底（复用现有程序化贴底滚动）。
    /// 材质（Safari 后退钮同款原生玻璃语言）：
    /// - 26+：GlassSurface 走官方 glassEffect(.regular)，系统自带 vibrancy/顶部高光/rim/投影；
    /// - 13~25 降级：ultraThinMaterial + 0.5pt 描边（GlassSurface 内建）+ 顶部受光 rim（此处叠加）
    ///   + 双层轻投影，营造玻璃感；
    /// - 箭头 bold 纯白（iconHover 0.95），与玻璃底强对比。
    private func toBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            scrollCoordinator.setPinned(sessionId, true)
            scrollToBottom(proxy, animated: true)
        } label: {
            Image(systemName: "arrow.down")
                .font(Theme.Typography.text(12, .bold))
                .foregroundColor(Theme.Colors.iconHover)
                .frame(width: Theme.Layout.chatToBottomButtonSize, height: Theme.Layout.chatToBottomButtonSize)
                .contentShape(Circle())
                .modifier(GlassSurface(shape: Circle()))
                // 降级路径补玻璃感：顶部受光 rim（26+ 由系统玻璃自带 specular，不叠加防双边缘）
                .overlay {
                    if !OSFeatures.liquidGlass {
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(Theme.Colors.rimTopOpacity * 0.5),
                                             .white.opacity(0)],
                                    startPoint: .top,
                                    endPoint: .center
                                ),
                                lineWidth: 0.5
                            )
                            .allowsHitTesting(false)
                    }
                }
                .shadow(color: .black.opacity(Theme.Shadow.dockContactOpacity),
                        radius: Theme.Shadow.dockContactRadius,
                        y: Theme.Shadow.dockContactY)
                .shadow(color: .black.opacity(Theme.Shadow.dockAmbientOpacity),
                        radius: Theme.Shadow.dockAmbientRadius,
                        y: Theme.Shadow.dockAmbientY)
        }
        .buttonStyle(.plain)
        .help("回到底部")
    }

    // MARK: - 分组 / 可重生成

    /// 是否渲染压缩边界卡：仅活跃会话（compactionInfo 是「当前会话」门面，隐藏会话树
    /// 不渲染，防跨会话错位；切回活跃时随重求值自然出现）；有压缩记录或压缩进行中。
    private var showsCompactionCard: Bool {
        MessageListDerivations.showsCompactionCard(isActive: isActive,
                                                   isCompacting: state.isCompacting,
                                                   compactionInfo: state.compactionInfo)
    }

    /// 压缩边界消息 id：beforeMessageID（String）转 UUID 且在本会话消息里存在时按位插入；
    /// nil / 转换失败 / 消息已不存在 → nil（卡片落到会话流最顶部，契约语义）。
    private var compactionBoundaryMessageId: UUID? {
        MessageListDerivations.compactionBoundaryMessageId(
            messages: messages,
            beforeMessageID: state.compactionInfo?.beforeMessageID
        )
    }

    /// 最后一条可重新生成的助手消息 id：仅活跃会话 + 本会话非生成中时提供
    /// （重试动作只对当前会话有效，隐藏会话不显示按钮）。
    private var lastRegeneratableAssistantId: UUID? {
        MessageListDerivations.lastRegeneratableAssistantId(messages: messages,
                                                            isActive: isActive,
                                                            isStreaming: isStreamingSession)
    }

    /// 会话内最后一条 user 消息 id：仅活跃会话 + 非生成中时提供
    /// （撤回/编辑只对当前会话最后一轮有效；隐藏会话与生成中不显示入口）。
    private var lastEditableUserMessageId: UUID? {
        MessageListDerivations.lastEditableUserMessageId(messages: messages,
                                                         isActive: isActive,
                                                         isGenerating: state.isGenerating)
    }
}

// MARK: - 会话列表 Equatable（视图级 diff 防线）

extension SessionMessageList: Equatable {
    /// 忽略闭包/Binding/class 引用（语义跨渲染恒稳），仅按数据身份判定相等——
    /// 与 ChatMessageRow.Equatable 同一模式。消息数组改用 O(1) 身份签名
    /// （count + 首尾 id + 尾条 state/长度），避免全量逐元素 O(n) 比较。
    /// 配合父级 .equatable()：父级 body 重求值时未变的常驻会话跳过整棵子树，
    /// 聚焦/失焦/剪贴板/pin 等非消息变化不再冲刷 12 棵会话的 ForEach + 虚拟化。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionId == rhs.sessionId
            && lhs.isActive == rhs.isActive
            && lhs.dockTotalHeight == rhs.dockTotalHeight
            && lhs.messages.count == rhs.messages.count
            && lhs.messages.first?.id == rhs.messages.first?.id
            && lhs.messages.last?.id == rhs.messages.last?.id
            && lhs.messages.last?.state == rhs.messages.last?.state
            && lhs.messages.last?.content.count == rhs.messages.last?.content.count
    }
}
