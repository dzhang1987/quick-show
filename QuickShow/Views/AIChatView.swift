import AppKit
import Combine
import SwiftUI

/// AI 对话视图（Lane C）：将嵌入 NSHostingView，由 AIWindowManager 管理外窗尺寸与焦点。
/// 视觉常量全部走 DesignTokens 令牌（AI 专用令牌集中在 DesignTokens 的 chatXxx 区，本文件不硬编码）。
///
/// Wave 3 结构（2026-10 视觉质感专项）：
/// - 左侧会话窄栏（⌘B 显隐，展开时窗口整体加宽，见 AIWindowManager.setSidebarVisible）
/// - 消息列表铺满窗口主体：AI 回复无气泡铺底排版；落定助手消息下方常驻弱显示操作行（复制/重新生成）
/// - 输入坞浮岛化：overlay 悬浮于消息列表之上；滚动区底缘 26pt 渐隐带止于坞顶，
///   内容在到达坞之前收没，绝不露出被裁的半截内容（2026-10 重设计取代 blur-through）
/// - 整窗方向性 rim light（顶亮侧弱底微）+ 输入坞双层阴影 + 激活态 accent rim（安静态零描边）
/// - 输入坞安静/激活渐进披露：安静态（无草稿/未悬停）收敛为纯输入行，低频工具（剪贴板/
///   水位/压缩）隐去；控件语言为纯灰图标 + hover 圆底（图钉同款克制），chip 为弱化小字，
///   发送钮仅在可发送瞬间实心强调色（空态 = 无底灰箭头）——空态视觉重心让回中部引导区
/// - 浏览导航（2026-10 重设计，取代竖排双↓胶囊簇）：右缘刻度轨（每条用户消息一枚 tick，
///   当前条 accent 点亮；hover 弹预览胶囊、点击跳转）+ 坞正上方 ↓ 回底钮；浏览态显示、贴底隐藏
/// - 快捷键 ⌘N/⌘B/⌘F 由 AIChatKeyMonitor（本地事件监听）接线；ESC/⌘K 仍走窗口层；
///   快捷键提示全部由各控件 .help() tooltip 承担（底部提示条已删）
///
/// 公开接口（接线用）：
/// - `state`：会话状态（AIChatState.shared）。
/// - `onOpenSettings`：未配置引导卡片「打开设置…」的出口（注入 AppState.openSettings）。
/// - `onClose`：输入框聚焦时 ESC 的兜底出口（注入 AIWindowManager 的关窗逻辑）。
/// 标注 @MainActor：AIChatState 全程 @MainActor，视图与状态同隔离域，消除 actor 隔离错误。
@MainActor
struct AIChatView: View {
    @ObservedObject var state: AIChatState
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

    /// 输入框占位文案（快捷键语义由各控件 .help() tooltip 承担，占位只留一句）。
    private let inputPlaceholder = "问点什么…"

