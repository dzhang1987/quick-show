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
///   当前条 accent 点亮；hover 弹预览胶囊、点击跳转）+ 坞正上方 ↓ 回底钮；浏览态显示、贴底隐藏
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
    /// 事件直写已被实证可靠），供消息列表尾部留白 / 空态 overlay / 导出 toast /
    /// 浏览导航统一消费——尾部留白 = 实测坞高 + 呼吸缝，随坞体动态生长；真穿透设计下
    /// 滚动内容穿入坞底由玻璃 blur 采样。值单向流入布局计算，绝不反向影响坞体布局
    /// （无反馈环）；初值 chatDockHeightFallback 首帧兜底，实测后校准；<0.5pt 去抖跳过。
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
            // 抽屉 UI 在场登记：逻辑层据此决定发布请求还是安全兜底（拒绝/取消）
            interaction.markUIActive(true)
        }
        .onDisappear {
            keyMonitor.remove()
            // UI 离场：挂起中的抽屉请求被唤醒为兜底结果（确认→拒绝 / 提问→取消），防泄漏
            interaction.markUIActive(false)
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
        // 真穿透：滚动内容自然穿入玻璃坞下方，坞体实时 blur 采样透出模糊内容；
        // 列表尾部留白 = 实测坞高 + 呼吸缝，保证滚到底时末条消息完整露出坞顶上方
        // （见 SessionMessageList）——坞体生长（队列胶囊等在坞顶向上生长、工具行换态）
        // 留白随之动态跟随。
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

    /// 安静态判据：无草稿、无附件、无待注入队列、非生成中、无抽屉请求，且鼠标不在坞区。
    /// 安静态下坞收敛为「纯输入行 + 弱化小字 chip + 无底灰箭头」——无 accent rim、
    /// 无实心色块、低频工具隐去，空态视觉重心让回中部引导区；
    /// 悬停坞区 / 开始输入 / 附加内容 / 生成开始 / 抽屉展开即切换激活态（0.16s 淡入，contentFade）。
    private var dockQuiet: Bool {
        // 空态判据双通道与：草稿恢复期 inputEmpty 可能滞后（@State 初值 true、首帧无变化事件），
        // state.inputText 非空即有草稿，首帧即正确（见 inputEmpty 声明处注释）。
        inputEmpty
            && state.inputText.isEmpty
            && state.clipboardAttachment == nil
            && state.imageAttachments.isEmpty
            && state.pendingQueue.isEmpty
            && !state.isStreaming
            && interaction.request == nil
            && !dockHovered
    }

    /// 激活态描边：坞体激活且窗口 key 时才点亮 accent 环（旧版仅按窗口 key 常亮，
    /// 空态下形成横贯底部的整圈彩色轮廓带——全图唯一彩色轮廓即源于此）。
    private var dockRimActive: Bool { windowIsKey && !dockQuiet }

    /// 低频工具组（压缩/水位/剪贴板）显隐：安静态隐去（保留占位、纯透明渐变、布局零跳动）；
    /// 两类破格常显，同源同档：水位逼近上限（需要警示的时刻不沉默）+ 压缩进行中
    /// （进行中的操作不消失——2026-10 用户决策：压缩中圆环转不定态 spinner，必须留在
    /// 视口内；压缩结束恢复随安静态隐去）。
    private var showDockSecondaryTools: Bool { !dockQuiet || watermarkBreaksThrough || state.isCompacting }

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

            // 连续玻璃体（2026-10 抽屉式交互）：抽屉（在场时）+ 输入卡共享同一个
            // GlassSurface / accent rim / 双层阴影——抽屉是输入卡"长出"的上半部分，
            // 衔接处零间隙、圆角恒为 Radius.groupCard，中间仅一条 0.5pt 极淡分隔线。
            // 窗口 frame 不动：抽屉展开纯视图内布局（聊天流自动让位收缩），
            // 规避整窗玻璃 + SwiftUI 测量链死锁。
            VStack(spacing: 0) {
                // 抽屉（权限确认 / AI 提问）：从输入卡上沿向上滑入；
                // .id(request.id) 使请求切换时整树重建、面板内 @State 天然重置。
                if let request = interaction.request {
                    AIChatDrawerPanel(request: request)
                        .id(request.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    // 衔接处极淡分隔（0.5pt，水平内收与抽屉内容边距一致）
                    Rectangle()
                        .fill(Theme.Colors.cardStroke)
                        .frame(height: Theme.Layout.dividerHeight)
                        .padding(.horizontal, Theme.Spacing.section)
                        .transition(.opacity)
                }

                inputCardContent
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
            // 激活态 rim：坞体激活（悬停/输入/附件/生成中/抽屉在场）且窗口 key 时叠加
            // accent 低透明度环，材质对状态有响应；安静态零描边。
            // allowsHitTesting(false) 防描边层吞掉坞内控件点击
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
            // 抽屉展开/收起动画：0.25s easeOut 滑入滑出（本特性私有节拍，令牌见
            // AIChatDrawerPanel.swift 头注）；尾部留白经 dockTotalHeight 实测自动跟随抽屉顶。
            .animation(.easeOut(duration: AIChatDrawerMetrics.slideDuration), value: interaction.request?.id)
        }
        // 浮岛坞与消息列同限宽、同居中；快捷键提示条已删（提示由各控件 .help() tooltip 承担，
        // 清空会话入口移入 ⊕ 菜单），坞体即输入区全部。
        // 顶部零 padding：真穿透后坞顶上方无任何过渡带，内容直接滚到玻璃坞下；
        // 底部 12pt 为坞与窗缘的呼吸缝
        .padding(.bottom, Theme.Spacing.xxl)
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

    /// 输入卡内容（连续玻璃体的下半部分）：文本区 + 底部工具行
    /// （⊕ 附件 / 模型 chip / 思考 chip ║ 低频工具组 / 发送）；安静/激活两态语义见 dockQuiet。
    /// 玻璃面/描边/阴影由外层连续体容器统一施加，本视图只排版内容。
    private var inputCardContent: some View {
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
                // 悬停/输入/附件/生成中淡入；两类破格常显：水位 >0.8（警戒亮弧语义在
                // 组件内）+ 压缩进行中（spinner 必须可见，见 showDockSecondaryTools）
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
