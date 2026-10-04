import AppKit
import Combine
import SwiftUI

/// AI 对话视图（Lane C）：将嵌入 NSHostingView，由 AIWindowManager 管理外窗尺寸与焦点。
/// 视觉常量全部走 DesignTokens 令牌（AI 专用令牌集中在 DesignTokens 的 chatXxx 区，本文件不硬编码）。
///
/// Wave 3 结构（2026-10 视觉质感专项）：
/// - 左侧会话窄栏（⌘B 显隐，展开时窗口整体加宽，见 AIWindowManager.setSidebarVisible）
/// - 消息列表铺满窗口主体：AI 回复无气泡铺底排版；落定助手消息下方常驻弱显示操作行（复制/重新生成）
/// - 输入坞浮岛化：overlay 悬浮于消息列表之上，消息滚动时从玻璃坞底下穿过（真 blur-through，
///   Liquid Glass 采样到真实内容流后折射/高光/自适应明度自动成立，不再有 fade 遮罩）
/// - 整窗方向性 rim light（顶亮侧弱底微）+ 输入坞双层阴影 + 激活态 accent rim（安静态零描边）
/// - 输入坞安静/激活渐进披露：安静态（无草稿/未悬停）收敛为纯输入行，低频工具（剪贴板/
///   水位/压缩）隐去；控件语言为纯灰图标 + hover 圆底（图钉同款克制），chip 为弱化小字，
///   发送钮仅在可发送瞬间实心强调色（空态 = 无底灰箭头）——空态视觉重心让回中部引导区
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
    /// 剪贴板是否有可用文本（控制剪贴板按钮弱化不可点）。
    @State private var hasClipboardText = false
    /// 剪贴板是否有可用图片（控制 ⊕ 菜单「剪贴板导入」可用态）。
    @State private var hasClipboardImage = false
    /// AI 窗滚轮监听（窗口级；意图经 SessionScrollRelay 路由到当前活跃会话视图）。
    @State private var scrollWheelMonitor = AIChatScrollWheelMonitor()
    /// 活跃会话滚轮意图中继：窗口级滚轮监听只有一个，需路由到「当前活跃会话视图」的
    /// 跟随状态。class 引用稳定，避免 @State 闭包在事件回调中的捕获时序与兄弟视图注册竞态。
    @State private var scrollRelay = SessionScrollRelay()
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
    /// 立即压缩入口 hover 态。
    @State private var compactHovered = false
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
            scrollWheelMonitor.remove()
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
                    if !configured && activeSessionMessagesEmpty {
                        UnconfiguredGuideView(onOpenSettings: onOpenSettings)
                            .padding(.bottom, Theme.Layout.chatDockClearance)
                    } else if activeSessionMessagesEmpty {
                        WelcomeView(
                            hasClipboardText: hasClipboardText,
                            onAttachClipboard: { attachClipboard() }
                        )
                        .padding(.bottom, Theme.Layout.chatDockClearance)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 输入坞浮岛化：overlay 悬浮于消息列表之上（不再与列表上下拼接）。
        // 消息滚动时从坞的玻璃底下穿过——glassEffect 采样到真实内容流，
        // 折射/高光/自适应明度自动成立（glass-on-glass 退化为塑料块的根因即采样不到内容）。
        // 列表底部留白（chatDockClearance）保证滚到底时末条消息完整露出坞顶。
        .overlay(alignment: .bottom) {
            inputArea
        }
        // 导出成功轻反馈：输入坞上方浮出胶囊（复用 toast 令牌语言），1.6s 自动淡出
        .overlay(alignment: .bottom) {
            if exportToastVisible {
                Text("已复制对话 Markdown")
                    .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .padding(.horizontal, Theme.Spacing.card)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(Capsule(style: .continuous).fill(Theme.Colors.toastFill))
                    .overlay(Capsule(style: .continuous).stroke(Theme.Colors.toastStroke, lineWidth: 0.5))
                    .padding(.bottom, Theme.Layout.chatDockClearance + Theme.Spacing.lg)
                    .transition(.opacity.combined(with: .scale(scale: Theme.Motion.toastScale)))
            }
        }
        // 全窗材质两级收敛：根部 ultraThinMaterial 是唯一内容基面（铺满主列与阅读区），
        // 输入坞 glass 是唯一浮层语言；此处不再叠第二层材质，全窗亮度关系唯一且自洽。
    }

    // MARK: - 顶部拖动条（移动窗口 + 图钉）

    /// 顶部拖动条：真实占位高 28pt 全宽，左段为可拖动区域，右端图钉按钮消费点击。
    private var windowTopBar: some View {
        HStack(spacing: 0) {
            WindowDragHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            pinButton
                .padding(.trailing, Theme.Spacing.xxl)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        // 纯透明热区：不铺 glass/底色/描边——顶栏只承担拖动与图钉命中功能，
        // 根部内容材质一铺到窗口圆角，恢复重构前的一体观感（告别独立「帽子」横带）。
        // 28pt 高度与 WindowDragHandle 命中区完整保留，拖动/吸附功能不受影响。
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
                    scrollRelay: scrollRelay
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

    private var inputArea: some View {
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
                        onInsertImages: { images in insertImages(images) }
                    )
                    // 双通道与：草稿恢复期 inputEmpty 滞后为 true（@State 初值、首帧无变化事件），
                    // state.inputText 非空即有文字，placeholder 不显示——防重影（见 inputEmpty 声明处注释）。
                    if inputEmpty && state.inputText.isEmpty {
                        Text(inputPlaceholder)
                            .font(Theme.Typography.text(13))
                            .foregroundColor(Theme.Colors.idleText)
                            // 与 textContainerInset 同步：光标距卡边 18pt（旧 12pt 太贴边）
                            .padding(.horizontal, Theme.Spacing.section)
                            .padding(.vertical, Theme.Spacing.xl)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 56)

                HStack(spacing: Theme.Spacing.lg) {
                    attachMenuButton
                    modelChip
                    thinkingChip
                    Spacer(minLength: 0)
                    // 低频工具组（压缩/水位/剪贴板）：安静态整体隐去——保留占位、纯透明度
                    // 渐变、布局零跳动；悬停/输入/附件/生成中淡入，水位 >0.8 破格常显
                    HStack(spacing: Theme.Spacing.lg) {
                        compactButton
                        contextWatermarkIndicator
                        clipboardButton
                    }
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
        }
        // 浮岛坞与消息列同限宽、同居中；快捷键提示条已删（提示由各控件 .help() tooltip 承担，
        // 清空会话入口移入 ⊕ 菜单），坞体即输入区全部
        .padding(.top, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.xxl)
        .chatReadingColumn()
        // 坞区 hover：进入时刷新剪贴板可用态（覆盖"先复制、后移动鼠标到窗口"的常见路径），
        // 同时驱动坞体安静→激活切换（低频工具组淡入、accent rim 点亮）
        .onHover { hovering in
            if hovering { refreshClipboardAvailability() }
            dockHovered = hovering
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

    /// 立即压缩入口：水位左侧的轻量图标钮，pinButton 同款克制语言——静态纯灰图标无底，
    /// hover 才出圆底提亮（比剪贴板/发送的常驻实底轻一档，与水位的「态势感知」同级）。
    /// 仅在有上下文数据（水位非 nil）时出现，与水位同生共死，右缘布局不插拔跳动；
    /// 并随水位一同归入低频工具组：安静态整体隐去（见 showDockSecondaryTools）；
    /// 压缩中禁用弱化（对齐剪贴板禁用态），不换成旋转/进度轮——克制优先。
    @ViewBuilder
    private var compactButton: some View {
        if state.contextWatermark != nil {
            Button {
                state.compactNow()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(Theme.Typography.text(13, .medium))
                    .foregroundColor(state.isCompacting
                                     ? Theme.Colors.idleText.opacity(0.5)
                                     : (compactHovered ? Theme.Colors.iconHover : Theme.Colors.iconRest))
                    .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
                    .background(
                        Circle().fill(compactHovered && !state.isCompacting
                                      ? Theme.Colors.iconHoverBg : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.isCompacting)
            .onHover { hovering in
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { compactHovered = hovering }
            }
            .help(state.isCompacting ? "正在压缩早期对话…" : "压缩早期对话（释放上下文）")
        }
    }

    /// 上下文水位指示：右缘紧凑数字（已用 / 窗口，自适应 k/M 单位）+ 无底衬微光细条
    /// （与一瞥倒计时同「光丝」语言，2.5pt）。nil 时完全隐藏不占位；
    /// 安静态随低频工具组整体隐去，唯 ratio > 0.8 破格常显——需要警示的时刻不沉默；
    /// 警示仍只交给那根线（细条进红），数字恒保持灰调，不喊。
    @ViewBuilder
    private var contextWatermarkIndicator: some View {
        if let watermark = state.contextWatermark {
            let label = "\(formatTokenCount(watermark.usedTokens)) / \(formatTokenCount(watermark.windowTokens))"
            VStack(spacing: Theme.Spacing.xxs) {
                watermarkText(label)
                // 细条宽锚定上方数字宽：hidden 文本占位撑出同宽，overlay 内按 ratio 填充；
                // 无底衬轨道（去掉多余淡胶囊底衬），只剩已用段光丝——0 用量时细条归零不露面
                watermarkText(label)
                    .hidden()
                    .overlay {
                        GeometryReader { geo in
                            Capsule(style: .continuous)
                                .fill(watermark.ratio > 0.8 ? Theme.Colors.statusWarning : Theme.Colors.idleText)
                                .frame(width: geo.size.width * min(max(watermark.ratio, 0), 1))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(height: Theme.Layout.glanceProgressHeight)
            }
            .fixedSize()
            .help("上下文用量（已用 tokens / 窗口上限）")
        }
    }

    /// 水位数字样式：SF Mono 10pt 三级灰（纯数字走 mono，与全项目字体族策略一致）。
    private func watermarkText(_ text: String) -> Text {
        Text(text)
            .font(Theme.Typography.mono(10))
            .foregroundColor(Theme.Colors.contentTertiary)
    }

    /// token 数紧凑格式化：<1k 原样；≥1k 用 k、≥1M 用 M，整倍去小数（512k），否则一位小数（12.3k）。
    private func formatTokenCount(_ count: Int) -> String {
        if count < 1_000 { return "\(count)" }
        if count < 1_000_000 {
            let k = Double(count) / 1_000
            return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        let m = Double(count) / 1_000_000
        return m.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(m))M" : String(format: "%.1fM", m)
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

        // 滚轮意图监听：窗口级只此一份，经 SessionScrollRelay 路由到当前活跃会话视图的
        // 跟随状态（活跃会话在 isActive 变化时注册/注销自己的处理闭包）。
        scrollWheelMonitor.onUserScroll = { scrollingUp in
            scrollRelay.relay(scrollingUp: scrollingUp)
        }
        scrollWheelMonitor.install()
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

// MARK: - AI 窗滚轮意图监听

/// AI 窗滚轮监听：不消费事件，只把「用户在滚」的意图透传给视图层（时间戳 + 方向）。
/// 用途：底部哨兵消失时区分「用户上滚离开」（解除跟随）与「流式内容增长顶出」（保持跟随）。
/// macOS 13 无 ScrollView 滚动相位 API，滚轮/触控板滚动统一走 NSEvent.scrollWheel 本地监听。
/// scrollingDeltaY 已按用户意图归一化（天然/传统方向一致）：> 0 = 向内容顶部滚。
/// 非隔离类：本地监听恒在主线程事件派发路径触发，回调直接执行，无跨隔离域开销。
final class AIChatScrollWheelMonitor {
    private var monitor: Any?

    /// 用户滚动回调；参数 scrollingUp = 是否朝内容顶部方向滚。
    var onUserScroll: (_ scrollingUp: Bool) -> Void = { _ in }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // 只关心 AI 对话窗内的滚动（设置窗等其他窗口不记时间戳）
            if event.window is AIPanel {
                self?.onUserScroll(event.scrollingDeltaY > 0)
            }
            return event
        }
    }

    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
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

// MARK: - 底部锚点几何信号

/// 底部锚点在滚动视口坐标系中的底边 Y（`frame(in: .named(<该实例坐标空间>)).maxY`）。
/// 每个 `SessionMessageList` 在自己的子树内消费该 preference（`onPreferenceChange` 挂在
/// 该实例的 ScrollView 上），且坐标系名称按 sessionId 隔离，多个常驻实例互不串扰。
private struct BottomAnchorYKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // 单实例内只有尾部锚点一处发射；取最新值即可。
        value = nextValue()
    }
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

// MARK: - 活跃会话滚轮意图中继

/// 窗口级滚轮监听只有一个，需路由到「当前活跃会话视图」的跟随状态。
/// class 引用稳定：避免 @State 闭包在事件回调中的捕获时序问题，也避免兄弟会话
/// 在 isActive 切换时互相覆盖处理闭包（用 activeSessionId 归属校验）。
@MainActor
private final class SessionScrollRelay {
    private(set) var activeSessionId: UUID?
    private var handler: ((Bool) -> Void)?

    /// AppKit 滚动桥：按会话持有底层 NSScrollView 弱引用（跳底直滚用，见 NSScrollBridgeView）。
    private struct WeakScrollViewBox { weak var view: NSScrollView? }
    private var scrollBridges: [UUID: WeakScrollViewBox] = [:]

    func attachScrollView(sessionId: UUID, scrollView: NSScrollView) {
        scrollBridges[sessionId] = WeakScrollViewBox(view: scrollView)
    }
    func scrollView(for sessionId: UUID) -> NSScrollView? {
        scrollBridges[sessionId]?.view
    }

    func register(sessionId: UUID, handler: @escaping (Bool) -> Void) {
        activeSessionId = sessionId
        self.handler = handler
    }

    /// 仅当注销者正是当前注册者时才清除（防旧会话的 onChange(false) 误清新会话的注册）。
    func unregister(sessionId: UUID) {
        guard activeSessionId == sessionId else { return }
        activeSessionId = nil
        handler = nil
    }

    func relay(scrollingUp: Bool) { handler?(scrollingUp) }
}

/// AppKit 桥：零尺寸 NSView 挂在 ScrollView **内容树内部**（必须在内——挂在 ScrollView
/// 外层时是兄弟节点，enclosingScrollView 解析不到）。捕获本会话底层 NSScrollView 存入
/// relay，供跳底直滚；视图若被 SwiftUI 重建，updateNSView 会用 !== 检测并重挂。
private struct NSScrollBridgeView: NSViewRepresentable {
    let sessionId: UUID
    let relay: SessionScrollRelay
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let sv = nsView.enclosingScrollView, relay.scrollView(for: sessionId) !== sv {
                relay.attachScrollView(sessionId: sessionId, scrollView: sv)
            }
        }
    }
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
    let scrollRelay: SessionScrollRelay

    private let bottomAnchorID = "aiChat.bottom"

    /// 本会话首载装载态：冷启动与 LRU 重挂载时抑制入场动画，防窗口上屏竞态白屏。
    @State private var isInitialHistoryLoad = true
    /// 贴底跟随态（pinned）：true = 自动跟随最新内容，false = 用户自由浏览。
    /// 用户滚动主权最高——一旦 unpinned，任何事件（切换/新消息/流式/渐进扩展）都不自动滚动，
    /// 直到用户主动回底（容差哨兵重新可见）。
    @State private var isPinned = true
    /// 本会话流式滚动节流时间戳。
    @State private var lastAutoScrollAt: Date = .distantPast
    /// 本会话最近一次用户滚轮时间戳（判定「哨兵消失是否由用户滚动驱动」）。
    @State private var lastUserScrollAt: Date = .distantPast
    /// 是否处于底部容差区（几何感知层驱动：锚点底边距视口底 ≤ bottomTolerance）。
    @State private var atBottom = true
    /// 真实视口顶部消息 id（由行级几何信号驱动，替代不可靠的 visibleMessageIDs）：
/// 切走时作为恢复锚点，浮动簇 ↑/↓ 导航也据此定位。
    @State private var topVisibleMessageID: UUID?
    /// 消息分组缓存（messages 未变则复用上次分组；见 MessageGroupingCache）。
    @State private var groupingCache = MessageGroupingCache()
    /// 用户滚轮短窗：用于「即时脱锚加速」与自动跟随的让位守卫（不再是脱锚的唯一证据）。
    private let userScrollWindow: TimeInterval = 0.5
    /// 内容增长窗口：仅在此窗口内确有增长事件（新消息/流式增量/渐进批次）时，
    /// 哨兵消失才保持 pinned；否则一律默认脱锚（覆盖滚动条拖拽/键盘等无滚轮事件的滚动方式）。
    private let contentGrowthWindow: TimeInterval = 0.4
    /// 底部容差区高度（pt）：容差哨兵嵌在原有坞区留白内部，置于真正底部上方此距离，
    /// 不额外叠加底部空隙（防弹性抖动误判只需 ~16-20pt）。
    private let bottomTolerance: CGFloat = 18
    /// 最近一次内容增长时间戳（messages.count 变化 / 流式消息更新 / 几何纠偏期间）。
    /// 初始为当前时间：让挂载/重挂载首帧的几何 settling（锚点尚在下方）不被误判为用户脱锚。
    @State private var lastContentGrowthAt: Date = Date()

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
                // 三级间距节奏与原单会话一致
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.chatGroupGap) {
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
                                ChatMessageRow(
                                    message: message,
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
                                // 行级几何信号：上报本行在滚动视口坐标系的 frame，供父级算出
                                // 真实「视口首个可见消息」。preference 每帧全量重算，诚实地反映
                                // 当前已实现行集合（修复行级 onAppear/onDisappear 只增不减导致的置顶）。
                                .background(
                                    GeometryReader { rowGeo in
                                        Color.clear.preference(
                                            key: MessageRowFramePreference.self,
                                            value: [message.id: rowGeo.frame(in: .named(scrollSpaceName))]
                                        )
                                    }
                                )
                                .id(message.id)
                                .transition(isInitialHistoryLoad
                                    ? .identity
                                    : .opacity.combined(with: .offset(y: Theme.Motion.messageArriveOffset)))
                            }
                        }
                    }
                    // 尾部整体作为 LazyVStack 的单个子视图：把原先 4 个尾部子项的 4×36pt 组间距收敛为
                    // 1 个，其余 3×36 的叠加被消除。
                    //
                    // 间距算术（实测坐实 LazyVStack 组间距对尾部子项生效）：本子视图与「末条消息组」
                    // 之间仍有 1×chatGroupGap(36)。为让「末条消息 → 视口底」回到重构前 124pt 量级，
                    // 坞区留白扣掉该 36 与内嵌容差：36 + (124−18−36) + 18 + 1 = 125pt。
                    VStack(spacing: 0) {
                        // 坞区留白（有效值 = 组间距 36 + 此 spacer + 容差 18 ≈ 124）
                        Color.clear
                            .frame(height: max(Theme.Layout.chatDockClearance - bottomTolerance - Theme.Spacing.chatGroupGap, 0))
                        // 容差带（18pt，嵌入坞区留白内部）
                        Color.clear
                            .frame(height: bottomTolerance)
                        // 底部锚点 + 几何读数：底边相对本实例滚动视口的 maxY。
                        // 替代不可靠的 onAppear/onDisappear 哨兵，作为 atBottom 的唯一信号源。
                        GeometryReader { anchorGeo in
                            Color.clear.preference(
                                key: BottomAnchorYKey.self,
                                value: anchorGeo.frame(in: .named(scrollSpaceName)).maxY
                            )
                        }
                        .frame(height: 1)
                        .id(bottomAnchorID)
                    }
                }
                .animation(isInitialHistoryLoad ? nil : .easeOut(duration: Theme.Motion.contentFade),
                           value: messages.count)
                .padding(.top, Theme.Spacing.section)
                .chatReadingColumn()
                // AppKit 滚动桥：必须挂在 ScrollView 内容闭包内部（此处是内容根视图），
                // 才能经 enclosingScrollView 解析到本会话底层 NSScrollView（见 NSScrollBridgeView）。
                .background(NSScrollBridgeView(sessionId: sessionId, relay: scrollRelay))
            }
            .coordinateSpace(name: scrollSpaceName)
            // 首帧视口自适应：把视口高度注入环境，供消息内 AssistantMarkdownView 估算「一屏块数」。
            .environment(\.chatViewportHeight, viewport.size.height)
            // 几何信号 → atBottom：底部锚点在视口中的底边 maxY 减去视口高度即「距底溢出」，
            // ≤ 容差（18pt）判定在底部。onPreferenceChange 仅在数值变化时触发；状态只在
            // atBottom 布尔跳变时写入，避免每帧 setState 风暴。
            .onPreferenceChange(BottomAnchorYKey.self) { anchorY in
                handleGeometry(anchorY, viewportHeight: viewport.size.height, proxy: proxy)
            }
            // 行级几何 → 真实视口顶部消息：每帧全量上报已实现行 frame，算出与视口相交且
            // minY 最靠上（最贴近视口顶）的行；仅在结果变化时写状态（去抖，避免每帧 setState）。
            .onPreferenceChange(MessageRowFramePreference.self) { frames in
                updateRowFrames(frames, viewportHeight: viewport.size.height)
            }
            .onAppear {
                registerRelayIfActive()
                // 首帧布局完成后的下一 runloop：恢复位置（snapshot 锚点 / 贴底）+ 解除装载态。
                // 解除装载态走显式空动画事务（历史白屏防线，勿动）。此路径仅在
                // 挂载 / LRU 重挂载时执行；常驻切回不再联动 restoreScroll（见 onChange(isActive)）。
                DispatchQueue.main.async {
                    restoreScroll(proxy)
                    withAnimation(nil) { isInitialHistoryLoad = false }
                }
            }
            // 卸载兜底保存快照：覆盖「同 runloop 连续切换、中间会话以 isActive=false 首次建树
            // 导致 onChange(of: isActive) 不触发、无快照」的反例（LRU 驱逐后重挂载会被强制贴底）。
            // 正常失活（非卸载）由 onChange(isActive=false) 保存；saveSnapshot 幂等，重复无害。
            .onDisappear { saveSnapshot() }
            // 消息数变化：同时记录内容增长事件。
            // 用户发送 → 无条件跳底并恢复跟随（pinned）：即便此前用户上滚解除了跟随，
            // 自己发出的消息也必须回到最新；其余情况（AI 流式/助手占位追加）仍走原 pinned 跟随规则。
            .onChange(of: messages.count) { _ in
                lastContentGrowthAt = Date()
                if isActive, messages.last?.role == .user {
                    isPinned = true
                    scrollToBottom(proxy, animated: true)
                    return
                }
                guard isActive, isPinned else { return }
                scrollToBottom(proxy, animated: true)
            }
            // 用户发送 → 无条件跳底并恢复跟随：监听 AIChatState 的跳底事件信号（见其注释），
            // 不依赖消息数组 diff（send() 同帧连续 append 用户消息与助手占位，合并帧下 role 判定失效）。
            // onChange 值类型为 Date?（字典下标返回可选，Equatable 合法）；值未变化不触发，
            // LRU 重挂载时字典里的旧时间戳与当前值相等，不会误触发跳底，既有 restoreScroll 逻辑不受影响。
            .onChange(of: state.scrollJumpRequests[sessionId]) { _ in
                guard isActive else { return }
                lastContentGrowthAt = Date()   // 延长 growth 窗口，防 handleGeometry 把 isPinned 翻回 false
                isPinned = true
                scrollToBottom(proxy, animated: true)
                // 保险补滚：信号触发时新插入行可能尚未完成布局，下一 runloop 布局落定后再无动画贴底一次。
                DispatchQueue.main.async {
                    if isActive, isPinned { scrollToBottom(proxy, animated: false) }
                }
            }
            // 流式/工具/思考增量：以整条 last 消息为增长信号，仅 pinned + 生成中 + 用户未滚动
            // 时跟随；节流 0.12s 非动画。
            .onChange(of: messages.last) { _ in
                lastContentGrowthAt = Date()
                guard isActive, isStreamingSession, isPinned, !recentlyUserScrolled else { return }
                let now = Date()
                guard now.timeIntervalSince(lastAutoScrollAt) > 0.12 else { return }
                lastAutoScrollAt = now
                scrollToBottom(proxy, animated: false)
            }
            // 流式结束：pinned 时补一次动画贴底。
            .onChange(of: isStreamingSession) { streaming in
                if !streaming, isActive, isPinned { scrollToBottom(proxy, animated: true) }
            }
            // 活跃态切换：只注册/注销滚轮中继，**不做任何 restoreScroll**。
            // 常驻视图的 NSScrollView 偏移天然保留；激活时无条件 restoreScroll 是唯一破坏源
            // （会把用户强制拉走）。位置恢复只发生在挂载/LRU 重挂载的 onAppear。
            // pinned 会话若在隐藏期间增长，几何纠偏会在其自身菜单内保持贴底（见 handleGeometry）。
            .onChange(of: isActive) { active in
                if active {
                    registerRelayIfActive()
                } else {
                    saveSnapshot()
                    scrollRelay.unregister(sessionId: sessionId)
                }
            }
            // 浮动导航簇：unpinned 且活跃时于内容区右下角浮现，0.15s 淡入淡出。
            .overlay(alignment: .bottom) {
                if !isPinned, isActive {
                    navClusterOverlay(proxy)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isPinned)
        }
        }
    }

    // MARK: - 滚轮路由

    private func registerRelayIfActive() {
        guard isActive else { return }
        scrollRelay.register(sessionId: sessionId) { scrollingUp in
            handleUserScrollIntent(scrollingUp)
        }
    }

    /// 用户滚轮意图：记录时间戳；已离开底部容差区时向上滚动即时脱锚（消除一次回拽）。
    private func handleUserScrollIntent(_ scrollingUp: Bool) {
        lastUserScrollAt = Date()
        if scrollingUp, !atBottom {
            isPinned = false
        }
    }

    // MARK: - 快照

    /// 切走时保存：真实视口顶部消息 id（几何信号维护）+ 当前 pinned 态。
    /// 防御：无锚点时保留上一份有效锚点，避免 restoreScroll 因 topID=nil 退回贴底。
    private func saveSnapshot() {
        // 诚实锚点：由行级几何信号维护的真实视口顶部消息；无则保留上一份有效锚点。
        let previousAnchor = scrollSnapshots[sessionId]?.topVisibleMessageID
        scrollSnapshots[sessionId] = ScrollSnapshot(
            topVisibleMessageID: topVisibleMessageID ?? previousAnchor,
            isPinned: isPinned
        )
    }

    /// 行级几何 → 真实视口顶部消息：取与视口相交（maxY>0 且 minY<viewportHeight）且 minY
    /// 最小（最贴近/高于视口顶）的行；无相交行（极端：视口落在尾部留白内）时退化为最靠近
    /// 视口顶的行（maxY 最大者）。仅在结果变化时写 @State（去抖）。
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
    }

    /// 挂载（首次 / LRU 重挂载）时恢复（唯一调用点：ScrollView.onAppear）：
    /// - 有非贴底快照且锚点仍在 → 无动画定位到锚点顶部，保持阅读位置；
    /// - 否则 → 无动画贴底并恢复跟随（含「离开时贴底」与「首次打开无快照」）。
    private func restoreScroll(_ proxy: ScrollViewProxy) {
        // 标记为一次「内容settling」：让首帧几何信号（锚点仍在下方）不误判为用户脱锚。
        lastContentGrowthAt = Date()
        if let snapshot = scrollSnapshots[sessionId],
           !snapshot.isPinned,
           let topID = snapshot.topVisibleMessageID,
           messages.contains(where: { $0.id == topID }) {
            isPinned = false
            proxy.scrollTo(topID, anchor: .top)
        } else {
            isPinned = true
            scrollToBottom(proxy, animated: false)
        }
    }

    /// 用户滚轮短窗内视为「正在滚动」：任何自动跟随都应让位（用户主权优先）。
    private var recentlyUserScrolled: Bool {
        Date().timeIntervalSince(lastUserScrollAt) < userScrollWindow
    }

    /// 本实例的滚动坐标空间名：按 sessionId 隔离，多个常驻会话并存时不互相污染。
    private var scrollSpaceName: String { "chatScroll.\(sessionId.uuidString)" }

    /// 几何感知层核心（替代不可靠的 onAppear/onDisappear 哨兵）：
    /// - 溢距 `overflow = anchorBottomY - viewportHeight`：>0 表示锚点在视口下方（已上滚）；
    ///   内容短于视口时为负 → 天然判定在底部。
    /// - `atBottom = overflow ≤ 容差`；仅在布尔跳变时写状态（去抖，避免每帧 setState 风暴）。
    /// - atBottom→true：重新贴底跟随；atBottom→false：内容增长（0.4s 内）且 pinned 且
    ///   用户未滚动 → 保持 pinned；其余（含滚动条/键盘等无滚轮事件的滚动）→ 脱锚。
    /// - 持续纠偏：pinned 且 overflow>容差且用户未滚动 → 非动画贴底；布局静止后 overflow
    ///   落入容差内自然停止（scrollTo 到最大偏移不过冲，故不振荡、不死循环）。
    private func handleGeometry(_ anchorBottomY: CGFloat, viewportHeight: CGFloat, proxy: ScrollViewProxy) {
        guard anchorBottomY != .greatestFiniteMagnitude, viewportHeight > 0 else { return }
        let overflow = anchorBottomY - viewportHeight
        let nowAtBottom = overflow <= bottomTolerance
        if nowAtBottom != atBottom {
            atBottom = nowAtBottom
            if nowAtBottom {
                isPinned = true
            } else {
                let growthRecent = Date().timeIntervalSince(lastContentGrowthAt) < contentGrowthWindow
                if !(growthRecent && isPinned && !recentlyUserScrolled) {
                    isPinned = false
                }
            }
        }
        // 持续纠偏（Fix 3）：初始装载期间让位给 restoreScroll，避免与锚点恢复竞争。
        if !isInitialHistoryLoad, isPinned, !recentlyUserScrolled, overflow > bottomTolerance {
            // 内容增长把锚点推走：刷新增长时间戳（豁免下一帧离底判定）并非动画重申贴底。
            lastContentGrowthAt = Date()
            scrollToBottom(proxy, animated: false)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        // AppKit 直滚：SwiftUI proxy.scrollTo 对 LazyVStack 尾部锚点不可靠（视口远离底部时
        // 锚点未实例化/新行布局竞态，scrollTo 无声失败）；用户滚轮本就直达此 NSScrollView，
        // 程序化设置 clip view 偏移与滚轮同路径，零竞态。
        if let sv = scrollRelay.scrollView(for: sessionId), let doc = sv.contentView.documentView {
            let bottomY = doc.isFlipped
                ? max(0, doc.bounds.height - sv.contentView.bounds.height)
                : 0
            let target = NSPoint(x: 0, y: bottomY)
            if animated {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    sv.contentView.animator().setBoundsOrigin(target)
                })
            } else {
                sv.contentView.scroll(to: target)
                sv.reflectScrolledClipView(sv.contentView)
            }
            return
        }
        // 桥未就绪回退（旧实现保留）
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(bottomAnchorID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    // MARK: - 浮动导航簇（unpinned 时的回底/用户消息跳转）

    // topVisibleMessageID 现为 @State，由行级几何信号（updateRowFrames）维护，见上方声明。

    /// 视口锚点之前的最后一条 user 消息（「上一条用户消息」目标）。
    private var previousUserMessageID: UUID? {
        guard let anchor = topVisibleMessageID,
              let index = messages.firstIndex(where: { $0.id == anchor }) else { return nil }
        return messages[..<index].last { $0.role == .user }?.id
    }

    /// 视口锚点之后的第一条 user 消息（「下一条用户消息」目标）。
    private var nextUserMessageID: UUID? {
        guard let anchor = topVisibleMessageID,
              let index = messages.firstIndex(where: { $0.id == anchor }) else { return nil }
        let start = messages.index(after: index)
        guard start < messages.endIndex else { return nil }
        return messages[start...].first { $0.role == .user }?.id
    }

    /// 浮动簇容器：右下角对齐到内容列右缘、浮于输入坞上方（同输入坞限宽/居中）。
    @ViewBuilder
    private func navClusterOverlay(_ proxy: ScrollViewProxy) -> some View {
        let previousID = previousUserMessageID
        let nextID = nextUserMessageID
        MessageNavCluster(
            canGoPrevious: previousID != nil,
            canGoNext: nextID != nil,
            onLatest: {
                isPinned = true
                scrollToBottom(proxy, animated: true)
            },
            onPrevious: {
                guard let previousID else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(previousID, anchor: .top) }
            },
            onNext: {
                guard let nextID else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(nextID, anchor: .top) }
            }
        )
        .padding(.bottom, Theme.Layout.chatDockClearance + Theme.Spacing.lg)
        .chatReadingColumn(alignment: .trailing)
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