    /// 端点配置可用性：hasConfiguredEndpoint 读 UserDefaults/Keychain，非 @Published，
    /// 故在视图出现与关键窗口激活时主动刷新（避免设置后回到对话窗仍显示引导）。
    @State private var configured = false
    /// 输入内容空态：独立于 state.inputText 的回写通道（IME 组字期间由 setMarkedText 回调驱动）。
    /// 显隐判据须与 state.inputText.isEmpty 取与：@State 初值固定为 true 且首挂载无变化事件
    /// （onChange 不响应初始值、updateNSView 周期内写 state 不可靠），单通道会在草稿恢复
    /// （重启载入 / 程序化填充）时与既有文字重影；派生条件首帧求值即正确，零时序依赖。
    @State private var inputEmpty = true
    /// 输入坞实测总高（生长区 + 输入卡 + 底缝，即 inputArea 完整高度）：
    /// 由 inputArea 最外层 background 内 GeometryReader 的 onAppear/onChange 直写
    /// （macOS 13 无 onGeometryChange；preference 冒泡在本上下文实测中断不可用，
    /// 事件直写已被实证可靠），供渐隐带锚点 / 消息列表尾部留白 / 空态 overlay /
    /// 导出 toast / 浏览导航统一消费——渐隐带 fadeEnd 恒锚定真实坞顶（穿透衔接不脱开），
    /// 尾部留白随坞体动态生长。值单向流入布局计算，绝不反向影响坞体布局（无反馈环）；
    /// 初值 chatDockHeightFallback 首帧兜底，实测后校准；<0.5pt 去抖跳过。
    @State private var dockTotalHeight: CGFloat = Theme.Layout.chatDockHeightFallback
    /// 剪贴板是否有可用文本（控制剪贴板按钮弱化不可点）。
    @State private var hasClipboardText = false
    /// 剪贴板是否有可用图片（控制 ⊕ 菜单「剪贴板导入」可用态）。
    @State private var hasClipboardImage = false
    /// 会话滚动控制中枢：每会话滚动事件「来源判定」（用户输入 vs 程序化/内容变化）+
    /// 程序化滚动仲裁。class 引用稳定，常驻会话经 bind/unbind 注册各自的处理闭包。
    @State private var scrollCoordinator = ChatScrollCoordinator()
    /// 会话窄栏显隐（持久化到 UserDefaults，窗口宽度联动见 AIWindowManager）。
    @State private var sidebarVisible = false
    /// 会话视图树 LRU 常驻集合（0 = 最近使用）。切换会话只改 opacity，视图常驻零重建：
    /// 滚动位置/贴底跟随/流式状态随视图树天然保留，位置记忆不再依赖 scrollTo 时序。
    /// 超上限 K 时淘汰尾部会话（其视图卸载，重挂载时用 scrollSnapshots 兜底恢复）。
    @State private var residentSessionIds: [UUID] = []
    /// LRU 常驻上限：12。用户会话数通常在 10 以内，提高上限使绝大多数会话全程常驻，
    /// 切换回到纯 opacity 切换、零整树重建（消除重挂载卡顿与锚点恢复需求）。
    /// 内存代价见报告：每常驻会话 = 其视图树 + 已实现化的 NSTextField 池（消息行），
    /// 公式位图不常驻于会话（在 MathRasterizer 共享 LRU 缓存，上限 512）；解析 AST 走全局
    /// 64 条/600k 字符预算缓存。上限 12 时最坏约「12 × 各会话已实现行」，仍由 LazyVStack
    /// 视口附近实现化约束（本机 macOS 13 实现化偏粘滞，见报告评估）。
    private let residentSessionLimit = 12
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
    /// 模型列表（AIChatService 非 @Published，随环境刷新主动拉取；
    /// 当前生效模型改读 state 会话级绑定，此处不再镜像选中态）。
    @State private var modelList: [AIModel] = []
    /// AI 窗快捷键监听（⌘N/⌘B/⌘F + 重命名/放大态下的 ESC 先行消费）。
    @State private var keyMonitor = AIChatKeyMonitor()
    /// 钉住常驻态（窗口层真源在 AIWindowManager，视图侧仅镜像渲染）。
    @State private var pinned = AIWindowManager.shared.isPinned
    /// 图钉按钮 hover 态。
    @State private var pinHovered = false
    /// 坞区 hover 态：安静/激活两态切换的触发源之一（鼠标进入坞区即浮现完整工具行）。
    /// 输入框唤出即自动聚焦（windowDidBecomeKey 兜底），"聚焦"恒为真、无法作披露信号，
    /// 故渐进披露的诚实触发源 = 坞区 hover + 内容存在（草稿/附件/队列/生成中）。
    @State private var dockHovered = false
    /// 窗口 key 态：输入卡激活 rim 的门控之一（与 dockQuiet 共同决定，见 dockRimActive；
    /// 窗口 key 时输入框必被抬为第一响应者，见 ChatInputTextView 的 windowDidBecomeKey 兜底；
    /// isKeyWindow 近似足够，不侵入事件链）。
    @State private var windowIsKey = false
    /// 输入坞微胶囊 hover 态（⊕ / 剪贴板 / 模型 chip / 思考 chip 的 hover 提亮）。
    @State private var attachHovered = false
    @State private var clipboardHovered = false
    @State private var chipHovered = false
    @State private var thinkingChipHovered = false
    /// 压缩状态变化戳（"count|boundaryId|isCompacting"）：state 的 compactionInfo/isCompacting
    /// 是无扇出属性的前提下，与 sessionConfigStamp 同款的触发器——订阅 store.$sessions
    /// 扇出时读取；removeDuplicates 挡流式冲刷，幂等赋值防重订阅重放循环。
    @State private var compactionStamp = ""
    /// 会话配置变化戳（"modelId|level"）：state 的会话级模型/思考档位是读 store 的计算属性，
    /// 且 state 的消息扇出管线按 messages 去重（只改模型/档位时消息数组不变、不扇出）——
    /// 此处作 chip 刷新的触发器：订阅当前会话两字段，变化时更新戳驱动 body 重算；
    /// 赋值幂等（重放同值不写入），防 onReceive 重订阅重放导致的更新循环。
    @State private var sessionConfigStamp = ""
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
            windowIsKey = NSApp.keyWindow is AIPanel
        }
        .onDisappear {
            keyMonitor.remove()
        }
        // 回到/激活 AI 窗口时刷新配置与剪贴板可用态（设置窗口改动后可即时生效）
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            refreshEnvironment()
            pinned = AIWindowManager.shared.isPinned
            // 输入卡激活 rim 门控：只在 AI 窗自身成为 key 时计入（其他窗口激活不误触）
            if note.object is AIPanel { windowIsKey = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if note.object is AIPanel { windowIsKey = false }
        }
        // 外部清空输入（发送 / ⌘K / 重试）经 state.inputText 变化同步空态。
        // 组字期间 ChatInputNSTextView 的 setMarkedText 回调已实时同步 state.inputText（见 syncInputState），
        // 因此这里对组字文本同样生效；绑定与 textView.string 一致后不会形成回写回路。
        .onChange(of: state.inputText) { newValue in
            inputEmpty = newValue.isEmpty
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
        // 会话级模型/思考档位变化 → 模型/思考 chip 跟随刷新（触发器为何必要的说明
        // 见 sessionConfigStamp 注释；切会话路径由上方 messages 扇出管线天然覆盖）。
        .onReceive(
            state.store.$sessions
                .map { sessions -> String in
                    let current = sessions.first(where: { $0.id == state.store.currentSessionId })
                    return "\(current?.modelId ?? "")|\(current?.thinkingLevel?.rawValue ?? "")"
                }
                .removeDuplicates()
        ) { stamp in
            if stamp != sessionConfigStamp { sessionConfigStamp = stamp }
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
                            hasClipboardText: hasClipboardText,
                            onAttachClipboard: { attachClipboard() }
                        )
                        .padding(.bottom, dockTotalHeight)
                        .animation(.easeOut(duration: Theme.Motion.contentFade), value: dockTotalHeight)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 输入坞浮岛化：overlay 悬浮于消息列表之上（不再与列表上下拼接）。
        // 滚动区底缘 26pt 渐隐带锚定 inputArea 实测总高 = 真实坞顶（见 SessionMessageList
        // 的 mask），内容渐隐没入玻璃坞下（穿透衔接），不再从坞下露出被裁的半截内容。
        // 列表尾部留白 = 实测坞高 + 渐隐带 + 呼吸缝，保证滚到底时末条消息完整露出
        // 渐隐带上缘——坞体生长（队列胶囊等在坞顶向上生长、工具行换态）遮挡带随之动态跟随。
        .overlay(alignment: .bottom) {
            inputArea
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
        .help(pinned ? "已常驻置顶 (点击解除)" : "点击常驻置顶")
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
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
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

    // MARK: - 输入区（浮岛输入坞）

    // MARK: 坞体安静/激活两态（渐进披露）

    /// 安静态判据：无草稿、无附件、无待注入队列、非生成中，且鼠标不在坞区。
    /// 安静态下坞收敛为「纯输入行 + 弱化小字 chip + 无底灰箭头」——无 accent rim、
    /// 无实心色块、低频工具隐去，空态视觉重心让回中部引导区；
    /// 悬停坞区 / 开始输入 / 附加内容 / 生成开始即切换激活态（0.16s 淡入，contentFade）。
    private var dockQuiet: Bool {
        // 空态判据双通道与：草稿恢复期 inputEmpty 可能滞后（@State 初值 true、首帧无变化事件），
        // state.inputText 非空即有草稿，首帧即正确（见 inputEmpty 声明处注释）。
        inputEmpty
            && state.inputText.isEmpty
            && state.clipboardAttachment == nil
            && state.imageAttachments.isEmpty
            && state.pendingQueue.isEmpty
            && !state.isStreaming
            && !dockHovered
    }

    /// 激活态描边：坞体激活且窗口 key 时才点亮 accent 环（旧版仅按窗口 key 常亮，
    /// 空态下形成横贯底部的整圈彩色轮廓带——全图唯一彩色轮廓即源于此）。
    private var dockRimActive: Bool { windowIsKey && !dockQuiet }

    /// 低频工具组（压缩/水位/剪贴板）显隐：安静态隐去（保留占位、纯透明渐变、布局零跳动）；
    /// 唯水位逼近上限时破格常显——需要警示的时刻不沉默。
    private var showDockSecondaryTools: Bool { !dockQuiet || watermarkBreaksThrough }

    /// 水位警示破格：用量占比 > 0.8（与细条进红同一阈值）。
    private var watermarkBreaksThrough: Bool { (state.contextWatermark?.ratio ?? 0) > 0.8 }

    /// 发送钮实心态判据：可发送或生成中（驱动 禁用灰箭头 ⇄ 实心强调色 的淡变）。
    private var sendButtonSolid: Bool { state.isStreaming || canSend }

    /// 生长区是否在场（队列/附件/剪贴板任一非空）：与 inputArea 生长区容器的 if 判据同源。
    private var hasDockGrowth: Bool {
        !state.pendingQueue.isEmpty
            || !state.imageAttachments.isEmpty
            || state.clipboardAttachment != nil
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // 生长区（输入卡上方：队列胶囊 / 附件条 / 剪贴板胶囊）：容器化以便整段实测高度
            // （background 内 GeometryReader + preference，macOS 13 无 onGeometryChange；
            // 先例见 ChatReadingColumn 的宽度读取）。间距语义与三段直接并列完全等价——
            // 段间 lg 收进内层，末段与输入卡的 lg 仍由外层承担，三段全空时容器整体缺席，
            // 布局与展开前逐点一致。
            if hasDockGrowth {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    // 待注入队列（steering 转向 / follow-up 追问）：生成中 ⏎/⌥⏎ 的消息在此排队，
                    // 点击胶囊取回编辑；队列区置于坞体顶部、随内容向上生长，宽度与坞一致。
                    if !state.pendingQueue.isEmpty {
                        VStack(spacing: Theme.Spacing.sm) {
                            ForEach(state.pendingQueue) { item in
                                QueuedInputCapsule(item: item) {
                                    state.recallQueuedInput(id: item.id)
                                }
                                .transition(.opacity.combined(with: .scale(scale: Theme.Motion.toastScale)))
                            }
                        }
                        .animation(.easeOut(duration: Theme.Motion.contentFade), value: state.pendingQueue)
                    }

                    // 待发送图片附件条：缩略图胶囊横排，可单个移除
                    if !state.imageAttachments.isEmpty {
                        ImageAttachmentStrip(attachments: state.imageAttachments) { id in
                            state.removeImageAttachment(id: id)
                        }
                    }

                    // 剪贴板附加胶囊：非 nil 时显示，可一键移除
                    if let clip = state.clipboardAttachment {
                        ClipboardAttachmentCapsule(charCount: clip.count) {
                            state.removeClipboardAttachment()
                        }
                    }
                }
                // 坞体高度上报已上移至 inputArea 根（整体实测直写 @State），
                // 生长区容器不再单独上报——生长区高度变化经总高自然捕获。
            }

            // 输入卡：文本区 + 底部工具行（⊕ 附件 / 模型 chip / 思考 chip ║ 低频工具组 / 发送）；
            // 安静/激活两态语义见 dockQuiet
            VStack(spacing: 0) {
                // 输入框：NSViewRepresentable 包装 NSTextView（自定义 ⏎/⇧⏎ 与中文 IME 组字语义）
                ZStack(alignment: .topLeading) {
                    ChatInputTextView(
                        text: $state.inputText,
                        isInputEmpty: $inputEmpty,
                        onSubmit: { submitInput() },
                        onSubmitFollowUp: { submitFollowUp() },
                        onEscape: { handleEscape() },
                        onInsertImages: { images in insertImages(images) },
                        onRecallFirst: { state.recallFirstQueuedInput() }
                    )
                    // 双通道与：草稿恢复期 inputEmpty 滞后为 true（@State 初值、首帧无变化事件），
                    // state.inputText 非空即有文字，placeholder 不显示——防重影（见 inputEmpty 声明处注释）。
                    if inputEmpty && state.inputText.isEmpty {
                        Text(inputPlaceholder)
                            .font(Theme.Typography.text(13))
                            .foregroundColor(Theme.Colors.idleText)
                            // 与 textContainerInset 同步：光标距卡边 18pt；垂直 12pt 配 44pt 行高近居中
                            .padding(.horizontal, Theme.Spacing.section)
                            .padding(.vertical, Theme.Spacing.xxl)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: Theme.Layout.chatInputHeight)

                // 底部工具行（2026-10 重设计）：左组 = ⊕ 附件 / 模型 chip / 思考 chip /
                // 水位圆环（低频工具组随 showDockSecondaryTools 显隐）；
                // 右组 = 剪贴板（hover 坞浮现）+ 发送钮。元素间距统一 lg(8)。
                HStack(spacing: Theme.Spacing.lg) {
                    attachMenuButton
                    modelChip
                    thinkingChip
                    // 低频工具组（水位圆环：水位/详情/压缩三合一，AIChatContextRingView）：
                    // 安静态整体隐去——保留占位、纯透明度渐变、布局零跳动；
                    // 悬停/输入/附件/生成中淡入，水位 >0.8 破格常显（警戒亮弧语义在组件内）
                    if let watermark = state.contextWatermark {
                        AIChatContextRingView(
                            watermark: watermark,
                            isCompacting: state.isCompacting,
                            summarizedCount: state.compactionInfo?.summarizedCount,
                            compactionOutcome: state.currentSessionOutcome,
                            onCompact: { state.compactNow() }
                        )
                        .opacity(showDockSecondaryTools ? 1 : 0)
                        .allowsHitTesting(showDockSecondaryTools)
                        .accessibilityHidden(!showDockSecondaryTools)
                        .animation(.easeOut(duration: Theme.Motion.contentFade), value: showDockSecondaryTools)
                    }
                    Spacer(minLength: 0)
                    clipboardButton
                        .opacity(showDockSecondaryTools ? 1 : 0)
                        .allowsHitTesting(showDockSecondaryTools)
                        .accessibilityHidden(!showDockSecondaryTools)
                        .animation(.easeOut(duration: Theme.Motion.contentFade), value: showDockSecondaryTools)
                    sendButton
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.lg)
            }
            // 功能层：输入坞是典型控件面（输入条/发送/附件/模型 chip），26+ 官方 Liquid Glass，
            // <26 退化为 ultraThinMaterial + 0.5pt 描边；坞悬浮于消息流之上，玻璃采样到真实
            // 内容流（blur-through）。纪律：坞内控件（⊕/chip/发送/剪贴板）绝不再用 glassEffect
            // （glass-on-glass），一律纯灰图标 hover 出圆底（与图钉同一克制语言）。
            // <26 降级描边随安静/激活换档：安静态降到 cardStroke(0.09) 近无感，激活态回 0.14。
            .modifier(GlassSurface(
                shape: RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous),
                strokeColor: dockQuiet ? Theme.Colors.cardStroke : Theme.Colors.chatStrokeStrong
            ))
            // 激活态 rim：坞体激活（悬停/输入/附件/生成中）且窗口 key 时叠加 accent 低透明度环，
            // 材质对状态有响应；安静态零描边。allowsHitTesting(false) 防描边层吞掉坞内控件点击
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                    .strokeBorder(
                        Theme.Colors.accent.opacity(dockRimActive ? Theme.Colors.dockFocusRimOpacity : 0),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: Theme.Motion.contentFade), value: dockRimActive)
            )
            // 双层阴影：接触影贴身定锚 + 环境影拉开纵深（旧单层贴身影 = 卡片糊在底板上）
            .shadow(color: .black.opacity(Theme.Shadow.dockContactOpacity), radius: Theme.Shadow.dockContactRadius, y: Theme.Shadow.dockContactY)
            .shadow(color: .black.opacity(Theme.Shadow.dockAmbientOpacity), radius: Theme.Shadow.dockAmbientRadius, y: Theme.Shadow.dockAmbientY)
            // 拖到输入卡边缘 padding 区也能接住（主路径在 NSTextView 子类）
            .onDrop(of: ["public.image", "public.file-url"], isTargeted: nil) { providers in
                handleDropProviders(providers)
            }
            // 水位圆环详情卡宿主：必须位于 GlassSurface 之后——26+ 的 .glassEffect 会把
            // 内容裁剪进玻璃形状，挂早了浮层会被输入卡顶缘切断（机制见组件头注）
            .contextRingDetailHost()
        }
        // 浮岛坞与消息列同限宽、同居中；快捷键提示条已删（提示由各控件 .help() tooltip 承担，
        // 清空会话入口移入 ⊕ 菜单），坞体即输入区全部。
        // 顶部零 padding：坞顶上方过渡由滚动区底缘渐隐带承担；底部 12pt 为坞与窗缘的呼吸缝
        .padding(.bottom, Theme.Spacing.xxl)
        // 坞体总高实测（生长区 + 输入卡 + 底缝）：background GeometryReader 不占布局、
        // 只在坞高变化（胶囊增删/工具行换态）时求值，事件级频率非逐帧；经 preference
        // 回写 dockTotalHeight，单向流入渐隐带锚点/尾部留白等消费点，绝不反向影响
        // 坞体布局（无反馈环）。
        // 坞体总高实测（生长区 + 输入卡 + 底缝）：background GeometryReader 不占布局、
        // 只在坞高变化（胶囊增删/工具行换态）时求值，事件级频率非逐帧。
        // 机制说明：经实测 preference 冒泡在本视图上下文中断——发射值到不了链尾观察点
        // （恒收 defaultValue 0，写死常量发射亦然，而发射视图 onAppear 正常在渲染）；
        // 改用 GeometryReader 内容的 onAppear/onChange 直写 @State（同视图事件已被
        // 实证可靠触发，首帧即拿到真实高度、坞体生长时跟随更新）。
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { noteDockTotalHeight(geo.size.height) }
                    .onChange(of: geo.size.height) { noteDockTotalHeight($0) }
            }
        )
        .chatReadingColumn()
        // 坞区 hover：进入时刷新剪贴板可用态（覆盖"先复制、后移动鼠标到窗口"的常见路径），
        // 同时驱动坞体安静→激活切换（低频工具组淡入、accent rim 点亮）
        .onHover { hovering in
            if hovering { refreshClipboardAvailability() }
            dockHovered = hovering
        }
    }

    /// 坞体总高回写：去抖（<0.5pt 跳过）防微抖重渲染；首帧 fallback → 实测校准一次。
    private func noteDockTotalHeight(_ height: CGFloat) {
        if abs(height - dockTotalHeight) > 0.5 {
            dockTotalHeight = height
        }
    }

    /// ⊕ 附件菜单：剪贴板导入 / 从文件选择… / 清空会话（清空入口自底部提示条迁入）。
    /// 克制语言：静止纯灰图标、无底无 rim（与顶栏图钉同款），hover 才出圆底提亮。
    private var attachMenuButton: some View {
        Menu {
            Button {
                attachImageFromPasteboard()
            } label: {
                Label("剪贴板导入", systemImage: "photo.on.rectangle")
            }
            .disabled(!hasClipboardImage)

            Button {
                chooseImageFiles()
            } label: {
                Label("从文件选择…", systemImage: "folder")
            }

            Divider()

            Button {
                exportConversation()
            } label: {
                Label("导出对话", systemImage: "square.and.arrow.up")
            }
            .disabled(state.messages.isEmpty)

            Button {
                state.clearSession()
            } label: {
                Label("清空会话", systemImage: "trash")
            }
            .disabled(state.messages.isEmpty)
        } label: {
            Image(systemName: "plus")
                .font(Theme.Typography.text(13, .medium))
                .foregroundColor(attachHovered ? Theme.Colors.iconHover : Theme.Colors.iconRest)
                .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
                .background(Circle().fill(attachHovered ? Theme.Colors.iconHoverBg : Color.clear))
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { attachHovered = hovering }
        }
        .help("添加图片附件（可粘贴/拖入）· 导出对话 · 清空会话（⌘K）")
    }

    /// 模型 chip：显示当前会话绑定模型（未绑定时回落全局默认），点击弹下拉切换。
    /// 选中写入会话级绑定（state.setSessionModel），不再写全局；仅多模型时显示，单模型弱化隐藏。
    /// 弱化小字语言：无胶囊底无 rim 的三级灰小字常驻（当前模型名需可瞥见），hover 才出圆底提亮。
    @ViewBuilder
    private var modelChip: some View {
        if modelList.count > 1 {
            Menu {
                ForEach(modelList) { model in
                    Button {
                        state.setSessionModel(model.modelId)
                    } label: {
                        if model.modelId == effectiveModelId {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(currentModelName)
                        .font(Theme.Typography.text(11, .regular))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Theme.Typography.text(8, .medium))
                        .foregroundColor(Theme.Colors.idleText)
                }
                .foregroundColor(chipHovered ? Theme.Colors.iconHover : Theme.Colors.contentTertiary)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.xxxs)
                .frame(height: Theme.Layout.iconButtonSize)
                .background(
                    Capsule(style: .continuous)
                        .fill(chipHovered ? Theme.Colors.iconHoverBg : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering in
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { chipHovered = hovering }
            }
            .help("切换本会话模型（下一轮对话生效）")
        }
    }

    /// 当前生效模型 id：会话级绑定优先，未绑定（nil）回落全局默认模型。
    private var effectiveModelId: String {
        state.currentSessionModelId ?? AIChatService.shared.selectedModel
    }

    private var currentModelName: String {
        if let matched = modelList.first(where: { $0.modelId == effectiveModelId }) {
            return matched.name
        }
        return effectiveModelId.isEmpty ? "模型" : effectiveModelId
    }

    /// 思考强度 chip：会话级档位（默认 = 跟随当前模型自身默认），与模型 chip 同弱化小字语言。
    /// 默认态三级灰小字，选定档位后提到二级对比度——一眼可辨「已覆盖」，但不再是白粗胶囊。
    /// 「关闭」档仅当当前生效模型允许关闭思考时出现（如 GLM-5.3 不可关则不显示该档）。
    private var thinkingChip: some View {
        Menu {
            Button {
                state.setThinkingLevel(nil)
            } label: {
                if state.currentThinkingLevel == nil {
                    Label("默认", systemImage: "checkmark")
                } else {
                    Text("默认")
                }
            }
            ForEach(ThinkingLevel.allCases, id: \.self) { level in
                if level != .off || state.canDisableThinking(for: effectiveModelId) {
                    Button {
                        state.setThinkingLevel(level)
                    } label: {
                        if state.currentThinkingLevel == level {
                            Label(thinkingLevelTitle(level), systemImage: "checkmark")
                        } else {
                            Text(thinkingLevelTitle(level))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(thinkingChipTitle)
                    .font(Theme.Typography.text(11, .regular))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.Typography.text(8, .medium))
                    .foregroundColor(Theme.Colors.idleText)
            }
            .foregroundColor(thinkingChipHovered
                             ? Theme.Colors.iconHover
                             : (state.currentThinkingLevel == nil
                                ? Theme.Colors.contentTertiary
                                : Theme.Colors.contentSecondaryStrong))
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.xxxs)
            .frame(height: Theme.Layout.iconButtonSize)
            .background(
                Capsule(style: .continuous)
                    .fill(thinkingChipHovered ? Theme.Colors.iconHoverBg : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { thinkingChipHovered = hovering }
        }
        .help("调整思考强度（本会话生效）")
    }

    /// chip 标题：默认态只露「思考」二字（弱化），选定档位后紧凑显示「思考·高」式后缀。
    private var thinkingChipTitle: String {
        guard let level = state.currentThinkingLevel else { return "思考" }
        switch level {
        case .off: return "思考·关"
        case .low: return "思考·低"
        case .medium: return "思考·中"
        case .high: return "思考·高"
        }
    }

    /// 菜单档位名（中文全字，与 chip 缩略后缀区分场景）。
    private func thinkingLevelTitle(_ level: ThinkingLevel) -> String {
        switch level {
        case .off: return "关闭"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    /// 剪贴板附加钮：低频功能，安静态随低频工具组整体隐去（见 showDockSecondaryTools）；
    /// 克制语言：静止纯灰图标无底无 rim（与图钉同款），hover 才出圆底提亮。
    private var clipboardButton: some View {
        Button {
            attachClipboard()
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(Theme.Typography.text(13, .medium))
                .foregroundColor(hasClipboardText
                                 ? (clipboardHovered ? Theme.Colors.iconHover : Theme.Colors.iconRest)
                                 : Theme.Colors.idleText.opacity(0.5))
                .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
                .background(Circle().fill(clipboardHovered && hasClipboardText ? Theme.Colors.iconHoverBg : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(!hasClipboardText)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { clipboardHovered = hovering }
        }
        .help("附加剪贴板内容作为上下文")
    }

    private var sendButton: some View {
        Button {
            if state.isStreaming {
                state.abortStreaming()
            } else {
                state.send()
            }
        } label: {
            Image(systemName: state.isStreaming ? "stop.fill" : "arrow.up")
                .font(Theme.Typography.text(13, .bold))
                .foregroundColor(sendButtonForeground)
                .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
                .background(Circle().fill(sendButtonFill))
                .animation(.easeOut(duration: Theme.Motion.contentFade), value: sendButtonSolid)
        }
        .buttonStyle(.plain)
        .disabled(!state.isStreaming && !canSend)
        .help(state.isStreaming ? "中止生成" : "发送（⏎）· 追问（⌥⏎）")
    }

    // MARK: - 状态与动作

    private var canSend: Bool {
        !state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || state.clipboardAttachment != nil
            || !state.imageAttachments.isEmpty   // 纯图片也可发送
    }

    /// ⏎ 发送键路（ChatInputNSTextView 回调）：
    /// - 非生成中：普通发送，清空由 send() 内部完成（含未配置端点时保留输入的语义）；
    /// - 生成中：数据层把 send() 转入 steering 队列（send 内 isStreaming 分支提前返回，
    ///   不消费输入态），此处按「入队反馈 = 输入框清空 + 队列胶囊浮现」由 UI 侧补齐清空。
    private func submitInput() {
        let wasStreaming = state.isStreaming
        state.send()
        if wasStreaming { clearDraft() }
    }

    /// ⌥⏎ 追问键路（ChatInputNSTextView 回调）：
    /// - 生成中：入 follow-up 队列（本轮将停时注入再跑一轮），随后按发送同款清空输入
    ///   （enqueueFollowUp 与 enqueueSteering 同样不消费输入态）；
    /// - 非生成中：退化为普通发送（与 ⏎ 同路径，send 内自守门控）。
    private func submitFollowUp() {
        // 门控信号与数据层 enqueueFollowUp 同源（isStreaming）：
        // 残留边界（消息态生成中但流集合已清）下入队会被拒，此处退化为普通发送不丢草稿。
        guard state.isStreaming else {
            state.send()
            return
        }
        let text = state.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = state.imageAttachments
        guard !text.isEmpty || !images.isEmpty else { return }
        state.enqueueFollowUp(text: text, images: images)
        clearDraft()
    }

    /// 清空草稿态（文本 / 剪贴板附加 / 图片附件）——与 state.send() 正常分支内清空同款。
    /// 同时丢弃已持久化的会话草稿（steering / follow-up 入队不会经 state.send() 消费输入态）。
    private func clearDraft() {
        state.discardCurrentDraft()
        state.inputText = ""
        state.clipboardAttachment = nil
        state.imageAttachments = []
    }

    /// 发送键底：可用 = 主题强调色实心（琥珀/青，全图最强图底反转——强调只在可发送瞬间登场），
    /// 流式 = 警告红；空态/禁用 = 无底（透明），杜绝空态下高亮实心色块抢夺视觉重心。
    private var sendButtonFill: Color {
        if state.isStreaming { return Theme.Colors.statusWarning.opacity(0.9) }
        return canSend ? Theme.Colors.accent : Color.clear
    }

    /// 发送键图标：实心强调色底上取深色（琥珀/青均属亮色底，深图标对比最稳），
    /// 流式红底用白色；禁用态 contentTertiary（≈4.7:1，灰箭头静止可读但不抢眼）。
    private var sendButtonForeground: Color {
        if state.isStreaming { return .white }
        if canSend { return Color.black.opacity(0.72) }
        return Theme.Colors.contentTertiary
    }

    /// 刷新非 @Published 的外部环境：端点配置、剪贴板可用性、模型列表。
    private func refreshEnvironment() {
        configured = state.hasConfiguredEndpoint
        refreshClipboardAvailability()
        modelList = AIChatService.shared.modelList
    }

    /// 单独刷新剪贴板可用态（轻量，供 hover/窗口激活调用）。
    private func refreshClipboardAvailability() {
        let clipboard = NSPasteboard.general
        let text = clipboard.string(forType: .string)
        hasClipboardText = !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        hasClipboardImage = PasteboardImageExtractor.containsImage(clipboard)
    }

    /// 附加剪贴板文本；失败（空剪贴板）时同步弱化按钮，做轻反馈。
    private func attachClipboard() {
        if !state.attachClipboard() {
            hasClipboardText = false
        }
    }

    /// 从剪贴板导入图片附件。
    private func attachImageFromPasteboard() {
        insertImages(PasteboardImageExtractor.images(from: NSPasteboard.general))
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

    /// 从文件选择器导入图片附件。
    private func chooseImageFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "选择图片"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let attachment = ImageAttachmentProcessor.makeAttachment(fromFileURL: url) {
                state.addImageAttachment(attachment)
            }
        }
    }

    /// 粘贴/拖入图片的统一落点（编码失败静默跳过）。
    private func insertImages(_ images: [NSImage]) {
        for image in images {
            _ = state.addImage(image)
        }
    }

    /// SwiftUI 层拖放（输入卡边缘区域）：按 NSImage / 文件 URL 两类加载。
    private func handleDropProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { item, _ in
                    guard let image = item as? NSImage else { return }
                    DispatchQueue.main.async { [state] in
                        _ = state.addImage(image)
                    }
                }
            } else if provider.canLoadObject(ofClass: NSURL.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSURL.self) { item, _ in
                    guard let url = item as? URL else { return }
                    DispatchQueue.main.async { [state] in
                        if let attachment = ImageAttachmentProcessor.makeAttachment(fromFileURL: url) {
                            state.addImageAttachment(attachment)
                        }
                    }
                }
            }
        }
        return handled
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

    /// ESC 三阶段语义（输入框聚焦时的兜底路径）：
    /// ① 行内重命名进行中 → 先取消重命名（不关窗、不中止流）；② 流式中 → 中止生成；③ 否则关窗还焦点。
    private func handleEscape() {
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
}

// MARK: - AI 窗快捷键监听

/// AI 窗级快捷键本地监听：⌘N 新会话 / ⌘B 侧栏显隐 / ⌘F 聚焦搜索。
/// 为什么不用 AIPanel.sendEvent 拦截：窗口层按键纪律（ESC/⌘K/文本聚焦放行）不允许改动；
/// 本地监听在 NSApplication 派发到窗口之前触发，既不动窗口层逻辑，又能覆盖
/// 「第一响应者非输入框」（如焦点在侧栏会话行）的路径。
/// 另承担两个 UI 态下的 ESC 先行消费：行内重命名中 → 取消重命名；图片放大中 → 关闭放大层。
/// 非隔离类：本地监听恒在主线程事件派发路径触发，回调直接执行，避免 NSEvent 跨隔离域。
final class AIChatKeyMonitor {
    private var monitor: Any?

    var isRenaming: () -> Bool = { false }
    var onCancelRename: () -> Void = {}
    var isZooming: () -> Bool = { false }
    var onDismissZoom: () -> Void = {}
    var onNewSession: () -> Void = {}
    var onToggleSidebar: () -> Void = {}
    var onFocusSearch: () -> Void = {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // 只接管 AI 对话窗的按键（设置窗等其他窗口不受影响）
        guard event.window is AIPanel else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ESC：仅在重命名/放大态下先行消费；其余放行给窗口层两阶段语义
        if event.keyCode == 53, flags.isEmpty {
            if isRenaming() { onCancelRename(); return nil }
            if isZooming() { onDismissZoom(); return nil }
            return event
        }

        guard flags == [.command] else { return event }
        switch event.keyCode {
        case 45: onNewSession(); return nil   // N
        case 11: onToggleSidebar(); return nil // B
        case 3: onFocusSearch(); return nil    // F
        default: return event
        }
    }
}

// MARK: - 会话滚动控制中枢（来源判定 + 程序化仲裁）

/// 滚动跟随的单一判定中枢（AI 窗一个，按会话路由）。
///
/// 第一性原理：视口偏移的变化只有两个来源——**用户输入**（滚轮/惯性/滚动条/键盘，最终都
/// 表现为 clipView bounds 的 origin 变化）与**非用户变化**（我们发起的程序化滚动、内容
/// 布局增长/塌缩引发的被动调整）。由「变化来源」直接判定 pinned 态，取代旧架构用
/// 0.5s/0.4s/0.12s 三个时间窗对「哨兵消失是谁干的」的猜测——时间窗没有时间上界语义
/// （异步渲染的 settling 可达秒级），猜测必错，这正是历次补丁反复复发的根源。
///
/// 判定规则（单一写路径）：
/// - pinned = true 只来自两处：用户输入把视口带回底部容差区 / 发送消息强制跳底；
/// - pinned = false 只来自一处：用户输入把视口推离底部容差区；
/// - 内容高度变化（documentView frame 变化）**永不**直接改 pin 态——pinned 时程序化
///   保持贴底（跟随的唯一执行点），unpinned 时绝不干预（用户阅读位置主权最高）；
/// - 程序化滚动经 `beginProgrammatic` 遮蔽窗排除在「用户输入」之外（同步滚动短窗、
///   动画滚动按动画时长 + 兜底）。
///
/// 非隔离类：全部回调恒在主线程（NSNotification 主队列 + SwiftUI 主线程回调），
/// 先例见 AIChatKeyMonitor；避免跨隔离域开销。
final class ChatScrollCoordinator {
    /// pin 态真源（按会话）。**必须放 class 内直接读写**：日志实证 @State 经通知回调写入后，
    /// 同帧读取闭包拿到的仍是旧值（写入对非渲染上下文的读取至少延迟一帧可见）——
    /// 判定路径读旧值 = 用户已解除跟随仍被逐帧贴底拽回（「走走停停被间歇拉回」根因）。
    /// 视图层的 isPinned @State 降级为纯 UI 镜像（导航簇显隐），由 onPinnedChange 同步。
    private var pinStates: [UUID: Bool] = [:]
    /// pin 态变化通知（每会话一个，视图挂载时注册）：coordinator 真源变化 → 回调写回
    /// 视图 @State 驱动 UI 刷新。UI 镜像延迟一帧无妨——它不在判定路径上。
    private var pinnedChangeHandlers: [UUID: (Bool) -> Void] = [:]

    /// 程序化滚动遮蔽——两种机制，按路径选用：
    /// - **同步作用域**（`programmaticDepths`）：`clipView.scroll(to:)` 的 bounds 通知在
    ///   调用栈内**同步**发出，进出作用域即可精确遮蔽，**零时间窗**——流式逐帧贴底
    ///   （~50ms 合帧节拍）的高频路径必须走此机制：若用时间窗，50ms 窗口背靠背覆盖
    ///   时间线，用户的滚轮输入几乎必然落在窗内被吞——pin 态永远无法解除，表现为
    ///   「流式输出中滚不上去」（被贴底循环持续拽回）。
    /// - **时间窗**（`programmaticUntil`）：仅用于动画滚动（animator 的 bounds 变化由
    ///   CA 逐帧异步驱动，作用域罩不住）与 proxy 回退路径（布局异步落定）。动画只
    ///   发生在低频路径（流结束收尾/导航跳转），不会饿死用户输入。
    /// - 兜底：无论哪种遮蔽生效中，若 origin 向**远离底部**方向移动（用户逆着程序化
    ///   滚动向上滚），立即解除遮蔽并按用户输入处理（用户主权最高，见 handleBoundsChanged）。
    private var programmaticDepths: [UUID: Int] = [:]
    private var programmaticUntil: [UUID: Date] = [:]
    /// 各会话上一次观察到的 clipView bounds origin：区分「滚动」（origin 变）与
    /// 「视口尺寸变化」（origin 不变，窗口 resize/工具条收展）——后者绝不能当作用户滚动。
    private var lastOrigins: [UUID: CGPoint] = [:]
    /// 各会话 documentView 上一次高度（frame 变化时算 delta）。
    private var lastDocHeights: [UUID: CGFloat] = [:]

    /// 底部容差区高度（pt）：与视图层 bottomTolerance 同源——判定「视口在底部」的容差。
    private let bottomTolerance: CGFloat = 18

    private struct WeakBox { weak var view: NSScrollView? }
    private var attached: [UUID: WeakBox] = [:]
    /// 各会话的通知监听 token（attach 时安装，重复 attach 先拆旧——SwiftUI 重建桥时换
    /// ScrollView 重装；会话视图销毁后 scrollView 随之释放，通知源消失，token 空转无害）。
    private var observers: [UUID: (bounds: NSObjectProtocol, frame: NSObjectProtocol)] = [:]

    // MARK: - 会话注册与 pin 真源

    /// 挂载时注册：pin 变化通知（同步视图的 isPinned UI 镜像）。常驻期间保持。
    func bind(sessionId: UUID, onPinnedChange: @escaping (Bool) -> Void) {
        pinnedChangeHandlers[sessionId] = onPinnedChange
    }

    /// 卸载时注销并清理真源。
    func unbind(sessionId: UUID) {
        pinnedChangeHandlers[sessionId] = nil
        pinStates[sessionId] = nil
    }

    /// pin 态唯一写入口：class 真源即时生效（判定路径同帧可读，零延迟），
    /// 变化时通知视图刷新 UI 镜像（导航簇显隐等，延迟一帧无妨）。
    func setPinned(_ sessionId: UUID, _ pinned: Bool) {
        let old = pinStates[sessionId] ?? true
        guard old != pinned else { return }
        pinStates[sessionId] = pinned
        pinnedChangeHandlers[sessionId]?(pinned)
    }

    /// pin 真源公开读取（视图层快照等路径必须读真源——@State 镜像写入对读取
    /// 延迟一帧可见，读镜像会存到旧值导致恢复路径走错分支）。
    func isPinnedState(of sessionId: UUID) -> Bool {
        pinStates[sessionId] ?? true
    }

    // MARK: - AppKit 桥挂载（通知安装）

    /// 桥视图解析到本会话底层 NSScrollView 后调用：安装 clipView bounds 变化与
    /// documentView frame 变化两类通知（posts 开关显式开启——两者默认都不发通知）。
    func attach(sessionId: UUID, scrollView: NSScrollView) {
        if attached[sessionId]?.view === scrollView, observers[sessionId] != nil { return }
        if let old = observers[sessionId] {
            NotificationCenter.default.removeObserver(old.bounds)
            NotificationCenter.default.removeObserver(old.frame)
            observers[sessionId] = nil
        }
        attached[sessionId] = WeakBox(view: scrollView)
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        if let doc = clipView.documentView {
            doc.postsFrameChangedNotifications = true
            lastDocHeights[sessionId] = lastDocHeights[sessionId] ?? doc.frame.height
        }
        lastOrigins[sessionId] = lastOrigins[sessionId] ?? clipView.bounds.origin
        let boundsToken = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in
            self?.handleBoundsChanged(sessionId: sessionId, scrollView: scrollView)
        }
        let frameToken = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clipView.documentView, queue: .main
        ) { [weak self] _ in
            self?.handleDocumentFrameChanged(sessionId: sessionId, scrollView: scrollView)
        }
        observers[sessionId] = (boundsToken, frameToken)
    }

    /// 底层 NSScrollView 弱引用读取（跳底直滚 / 桥可用性判定）。
    func scrollView(for sessionId: UUID) -> NSScrollView? {
        attached[sessionId]?.view
    }

    // MARK: - 程序化滚动仲裁

    /// 开程序化时间窗：窗口内的 bounds origin 变化不计为用户输入（仅动画/proxy 路径用）。
    private func beginProgrammatic(sessionId: UUID, window: TimeInterval) {
        let until = Date().addingTimeInterval(window)
        if (programmaticUntil[sessionId] ?? .distantPast) < until {
            programmaticUntil[sessionId] = until
        }
    }

    /// 解除该会话全部程序化遮蔽（作用域 + 时间窗）：用户逆程序化方向滚动的兜底。
    private func endProgrammatic(sessionId: UUID) {
        programmaticDepths[sessionId] = 0
        programmaticUntil[sessionId] = .distantPast
    }

    private func isProgrammaticActive(sessionId: UUID) -> Bool {
        (programmaticDepths[sessionId] ?? 0) > 0
            || Date() < (programmaticUntil[sessionId] ?? .distantPast)
    }

    /// 同步程序化作用域：闭包内 `clipView.scroll(to:)` 触发的 bounds 通知在调用栈内
    /// 同步发出，进出配对遮蔽——零时间窗，流式逐帧贴底（高频）的安全路径。
    private func withSyncProgrammaticScope<T>(_ sessionId: UUID, _ body: () -> T) -> T {
        programmaticDepths[sessionId, default: 0] += 1
        let result = body()
        programmaticDepths[sessionId, default: 0] -= 1
        return result
    }

    /// 程序化作用域（proxy 路径）：proxy.scrollTo 的布局/动画异步落定，作用域罩不住
    /// bounds 变化，用时间窗兜——短窗覆盖非动画落定，动画路径（0.18~0.2s）调用方传
    /// 0.28~0.35 覆盖逐帧变化。仅低频路径使用（导航/恢复定位），不构成用户输入饥饿。
    func withProgrammaticScope<T>(_ sessionId: UUID, window: TimeInterval = 0.05, _ body: () -> T) -> T {
        beginProgrammatic(sessionId: sessionId, window: window)
        return body()
    }

    // MARK: - 通知处理（判定核心）

    /// clipView bounds 变化：origin 变 = 滚动（用户，或未被遮蔽的程序化）；origin 不变
    /// = 纯视口尺寸变化（resize），pinned 会话程序化重新贴底，绝不当用户滚动。
    /// 遮蔽中的兜底：程序化贴底只会让 origin 向底部方向移动（或持平）；origin 向**远离
    /// 底部**方向移动必然来自用户输入（用户逆着程序化滚动向上滚）——立即解除遮蔽并
    /// 按用户输入处理（用户主权最高）。这保证流式逐帧贴底期间用户上滚**立即**生效
    /// （历史缺陷：贴底开 0.05s 时间窗 × 50ms 合帧节拍背靠背覆盖时间线，用户滚轮
    /// 全部被吞——「转向消息后滚不上去」的根因）。
    private func handleBoundsChanged(sessionId: UUID, scrollView: NSScrollView) {
        let origin = scrollView.contentView.bounds.origin
        let last = lastOrigins[sessionId] ?? origin
        lastOrigins[sessionId] = origin
        let originChanged = abs(origin.x - last.x) > 0.1 || abs(origin.y - last.y) > 0.1
        guard originChanged else {
            // 视口尺寸变化（非滚动）：pinned 会话保持贴底（窗口缩小会让底部内容沉下去）。
            if isPinned(sessionId) { scrollPinnedToBottom(sessionId: sessionId, animated: false) }
            return
        }
        let flipped = scrollView.contentView.documentView?.isFlipped ?? true
        // flipped 文档：向上滚 = origin.y 减小；非 flipped：origin.y 增大。
        let movedUp = flipped ? (origin.y < last.y - 0.1) : (origin.y > last.y + 0.1)
        let masked = isProgrammaticActive(sessionId: sessionId)
        if masked {
            // 兜底仅对「贴底跟随中的逆向上滚」生效（isPinned=true）；unpinned 时的
            // movedUp 可能是内容塌缩后的被动 clamp（flipped 下 offset 被压小、方向同
            // 向上），若触发兜底会把 clamp 误判为用户输入、在底部误恢复 pin——
            // 历史「塌缩瞬移」根因的复活路径，必须排除。
            guard movedUp, isPinned(sessionId) else {
                return
            }
            endProgrammatic(sessionId: sessionId)
        }
        let atBottom = isAtBottom(scrollView)
        // 方向守卫（塌缩瞬移特征排除）：用户回底必然是**向下滚**（origin 向底部移动）；
        // 「向上滚却判定在底部」（movedUp && atBottom）的矛盾组合只来自内容塌缩后
        // SwiftUI/AppKit 把 origin 压到新 maxOffset 的被动调整——日志实证的
        // 「瞬移 13915px 回底 + pin 误恢复 → 回填期间逐帧 scrollToBottom 拽回」根因。
        // 矛盾组合一律吞掉（不写 pin）；内容不满一屏区（maxOffset=0 恒 atBottom）的
        // 向上橡皮筋微滚同被吞，写同值 1 亦无语义损失。
        if movedUp, atBottom {
            return
        }
        setPinned(sessionId, atBottom)
    }

    /// documentView frame 变化（内容高度增长/塌缩）：跟随的唯一执行点。
    /// - pinned：程序化贴底（非动画，与内容布局同步，流式增量即逐帧跟随）；
    /// - unpinned：不干预——但**塌缩时必须把偏移预先 clamp 到新最大值**（等价 AppKit
    ///   即将做的调整，但由我们在遮蔽窗内完成）：否则随后 AppKit 自己 clamp 的 bounds
    ///   变化会被误判为用户滚动，把 pin 态错误翻转（历史「瞬移到底 + 回弹错位」根因）。
    private func handleDocumentFrameChanged(sessionId: UUID, scrollView: NSScrollView) {
        guard let doc = scrollView.contentView.documentView else { return }
        let newHeight = doc.frame.height
        let oldHeight = lastDocHeights[sessionId] ?? newHeight
        lastDocHeights[sessionId] = newHeight
        let delta = newHeight - oldHeight
        guard abs(delta) > 0.5 else { return }
        let pinned = isPinned(sessionId)
        if pinned {
            scrollPinnedToBottom(sessionId: sessionId, animated: false)
        } else if delta < 0 {
            // 塌缩：程序化执行 clamp 等价（同步作用域遮蔽），视觉与 AppKit 自然行为一致。
            // 额外保留 0.15s 时间窗：AppKit 在布局 pass 的后续自然 clamp（若发生）不在
            // 我们的调用栈内，同步作用域罩不住——它的 bounds 变化方向与向上滚相同
            // （offset 被压小），不遮蔽会被判定为用户输入、在底部误恢复 pin。
            let clip = scrollView.contentView
            let maxOffset = max(0, newHeight - clip.bounds.height)
            let current = doc.isFlipped ? clip.bounds.origin.y : -clip.bounds.origin.y
            if current > maxOffset {
                beginProgrammatic(sessionId: sessionId, window: 0.15)
                let target = NSPoint(x: 0, y: doc.isFlipped ? maxOffset : -maxOffset)
                withSyncProgrammaticScope(sessionId) {
                    clip.scroll(to: target)
                    scrollView.reflectScrolledClipView(clip)
                }
            }
        }
    }

    /// 视口是否在底部容差区（flipped 文档：距底溢出 ≤ 容差；内容不满一屏恒在底部）。
    private func isAtBottom(_ scrollView: NSScrollView) -> Bool {
        guard let doc = scrollView.contentView.documentView else { return true }
        let clip = scrollView.contentView
        guard doc.isFlipped else {
            return clip.bounds.origin.y <= bottomTolerance
        }
        let maxOffset = max(0, doc.bounds.height - clip.bounds.height)
        return (maxOffset - clip.bounds.origin.y) <= bottomTolerance
    }

    private func isPinned(_ sessionId: UUID) -> Bool {
        pinStates[sessionId] ?? true
    }

    // MARK: - 跳底直滚（AppKit 路径，程序化仲裁内）

    /// 程序化滚动到本会话底部。返回 false = 桥未就绪（无底层 NSScrollView 可控）。
    /// - 非动画（流式逐帧跟随的高频路径）：同步作用域遮蔽——`scroll(to:)` 的 bounds
    ///   通知在调用栈内同步发出，进出配对即可精确遮蔽，**零时间窗**（用时间窗会被
    ///   50ms 合帧节拍背靠背铺满时间线、吞掉全部用户滚轮输入）；
    /// - 动画（低频：流结束收尾/导航回底）：时间窗 = 动画时长 + 兜底（CA 逐帧异步
    ///   驱动的 bounds 变化作用域罩不住；低频路径不构成输入饥饿，且有 movedUp 兜底）。
    @discardableResult
    func scrollPinnedToBottom(sessionId: UUID, animated: Bool) -> Bool {
        guard let sv = attached[sessionId]?.view, let doc = sv.contentView.documentView else {
            return false
        }
        let bottomY = doc.isFlipped
            ? max(0, doc.bounds.height - sv.contentView.bounds.height)
            : 0
        let target = NSPoint(x: 0, y: bottomY)
        if animated {
            beginProgrammatic(sessionId: sessionId, window: 0.34)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sv.contentView.animator().setBoundsOrigin(target)
            })
        } else {
            withSyncProgrammaticScope(sessionId) {
                sv.contentView.scroll(to: target)
                sv.reflectScrolledClipView(sv.contentView)
            }
        }
        return true
    }
}

/// AppKit 滚动桥：零尺寸 NSView 挂在 ScrollView **内容树内部**（必须在内——挂在 ScrollView
/// 外层时是兄弟节点，enclosingScrollView 解析不到）。解析到本会话底层 NSScrollView 后
/// 交 coordinator 安装通知；视图若被 SwiftUI 重建，updateNSView 以 !== 检测并重挂。
private struct ChatScrollBridgeView: NSViewRepresentable {
    let sessionId: UUID
    let coordinator: ChatScrollCoordinator
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let sv = nsView.enclosingScrollView,
               coordinator.scrollView(for: sessionId) !== sv {
                coordinator.attach(sessionId: sessionId, scrollView: sv)
            }
        }
    }
}

