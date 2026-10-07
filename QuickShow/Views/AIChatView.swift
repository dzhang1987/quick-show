import AppKit
import Combine
import SwiftUI

/// AI 对话视图（Lane C）：将嵌入 NSHostingView，由 AIWindowManager 管理外窗尺寸与焦点。
/// 视觉常量全部走 DesignTokens 令牌（AI 专用令牌集中在 DesignTokens 的 chatXxx 区，本文件不硬编码）。
///
/// Wave 3 结构（2026-10 视觉质感专项）：
/// - 左侧会话窄栏（⌘B 显隐，展开时窗口整体加宽，见 AIWindowManager.setSidebarVisible）
/// - 消息列表铺满窗口主体：AI 回复无气泡铺底排版；落定助手消息下方常驻弱显示操作行（复制/重新生成）
/// - 输入坞浮岛化：overlay 悬浮于消息列表之上；真穿透——滚动内容自然穿入玻璃坞
///   下方，坞体实时 blur 采样透出模糊内容（2026-10 再设计，恢复 blur-through）
/// - 整窗方向性 rim light（顶亮侧弱底微）+ 输入坞双层阴影 + 激活态 accent rim（安静态零描边）
/// - 输入坞安静/激活渐进披露：安静态（无草稿/未悬停）收敛为纯输入行，低频工具（剪贴板/
///   水位/压缩）隐去；控件语言为纯灰图标 + hover 圆底（图钉同款克制），chip 为弱化小字，
///   发送钮仅在可发送瞬间实心强调色（空态 = 无底灰箭头）——空态视觉重心让回中部引导区
/// - 浏览导航（2026-10 重设计，取代竖排双↓胶囊簇）：右缘刻度轨（每条用户消息一枚 tick，
///   当前条 accent 点亮；hover 弹预览胶囊、点击跳转）+ 坞正上方 ↓ 回底钮；离开底部
///   足够距离（chatNavRevealDistance）才浮现、贴底隐藏——上滚一点点只暂停跟随不冒 UI
/// - 快捷键 ⌘N/⌘B/⌘F 由 AIChatKeyMonitor（本地事件监听）接线；ESC/⌘K 仍走窗口层；
///   快捷键提示全部由各控件 .help() tooltip 承担（底部提示条已删）
/// - 输入坞抽屉（2026-10 抽屉式交互）：权限确认 / AI 提问从输入框正上方向上滑出，
///   与输入卡共享同一个连续玻璃体（抽屉是输入卡"长出"的上半部分，详见
///   AIChatDrawerPanel.swift）；抽屉在场时 ESC 优先取消抽屉（权限 = 拒绝 / 提问 = 取消），
///   聊天流经 dockTotalHeight 实测自动让位，窗口 frame 不动
///
/// 公开接口（接线用）：
/// - `state`：会话状态（AIChatState.shared）。
/// - `onOpenSettings`：未配置引导卡片「打开设置…」的出口（注入 AppState.openSettings）。
/// - `onClose`：输入框聚焦时 ESC 的兜底出口（注入 AIWindowManager 的关窗逻辑）。
/// 标注 @MainActor：AIChatState 全程 @MainActor，视图与状态同隔离域，消除 actor 隔离错误。
@MainActor
struct AIChatView: View {
    @ObservedObject var state: AIChatState
    /// 输入坞抽屉交互中心：观察 request 驱动抽屉展开/收起（权限确认 / AI 提问）。
    @ObservedObject private var interaction = ChatInteractionCenter.shared
    var onOpenSettings: (() -> Void)?
    var onClose: (() -> Void)?

    init(state: AIChatState, onOpenSettings: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.state = state
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
        // 侧栏显隐偏好与 AIWindowManager 共用同一 UserDefaults 键（窗口首次取尺寸早于视图出现）
        _sidebarVisible = State(initialValue: UserDefaults.standard.bool(forKey: AIWindowManager.sidebarVisibleKey))
        // LRU 常驻集合以当前会话起步（避免首帧 ZStack 为空导致的闪烁/空窗）。
        _residentSessionIds = State(initialValue: state.store.currentSessionId.map { [$0] } ?? [])
        // 会话级阅读位置冷启动装载（跨重启记忆）：磁盘持久层 → 内存快照真源，
        // 重挂载/首次切回走 restoreScroll 恢复到上次阅读位置（无快照才贴底）。
        _scrollSnapshots = State(initialValue: state.store.loadScrollPositions().mapValues {
            ScrollSnapshot(topVisibleMessageID: $0.topMessageID, isPinned: $0.isPinned)
        })
    }