// MARK: - 浮动导航簇（unpinned 时回底 / 用户消息跳转）

/// 浮动导航簇：半透明底小控件簇，纵排三键——上一条用户消息 / 下一条用户消息 / 跳到最新。
/// 复用现有 surface/stroke/icon 配色，hover 提亮；显示与否由父级 isPinned 控制（贴底淡出）。
private struct MessageNavCluster: View {
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onLatest: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NavClusterButton(systemName: "arrow.up", help: "上一条用户消息",
                             enabled: canGoPrevious, action: onPrevious)
            divider
            NavClusterButton(systemName: "arrow.down", help: "下一条用户消息",
                             enabled: canGoNext, action: onNext)
            divider
            NavClusterButton(systemName: "arrow.down.to.line", help: "跳到最新",
                             enabled: true, action: onLatest)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .fill(Theme.Colors.surfaceTrack)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(Theme.Shadow.dockContactOpacity),
                radius: Theme.Shadow.dockContactRadius,
                y: Theme.Shadow.dockContactY)
        .fixedSize()
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Colors.chatStrokeStrong)
            .frame(height: 0.5)
            .padding(.horizontal, Theme.Spacing.sm)
    }
}

/// 簇内单键：30×30 命中区，hover 叠 iconHoverBg 圆角底（与操作行按钮同语言）；禁用降透明度。
private struct NavClusterButton: View {
    let systemName: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(Theme.Typography.text(12, .medium))
                .foregroundColor(enabled
                                 ? (hovered ? Theme.Colors.iconHover : Theme.Colors.contentSecondaryStrong)
                                 : Theme.Colors.contentTertiary.opacity(0.45))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                        .fill(hovered && enabled ? Theme.Colors.iconHoverBg : Color.clear)
                        .padding(1.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
        .help(help)
    }
}