// MARK: - 单条消息

/// 连续同角色消息组（消息列表分组渲染用；id 取首条消息 id 保证身份稳定）。
private struct MessageGroup: Identifiable {
    let id: UUID
    let role: ChatMessage.Role
    var messages: [ChatMessage]
}

/// 消息分组缓存：messages 底层存储未变时复用上次分组结果，避免隐藏会话随 store 扇出
/// 重求值时每次 body 都做 O(n) 全量分组。
/// 判定用「持有同一份 messages 值 + 同 buffer 地址 + 同长度」：缓存持有值会保持该 buffer
/// 的引用，store 后续修改必触发 COW 换 buffer，故地址+长度相同即内容相同。O(1)，
/// 比逐字段 Equatable（含图片 base64/长文本）便宜且同样可靠。
private final class MessageGroupingCache {
    private var cachedMessages: [ChatMessage] = []
    private var cachedGroups: [MessageGroup] = []

    func groups(for messages: [ChatMessage]) -> [MessageGroup] {
        if !messages.isEmpty,
           messages.count == cachedMessages.count,
           sameStorage(messages, cachedMessages) {
            return cachedGroups
        }
        cachedMessages = messages
        cachedGroups = Self.group(messages)
        return cachedGroups
    }

    /// 两数组是否共享同一底层存储 buffer（值语义下即同内容）。
    private func sameStorage(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> Bool {
        lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                left.baseAddress == right.baseAddress
            }
        }
    }

    private static func group(_ messages: [ChatMessage]) -> [MessageGroup] {
        var groups: [MessageGroup] = []
        for message in messages {
            if let last = groups.last, last.role == message.role, message.role != .system {
                groups[groups.count - 1].messages.append(message)
            } else {
                groups.append(MessageGroup(id: message.id, role: message.role, messages: [message]))
            }
        }
        return groups
    }
}