    /// 端点配置可用性：hasConfiguredEndpoint 读 UserDefaults/Keychain，非 @Published，
    /// 故在视图出现与关键窗口激活时主动刷新（避免设置后回到对话窗仍显示引导）。
    @State private var configured = false
    /// 输入坞实测总高（生长区 + 输入卡 + 底缝，即 AIChatInputDock 完整高度）：
    /// 由 AIChatInputDock 最外层 background 内 GeometryReader 的 onAppear/onChange 直写
    /// （macOS 13 无 onGeometryChange；preference 冒泡在本上下文实测中断不可用，
    /// 事件直写已被实证可靠），供消息列表尾部留白 / 空态 overlay / 导出 toast /
    /// 浏览导航统一消费——尾部留白 = 实测坞高 + 呼吸缝，随坞体动态生长；真穿透设计下
    /// 滚动内容穿入坞底由玻璃 blur 采样。值单向流入布局计算，绝不反向影响坞体布局
    /// （无反馈环）；初值 chatDockHeightFallback 首帧兜底，实测后校准；<0.5pt 去抖跳过。
    @State private var dockTotalHeight: CGFloat = Theme.Layout.chatDockHeightFallback
    /// 会话滚动控制中枢：每会话滚动事件「来源判定」（用户输入 vs 程序化/内容变化）+
    /// 程序化滚动仲裁。class 引用稳定，常驻会话经 bind/unbind 注册各自的处理闭包。
    @State private var scrollCoordinator = ChatScrollCoordinator()
    /// 会话窄栏显隐（持久化到 UserDefaults，窗口宽度联动见 AIWindowManager）。
    @State private var sidebarVisible = false
    /// 会话视图树 LRU 常驻集合（0 = 最近使用）。切换会话只改 opacity，视图常驻零重建：
    /// 滚动位置/贴底跟随/流式状态随视图树天然保留，位置记忆不再依赖 scrollTo 时序。
    /// 超上限 K 时淘汰尾部会话（其视图卸载，重挂载时用 scrollSnapshots 兜底恢复）。
    @State private var residentSessionIds: [UUID] = []
    /// LRU 常驻上限：1（仅活跃会话）。其余会话不建树，切换时按需重建——
    /// 由 MarkdownASTCache / 高亮 LRU / 逐会话 rowHeights 快照兜底，重建成本可控。
    /// 性能实证：常驻树数量直接决定聚焦期全树布局成本（12 常驻=2196 帧采样 →
    /// 3 常驻=748 帧 → 1 常驻≈活跃树本身）；聚焦/失焦不再连带重算非活跃会话树。
    /// 切换回被淘汰会话靠 scrollSnapshots 恢复阅读位置（见 restoreScroll）。
    private let residentSessionLimit = 1
    /// 按会话保存的滚动快照：仅 LRU 驱逐后的重挂载恢复需要（常驻会话靠视图树天然保留位置）。
    @State private var scrollSnapshots: [UUID: ScrollSnapshot] = [:]
    /// 各会话 latex 预热去重签名：签名未变则跳过重复收集/预热（见 prefetchMathLatex）。
    @State private var latexPrefetchSignatures: [UUID: LatexPrefetchSignature] = [:]
    /// 上一次观察到的会话 id 集合基线：检测会话被删除，清理快照与常驻集合中的死项。
    @State private var knownSessionIds: Set<UUID> = []
    /// ⌘F 聚焦令牌：递增即让侧栏搜索框聚焦。
    @State private var searchFocusRequest = 0
    /// 点击放大预览的图片附件（非 nil 时显示覆盖层，ESC/点击关闭）。
    @State private var zoomedAttachment: ChatImageAttachment?
    /// AI 窗快捷键监听（⌘N/⌘B/⌘F + 重命名/放大态下的 ESC 先行消费）。
    @State private var keyMonitor = AIChatKeyMonitor()
    /// 钉住常驻态（窗口层真源在 AIWindowManager，视图侧仅镜像渲染）。
    @State private var pinned = AIWindowManager.shared.isPinned
    /// 图钉按钮 hover 态。
    @State private var pinHovered = false
    /// 压缩状态变化戳（"count|boundaryId|isCompacting"）：state 的 compactionInfo/isCompacting
    /// 是无扇出属性的前提下，与 sessionConfigStamp 同款的触发器——订阅 store.$sessions
    /// 扇出时读取；removeDuplicates 挡流式冲刷，幂等赋值防重订阅重放循环。
    @State private var compactionStamp = ""
    /// 「导出对话」成功反馈 toast 可见态。
    @State private var exportToastVisible = false
    /// toast 世代令牌：连续导出时旧定时器不得提前收起新 toast。
    @State private var exportToastGeneration = 0
    /// 压缩结果反馈 toast 可见态（导出 toast 同款语言，坞上方浮出、1.6s 自动淡出）。
    @State private var compactionToastVisible = false
    /// 压缩 toast 世代令牌（同款语义：连续触发时旧定时器不得提前收起新 toast）。
    @State private var compactionToastGeneration = 0
    /// 已处理的压缩结果：防 @Published 重放误弹——窗口/视图重建时 onReceive 会先
    /// 收到一次当前值，非 nil 即误弹 toast；记录已处理值，仅在值真正变化时弹出。
    @State private var handledCompactionOutcome: CompactionOutcome?
    /// 当前明暗外观：会话预热取色与渲染路径严格对齐（颜色分量参与公式缓存 key，
    /// 取色外观不一致会让预热缓存无法命中）。
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            // 左侧会话窄栏（⌘B 显隐；窗口宽度由 AIWindowManager 同步加宽/收窄）。
            // 常驻视图 + 宽度 0↔sidebarWidth 动画：内层内容恒为最终宽度（不随动画重排），
            // 外层宽度与窗口 setFrame 同参数变化，消除旧「if 插拔瞬间占位挤窄主区、
            // 窗口渐宽再弹回」的跳变卡顿；.leading 锚定从左缘展开，clipped 裁掉溢出。
            AIChatSidebarView(
                store: state.store,
                searchFocusRequest: searchFocusRequest,
                renamingSessionId: $state.renamingSessionId,
                streamingSessionIds: state.streamingSessionIds,
                unreadSessionIds: state.unreadSessionIds,
                onAbortStreaming: { id in state.abortStreaming(sessionId: id) },
                onSelect: { id in state.selectSession(id: id) },
                onNewSession: { newSession() }
            )
            .opacity(sidebarVisible ? 1 : 0)
            .allowsHitTesting(sidebarVisible)
            .frame(width: sidebarVisible ? AIChatLayout.sidebarWidth : 0, alignment: .leading)
            .clipped()