private struct ChatMessageRow: View, Equatable {
    let message: ChatMessage
    /// 是否为最后一条可重新生成的助手消息（父视图计算，含流式中禁用语义）。
    let canRegenerate: Bool
    /// 是否为会话内最后一条 user 消息且可撤回/编辑（父视图计算，含生成中禁用语义）。
    let canEditLastRound: Bool
    let onRetry: () -> Void
    let onRegenerate: () -> Void
    /// 撤回最后一轮（数据层删除该轮并把文本+图片回填输入框）。
    let onWithdraw: () -> Void
    /// 编辑重发最后一轮（就地编辑确认后回调新文本与图片附件）。
    let onEditResend: (String, [ChatImageAttachment]) -> Void
    let onTapImage: (ChatImageAttachment) -> Void

    /// 仅按内容与可用操作标记判定相等：闭包语义跨渲染一致，忽略其对 diff 的干扰，
    /// 使 .equatable() 能在流式期间跳过未变更行。
    /// 编辑态/对勾态等瞬态 UI 由 @State 承载（存储于视图值之外），不参与相等判定，
    /// 既不被流式冲刷重置，也不会导致无关行重绘。
    static func == (lhs: ChatMessageRow, rhs: ChatMessageRow) -> Bool {
        lhs.message == rhs.message
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
                if message.role == .assistant { Spacer(minLength: Theme.Spacing.panel) }
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
    private var userBubble: some View {
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
        // 胶囊行随 VStack 居中（章节标记语义，同 iMessage 时间戳）；上下补一点呼吸，
        // 使组内插入时上下节奏（xl=10 + xs）与组间章节感平衡
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xs)
    }

    /// 两端羽化的 0.5pt 细边线（窗口分割线同款渐变语言，水平方向）。
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

/// 待注入队列胶囊：类型标签（转向=↪ / 追问=↩ + 中文小字）+ 文本单行截断。
/// 点击整枚胶囊取回编辑（数据层回填输入框，胶囊随队列移除消失）；hover 提亮。
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
        .help(isSteering
              ? "转向：本轮生成中即时注入、修正方向 · 点击取回编辑"
              : "追问：本轮回复完成后自动追加一轮 · 点击取回编辑")
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
        // 内边距与 SwiftUI 占位文案 padding 对齐：左右 18pt（section），光标不再贴卡边
        textView.textContainerInset = NSSize(
            width: Theme.Spacing.section,
            height: Theme.Spacing.xl
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
/// （内容区 <720pt 用 `Spacing.section`=18 即默认窗现状；≥720pt 升为 28，宽窗保留玻璃呼吸边）。
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