/// 单会话滚动快照：切走时记录，切回时据此恢复阅读位置。
private struct ScrollSnapshot {
    /// 离开时数组序最靠前的可见消息 id（nil 表示当时无可见消息）。
    var topVisibleMessageID: UUID?
    /// 离开时是否处于贴底跟随态（pinned）；true 则切回贴底，false 则回到锚点。
    var isPinned: Bool
}

// MARK: - 消息行几何信号（诚实视口锚点）

/// 每个已实现化消息行上报其在本实例滚动视口坐标系中的 frame（`[messageID: CGRect]`）。
/// 关键：preference 每次布局**全量重算**，reduce 合并出的字典 = 当前帧真实已实现行集合
/// （不像行级 onAppear/onDisappear 那样只增不减），据此可算出真实「视口首个可见消息」。
private struct MessageRowFramePreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - 公式预热去重签名

/// 会话 latex 预热签名：消息条数 + 内容总字符 + 末条 id。未变则复用上次收集结果、跳过重复收集。
private struct LatexPrefetchSignature: Equatable {
    var messageCount: Int
    var totalChars: Int
    var lastMessageID: UUID?
}

// MARK: - 单会话消息列表（视图树保活单元）

/// 单会话消息列表：每个常驻会话一份完整独立的 ScrollViewReader+ScrollView+LazyVStack，
/// 滚动位置/贴底跟随/首挂载态全部私有化随视图树保活——切会话只切 opacity，零身份重建。
/// 由父级 AIChatView 的 LRU 常驻集合（residentSessionIds）驱动挂载/卸载。
@MainActor
private struct SessionMessageList: View {
    let sessionId: UUID
    let isActive: Bool
    /// 会话门面（读取本会话流式状态、发起重试）；更新由父级重渲染驱动。
    let state: AIChatState
    /// 本会话消息（父级传入；隐藏会话无需独立订阅 store）。
    let messages: [ChatMessage]
    let onTapImage: (ChatImageAttachment) -> Void
    @Binding var scrollSnapshots: [UUID: ScrollSnapshot]
    let scrollCoordinator: ChatScrollCoordinator
    /// 输入坞生长区实测高度（父级统一传入）：尾部留白、底缘渐隐带与浏览导航的底部预算同步叠加，
    /// 遮挡带随坞体向上生长动态跟随。生长区只属于当前活跃会话的输入坞，但 pendingQueue
    /// 本就按会话隔离读取，高度值对全部常驻实例统一应用（非活跃会话 opacity=0 不可见）。
    let dockTotalHeight: CGFloat

    private let bottomAnchorID = "aiChat.bottom"