            // 竖向细分割线（与横分割线同款两端羽化语言）：随侧栏同参数收拢/展开
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.0),
                            Color.primary.opacity(Theme.Colors.dividerOpacity),
                            Color.primary.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: sidebarVisible ? Theme.Layout.dividerHeight : 0)

            mainColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 内容层背景：26+ 整窗真玻璃透出（内容「印」在玻璃上，系统 Spotlight 语义）；
        // <26 降级铺 ultraThinMaterial。两窗共用 LiquidPanelBackground。
        .liquidPanelBackground()
        // 窗口边缘 rim light（方向性内描边：顶 ~70% 白 → 侧 ~15% → 底 ~5%，另底缘 1pt 黑 8% 重边）
        // 仅 <26 降级路径需要：26+ 整窗 NSGlassEffectView 自带 specular rim（受光方向 + 断面
        // 折光），手绘描边叠加会出双边缘。写在放大层之前：放大覆盖层激活时盖住 rim；
        // allowsHitTesting(false) 防描边层吞点击。
        .overlay {
            if !OSFeatures.liquidGlass {
                windowRimLight
                    .allowsHitTesting(false)
            }
        }
        // 图片点击放大覆盖层（轻量自实现；ESC 由 keyMonitor 先行消费关闭）
        // 注意顺序：overlay 必须写在圆角裁剪之前，否则 13~25 降级路径下覆盖层会是直角
        .overlay {
            if let zoomed = zoomedAttachment {
                ImageZoomOverlay(attachment: zoomed) {
                    withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                        zoomedAttachment = nil
                    }
                }
            }
        }
        .modifier(AIChatRoundedClip())
        .onAppear {
            refreshEnvironment()
            installKeyMonitor()
            pinned = AIWindowManager.shared.isPinned
            // 抽屉 UI 在场登记：逻辑层据此决定发布请求还是安全兜底（拒绝/取消）
            interaction.markUIActive(true)
        }
        .onDisappear {
            keyMonitor.remove()
            // UI 离场：挂起中的抽屉请求被唤醒为兜底结果（确认→拒绝 / 提问→取消），防泄漏
            interaction.markUIActive(false)
        }
        // B1：只在 AI 窗自身成为 key 时刷新（设置窗等本 App 其他窗口激活不误触；
        // 也避免无关窗口激活触发无谓的环境重算）。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard note.object is AIPanel else { return }
            // F3：异步化执行环境与钉住状态同步，确保 becomeKeyWindow 同步调用栈内
            // 零 @State 写入，绝不弄脏根节点，保证紧随的事件路由 hit-test 命中温热图。
            DispatchQueue.main.async {
                refreshEnvironment()
                let latestPinned = AIWindowManager.shared.isPinned
                if latestPinned != pinned { pinned = latestPinned }
            }
        }
        // 抽屉关闭（request 由非 nil 变 nil）后把焦点还回主输入框：
        // 提问面板的自由输入条持焦期间点提交/取消，焦点随抽屉移除悬空，须主动归还。
        .onChange(of: interaction.request == nil) { drawerGone in
            if drawerGone {
                NotificationCenter.default.post(name: .aiChatRefocusInput, object: nil)
            }
        }
        // 会话切换检测（根级恒挂载）：把新会话置入 LRU 常驻集合头部，超限淘汰尾部（视图卸载）。
        // dropFirst 跳过订阅时重放的当前值，避免首挂载误判；常驻集合已由 init 以当前会话起步。
        .onReceive(state.store.$currentSessionId.dropFirst()) { newId in
            updateResidency(for: newId)
        }
        // 会话删除检测：清理被删会话的滚动快照与 LRU 常驻项，防死项累积。
        // 以 id 集合 + removeDuplicates 收敛触发频率（流式冲刷不改 id 集合，不重复扇出）；
        // 初始订阅重放时 knownSessionIds 为空，subtracting 结果为空，不误判。
        .onReceive(state.store.$sessions.map { Set($0.map { $0.id }) }.removeDuplicates()) { currentIds in
            let disappeared = knownSessionIds.subtracting(currentIds)
                if !disappeared.isEmpty {
                    for id in disappeared {
                        scrollSnapshots.removeValue(forKey: id)
                        residentSessionIds.removeAll { $0 == id }
                    }
                    // 同步清理磁盘持久层，防死会话的位置记录残留（重挂载锚点已失效）。
                    state.store.persistScrollPositions(
                        scrollSnapshots.mapValues {
                            ChatSessionStore.PersistedScrollPosition(
                                topMessageID: $0.topVisibleMessageID, isPinned: $0.isPinned
                            )
                        }
                    )
                }
            knownSessionIds = currentIds
            // 恒定保证：当前会话必须常驻（residency 误删/竞态兜底；丢失则全部层 opacity=0 → 整片白屏）。
            // 侧栏选中只读 currentSessionId、与 residency 无关：residency 丢失时侧栏看似正常，
            // 但消息区全白，切一次会话才恢复——故此处每次扇出后无条件补齐。
            if let current = state.store.currentSessionId, !residentSessionIds.contains(current) {
                updateResidency(for: current)
            }
        }
        // 压缩状态（compactionInfo / isCompacting）变化 → 压缩边界卡与立即压缩入口刷新。
        // 触发器模式与 sessionConfigStamp 相同；压缩「结束」伴随 sessions 写入（compactionInfo
        // 落会话）必然覆盖，压缩「开始」态的即时刷新依赖 isCompacting 自身 @Published 扇出。
        .onReceive(
            state.store.$sessions
                .map { _ -> String in
                    let info = state.compactionInfo
                    return "\(info?.summarizedCount ?? -1)|\(info?.beforeMessageID ?? "")|\(state.isCompacting)"
                }
                .removeDuplicates()
        ) { stamp in
            if stamp != compactionStamp { compactionStamp = stamp }
        }
        // 压缩结果 → 视口内即时 toast：边界卡常落在会话流顶部（视口外）、圆环在安静态
        // 可能隐去，toast 浮于坞上方恒可见，是压缩成功/失败最可靠的即时信号。
        // 仅当前会话的结果弹出（自动压缩在流结束后异步触发，用户可能已切会话——
        // 跨会话弹「已压缩」会错位）；handledCompactionOutcome 防重建重放误弹。
        .onReceive(state.$lastCompactionOutcome) { outcome in
            guard let outcome, outcome != handledCompactionOutcome else { return }
            handledCompactionOutcome = outcome
            guard state.currentSessionOutcome != nil else { return }
            showCompactionToast()
        }
    }

    // MARK: - 窗口边缘 rim light

    /// 方向性内描边：1pt strokeBorder 沿窗口圆角矩形走，垂直多段渐变近似受光模型
    /// （顶缘受光最强 → 侧缘弱 → 底缘近无）；底缘再叠一条只在末端显形的 1pt 黑 8% 重边，
    /// 与窗口投影衔接出「厚度」。两层均为纯描边（无填充），不遮挡内容。
    private var windowRimLight: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(Theme.Colors.rimTopOpacity), location: 0.0),
                            .init(color: .white.opacity(Theme.Colors.rimSideOpacity), location: 0.30),
                            .init(color: .white.opacity(Theme.Colors.rimSideOpacity), location: 0.70),
                            .init(color: .white.opacity(Theme.Colors.rimBottomOpacity), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0), location: 0.85),
                            .init(color: .black.opacity(Theme.Colors.rimDarkEdgeOpacity), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
    }

    // MARK: - 主列（对话区 + 浮岛输入坞）

    /// 空态判据与 ZStack 同源：直读 store 当前会话，而非 `state.messages`（后者经
    /// CombineLatest + removeDuplicates 异步扇出，切换瞬间可能与 ZStack 直读的 store
    /// 真源差一帧——出现「ZStack 已空、overlay 判据仍非空」的单帧空白）。
    private var activeSessionMessagesEmpty: Bool {
        state.store.currentSession?.messages.isEmpty ?? true
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            windowTopBar

            // 消息列表容器常驻（ZStack 多会话树保活，绝不可插拔卸载——否则保活失效）。
            // 空态（未配置引导 / 欢迎页）以 overlay 盖在其上，视觉布局与原三态分支等价；
            // 空会话在 ZStack 内渲染 EmptyView，空态由本 overlay 承担。
            messageList
                .overlay {
                    // 底部 padding 叠加生长区实测高度：附件草稿可在空态出现（附件条会挡
                    // 欢迎页/引导页），遮挡带随坞体生长动态抬高
                    if !configured && activeSessionMessagesEmpty {
                        UnconfiguredGuideView(onOpenSettings: onOpenSettings)
                            .padding(.bottom, dockTotalHeight)
                            .animation(.easeOut(duration: Theme.Motion.contentFade), value: dockTotalHeight)
                    } else if activeSessionMessagesEmpty {
                        WelcomeView(
                            // B2：已移除聚焦时主动探测剪贴板；欢迎页剪贴板快捷入口不再动态展示
                            // （显式入口保留在输入坞的剪贴板/⊕ 菜单，点击时按需读取）。
                            hasClipboardText: false,
                            onAttachClipboard: { attachClipboard() }
                        )
                        .padding(.bottom, dockTotalHeight)
                        .animation(.easeOut(duration: Theme.Motion.contentFade), value: dockTotalHeight)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 输入坞浮岛化：overlay 悬浮于消息列表之上（不再与列表上下拼接）。
        // 真穿透：滚动内容自然穿入玻璃坞下方，坞体实时 blur 采样透出模糊内容；
        // 列表尾部留白 = 实测坞高 + 呼吸缝，保证滚到底时末条消息完整露出坞顶上方
        // （见 SessionMessageList）——坞体生长（队列胶囊等在坞顶向上生长、工具行换态）
        // 留白随之动态跟随。
        .overlay(alignment: .bottom) {
            AIChatInputDock(
                state: state,
                dockTotalHeight: $dockTotalHeight,
                onAttachClipboard: { attachClipboard() },
                onExportConversation: { exportConversation() },
                onEscape: { handleEscape() }
            )
        }
        // 导出成功轻反馈：输入坞上方浮出胶囊（复用 toast 令牌语言），1.6s 自动淡出；
        // 底部 padding 叠加生长区高度——生成中导出时队列胶囊在场，toast 须抬到生长区之上
        .overlay(alignment: .bottom) {
            if exportToastVisible {
                Text("已复制对话 Markdown")
                    .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .padding(.horizontal, Theme.Spacing.card)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(Capsule(style: .continuous).fill(Theme.Colors.toastFill))
                    .overlay(Capsule(style: .continuous).stroke(Theme.Colors.toastStroke, lineWidth: 0.5))
                    .padding(.bottom, dockTotalHeight + Theme.Spacing.lg)
                    .animation(.easeOut(duration: Theme.Motion.contentFade), value: dockTotalHeight)
                    .transition(.opacity.combined(with: .scale(scale: Theme.Motion.toastScale)))
            }
        }
        // 压缩结果轻反馈：与导出 toast 同位同语言（坞上方胶囊、1.6s 自动淡出）；
        // 成功纯文字，失败前置警示三角——克制度对齐：不整行变红，图标一点警示色足够
        .overlay(alignment: .bottom) {
            if compactionToastVisible, let outcome = state.currentSessionOutcome {
                HStack(spacing: Theme.Spacing.sm) {
                    if case .failed = outcome {
                        Image(systemName: "exclamationmark.triangle")
                            .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                            .foregroundColor(Theme.Colors.statusWarning)
                    }
                    Text(compactionToastText(outcome))
                        .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                        .foregroundColor(Theme.Colors.contentPrimary)
                }
                .padding(.horizontal, Theme.Spacing.card)
                .padding(.vertical, Theme.Spacing.md)
                .background(Capsule(style: .continuous).fill(Theme.Colors.toastFill))
                .overlay(Capsule(style: .continuous).stroke(Theme.Colors.toastStroke, lineWidth: 0.5))
                .padding(.bottom, dockTotalHeight + Theme.Spacing.lg)
                .animation(.easeOut(duration: Theme.Motion.contentFade), value: dockTotalHeight)
                .transition(.opacity.combined(with: .scale(scale: Theme.Motion.toastScale)))
            }
        }
        // 全窗材质两级收敛：根部 ultraThinMaterial 是唯一内容基面（铺满主列与阅读区），
        // 输入坞 glass 是唯一浮层语言；此处不再叠第二层材质，全窗亮度关系唯一且自洽。
    }

    // MARK: - 顶部拖动条（移动窗口 + 图钉）

    /// 顶部拖动条：36pt 全宽，左段为可拖动区域，右端图钉经 chatReadingColumn 对齐——
    /// 图钉右缘 = 阅读列右缘（统一右基准线），与内容/坞卡同一条线，不再悬浮于真空中。
    private var windowTopBar: some View {
        WindowDragHandle()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .trailing) {
                pinButton
                    .chatReadingColumn(alignment: .trailing)
            }
            .frame(height: Theme.Layout.chatTopBarHeight)
            .frame(maxWidth: .infinity)
        // 纯透明热区：不铺 glass/底色/描边——顶栏只承担拖动与图钉命中功能，
        // 根部内容材质一铺到窗口圆角，恢复重构前的一体观感（告别独立「帽子」横带）。
        // WindowDragHandle 命中区完整保留，拖动/吸附功能不受影响。
    }

    /// 图钉按钮：与主面板 StatusBarView 同一克制语言——静止 iconRest 灰、hover 提亮 + 圆底，
    /// pinned 态仅 accent 着色 pin.fill 表达状态，不叠高饱和圆块（全窗唯一的浮起语言留给输入坞）。
    private var pinButton: some View {
        Button {
            AIWindowManager.shared.togglePin()
            pinned = AIWindowManager.shared.isPinned
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(Theme.Typography.text(Theme.Typography.callout, .medium))
                .foregroundColor(pinned
                                 ? Theme.Colors.accent
                                 : (pinHovered ? Theme.Colors.iconHover : Theme.Colors.iconRest))
                .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
                .background(
                    Circle().fill(pinHovered ? Theme.Colors.iconHoverBg : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { pinHovered = hovering }
        }
        .qsHelp(pinned ? "已常驻置顶 (点击解除)" : "点击常驻置顶")
    }

    // MARK: - 消息列表

    private var messageList: some View {
        // 多会话视图树保活：每个常驻会话一份完整独立的 ScrollViewReader+ScrollView+LazyVStack
        // 叠在 ZStack 中，切换只切 opacity/allowsHitTesting——零身份重建、零重新解析。
        // LRU 顺序由 residentSessionIds 维护；隐藏会话仍随 store 失效重求值，但 .equatable()
        // 行会跳过未变内容，开销与原单会话同量级。
        ZStack(alignment: .top) {
            ForEach(residentSessionIds, id: \.self) { sid in
                let isActive = sid == state.store.currentSessionId
                // R1：非活跃会话树退出布局/渲染走查（key 态变化全树布局 ~1.8s 的主来源 =
                // 3 棵 opacity(0) 常驻树仍参与布局遍历）。用 `.hidden()`（`_HiddenModifier`，
                // 始终挂在同一视图上）替代 `.opacity(0)`——保留视图身份与 @State（区别于
                // `if` 插拔），但不参与布局与渲染。
                // 例外：后台**流式中**会话保留 `.opacity(0)`——其贴底跟随依赖底层
                // NSScrollView 的实测几何（ChatScrollCoordinator 的 frame 路径），隐藏
                // 可能令几何退化为 0 而误判；流式会话内容高度持续变化，风险最大。
                let isStreaming = state.isStreaming(sessionId: sid)
                SessionMessageList(
                    sessionId: sid,
                    isActive: isActive,
                    state: state,
                    messages: state.store.messages(in: sid),
                    onTapImage: { attachment in
                        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                            zoomedAttachment = attachment
                        }
                    },
                    scrollSnapshots: $scrollSnapshots,
                    scrollCoordinator: scrollCoordinator,
                    dockTotalHeight: dockTotalHeight
                )
                .modifier(InactiveSessionVisibility(isActive: isActive, isStreaming: isStreaming))
                .allowsHitTesting(isActive)
                // S5：不可见子树 accessibility 剪枝——LRU 非活跃会话整棵树对无障碍
                // 本质不可见，却会被 SwiftUI 纳入 AccessibilityViewGraph 全树遍历
                // （实测占主线程可观的样本）。结构性不可见即从无障碍树摘除。
                .accessibilityHidden(!isActive)
            }
        }
        // 空态布局兜底：常驻会话全空时 SessionMessageList 均为 EmptyView，
        // ZStack 高度塌缩为 0 会令 mainColumn 的 VStack 垂直居中——顶栏（图钉+拖动热区）
        // 整体掉到窗口中部（冷启动全空常驻集合时偶现）。此处令列表容器永远占据
        // 顶栏以下全部剩余高度，顶栏恒定钉在顶部，空态欢迎页由外层 overlay 承担。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// LRU 常驻集合更新：新会话移到头部；超出上限淘汰尾部（其视图卸载，重挂载时快照兜底）。
    /// 会话首次进入常驻集合（视图将新建，首帧会构建公式）时，后台预热其数学公式缓存，
    /// 使行内公式的同步光栅化路径大多直接命中缓存，避免首帧主线程卡顿。
    private func updateResidency(for newId: UUID?) {
        guard let newId else { return }
        let isNewlyResident = !residentSessionIds.contains(newId)
        var updated = residentSessionIds
        updated.removeAll { $0 == newId }
        updated.insert(newId, at: 0)
        if updated.count > residentSessionLimit {
            updated.removeLast(updated.count - residentSessionLimit)
        }
        if updated != residentSessionIds { residentSessionIds = updated }
        if isNewlyResident { prefetchMathLatex(in: newId) }
    }

    /// 选中会话的公式预热：提取会话内全部助手消息的块级/行内 latex，按各自展示模式与取色
    /// 外观分别后台预热（模式/颜色分量参与缓存 key，须与渲染路径对齐）。
    ///
    /// 性能：① 签名去重——同一会话内容未变则跳过重复收集；② 收集（解析+遍历）整体移出主线程
    /// （MarkdownParser 为纯函数，解析缓存已加锁线程安全），主线程只做颜色外观解析与派发，
    /// 消除大会话在 updateResidency 的主线程卡顿。
    private func prefetchMathLatex(in sessionId: UUID) {
        let messages = state.store.messages(in: sessionId)
        guard !messages.isEmpty else { return }

        let signature = LatexPrefetchSignature(
            messageCount: messages.count,
            totalChars: messages.reduce(0) { $0 + $1.content.count },
            lastMessageID: messages.last?.id
        )
        if latexPrefetchSignatures[sessionId] == signature { return }
        latexPrefetchSignatures[sessionId] = signature

        let assistantContents = messages.filter { $0.role == .assistant }.map(\.content)
        guard !assistantContents.isEmpty else { return }

        // 颜色外观解析留在主线程（AppKit 颜色解析需主线程上下文），后台仅做纯解析 + 收集 + 预热。
        let appearance = MathRasterizer.appearance(for: colorScheme)
        let blockColor = MathRasterizer.resolvedColor(Theme.Colors.contentPrimary, appearance: appearance)
        let inlineColor = MathRasterizer.resolvedColor(Color.primary.opacity(0.80), appearance: appearance)

        DispatchQueue.global(qos: .utility).async {
            var displayLatex: [String] = []
            var inlineLatex: [String] = []
            var seenDisplay = Set<String>()
            var seenInline = Set<String>()
            for content in assistantContents {
                // 后台复用（已加锁的）解析缓存：未命中则后台解析并回填，与随后主线程首帧共用。
                let blocks = AssistantMarkdownView.parsedBlocksForPrefetch(content)
                for latex in MathLatexCollector.collectBlockMathLatex(blocks: blocks)
                where seenDisplay.insert(latex).inserted {
                    displayLatex.append(latex)
                }
                for latex in MathLatexCollector.collectInlineMathLatex(blocks: blocks)
                where seenInline.insert(latex).inserted {
                    inlineLatex.append(latex)
                }
            }
            if !displayLatex.isEmpty {
                // 块级：mathBlockView 的 contentPrimary + 14pt display 模式。
                MathRasterizer.prefetch(latexList: displayLatex, pointSize: 14, color: blockColor, isDisplay: true)
            }
            if !inlineLatex.isEmpty {
                // 行内：正文默认取色（primary 0.80）+ 基准 13pt text 模式。
                MathRasterizer.prefetch(latexList: inlineLatex, pointSize: 13, color: inlineColor, isDisplay: false)
            }
        }
    }

    /// 刷新非 @Published 的外部环境：端点配置（模型列表已随坞体自持刷新）。
    /// B2：不再在窗口激活时主动读取 NSPasteboard（原 string + containsImage 可阻塞 XPC，
    /// 是聚焦迟滞来源之一）；剪贴板文本/图片改为用户显式操作时按需读取。
    private func refreshEnvironment() {
        // F3：等值门控——becomeKey 调用栈内同步派发时，非 @Published 的 configured 常在
        // 重聚焦时并无变化；无条件赋值会弄脏根节点、加重紧随的光标 hit-test。
        let latestConfigured = state.hasConfiguredEndpoint
        if latestConfigured != configured { configured = latestConfigured }
    }

    /// 附加剪贴板文本（空剪贴板静默无动作）。
    private func attachClipboard() {
        _ = state.attachClipboard()
    }

    /// 导出整段对话 Markdown 到剪贴板，浮出轻量成功反馈（不阻塞；世代令牌防连续导出被提前收起）。
    private func exportConversation() {
        let markdown = state.exportConversationMarkdown()
        guard !markdown.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        exportToastGeneration += 1
        let generation = exportToastGeneration
        withAnimation(.easeInOut(duration: Theme.Motion.contentFade)) { exportToastVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.toastDuration) {
            guard generation == exportToastGeneration else { return }
            withAnimation(.easeInOut(duration: Theme.Motion.toastOut)) { exportToastVisible = false }
        }
    }

    /// 压缩结果轻反馈（导出 toast 同款：世代令牌 + 1.6s 自动淡出）。
    private func showCompactionToast() {
        compactionToastGeneration += 1
        let generation = compactionToastGeneration
        withAnimation(.easeInOut(duration: Theme.Motion.contentFade)) { compactionToastVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.toastDuration) {
            guard generation == compactionToastGeneration else { return }
            withAnimation(.easeInOut(duration: Theme.Motion.toastOut)) { compactionToastVisible = false }
        }
    }

    /// 压缩 toast 文案：成功报本次条数（非累计值，更诚实）；失败带一句原因简述。
    private func compactionToastText(_ outcome: CompactionOutcome) -> String {
        switch outcome {
        case .succeeded(_, let count, _): return "已压缩 \(count) 条早期对话"
        case .failed(_, let reason): return "压缩失败：\(reason)"
        }
    }

    /// 新建会话（⌘N 与侧栏按钮共用）：若正处于行内重命名则先退出。
    private func newSession() {
        state.renamingSessionId = nil
        _ = state.newSession()
    }

    /// 侧栏显隐切换（⌘B）：视图状态 + 窗口宽度联动（AIWindowManager 内写偏好并动画调宽）。
    private func toggleSidebar() {
        setSidebarVisible(!sidebarVisible)
    }

    private func setSidebarVisible(_ visible: Bool) {
        guard visible != sidebarVisible else { return }
        // 曲线/时长与窗口侧 animator().setFrame 严格一致（AIWindowManager.setSidebarVisible
        // 的 easeInEaseOut + windowResize；SwiftUI 侧同名曲线为 easeInOut）：
        // 内容宽度与窗口 frame 同速变化，窗与内容一体伸缩
        withAnimation(.easeInOut(duration: Theme.Motion.windowResize)) {
            sidebarVisible = visible
        }
        AIWindowManager.shared.setSidebarVisible(visible)
    }

    // MARK: - 快捷键监听（⌘N/⌘B/⌘F + 重命名/放大态 ESC 先行消费）

    private func installKeyMonitor() {
        keyMonitor.isDrawerOpen = { ChatInteractionCenter.shared.request != nil }
        keyMonitor.onCancelDrawer = { _ = self.cancelActiveDrawerIfNeeded() }
        keyMonitor.isRenaming = { AIChatState.shared.renamingSessionId != nil }
        keyMonitor.onCancelRename = { AIChatState.shared.renamingSessionId = nil }
        keyMonitor.isZooming = { zoomedAttachment != nil }
        keyMonitor.onDismissZoom = {
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                zoomedAttachment = nil
            }
        }
        keyMonitor.onNewSession = { newSession() }
        keyMonitor.onToggleSidebar = { toggleSidebar() }
        // ⌘F：侧栏收起时先展开，再聚焦搜索框
        keyMonitor.onFocusSearch = {
            if !sidebarVisible { setSidebarVisible(true) }
            searchFocusRequest += 1
        }
        keyMonitor.install()
    }

    /// ESC 阶段语义（输入框聚焦时的兜底路径）：
    /// ⓪ 抽屉在场 → 先取消抽屉（权限 = 拒绝 / 提问 = 取消）；
    /// ① 行内重命名进行中 → 先取消重命名（不关窗、不中止流）；
    /// ② 流式中 → 中止生成；③ 否则关窗还焦点。
    private func handleEscape() {
        if cancelActiveDrawerIfNeeded() { return }
        if state.renamingSessionId != nil {
            state.renamingSessionId = nil
            return
        }
        if state.isStreaming {
            state.abortStreaming()
        } else {
            onClose?()
        }
    }

    /// ESC 阶段 0（与窗口层 AIPanel / 按键监听 AIChatKeyMonitor 三条链路同一语义）：
    /// 抽屉在场时取消并消费本次 ESC；权限抽屉 = 拒绝，提问抽屉 = 取消。
    /// 返回 true = 已消费。request 由逻辑层清空，抽屉随动画收起。
    private func cancelActiveDrawerIfNeeded() -> Bool {
        guard let request = interaction.request else { return false }
        switch request {
        case .toolConfirmation:
            interaction.resolveConfirmation(.denied)
        case .userQuestions:
            interaction.cancelQuestions()
        }
        return true
    }
}

// MARK: - R1：非活跃会话可见性

/// 非活跃常驻会话的可见性处置：始终作为同一视图上的 modifier（身份/@State 保留），
/// 区别于 `if` 插拔。
/// - 活跃：原样；
/// - 非活跃且流式中：`.opacity(0)`（后台贴底跟随依赖 AppKit 实测几何，隐藏有风险）；
/// - 非活跃且非流式：`.hidden()`（退出布局与渲染走查）。
private struct InactiveSessionVisibility: ViewModifier {
    let isActive: Bool
    let isStreaming: Bool

    func body(content: Content) -> some View {
        if isActive {
            content
        } else if isStreaming {
            content.opacity(0)
        } else {
            content.hidden()
        }
    }
}

// MARK: - R2：tooltip 全关开关

/// tooltip 全关开关：`QUICKSHOW_TOOLTIPS=off`（环境变量优先，UserDefaults 兜底）。
/// 语义**全有/全无**——`.help()` 的数量与鼠标风暴无关（一次 key 变化一次查找），
/// 本开关只用于实验隔离「tooltip 体系触碰 responder 图导致的重建 ~0.5s」：
/// 关闭时整窗 AI 消息树不再建立任何 tooltip 关联。
private enum QSHelpSwitch {
    static var isEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["QUICKSHOW_TOOLTIPS"] {
            return raw.lowercased() != "off"
        }
        if let raw = UserDefaults.standard.string(forKey: "QUICKSHOW_TOOLTIPS") {
            return raw.lowercased() != "off"
        }
        return true
    }
}

extension View {
    /// R2：包一层可关断的 `.help`。开关开启（默认）等价 `.help(text)`；关闭则不附加任何
    /// tooltip 修饰器。AI 窗消息树相关调用点统一改用本方法。
    @ViewBuilder
    func qsHelp(_ text: String) -> some View {
        if QSHelpSwitch.isEnabled {
            self.help(text)
        } else {
            self
        }
    }
}