    /// 本会话首载装载态：冷启动与 LRU 重挂载时抑制入场动画，防窗口上屏竞态白屏。
    @State private var isInitialHistoryLoad = true
    /// 贴底跟随态（pinned）：true = 自动跟随最新内容，false = 用户自由浏览。
    /// 写路径单一（见 ChatScrollCoordinator）：用户输入回底/发送跳底 → true；
    /// 用户输入离底 → false。内容高度变化永不直接改写本态。
    @State private var isPinned = true
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
            // 底缘渐隐带的绝对位置（换算为渐变 location 比例，钉死数学、不依赖布局分配）：
            // 顶部→fadeStart 全不透明；fadeStart→fadeEnd 26pt 渐隐；fadeEnd→底部（坞区）全透明。
            // fadeEnd 锚定 inputArea 实测总高 = 真实坞顶：渐隐带与坞体恒衔接（内容渐隐没入
            // 玻璃坞下的穿透感），静态预算脱开断层与工具行动态超估算漂移一并根治。
            let viewportHeight = max(viewport.size.height, 1)
            let dockBand = dockTotalHeight
            let fadeEndLocation = min(max((viewportHeight - dockBand) / viewportHeight, 0), 1)
            let fadeStartLocation = min(max((viewportHeight - dockBand - Theme.Layout.chatFadeMaskHeight) / viewportHeight, 0), 1)
            ScrollView(.vertical, showsIndicators: false) {
                // 手动虚拟化容器（VStack 全行常驻）：LazyVStack 在 macOS 13 上回收远行
                // 的高度估算归零/失准，实例化-回收的「估算↔真实」差一次性结算成 doc 骤变
                // （日志定证 -14306 → 视口瞬移 14053 = 上滚跳消息的最终根因）。改为
                // VStack + 行内「实渲染 ↔ 等高占位」切换（ChatVirtualRow）：占位高度 =
                // 实测缓存高度，切换高度恒等 → doc 恒稳。间距语义与 LazyVStack 一致。
                VStack(alignment: .leading, spacing: Theme.Spacing.chatGroupGap) {
                    ForEach(groupingCache.groups(for: messages)) { group in
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
                    // 尾部总留白 = dockTotalHeight（实测坞高）+ 渐隐带 26 + 呼吸缝 4：
                    // 36 + (坞高+30−18−36) + 18 + 1 = 坞高+31，末条消息底边恒在渐隐带
                    // fadeStart 之上完整可见（与坞体真实高度解耦，工具行动态变化自动跟随）。
                    // （2026-10：静态 90/110 预算时代末条悬在渐隐带深区被压、渐隐带与
                    // 坞体脱开断层 → 由实测坞高单一真实来源根治。）
                    VStack(spacing: 0) {
                        // 坞区让位留白：实测坞总高 + 渐隐带 + 呼吸缝，扣除外层组间距(36)
                        // 与容差带(18)——两者分别由本子视图外/内承担，此处只补差额。
                        // 留白随坞体生长/收缩平滑过渡（与坞内动画同时长）；pinned 时由
                        // coordinator 的内容高度路径自动保持贴底，unpinned 不受干扰
                        // （用户阅读位置主权最高）。
                        Color.clear
                            .frame(height: max(dockTotalHeight + Theme.Layout.chatFadeMaskHeight + Theme.Layout.chatDockTailBreathing - bottomTolerance - Theme.Spacing.chatGroupGap, 0))
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
            // 底缘渐隐带（2026-10 重设计）：滚动内容在坞顶上方 26pt 内渐隐收没，
            // 坞下不再露出被裁的半截内容（替代生硬裁切）。
            // 关键纪律：mask 只挂 ScrollView 本体——导航 overlay 挂在其后（见下方两个
            // .overlay），坞在更外层 mainColumn overlay，均不被罩住。
            // 实现双保险（修复顶部 ~130px 暗带事故）：
            // ① 遮罩色用不透明白而非黑——mask 在某些渲染路径按亮度解释（黑=暗=半透明遮蔽），
            //    白色在 alpha/亮度两种语义下恒为「全显示」；
            // ② 单条 LinearGradient 绝对 stops 替代 VStack 三段堆叠——渐隐带位置由视口高度
            //    数学换算钉死，不依赖 flexible 视图的布局分配（macOS 13 黑盒行为排除）。
            .mask(
                LinearGradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: fadeStartLocation),
                    .init(color: .clear, location: fadeEndLocation),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
            .animation(.easeOut(duration: Theme.Motion.contentFade), value: dockTotalHeight)
            // 首帧视口自适应：把视口高度注入环境，供消息内 AssistantMarkdownView 估算「一屏块数」。
            .environment(\.chatViewportHeight, viewport.size.height)
            // 行级几何 → 真实视口顶部消息：每帧全量上报已实现行 frame，算出与视口相交且
            // minY 最靠上（最贴近视口顶）的行；仅在结果变化时写状态（去抖，避免每帧 setState）。
            .onPreferenceChange(MessageRowFramePreference.self) { frames in
                updateRowFrames(frames, viewportHeight: viewport.size.height)
            }
            .onAppear {
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
            // unpinned（浏览态）且活跃时显示，0.15s 淡入淡出；贴底时整体隐藏。
            // 两件套各自挂 overlay（均在 mask 之后，不被渐隐罩住）：
            // ① 右缘刻度轨：贴窗口右内缘、垂直居中于内容区（扣坞区），每条用户消息一枚 tick，
            //   静止紧凑密排、光标接近时按余弦钟形衰减放大推开（详见 ChatTickRail）；
            // ② ↓ 回底钮：坞正上方、右缘贴统一右基准线。
            .overlay(alignment: .trailing) {
                if !isPinned, isActive, !tickItems.isEmpty {
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
                if !isPinned, isActive {
                    toBottomButton(proxy)
                        .padding(.bottom, dockTotalHeight + Theme.Layout.chatNavDockGap)
                        .animation(.easeOut(duration: Theme.Motion.contentFade), value: dockTotalHeight)
                        .chatReadingColumn(alignment: .trailing)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isPinned)
        }
        }
    }

    // MARK: - 滚动协调器接线

    /// 挂载时注册（常驻期间保持，不随 isActive 切换注销——隐藏会话并行流式时
    /// coordinator 的 frame 路径仍需读 pin 真源保持贴底）：
    /// pin 真源在 coordinator（class 内即时读写）——@State isPinned 降级为纯 UI 镜像
    /// （导航簇显隐），由本闭包同步。日志实证：@State 经通知回调写入后同帧读取拿到
    /// 旧值（「解除跟随后仍被逐帧贴底拽回」根因），判定路径必须读 class 真源。
    private func bindScrollCoordinator() {
        scrollCoordinator.bind(sessionId: sessionId) { pinned in
            isPinned = pinned
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
        let users = messages.filter { $0.role == .user }
        let limit = Theme.Layout.chatTickMaxCount
        guard users.count > limit else { return users }
        let anchorId = currentTickMessageId ?? users.last?.id
        guard let anchorId, let index = users.firstIndex(where: { $0.id == anchorId }) else {
            return Array(users.suffix(limit))
        }
        let half = limit / 2
        let lower = max(0, min(index - half, users.count - limit))
        return Array(users[lower ..< lower + limit])
    }

    /// 当前查看的用户消息 tick：视口锚点（含自身）所属的最近一条用户消息，
    /// 随滚动经行级几何信号实时更新；无锚点时兜底取最后一条用户消息。
    private var currentTickMessageId: UUID? {
        guard let anchor = topVisibleMessageID,
              let index = messages.firstIndex(where: { $0.id == anchor }) else {
            return messages.last { $0.role == .user }?.id
        }
        return messages[...index].last { $0.role == .user }?.id
    }

    /// 刻度轨条目：采样后用户消息 → 轨渲染模型（预览文本预裁剪、当前条标记）。
    private var tickItems: [ChatTickRail.Item] {
        tickMessages.map {
            ChatTickRail.Item(
                id: $0.id,
                preview: $0.content.trimmingCharacters(in: .whitespacesAndNewlines),
                isCurrent: $0.id == currentTickMessageId
            )
        }
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
        isActive && (state.isCompacting || state.compactionInfo != nil)
    }

    /// 压缩边界消息 id：beforeMessageID（String）转 UUID 且在本会话消息里存在时按位插入；
    /// nil / 转换失败 / 消息已不存在 → nil（卡片落到会话流最顶部，契约语义）。
    private var compactionBoundaryMessageId: UUID? {
        guard let raw = state.compactionInfo?.beforeMessageID,
              let uuid = UUID(uuidString: raw),
              messages.contains(where: { $0.id == uuid }) else { return nil }
        return uuid
    }

    /// 最后一条可重新生成的助手消息 id：仅活跃会话 + 本会话非生成中时提供
    /// （重试动作只对当前会话有效，隐藏会话不显示按钮）。
    private var lastRegeneratableAssistantId: UUID? {
        guard isActive, !isStreamingSession else { return nil }
        return messages.last { message in
            guard message.role == .assistant else { return false }
            switch message.state {
            case .done, .aborted: return true
            default: return false
            }
        }?.id
    }

    /// 会话内最后一条 user 消息 id：仅活跃会话 + 非生成中时提供
    /// （撤回/编辑只对当前会话最后一轮有效；隐藏会话与生成中不显示入口）。
    private var lastEditableUserMessageId: UUID? {
        guard isActive, !state.isGenerating else { return nil }
        return messages.last { $0.role == .user }?.id
    }
}

// MARK: - 浏览导航刻度轨（Dock 放大手感）

/// 刻度轨布局数学（纯值模型，光标每帧移动即整轨 O(n) 重算）：
/// - 静止态：均匀紧凑 pitch（可用高 ÷ 条数自适应收缩、保底 pitchMin），容器高恒为
///   静止总高并垂直居中——**坐标系恒定是丝滑的关键**：放大只改槽内偏移与 scale，
///   容器几何不随放大变化，跟踪坐标无反馈漂移、无边界追逐振荡；
/// - 放大态：每枚 tick 按「光标 → 静止中心」距离的余弦钟形得权重 w（Dock 经典衰减：
///   峰在光标正下方、radius 处平滑归零、域外恒 0）；槽心 = 静止中心 + 上方累计生长
///   − 锚点前累计生长——**锚点（当前消息 tick）恒钉死在静止位、scale 恒 1**，不参与
///   放大布局，成为波中的稳定零位；其余 tick 相对它彼此推开；
/// - 明暗与大小共用同一条 w：不透明度 = rest + t×(lerp(dim, bright, w) − rest)，
///   光标正下方最亮、远端比静止更暗，两个维度同步流动；
/// - 命中槽由相邻槽心中点切分（Voronoi），无缝相接、随放大同步长大——hover 判定与
///   点击目标在任何放大态下都严丝合缝。
private struct ChatTickRailLayout {
    struct Slot: Equatable {
        var center: CGFloat      // 槽心 y（容器静止坐标系；tick 视觉锚点）
        var frameTop: CGFloat    // 命中槽顶（相邻槽心中点切分，可溢出容器上下缘）
        var frameHeight: CGFloat // 命中槽高（槽间恒无缝）
        var scale: CGFloat       // 放大倍率（1 = 静止/锚点）
        var opacity: Double      // 明暗梯度输出（仅普通 tick 使用；accent 锚点忽略）
    }

    let pitch: CGFloat
    /// 静止总高（容器固定高 = n × pitch）
    let restHeight: CGFloat
    /// 容器顶缘在几何区（overlay 可用区）坐标系中的 y（垂直居中换算；跟踪层局部坐标
    /// 经 trackTop 偏移换算到本坐标系后使用）
    let containerTop: CGFloat
    /// 首/末命中槽的外缘（容器坐标系，可越出 [0, restHeight]）——hover 判定的上下界
    let railTop: CGFloat
    let railBottom: CGFloat
    let slots: [Slot]

    /// - pinnedIndex: 当前消息 tick 下标（accent 锚点）——恒 scale 1、位置钉死不动；
    ///   nil 时退化为绕几何中心对称生长
    init(count: Int, availableHeight: CGFloat, cursorY: CGFloat, amount: CGFloat, pinnedIndex: Int?) {
        let tokens = Theme.Layout.self
        let n = max(count, 0)
        let avail = max(availableHeight, 1)
        // 放大生长余量（worst-case 上界 Σ(scale−1)·pitch ≤ (maxScale−1)·(radius+pitch)）：
        // 静止总高预算先扣除它 → 光标扫到峰值时整轨视觉高也不超可用区
        let growthReserve = (tokens.chatTickMagnifyMaxScale - 1)
            * (tokens.chatTickMagnifyRadius + tokens.chatTickPitch)
        let p = n > 0
            ? min(tokens.chatTickPitch, max(tokens.chatTickPitchMin, (avail - growthReserve) / CGFloat(n)))
            : tokens.chatTickPitch
        pitch = p
        restHeight = p * CGFloat(n)
        containerTop = (avail - restHeight) / 2

        guard n > 0 else {
            slots = []
            railTop = 0
            railBottom = 0
            return
        }
        let t = min(max(amount, 0), 1)
        let maxGain = tokens.chatTickMagnifyMaxScale - 1
        let radius = tokens.chatTickMagnifyRadius
        let pinned = pinnedIndex.flatMap { $0 >= 0 && $0 < n ? $0 : nil }
        let colors = Theme.Colors.self

        // 第一遍：各 tick 的权重 w（余弦钟形）→ scale / 不透明度 / 生长量
        var scales: [CGFloat] = []
        scales.reserveCapacity(n)
        var opacities: [Double] = []
        opacities.reserveCapacity(n)
        var growths: [CGFloat] = []
        growths.reserveCapacity(n)
        for i in 0..<n {
            let center = containerTop + p * (CGFloat(i) + 0.5)
            let d = abs(cursorY - center)
            let w: CGFloat = d < radius ? 0.5 * (1 + cos(.pi * d / radius)) : 0
            // 锚点不参与放大布局：scale 恒 1（颜色恒 accent，不透明度输出不参与）
            let scale = i == pinned ? 1 : 1 + maxGain * w * t
            scales.append(scale)
            growths.append((scale - 1) * p)
            // 明暗双维度：与大小共用同一 w 与渐入量 t（rest → lerp(dim, bright, w)）
            let target = colors.chatTickDimOpacity + (colors.chatTickBrightOpacity - colors.chatTickDimOpacity) * Double(w)
            opacities.append(colors.chatTickRestOpacity + Double(t) * (target - colors.chatTickRestOpacity))
        }
        // 第二遍：槽心 = 静止中心 + 上方累计生长 − 锚点前累计生长（锚点钉死 = 零位）；
        // 无锚点时退化为全局生长一半（绕几何中心对称生长）
        var growthAbove: [CGFloat] = []
        growthAbove.reserveCapacity(n)
        var running: CGFloat = 0
        var totalGrowth: CGFloat = 0
        for i in 0..<n {
            growthAbove.append(running)
            running += growths[i]
            totalGrowth += growths[i]
        }
        let pivot = pinned.map { growthAbove[$0] } ?? totalGrowth / 2
        var centers: [CGFloat] = []
        centers.reserveCapacity(n)
        for i in 0..<n {
            centers.append(p * (CGFloat(i) + 0.5) + growthAbove[i] - pivot)
        }
        // 第三遍：命中槽 = 相邻槽心中点切分（端点槽向外延伸自身半步，可越容器缘）
        var result: [Slot] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            let top = i > 0
                ? (centers[i - 1] + centers[i]) / 2
                : centers[0] - (n > 1 ? (centers[1] - centers[0]) / 2 : p * scales[0] / 2)
            let bottom = i < n - 1
                ? (centers[i] + centers[i + 1]) / 2
                : centers[i] + (n > 1 ? (centers[i] - centers[i - 1]) / 2 : p * scales[i] / 2)
            result.append(Slot(center: centers[i], frameTop: top,
                               frameHeight: bottom - top, scale: scales[i], opacity: opacities[i]))
        }
        slots = result
        railTop = result[0].frameTop
        railBottom = result[n - 1].frameTop + result[n - 1].frameHeight
    }

    /// 几何区坐标 → 光标正下方的 tick 下标：横坐标须落在轨体内（左伸接近带只驱动放大、
    /// 不触发 hover），纵坐标须落在命中槽域内；槽无缝相接，命中即返。
    func hoveredIndex(at point: CGPoint, trackWidth: CGFloat, railWidth: CGFloat) -> Int? {
        guard !slots.isEmpty, point.x >= trackWidth - railWidth else { return nil }
        let y = point.y - containerTop
        guard y >= railTop, y <= railBottom else { return nil }
        for (i, slot) in slots.enumerated() where y >= slot.frameTop && y < slot.frameTop + slot.frameHeight {
            return i
        }
        return slots.indices.last  // y == railBottom 边界兜底
    }
}

/// 右缘消息刻度轨（Dock magnification 手感）：
/// 每条用户消息一枚 tick，静止紧凑密排（pitch 按可用高度自适应收缩）；光标进入磁吸
/// 跟踪带（轨体 + 上下各一个衰减半径 + 左伸接近带）后，光标附近的 tick 按余弦钟形
/// 衰减实时放大并彼此推开、明暗同步流动；离开平滑收拢。hover 预览胶囊、点击直达、
/// 当前条 accent 锚点（钉死不动）全部保留。
///
/// 丝滑的关键路径：
/// - **跟踪面必须挂在覆盖整个交互区的共同祖先上**（历史根因：跟踪层曾是 tick 层
///   下方兄弟节点，光标压上可命中的 tick 即触发 hover exit → 放大瞬间塌缩、胶囊
///   永不出现）——现在 contentShape + onContinuousHover 挂在包裹 tick 层的磁吸带
///   容器上，tick 是其后代，从左邻带到轨上 hover 连续不断流；
/// - 光标 y 直接赋值驱动每帧布局（无隐式动画、即时跟随）；只有 magnifyAmount 的
///   进入 0→1 / 离开 1→0 走显式 easeOut 动画（渐入点亮 / 收拢回弹）——进入动画
///   只在 hover 生命周期开始播一次（amount 目标值即时为 1，后续移动不重复触发）；
/// - hover 写入不走 withAnimation（防同事物染指槽位布局），胶囊过渡由 tick 内层
///   值域动画 `.animation(_:value:)` 承担（只在 hover 变化帧生效，光标移动帧零动画）；
/// - 光标状态私有于本视图——每帧重算只触及刻度轨子树，不冲刷消息列表。
private struct ChatTickRail: View {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let preview: String
        let isCurrent: Bool
    }

    let items: [Item]
    let onSelect: (UUID) -> Void

    /// 光标 y（几何区坐标系；直接驱动 = 零动画即时跟随）
    @State private var cursorY: CGFloat = 0
    /// 放大渐入量 0…1：唯一走动画的分量（进入点亮 / 离开收拢）
    @State private var magnifyAmount: CGFloat = 0
    /// 被悬停 tick 的消息 id（预览胶囊锚点），由跟踪坐标派生
    @State private var hoveredTickId: UUID?

    /// 轨体宽 = 当前条峰值放大后宽度（tick 右缘对齐，放大向左生长，右基准线钉死不动）
    private var railWidth: CGFloat {
        Theme.Layout.chatTickActiveWidth * Theme.Layout.chatTickMagnifyMaxScale
    }

    /// 跟踪带宽 = 轨体宽 + 左伸接近带（光标逼近即开始响应，Dock 同款「迎光标」）
    private var trackWidth: CGFloat {
        railWidth + Theme.Layout.chatTickTrackSlop
    }

    var body: some View {
        GeometryReader { geo in
            let model = ChatTickRailLayout(
                count: items.count,
                availableHeight: geo.size.height,
                cursorY: cursorY,
                amount: magnifyAmount,
                pinnedIndex: items.firstIndex(where: { $0.isCurrent })
            )
            let radius = Theme.Layout.chatTickMagnifyRadius
            // 磁吸带 = 轨体 ± 一个衰减半径（几何区坐标）；不铺满全高——带外衰减恒零
            // （手感无差），右缘其余区域不占用命中（滚动条可拖拽）
            let trackTop = max(0, model.containerTop - radius)
            let trackHeight = min(geo.size.height, model.containerTop + model.restHeight + radius) - trackTop
            ZStack(alignment: .topTrailing) {
                // tick 层：容器恒为静止总高；放大形变全部收在槽内偏移与 scale
                ZStack(alignment: .top) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        tick(item, slot: model.slots[index])
                    }
                }
                .frame(width: railWidth, height: model.restHeight, alignment: .top)
                .offset(y: model.containerTop - trackTop)
            }
            .frame(width: trackWidth, height: trackHeight, alignment: .topTrailing)
            // 单一跟踪面：覆盖整个交互区（接近带 + 轨体），tick 是其后代 →
            // 光标在带内任意位置 hover 连续；点击仍由 tick 自身的 tap 手势命中
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let y = location.y + trackTop  // 带局部 → 几何区坐标系
                    cursorY = y
                    updateHover(at: CGPoint(x: location.x, y: y), model: model)
                    if magnifyAmount < 1 {
                        withAnimation(.easeOut(duration: Theme.Motion.chatTickMagnifyIn)) {
                            magnifyAmount = 1
                        }
                    }
                case .ended:
                    withAnimation(.easeOut(duration: Theme.Motion.chatTickMagnifyOut)) {
                        magnifyAmount = 0
                        hoveredTickId = nil
                    }
                }
            }
            .position(x: geo.size.width - trackWidth / 2, y: trackTop + trackHeight / 2)
        }
    }

    /// 跟踪坐标派生 hover：命中槽含光标即点亮该 tick；变化才写状态（去抖防每帧 setState）。
    /// 刻意裸写不走 withAnimation——胶囊过渡由 tick 内层 .animation(_:value:) 承担，
    /// 本路径若带动画事务会染指同一渲染帧里的槽位布局（放大跟手性受损）。
    private func updateHover(at location: CGPoint, model: ChatTickRailLayout) {
        let newId = model.hoveredIndex(at: location, trackWidth: trackWidth, railWidth: railWidth)
            .map { items[$0].id }
        guard newId != hoveredTickId else { return }
        hoveredTickId = newId
    }

    /// 单枚 tick：默认 10×2 圆头；当前查看条 16×3 accent 点亮（锚点，钉死不动）；
    /// 普通 tick 明暗随槽位梯度输出（光标正下方最亮、远端更暗）；点击直达该条消息。
    /// 命中区 = Voronoi 槽（随放大同步长大、槽间无缝），胶囊视觉锚定槽心、scaleEffect 放大。
    /// 动画作用域纪律：`.animation(_:value:)` 只罩颜色/胶囊/缩放内层（hover 变化帧才生效）；
    /// 槽位 offset/frame 外壳零动画修饰——光标移动帧的布局即时跟随，绝不橡胶延迟。
    @ViewBuilder
    private func tick(_ item: Item, slot: ChatTickRailLayout.Slot) -> some View {
        let hovered = hoveredTickId == item.id
        let baseWidth = item.isCurrent ? Theme.Layout.chatTickActiveWidth : Theme.Layout.chatTickWidth
        let baseHeight = item.isCurrent ? Theme.Layout.chatTickActiveHeight : Theme.Layout.chatTickHeight
        Capsule(style: .continuous)
            .fill(item.isCurrent ? Theme.Colors.accent : Color.primary.opacity(slot.opacity))
            .frame(width: baseWidth, height: baseHeight)
            .scaleEffect(slot.scale)
            .overlay(alignment: .trailing) {
                // 预览胶囊：hover 弹出，锚定放大后 tick 左侧（overlay trailing = 垂直中心
                // 即 tick 视觉中心）；空文本（纯图片等）消息不弹胶囊；纯展示不吞命中
                if hovered && !item.preview.isEmpty {
                    tickPreviewCapsule(item.preview)
                        .padding(.trailing, baseWidth * slot.scale + Theme.Layout.chatTickPreviewGap)
                        .transition(.opacity.combined(with: .offset(x: 5)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: Theme.Motion.chatTickHoverFade), value: hovered)
            .animation(.easeOut(duration: Theme.Motion.chatTickHoverFade), value: item.isCurrent)
            // —— 以下外壳定位属性无动画修饰覆盖：光标驱动即时跟随 ——
            // 视觉锚定槽心（命中槽与视觉中心在轨端略有错位，故不用槽 frame 的中心对齐）
            .offset(y: slot.center - slot.frameTop - baseHeight / 2)
            .frame(width: railWidth, height: slot.frameHeight, alignment: .topTrailing)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(item.id) }
            // 刻意不挂 .help()——系统 tooltip 与预览胶囊语义冗余，且贴右缘没有 tip 落点空间
            .offset(y: slot.frameTop)
    }

    /// 预览胶囊：深面板底 + 0.5pt 描边 + 8pt 圆角 + 轻投影，白字单行截断；
    /// 右端小三角指回 tick（方向性锚点）。
    ///
    /// 布局关键（空壳事故根因）：本视图挂在 tick 的 overlay 里，SwiftUI overlay 会把
    /// 宿主 tick 的窄尺寸（≈10~16pt）作为宽度 proposal 传进来，Text 会被压扁截断、
    /// 只剩描边空壳。修复 = 先 frame(maxWidth:) 再 fixedSize：fixedSize 让本视图忽略
    /// 宿主 proposal，frame(maxWidth:) 在自由 proposal 下把超长文本钳到上限截断。
    /// 顺序不可换（fixedSize 在前会让 frame 重新收到窄 proposal，前功尽弃）。
    private func tickPreviewCapsule(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.text(Theme.Typography.footnote))
            .foregroundColor(Theme.Colors.contentPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Theme.Layout.chatTickPreviewMaxWidth - Theme.Spacing.xl * 2)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.previewCapsule, style: .continuous)
                    .fill(Theme.Colors.chatNavFloatFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.previewCapsule, style: .continuous)
                    .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
            )
            .overlay(alignment: .trailing) {
                TickPreviewTail()
                    .fill(Theme.Colors.chatNavFloatFill)
                    .frame(width: 5, height: 8)
                    .offset(x: 4.5)
            }
            .shadow(color: .black.opacity(Theme.Shadow.navFloatOpacity),
                    radius: Theme.Shadow.navFloatRadius,
                    y: Theme.Shadow.navFloatY)
    }
}

// MARK: - 手动虚拟化行容器

/// 行级「实渲染 ↔ 等高占位」切换容器：窗口内（或首见无缓存）实渲染；窗口外用缓存
/// 高度的**等高占位**。占位高度 = 实测缓存高度 → 切换零位移 → document 高度恒稳。
/// 这是 LazyVStack 黑盒行估算的替代：macOS 13 上 LazyVStack 回收远行的估算归零/
/// 失准，实例化-回收的「估算↔真实」差一次性结算成万级 pt 的 doc 骤变（日志定证
/// -14306 → 视口瞬移 14053 = 「上滚跳过数条消息」的最终根因，塌缩瞬间零子视图
/// 回退事件、视频无占位闪现——纯行级估算结算）。窗口集合与高度缓存由
/// SessionMessageList.updateRowFrames 的行级几何信号维护。
@MainActor
private struct ChatVirtualRow<Content: View>: View {
    let messageId: UUID
    @Binding var rowHeights: [UUID: CGFloat]
    let inWindow: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            // 首见（无缓存）恒实渲染：几何信号测得高度回写缓存后，离开窗口才切占位。
            if inWindow || rowHeights[messageId] == nil {
                content()
            } else if let height = rowHeights[messageId] {
                Color.clear.frame(height: height)
            }
        }
        // 实渲染 ↔ 占位是内容等效替换：禁动画防闪烁与 CA 事务竞态（历史白屏族防线）。
        // 行 id（message.id）恒定；消息入场 transition 保留在 content 内部。
        .transaction { $0.animation = nil }
    }
}

// MARK: - 浏览导航预览胶囊小三角

/// 预览胶囊右端指向 tick 的小三角（方向性锚点）。
private struct TickPreviewTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct ChatMessageRow: View, Equatable {
    let message: ChatMessage
    /// 是否已被压缩摘要化（纯显示态：驱动整行降档透明度；行内不直接消费，
    /// 参与 Equatable 判定使压缩落盘瞬间相关行重绘弱化）。
    let isSummarized: Bool
    /// 是否为最后一条可重新生成的助手消息（父视图计算，含流式中禁用语义）。
    let canRegenerate: Bool
    /// 是否为会话内最后一条 user 消息且可撤回/编辑（父视图计算，含生成中禁用语义）。
    let canEditLastRound: Bool
    let onRetry: () -> Void
    let onRegenerate: () -> Void
    /// 撤回最后一轮（数据层删除该轮并把文本+图片回填输入框）。
    let onWithdraw: () -> Void
    /// 编辑重发（就地编辑确认后回调新文本与图片附件）。
    let onEditResend: (String, [ChatImageAttachment]) -> Void
    let onTapImage: (ChatImageAttachment) -> Void

    /// 仅按内容与可用操作标记判定相等：闭包语义跨渲染一致，忽略其对 diff 的干扰，
    /// 使 .equatable() 能在流式期间跳过未变更行。
    /// 编辑态/对勾态等瞬态 UI 由 @State 承载（存储于视图值之外），不参与相等判定，
    /// 既不被流式冲刷重置，也不会导致无关行重绘。
    static func == (lhs: ChatMessageRow, rhs: ChatMessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.isSummarized == rhs.isSummarized
            && lhs.canRegenerate == rhs.canRegenerate
            && lhs.canEditLastRound == rhs.canEditLastRound
    }

    @State private var rowHovered = false
    @State private var copied = false
    /// 就地编辑态（仅 canEditLastRound 的 user 行可进入）。
    @State private var editing = false
    /// 编辑草稿：进入编辑时以原消息文本/图片初始化，确认后交给 onEditResend。
    @State private var editText = ""
    @State private var editImages: [ChatImageAttachment] = []
    /// 编辑器内容高度（由 ChatInlineEditTextView 实测回写，驱动编辑气泡自适应生长）。
    @State private var editHeight: CGFloat = 18

    var body: some View {
        // 消息内容 + 下方紧凑操作行（紧贴正文底部 3pt；用户消息整体右对齐）
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .top, spacing: 0) {
                if message.role == .user { Spacer(minLength: Theme.Spacing.panel) }
                content
                // 2026-10 重设计：助手侧尾部 Spacer 已移除——正文/代码块右缘
                // 与用户气泡、输入坞统一到同一条右基准线（阅读列右缘，±0）
            }
            if showsActionRow {
                actionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { rowHovered = hovering }
        }
        .contextMenu { rowContextMenu }
    }

    /// 行级右键菜单：复制整条消息（图片消息复制其文本，若有）；
    /// 会话内最后一条 user 消息追加「编辑并重发 / 撤回该轮」。
    @ViewBuilder
    private var rowContextMenu: some View {
        if !message.content.isEmpty {
            Button { copyContent() } label: {
                Label("复制消息", systemImage: "square.on.square")
            }
        }
        if message.role == .user, canEditLastRound {
            if !message.content.isEmpty { Divider() }
            Button { beginEdit() } label: {
                Label("编辑并重发", systemImage: "pencil")
            }
            Button { onWithdraw() } label: {
                Label("撤回该轮", systemImage: "arrow.uturn.backward")
            }
        }
    }

    /// 操作行渲染条件：
    /// - 助手：落定终态（done/aborted；失败态有独立重试卡片，流式期间不提供半截内容的复制入口）
    /// - 用户：有文本可复制，或是可撤回/编辑的最后一轮
    /// 就地编辑态一律隐藏（编辑操作由编辑气泡内按钮承担）。
    private var showsActionRow: Bool {
        if editing { return false }
        switch message.role {
        case .user:
            return !message.content.isEmpty || canEditLastRound
        case .assistant:
            switch message.state {
            case .done, .aborted:
                return true
            case .sending, .streaming, .failed:
                return false
            }
        case .system:
            return false
        }
    }

    /// 常驻操作行：复制（成功变对勾轻反馈）；最后一条落定助手消息附「重新生成」；
    /// 会话内最后一条 user 消息附「撤回 / 编辑」（与复制一致常驻，生成中不显示）。
    /// 弱化常驻：图标静止 38% 灰、整行 hover 提亮 85%；按钮自身 hover 叠 0.08 圆角底，不抢正文层级。
    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if !message.content.isEmpty {
                ChatActionIconButton(
                    systemName: copied ? "checkmark" : "square.on.square",
                    tint: copied ? Theme.Colors.accent : nil,
                    help: "复制",
                    rowHovered: rowHovered,
                    action: copyContent
                )
            }

            if message.role == .assistant, canRegenerate {
                ChatActionIconButton(
                    systemName: "arrow.clockwise",
                    tint: nil,
                    help: "重新生成",
                    rowHovered: rowHovered,
                    action: onRegenerate
                )
            }

            // 撤回/编辑：与复制行为一致——常驻可见（静止 38% 灰、行 hover 提亮），不做 hover 浮现
            if message.role == .user, canEditLastRound {
                ChatActionIconButton(
                    systemName: "pencil",
                    tint: nil,
                    help: "编辑并重发",
                    rowHovered: rowHovered,
                    action: beginEdit
                )
                ChatActionIconButton(
                    systemName: "arrow.uturn.backward",
                    tint: nil,
                    help: "撤回该轮（内容回填输入框）",
                    rowHovered: rowHovered,
                    action: onWithdraw
                )
            }
        }
    }

    private func copyContent() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)
        copied = true
        // 轻反馈：对勾短暂停留后复位
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .user:
            // 就地编辑态：气泡原地变为编辑器（仅最后一轮 user 消息可进入）
            if editing {
                editBubble
            } else {
                userBubble
            }
        case .assistant:
            assistantContent
        case .system:
            EmptyView()
        }
    }

    /// 用户消息：右对齐气泡，琥珀实底（chatUserBubble：亮色暖纸 / 暗色深琥珀随玻璃微光），
    /// 无描边（实底自身即容器，描边是廉价感来源），圆角 18 对话语言；
    /// 图片缩略图排在文本上方（点击放大），行距与 AI 正文同节奏（13pt + 6 ≈ 1.7 倍行高）。
    /// 文本启用选区复制（textSelection），与助手 Markdown 选区行为对齐。
    /// steering 注入的消息在气泡上方带「已转向」弱标记：纯图文无底色（比「已中止」标签更轻），
    /// 不抢气泡视觉重心，仅作来源可辨识记号。
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
            if message.isSteered == true {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "arrowshape.turn.up.right")
                        .font(Theme.Typography.text(10, .semibold))
                    Text("已转向")
                        .font(Theme.Typography.text(10, .semibold))
                }
                .foregroundColor(Theme.Colors.contentTertiary)
            }
            VStack(alignment: .trailing, spacing: Theme.Spacing.xl) {
                if !message.images.isEmpty {
                    MessageImageThumbs(images: message.images, onTap: onTapImage)
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(Theme.Typography.text(13))
                        .foregroundColor(Theme.Colors.contentPrimary)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.vertical, Theme.Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.userBubble, style: .continuous)
                    .fill(Theme.Colors.chatUserBubble)
            )
        }
    }

    /// 就地编辑态：气泡原地「展开」为编辑器——同底色/圆角/内边距，无跳变感。
    /// 顶部为可单张移除的图片附件条（粘贴可追加）；中间为 IME 安全编辑框
    /// （⏎ 确认 / ⇧⏎ 换行 / ESC 取消，高度随内容自适应、封顶滚动）；
    /// 底部为操作钮（快捷键语义由 .help() tooltip 承担，对齐全窗提示纪律）。
    private var editBubble: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.lg) {
            if !editImages.isEmpty {
                ImageAttachmentStrip(attachments: editImages) { id in
                    editImages.removeAll { $0.id == id }
                }
            }

            ChatInlineEditTextView(
                text: $editText,
                contentHeight: $editHeight,
                onSubmit: confirmEdit,
                onEscape: cancelEdit,
                onInsertImages: { images in
                    for image in images {
                        if let attachment = ImageAttachmentProcessor.makeAttachment(from: image) {
                            editImages.append(attachment)
                        }
                    }
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: editHeight)

            HStack(spacing: Theme.Spacing.md) {
                editBubbleButton(title: "取消", tint: Theme.Colors.contentSecondaryStrong, action: cancelEdit)
                    .help("取消编辑（ESC）")
                editBubbleButton(
                    title: "重发",
                    tint: canConfirmEdit ? Theme.Colors.accent : Theme.Colors.contentTertiary,
                    action: confirmEdit
                )
                .disabled(!canConfirmEdit)
                .help("确认并重发（⏎）")
            }
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.userBubble, style: .continuous)
                .fill(Theme.Colors.chatUserBubble)
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// 编辑气泡内的小胶囊钮：与失败卡「重试」同一语言（surfaceButton 实底 + keyCap 圆角）。
    private func editBubbleButton(title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.text(11, .semibold))
                .foregroundColor(tint)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.vertical, Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                        .fill(Theme.Colors.surfaceButton)
                )
        }
        .buttonStyle(.plain)
    }

    /// 可确认重发：文本非空或仍有图片附件（与主输入框 canSend 同规则）。
    private var canConfirmEdit: Bool {
        !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !editImages.isEmpty
    }

    /// 进入编辑态：以原消息文本/图片初始化草稿，轻量淡入切换。
    private func beginEdit() {
        editText = message.content
        editImages = message.images
        editHeight = 18
        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { editing = true }
    }

    /// 确认编辑：先退出编辑态（视觉先行），再把新文本/图片交给数据层重发（不阻塞）。
    private func confirmEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !editImages.isEmpty else { return }
        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { editing = false }
        onEditResend(text, editImages)
    }

    /// 取消编辑：丢弃草稿，恢复原气泡。
    private func cancelEdit() {
        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { editing = false }
    }

    /// 是否处于生成中（sending/streaming）：思考折叠区据此做流式节流与收尾全量同步。
    private var isLive: Bool {
        switch message.state {
        case .sending, .streaming: return true
        default: return false
        }
    }

    @ViewBuilder
    private var assistantContent: some View {
        // 思考折叠区（有 reasoning 时）→ 文本（无气泡铺底）→ 工具调用卡片纵向排列；
        // 一轮助手消息可能兼有文本与工具调用，纯工具调用轮（无文本）只渲染卡片、不留空文本段；
        // 卡片与正文同宽
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                ReasoningDisclosureView(reasoning: reasoning, isLive: isLive)
            }
            assistantTextPart
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                AIToolCallCardView(toolCalls: toolCalls)
                // 富内容卡片：工具结果携带 card 信封（如地图卡）时，紧随工具卡独立成卡渲染（与正文同宽），
                // 未携带信封的工具调用不产生任何占位
                ForEach(toolCalls, id: \.id) { record in
                    RichCardHostView(resultJSON: record.result ?? "")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 助手消息的文本部分（按状态分派）；纯工具调用消息（无文本）不渲染空文本段。
    @ViewBuilder
    private var assistantTextPart: some View {
        // 有工具调用且文本为空时跳过文本段（工具卡片单独成段）
        let skipsTextPart = message.content.isEmpty && !(message.toolCalls?.isEmpty ?? true)
        switch message.state {
        case .sending, .streaming:
            // 流式/首 token 等待：纯文本增量 + 块状光标（流结束后切完整 AST 渲染）；
            // hasReasoning 让空正文态决定是否补「思考中…」阶段词（有 reasoning 时折叠区已承载活性）
            StreamingMessageView(content: message.content, hasReasoning: !(message.reasoning?.isEmpty ?? true))
        case .failed(let errorText):
            // 失败态保留提示卡片（状态提示，非正文排版）
            FailedMessageView(errorText: errorText, onRetry: onRetry)
        case .done:
            // 落定态：完整块级 Markdown 渲染（AIChatMarkdownView）；
            // textSelection 支持按块选区复制（跨块选择与含公式段落不支持，见 MarkdownInlineText 结构限制）
            if !skipsTextPart {
                AssistantMarkdownView(content: message.content)
                    // 显式绑定消息身份：message.id 变化即重建视图，分批渲染游标随之重置。
                    .id(message.id)
                    .textSelection(.enabled)
                    // 白屏防线（勿动族）：落定态从流式视图结构性替换为完整渲染时，禁用从祖先
                    // （messageList 的 .animation(value: messages.count) 与行级 transition）传入的
                    // 隐式动画，防止 CA 事务竞态把内容层卡在近零透明度；无动画瞬时替换。
                    .transaction { $0.animation = nil }
            }
        case .aborted:
            // 中止：保留半截内容的富渲染 + 弱标记
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if !skipsTextPart {
                    AssistantMarkdownView(content: message.content)
                        .id(message.id)
                        .textSelection(.enabled)
                        // 白屏防线（勿动族）：同 .done 分支，结构性替换禁用祖先隐式动画，防 CA 事务竞态。
                        .transaction { $0.animation = nil }
                }
                AbortedTag()
            }
        }
    }
}

/// 操作行图标钮：10pt hierarchical 符号、18×18 命中区；
/// 图标色随行 hover 提亮（0.38 → 0.85），自身 hover 叠 primary 0.08 圆角底（macOS 工具图标惯例）。
private struct ChatActionIconButton: View {
    let systemName: String
    /// 反馈色（如复制成功的 accent 对勾）；nil = 常规灰度档。
    var tint: Color? = nil
    let help: String
    /// 父行 hover 态：驱动图标色提亮（行级弱化/增强的统一信号）。
    let rowHovered: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(Theme.Typography.text(10, .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(tint ?? Color.primary.opacity(rowHovered ? 0.85 : 0.38))
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
    }
}

/// 流式消息：增量 Markdown 渲染（节流）+ 闪烁块状光标。
/// 与落定态一致无气泡，流式→定稿不再发生排版/颜色跳变。
/// 两级表达：① 无正文且无 reasoning = 光标 + 弱化阶段词「思考中…」（首 token 等待）；
/// ② 无正文但有 reasoning = 不渲染任何占位，活性由上方的思考折叠区摘要行实时更新承担
/// （避免孤儿光标噪声）；③ 有正文增量后 = 光标跟随文尾，无状态词。
private struct StreamingMessageView: View {
    let content: String
    /// 是否已有思考过程（reasoning 折叠区由外层 assistantContent 承载，此处只做空态取舍）。
    let hasReasoning: Bool

    var body: some View {
        if !content.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                StreamingMarkdownContentView(content: content)
                // 光标跟随文尾（置于内容块尾行下方左侧，模拟文尾 caret）
                BlinkingCaret()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !hasReasoning {
            HStack(spacing: Theme.Spacing.sm) {
                BlinkingCaret()
                Text("思考中…")
                    .font(Theme.Typography.text(Theme.Typography.footnote))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }
        }
    }
}

/// 闪烁块状光标：▌ 以线性节拍闪烁（近似系统 caret；只闪光标，不呼吸整行，避免视觉噪声）。
private struct BlinkingCaret: View {
    @State private var lit = false

    var body: some View {
        Text("▌")
            .font(Theme.Typography.text(Theme.Typography.body))
            .foregroundColor(Theme.Colors.contentSecondaryStrong)
            .opacity(lit ? 1 : 0)
            .onAppear {
                withAnimation(.linear(duration: Theme.Motion.caretBlink).repeatForever(autoreverses: true)) {
                    lit = true
                }
            }
    }
}

/// 思考过程（reasoning）折叠区：默认收起为单行摘要（时钟/大脑小图标 + 最近一段思考
/// 单行截断 + 展开箭头），点击 toggle 展开为限高滚动多行区；落定后同样保留、默认收起。
/// 流式期间 250ms 时间门控节流刷新（与正文增量渲染同节奏），收尾（isLive 翻 false）全量对账。
private struct ReasoningDisclosureView: View {
    let reasoning: String
    /// 是否仍在生成中：节流门控期间中间帧可丢，收尾帧必须全量（防止末尾增量被门控吞掉）。
    let isLive: Bool

    @State private var expanded = false
    @State private var rendered: String = ""
    @State private var lastRenderAt: Date = .distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Button {
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { expanded.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "brain")
                        .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                    Text(summary)
                        .font(Theme.Typography.text(Theme.Typography.footnote))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // chevron 固定行尾：摘要流式更新时宽度变化不带动其位置，消除抖动
                    Spacer(minLength: Theme.Spacing.sm)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(Theme.Typography.text(Theme.Typography.micro, .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(Theme.Colors.contentTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起思考过程" : "展开思考过程")

            if expanded {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(rendered)
                        .font(Theme.Typography.text(Theme.Typography.label))
                        .foregroundColor(Theme.Colors.contentSecondaryStrong)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Theme.Layout.reasoningMaxHeight)
                .transition(.opacity)
            }
        }
        .onAppear {
            rendered = reasoning
            lastRenderAt = Date()
        }
        .onChange(of: reasoning) { newValue in
            let now = Date()
            guard now.timeIntervalSince(lastRenderAt) >= 0.25 else { return }
            lastRenderAt = now
            rendered = newValue
        }
        // 收尾对账：生成结束时无论门控窗口如何都渲染全量，防止末尾增量被节流吞掉
        .onChange(of: isLive) { live in
            if !live { rendered = reasoning }
        }
    }

    /// 摘要：取最近一个非空段落（流式期间摘要行随增量实时更新，单行截断）。
    private var summary: String {
        let paragraphs = rendered
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paragraphs.last ?? "思考中…"
    }
}

// MARK: - 压缩标记折叠卡

/// 上下文压缩边界卡：会话流内的章节标记（不参与消息选中/上下文菜单交互，独立 struct 天然隔离）。
/// - 收起态：居中弱化胶囊行（⟲ + 「已压缩早期对话（N 条）」+ micro chevron），
///   surfaceBadge 底 + contentTertiary 灰字，总高 ≈24pt，与「已中止」标记同档弱化；
/// - 展开态：摘要全文（footnote 正文 + 3pt 行距 + 正常阅读色），上下各一条两端羽化的
///   0.5pt 细边线收束——ReasoningDisclosureView 的折叠气质，但更轻（不限高不内滚，
///   摘要语义上远短于原文，纵向让位给外层会话流滚动）；
/// - 压缩中：「⟲ 正在压缩…」，不可点、无 chevron，仅靠文案表达进行中（不加旋转/脉冲动画）。
private struct CompactionBoundaryCard: View {
    let isCompacting: Bool
    let summarizedCount: Int
    let summary: String

    @State private var expanded = false
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            // 分界线语义（2026-10 升级）：胶囊不再是孤立徽章，两侧羽化细线贯穿阅读列，
            // 与行级降档（线上方 = 已摘要化区域、整行弱化）共同构成「章节分界」——
            // 用户扫读时一眼可见模型视角的分叉点。
            HStack(spacing: Theme.Spacing.xl) {
                featheredDivider
                Button {
                    withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { expanded.toggle() }
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                        Text(isCompacting ? "正在压缩…" : "已压缩早期对话（\(summarizedCount) 条）")
                            .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                        if !isCompacting {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(Theme.Typography.text(Theme.Typography.micro, .medium))
                        }
                    }
                    // 单行钉死：两侧羽化细线是无限弹性填充，会把胶囊可用宽挤窄导致文案折行
                    //（回归实拍：「已压缩早期对话／（N 条）」两行）。fixedSize 让胶囊取理想
                    // 单行宽，宽度余量由细线吸收——章节分界语义下「线让位于字」。
                    .fixedSize()
                    .foregroundColor(isCompacting
                                     ? Theme.Colors.idleText
                                     : (hovered ? Theme.Colors.contentSecondaryStrong : Theme.Colors.contentTertiary))
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.chip)
                    .background(
                        Capsule(style: .continuous)
                            .fill(!isCompacting && hovered ? Theme.Colors.iconHoverBg : Theme.Colors.surfaceBadge)
                    )
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isCompacting)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
                }
                .help(isCompacting ? "正在压缩早期对话…" : (expanded ? "收起压缩摘要" : "查看压缩摘要"))
                featheredDivider
            }

            if expanded, !isCompacting, !summary.isEmpty {
                VStack(spacing: 0) {
                    featheredDivider
                    Text(summary)
                        .font(Theme.Typography.text(Theme.Typography.footnote))
                        .foregroundColor(Theme.Colors.contentSecondaryStrong)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Spacing.lg)
                    featheredDivider
                }
                .padding(.top, Theme.Spacing.lg)
                .transition(.opacity)
            }
        }
        // 分界行随 VStack 撑满阅读列（细线向两侧延展）；上下补一点呼吸，
        // 使组内插入时上下节奏（xl=10 + xs）与组间章节感平衡
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xs)
    }

    /// 两端羽化的 0.5pt 细边线（窗口分割线同款渐变语言，水平方向）；
    /// 分界行内左右各一条，maxWidth 均分胶囊两侧的剩余空间。
    private var featheredDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.0),
                        Color.primary.opacity(Theme.Colors.dividerOpacity),
                        Color.primary.opacity(0.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Layout.dividerHeight)
    }
}

/// 流式 Markdown 增量渲染：把高频 token 触发的重解析节流到 ≤4Hz（250ms 时间门控）。
/// - rendered 仅在距上次渲染 ≥250ms 时更新；被跳过的中间帧不补渲染。
/// - 收尾帧完整性由 streaming→done/aborted 后切换的 AssistantMarkdownView 全量渲染保证。
/// - 未闭合 `$$`/`**` 短暂显示源码属预期，不做特殊处理。
private struct StreamingMarkdownContentView: View {
    let content: String

    @State private var rendered: String = ""
    @State private var lastRenderAt: Date = .distantPast

    var body: some View {
        AssistantMarkdownView(content: rendered, useCache: false)
            .onAppear {
                rendered = content
                lastRenderAt = Date()
            }
            .onChange(of: content) { newValue in
                let now = Date()
                guard now.timeIntervalSince(lastRenderAt) >= 0.25 else { return }
                lastRenderAt = now
                rendered = newValue
            }
    }
}

/// 失败消息：错误色提示 + 重试按钮（重发最后一条 user 消息）。
private struct FailedMessageView: View {
    let errorText: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.text(12))
                    .foregroundColor(Theme.Colors.statusWarning)
                Text(errorText)
                    .font(Theme.Typography.text(12))
                    .foregroundColor(Theme.Colors.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: onRetry) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.Typography.text(11, .semibold))
                    Text("重试")
                        .font(Theme.Typography.text(11, .semibold))
                }
                .foregroundColor(Theme.Colors.contentPrimary)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.vertical, Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                        .fill(Theme.Colors.surfaceButton)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .fill(Theme.Colors.statusWarning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .stroke(Theme.Colors.statusWarning.opacity(0.28), lineWidth: 0.5)
        )
    }
}

/// 「已中止」弱标记。
private struct AbortedTag: View {
    var body: some View {
        Text("已中止")
            .font(Theme.Typography.text(10.5, .medium))
            .foregroundColor(Theme.Colors.contentTertiary)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.surfaceBadge)
            )
    }
}

// MARK: - 待注入队列胶囊（steering / follow-up）

/// 待注入队列胶囊：类型标签（转向=↪ / 追问=↩ + 中文小字）+ 文本单行截断 + hover 露出 ✕。
/// 点击整枚胶囊取回编辑（数据层回填输入框，胶囊随队列移除消失）；hover 提亮。
/// ✕ 与整枚同语义（撤回该条回填输入框），始终占位、hover 才显形——opacity 渐变、
/// 布局零跳动（同 showDockSecondaryTools 纪律）。
/// 视觉沿用坞内微胶囊语言：实底 surfaceTrack + 0.5pt 白 rim，不新增设计令牌。
private struct QueuedInputCapsule: View {
    let item: QueuedChatInput
    let onRecall: () -> Void

    @State private var hovered = false

    private var isSteering: Bool { item.kind == .steering }

    var body: some View {
        Button(action: onRecall) {
            HStack(spacing: Theme.Spacing.md) {
                // 类型标签：转向=即时修正方向（accent 强调）；追问=轮末追加（次级色）
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: isSteering
                          ? "arrowshape.turn.up.right.fill"
                          : "arrowshape.turn.up.left.fill")
                        .font(Theme.Typography.text(10, .semibold))
                    Text(isSteering ? "转向" : "追问")
                        .font(Theme.Typography.text(10, .semibold))
                }
                .foregroundColor(isSteering ? Theme.Colors.accent : Theme.Colors.contentSecondaryStrong)

                Text(displayText)
                    .font(Theme.Typography.text(11, .medium))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                // ✕ 撤回钮：与点击整枚同动作（撤回回填），嵌套命中无歧义；
                // 非 hover 时禁命中，点击穿透到整枚胶囊。
                Button(action: onRecall) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Typography.text(12))
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
                .accessibilityHidden(!hovered)
                .help("撤回该条到输入框")
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
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
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
        // 固定文案后附队列项完整文本（单行截断的补偿：多行长文经 tooltip 全量可读）
        .help((isSteering
              ? "转向：本轮生成中即时注入、修正方向 · 点击取回编辑"
              : "追问：本轮回复完成后自动追加一轮 · 点击取回编辑")
              + "\n" + displayText)
    }

    /// 展示文本：纯图片队列项给占位文案（对齐 send 的「请查看图片。」兜底语义）。
    private var displayText: String {
        if !item.text.isEmpty { return item.text }
        if !item.images.isEmpty { return "图片 ×\(item.images.count)" }
        return ""
    }
}

// MARK: - 剪贴板胶囊

private struct ClipboardAttachmentCapsule: View {
    let charCount: Int
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(Theme.Typography.text(11, .medium))
                .foregroundColor(Theme.Colors.accent)
            Text("已附加剪贴板 \(charCount) 字")
                .font(Theme.Typography.text(11, .medium))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(Theme.Typography.text(12))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }
            .buttonStyle(.plain)
            .help("移除剪贴板附加")
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .fill(Theme.Colors.surfaceButton)
        )
    }
}

// MARK: - 空态欢迎页（已配置、无消息）

private struct WelcomeView: View {
    let hasClipboardText: Bool
    let onAttachClipboard: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Image(systemName: "sparkles")
                .font(.system(size: Theme.Typography.settingsIcon, weight: .regular))
                .foregroundColor(Theme.Colors.accent)
            Text("有什么想问的？")
                .font(Theme.Typography.text(Theme.Typography.toast, .medium))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)

            // 剪贴板快捷引用：有可用文本时给一个轻入口
            if hasClipboardText {
                Button(action: onAttachClipboard) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "doc.on.clipboard")
                            .font(Theme.Typography.text(11, .medium))
                        Text("附加剪贴板内容")
                            .font(Theme.Typography.text(11, .medium))
                    }
                    .foregroundColor(Theme.Colors.contentTertiary)
                    .padding(.horizontal, Theme.Spacing.xxl)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                            .fill(Theme.Colors.surfaceButton)
                    )
                }
                .buttonStyle(.plain)
                .help("把剪贴板文本附加为对话上下文")
            }
        }
        .padding(Theme.Spacing.panel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 未配置引导

private struct UnconfiguredGuideView: View {
    let onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.xxl) {
            Image(systemName: "sparkles")
                .font(.system(size: Theme.Typography.settingsIcon, weight: .regular))
                .foregroundColor(Theme.Colors.accent)
            Text("未配置 AI 服务")
                .font(Theme.Typography.text(Theme.Typography.toast, .semibold))
                .foregroundColor(Theme.Colors.contentPrimary)
            Text("在设置中填写 Base URL、API Key 与 Model 后即可开始对话。")
                .font(Theme.Typography.text(12))
                .foregroundColor(Theme.Colors.contentTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onOpenSettings?()
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "gearshape.fill")
                        .font(Theme.Typography.text(12, .semibold))
                    Text("打开设置…")
                        .font(Theme.Typography.text(12, .semibold))
                }
                .foregroundColor(Color(.windowBackgroundColor))
                .padding(.horizontal, Theme.Spacing.card)
                .padding(.vertical, Theme.Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                        .fill(Theme.Colors.accent)
                )
            }
            .buttonStyle(.plain)
            .disabled(onOpenSettings == nil)
        }
        .padding(Theme.Spacing.panel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 输入框（NSTextView 包装）

/// NSTextView 包装：实现 ⏎ 发送 / ⇧⏎ 换行 / 中文输入法组字放行 / 图片粘贴与拖入。
/// 为什么不用 SwiftUI TextField/TextEditor：⏎ 语义必须自定义，且必须在 doCommandBy 层
/// 通过 markedRange 判定中文输入法组字，避免组字回车被误判为发送。
private struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    /// 输入内容是否为空的独立回写通道：IME 组字期间 SwiftUI 绑定不更新，
    /// 需由 setMarkedText 回调驱动，避免组字文本与 placeholder 重叠。
    @Binding var isInputEmpty: Bool
    let onSubmit: () -> Void
    /// ⌥⏎ 追问：生成中入 follow-up 队列 / 非生成中退化普通发送（语义由调用方承载）。
    let onSubmitFollowUp: () -> Void
    let onEscape: () -> Void
    /// 粘贴/拖入图片（NSImage 数组，由调用方转附件）。
    let onInsertImages: ([NSImage]) -> Void
    /// ⌘⌫ 撤回队首（仅空输入框时由 NSTextView 触发；空队列时调用方静默不动作）。
    let onRecallFirst: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 手工搭建文本系统：scrollableTextView() 返回基类 NSTextView，无法插入自定义子类
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = ChatInputNSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.onEscape = onEscape
        textView.onInsertImages = onInsertImages
        textView.onRecallFirst = onRecallFirst
        // IME 组字（marked text）不触发 textDidChange：靠该回调同步组字文本与空态，
        // 避免 placeholder 重叠，并让绑定不滞后于组字内容（防止 updateNSView 误回写）。
        textView.onContentStateChanged = { [weak coordinator = context.coordinator] in
            guard let coordinator, let tv = coordinator.textView else { return }
            coordinator.syncInputState(tv)
        }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        // 关闭各类自动替换/检查，避免对话输入被系统“纠正”并出现下划线噪音
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        // 内边距与 SwiftUI 占位文案 padding 对齐：左右 18pt（section），垂直 12pt
        //（配 44pt 输入行高视觉近居中；56→44 收紧后同步调整）
        textView.textContainerInset = NSSize(
            width: Theme.Spacing.section,
            height: Theme.Spacing.xxl
        )
        textView.textContainer?.lineFragmentPadding = 0
        // 追加注册图片拖放类型（不影响默认文本拖入；jpeg 无内置常量，用 UTI 字符串）
        textView.registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")])

        let scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        context.coordinator.textView = textView
        context.coordinator.startObservingWindow()
        // 首帧若窗口已就绪则聚焦；窗口后续成为 key 时由观察者兜底聚焦。
        // 若此刻其他 NSTextView（如侧栏重命名 field editor）已持焦点则让位（一致性保险）。
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            if let responder = window.firstResponder as? NSTextView, responder !== textView {
                return
            }
            window.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.onEscape = onEscape
        textView.onInsertImages = onInsertImages
        textView.onRecallFirst = onRecallFirst
        // 外部（发送清空 / ⌘K / 重试）修改文本时回写；仅在内容不一致时写。
        // 关键防线：IME 组字期间（markedRange 非空）绝不做程序化回写——textDidChange 在组字时不触发，
        // 绑定必然滞后于组字文本（如首键 "a" 尚未进绑定），此时回写会摧毁组字导致首字母闪失。
        // 组字提交/取消后 textDidChange（或 syncInputState 回调）会补齐绑定，届时再对账。
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObservingWindow()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        weak var textView: ChatInputNSTextView?

        init(_ parent: ChatInputTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // 提交/普通输入：合并同步 text 与空态（仅在不等时写，避免与 updateNSView 形成回写回路）
            syncInputState(tv)
        }

        /// 同步输入状态（供 textDidChange 与 IME setMarkedText/unmarkText 回调共用）：
        /// - 组字期间 textDidChange 不触发，绑定会滞后；这里把组字文本实时写入 parent.text，
        ///   使 `.onChange(of: state.inputText)` 与 updateNSView 对账天然一致；
        /// - 组字取消 setMarkedText("") 时绑定随之清空，placeholder 正确恢复；
        /// - 同时刷新 isInputEmpty（独立于 state.inputText 的 placeholder 通道）。
        func syncInputState(_ tv: NSTextView) {
            if parent.text != tv.string {
                parent.text = tv.string
            }
            let empty = tv.string.isEmpty
            if parent.isInputEmpty != empty {
                parent.isInputEmpty = empty
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // ⏎：中文 IME 组字期间 markedRange 非空 → 放行给输入法先提交候选字，绝不触发发送
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if textView.hasMarkedText() { return false }
                if NSEvent.modifierFlags.contains(.shift) {
                    // ⇧⏎ 换行：忽略 field editor 语义，强制插入软换行（⌥⇧⏎ 同按 ⇧ 处理）
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else if NSEvent.modifierFlags.contains(.option) {
                    // ⌥⏎ 追问（组字守卫与 ⏎ 一致，上面已先行放行输入法）
                    parent.onSubmitFollowUp()
                } else {
                    parent.onSubmit()
                }
                return true
            }
            // ⇧⏎ / ⌥⏎ 在默认键绑定（$↩ / ~↩）下多映射为该命令：
            // ⌥⏎ → 追问（组字守卫同上）；⇧⏎ 及其余 → 交给默认实现插入换行
            if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                if NSEvent.modifierFlags.contains(.option), !NSEvent.modifierFlags.contains(.shift) {
                    if textView.hasMarkedText() { return false }
                    parent.onSubmitFollowUp()
                    return true
                }
                return false
            }
            return false
        }

        /// 监听窗口成为 key：保证 AI 窗每次唤出时输入框拿到第一响应者。
        func startObservingWindow() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
        }

        func stopObservingWindow() {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        }

        @objc private func windowDidBecomeKey(_ note: Notification) {
            guard let window = note.object as? NSWindow,
                  window === textView?.window else { return }
            // 侧栏行内重命名等文本控件已持焦点时让位，不抢占第一响应者
            // （重命名 TextField 的 field editor 也是 NSTextView；区别于本输入框）
            if let responder = window.firstResponder as? NSTextView, responder !== textView {
                return
            }
            window.makeFirstResponder(textView)
        }
    }
}

/// 自定义 NSTextView：ESC 触发注入回调（先中止/后关窗由调用方决定）；
/// 粘贴/拖入图片优先转附件（剪贴板或拖拽源含图片时消费，不落入文本）。
/// FloatingPanel 系面板对 firstResponder is NSTextView 全键放行，ESC 可能直达此处；
/// 由 AIChatView.handleEscape 承载两阶段语义；无回调时走默认 cancelOperation。
private final class ChatInputNSTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onInsertImages: (([NSImage]) -> Void)?
    /// ⌘⌫ 撤回队首回调（仅输入框为空且非组字时触发；有文字时 ⌘⌫ 保留系统「删到行首」语义）。
    var onRecallFirst: (() -> Void)?
    /// 内容状态变化回调（IME 组字/取消组字时 textDidChange 不触发，需单独通知 placeholder）。
    var onContentStateChanged: (() -> Void)?

    /// IME 组字更新：marked text 变化不触发 textDidChange，这里主动通知空态变化。
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onContentStateChanged?()
    }

    /// 取消/提交组字：ESC 取消组字会走 unmarkText（string 可能回到空），同样通知空态。
    override func unmarkText() {
        super.unmarkText()
        onContentStateChanged?()
    }

    // 无 Edit 菜单的轻量应用里，文本系统的标准编辑键等效可能不被派发——
    // 显式接住，保证 ⌘V 粘贴 / ⌘C 拷贝 / ⌘X 剪切 / ⌘A 全选任何环境下可用
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 9: paste(nil); return true       // V
            case 8: copy(nil); return true        // C
            case 7: cut(nil); return true         // X
            case 0: selectAll(nil); return true   // A
            case 51:                              // ⌫
                // ⌘⌫：仅空输入框（且非 IME 组字中）消费为「撤回队首」——撤回后文字回填进
                // 输入框，心智自洽；有文字时放行，保留系统 ⌘⌫「删到行首」语义，不吞正常编辑。
                if string.isEmpty, !hasMarkedText(), let onRecallFirst {
                    onRecallFirst()
                    return true
                }
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// 粘贴：剪贴板含图片（截图位图 / Finder 图片文件）时优先转为图片附件，否则走默认文本粘贴。
    override func paste(_ sender: Any?) {
        let images = PasteboardImageExtractor.images(from: NSPasteboard.general)
        if !images.isEmpty {
            onInsertImages?(images)
            return
        }
        super.paste(sender)
    }

    /// 拖入：拖拽源含图片时高亮接收并转附件，否则交给默认文本拖放。
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if PasteboardImageExtractor.containsImage(sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = PasteboardImageExtractor.images(from: sender.draggingPasteboard)
        if !images.isEmpty {
            onInsertImages?(images)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape {
            onEscape()
        } else {
            super.cancelOperation(sender)
        }
    }
}

// MARK: - 就地编辑输入框（最后一轮 user 消息）

/// 就地编辑输入框：与主输入框 ChatInputTextView 同源语义——⏎ 确认 / ⇧⏎ 换行 /
/// 中文 IME 组字放行 / ESC 取消 / 图片粘贴追加附件，复用 ChatInputNSTextView 子类。
/// 差异：不挂窗口级焦点观察（只在进入编辑态时主动拿一次焦点，避免与主输入框抢响应者）；
/// 内容高度经 contentHeight 实测回写，驱动编辑气泡随文本自适应生长（封顶后内部滚动）。
private struct ChatInlineEditTextView: NSViewRepresentable {
    @Binding var text: String
    /// 内容高度回写（编辑气泡 frame 高度的唯一来源）。
    @Binding var contentHeight: CGFloat
    let onSubmit: () -> Void
    let onEscape: () -> Void
    /// 粘贴/拖入图片（NSImage 数组，由调用方转附件）。
    let onInsertImages: ([NSImage]) -> Void

    /// 高度下限（单行 13pt ≈ 17）与上限（封顶后由内置 scrollView 滚动）。
    private let minHeight: CGFloat = 18
    private let maxHeight: CGFloat = 160

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 手工搭建文本系统（与主输入框同理：scrollableTextView() 无法插入自定义子类）
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = ChatInputNSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.onEscape = onEscape
        textView.onInsertImages = onInsertImages
        // IME 组字（marked text）不触发 textDidChange：靠该回调同步草稿文本与高度
        textView.onContentStateChanged = { [weak coordinator = context.coordinator] in
            guard let coordinator, let tv = coordinator.textView else { return }
            coordinator.syncState(tv)
        }
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        // 关闭各类自动替换/检查（与主输入框同一纪律，避免编辑被系统"纠正"）
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        // 编辑气泡的内边距已由外层 padding 承担，文本系统零内边距（高度回写即纯文本高）
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // 追加注册图片拖放类型（与主输入框一致）
        textView.registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")])
        textView.string = text

        let scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        context.coordinator.textView = textView
        // 进入编辑态：首帧布局后同步初始高度、聚焦并把光标移到文尾
        DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
            guard let textView else { return }
            coordinator?.syncState(textView)
            guard let window = textView.window else { return }
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.onEscape = onEscape
        textView.onInsertImages = onInsertImages
        // 外部回写防线与主输入框一致：IME 组字期间绝不程序化改写（防摧毁组字）
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        context.coordinator.syncHeight(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInlineEditTextView
        weak var textView: ChatInputNSTextView?

        init(_ parent: ChatInlineEditTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            syncState(tv)
        }

        /// 合并同步草稿文本与高度（textDidChange 与 IME 组字回调共用；仅在不等时写，防回写回路）。
        func syncState(_ tv: NSTextView) {
            if parent.text != tv.string {
                parent.text = tv.string
            }
            syncHeight(tv)
        }

        /// 内容高度对账：usedRect 实测文本高，钳制到 [minHeight, maxHeight] 后回写。
        func syncHeight(_ tv: NSTextView) {
            guard let layoutManager = tv.layoutManager, let textContainer = tv.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let fitted = layoutManager.usedRect(for: textContainer).height
            let clamped = min(max(fitted, parent.minHeight), parent.maxHeight)
            if abs(parent.contentHeight - clamped) > 0.5 {
                parent.contentHeight = clamped
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // ⏎：中文 IME 组字期间 markedRange 非空 → 放行给输入法先提交候选字，绝不触发确认
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if textView.hasMarkedText() { return false }
                if NSEvent.modifierFlags.contains(.shift) {
                    // ⇧⏎ 换行：忽略 field editor 语义，强制插入软换行
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            // ⇧⏎ 在部分系统路径下映射为该命令：交给默认实现插入换行
            if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                return false
            }
            return false
        }
    }
}

// MARK: - 面板圆角裁剪（统一路径）
// 整窗 glass 已移除后，窗口层圆角由 PanelHostingConfigurator 在 AppKit 根图层统一施加；
// 这里再对 SwiftUI 内容做一次同半径裁剪，保证自绘内容不越界。
private struct AIChatRoundedClip: ViewModifier {
    func body(content: Content) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }
}

// MARK: - 阅读列约束（消息列 / 输入坞 / 浮动导航簇共用）

/// 内容区宽度上报键（阅读列水平边距分级的输入信号）。
private struct ChatReadingColumnWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 阅读列统一约束：限宽 `Theme.Layout.chatContentMaxWidth` 居中 + 水平边距分级
/// （内容区 <720pt 用 `Spacing.section`=18 即默认窗现状；≥720pt 升为 28，宽窗保留玻璃呼吸边）
/// + 右缘 `chatTickRailLane` 让位通道（消息/坞/图钉/回底钮整体内缩，与右缘刻度轨之间
/// 留足呼吸带——窄窗右总边距 46pt，覆盖 tick 放大峰值宽度仍有余量）。
/// 三处应用点共用本修饰器，列左缘/右缘对齐逻辑单一来源、永不漂移。
///
/// 宽度读取走 background GeometryReader + preference：部署目标 macOS 13 不可用
/// onGeometryChange（14+）；GeometryReader 挂 background 内尺寸被前景约束（最外层撑满帧），
/// 无 ScrollView 内直接嵌 GeometryReader 的高度提议风险。padding 跳变不回读最外层宽度
/// （maxWidth: .infinity 层宽度只取决于父级提议），无反馈环。
/// 已知行为：冷启动首帧 preference 尚未上报时按窄档 18 上屏，次帧修正为宽档（仅窗口
/// ≥720pt 首建时发生一次 ~1 帧的列定锚；面板复用/LRU 常驻路径 @State 已持正确值，不跳变）。
private struct ChatReadingColumn: ViewModifier {
    /// 列内内容对齐：消息列/输入坞 leading，浮动导航簇 trailing（贴列右缘）。
    let alignment: Alignment
    /// 内容区实测宽度（最外层撑满帧的几何读数），驱动水平边距分级。
    @State private var containerWidth: CGFloat = 0

    private var horizontalPadding: CGFloat {
        containerWidth >= Theme.Layout.chatReadingWideBreakpoint
            ? Theme.Layout.chatReadingWidePadding
            : Theme.Spacing.section
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: Theme.Layout.chatContentMaxWidth, alignment: alignment)
            .padding(.horizontal, horizontalPadding)
            .padding(.trailing, Theme.Layout.chatTickRailLane)
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ChatReadingColumnWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(ChatReadingColumnWidthKey.self) { containerWidth = $0 }
    }
}

private extension View {
    /// 阅读列统一约束（限宽居中 + 水平边距分级），详见 `ChatReadingColumn`。
    func chatReadingColumn(alignment: Alignment = .leading) -> some View {
        modifier(ChatReadingColumn(alignment: alignment))
    }
}
