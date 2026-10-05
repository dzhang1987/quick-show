import SwiftUI
import Combine

enum PanelMode: Equatable {
    case hidden
    case glance   // 一瞥：3 秒后自动淡出
    case pinned   // 固定：常驻显示，直到 ESC 或快捷键
}

// 面板上下文（独立功能 = 独立全面板视图，快捷键任意状态直达）
// 新组件接入：① 加 case ② contextHotkeys 注册直达键 ③ targetSize 尺寸映射 ④ PanelView 渲染分支
enum PanelContext: Equatable {
    case glance
    case dashboard
    case calendar

    /// 上下文 → 目标面板尺寸（速查表 overlay 尺寸策略由 PanelManager.targetSize 统一叠加）
    func targetSize(in metrics: PanelLayoutMetrics) -> NSSize {
        switch self {
        case .glance: return metrics.compactSize
        case .dashboard: return metrics.expandedSize
        case .calendar: return metrics.calendarSize
        }
    }
}

// 装配门面：视图层唯一注入对象（19 处 @ObservedObject + $appState Binding 零改动）；状态与管线按域拆入
// 各 store，经 AppState+Forwarding 计算转发、objectWillChange 合并、tick 总线订阅对外保持原契约。
final class AppState: ObservableObject {
    @Published var mode: PanelMode = .hidden
    @Published var isExpanded: Bool = false
    @Published var currentTime: Date = Date()
    @Published var livePanelSize: CGSize = .zero   // 窗口动画逐帧推送，frame 是唯一尺寸时钟

    func updateLivePanelSize(_ size: CGSize) { livePanelSize = size }

    @Published var toastMessage: String? = nil   // Toast 状态留门面，方法在 AppState+Actions
    var toastTimer: Timer?

    @Published var isHovered: Bool = false
    @Published var glanceProgress: CGFloat = 1.0   // 液态微光一瞥进度 (1.0 -> 0.0)
    private var glanceTotalDuration: Double = 3.0
    private var glanceRemainingSeconds: Double = 3.0
    private let glanceTickInterval: Double = 0.04
    private var glanceTimer: Timer?

    @Published var showCheatSheet: Bool = false

    @Published var showCalendarView: Bool = false   // 「当前上下文 == .calendar」的存储载体
    private var contextReturnPoint: PanelContext? = nil   // 进入独立上下文前的来源快照

    /// 当前面板上下文（派生语义：日历 > 看板 > 一瞥）
    var currentContext: PanelContext {
        if showCalendarView { return .calendar }
        return isExpanded ? .dashboard : .glance
    }

    /// 组件直达键注册表：keyCode → 上下文（新组件注册一行即接入「任意状态直达」）
    static let contextHotkeys: [UInt16: PanelContext] = [5: .calendar]   // G: 日历视图

    // MARK: - 面板回调（PanelManager / QuickShowApp 赋值点不动）
    var onTogglePanel: ((PanelMode) -> Void)?
    var onDismissPanel: (() -> Void)?
    var onExpansionChange: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onMenuBarIconVisibilityChange: ((Bool) -> Void)?
    var onCheatSheetChange: ((Bool) -> Void)?
    var onLayoutChange: (() -> Void)?

    // MARK: - 域 store（门面强持，store 弱回指门面）
    let settings: SettingsStore
    let status: SystemStatusStore
    let monitoring: MonitoringStore
    let media: MediaStore
    let pomodoro: PomodoroStore
    let calendar: CalendarStore

    let tickEngine = TickEngine()
    private var cancellables = Set<AnyCancellable>()

    init() {
        let settingsStore = SettingsStore()
        let mediaStore = MediaStore()
        let statusStore = SystemStatusStore()
        let monitoringStore = MonitoringStore()
        let pomodoroStore = PomodoroStore()
        let calendarStore = CalendarStore()
        self.settings = settingsStore
        self.status = statusStore
        self.monitoring = monitoringStore
        self.media = mediaStore
        self.pomodoro = pomodoroStore
        self.calendar = calendarStore

        Theme.variant = themeVariant   // 首帧即用持久化主题

        // 保序（对齐原 init）：Now Playing 桥接 → CoreAudio 属性监听
        mediaStore.configure(facade: self)
        statusStore.configure(facade: self)

        // objectWillChange 合并：任一 store 变化 → 门面统一转发（漏一个 = 该域视图静默不刷新）
        settingsStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        statusStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        monitoringStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        mediaStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        pomodoroStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        calendarStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        // tick 订阅顺序固定 = 原分发顺序（facade.currentTime → pomodoro → monitoring → status → calendar）
        tickEngine.publisher
            .sink { [weak self] tick in self?.currentTime = tick.date }
            .store(in: &cancellables)
        pomodoroStore.attach(tick: tickEngine.publisher, facade: self)
        monitoringStore.attach(tick: tickEngine.publisher, facade: self)
        statusStore.attach(tick: tickEngine.publisher, facade: self)
        calendarStore.attach(tick: tickEngine.publisher, facade: self)

        statusStore.refreshAll()   // 最后刷新全部系统状态（对齐原 init 尾序）
    }

    func currentMetrics(for screen: NSScreen = ScreenHelper.activeScreen) -> PanelLayoutMetrics {
        ScreenHelper.metrics(for: screen, option: panelScaleOption)
    }

    // MARK: - 显示/隐藏生命周期
    /// 响应快捷键触发（纯粹的显示/隐藏全局开关）
    func toggleFromHotKey() {
        switch mode {
        case .hidden: show(mode: .glance)
        case .glance, .pinned: dismiss()
        }
    }

    /// 显示指定模式（顺序逐行保持；startClock 原位替换为 tickEngine.start）
    func show(mode: PanelMode) {
        self.mode = mode
        self.isHovered = false
        currentTime = Date()
        tickEngine.start()

        cancelGlanceTimer()
        if mode == .glance && !isExpanded {
            startGlanceTimer()
        }

        // 窗口先上屏、状态后刷新：refreshAllSystemStatus 内部异步，避免阻塞式系统查询拖慢呼出
        onTogglePanel?(mode)
        refreshAllSystemStatus()
    }

    /// 切换详细展开监控视图
    func toggleExpanded() {
        if showCalendarView { exitContext(); return }   // 日历内按 Tab：切回进入前上下文

        // 状态瞬时切换：面板尺寸动画的唯一时钟是 PanelManager 窗口 setFrame 动画，
        // 此处绝不能再包 withAnimation，否则内容与窗口两套插值时钟打架导致布局抖动
        isExpanded.toggle()
        if isExpanded {
            if mode == .glance { cancelGlanceTimer() }   // 展开则暂停一瞥倒计时
        } else {
            if mode == .glance { startGlanceTimer() }    // 收起则恢复倒计时平滑退场
        }
        onExpansionChange?(isExpanded)
    }

    /// 切换常驻状态 (Space 键 / 图钉按钮)
    func togglePin() {
        if mode == .pinned { unpin() } else { pin() }
    }

    /// 固定面板常驻
    func pin() {
        guard mode != .pinned else { return }
        cancelGlanceTimer()
        mode = .pinned
        onTogglePanel?(.pinned)
    }

    /// 解除常驻，变回一瞥模式（若未展开则恢复倒计时自动淡出）
    func unpin() {
        guard mode == .pinned else { return }
        mode = .glance
        if !isExpanded { startGlanceTimer() }
        onTogglePanel?(.glance)
    }

    /// 关闭/隐藏面板（stopClock 原位替换为 tickEngine.stop；日历清理走 resetOnDismiss）
    func dismiss() {
        cancelGlanceTimer()
        tickEngine.stop()
        mode = .hidden
        isExpanded = false
        isHovered = false
        showCheatSheet = false
        // 日历状态归位：下次呼出回默认看板语义，来源快照清零防脏状态，网格/日程缓存清空
        showCalendarView = false
        calendar.resetOnDismiss()
        contextReturnPoint = nil
        glanceProgress = 1.0
        onDismissPanel?()
    }

    /// 切换快捷键速查表浮层
    func toggleCheatSheet() {
        withAnimation(.easeInOut(duration: Theme.Motion.contentFade)) {
            showCheatSheet.toggle()
        }
        onCheatSheetChange?(showCheatSheet)
        if showCheatSheet {
            cancelGlanceTimer()
        } else if mode == .glance && !isExpanded {
            startGlanceTimer()
        }
    }

    /// 明确设置速查表显示状态（长按 ⌘ 弹出 / 松开淡出）
    func setCheatSheetVisible(_ visible: Bool) {
        guard showCheatSheet != visible else { return }
        withAnimation(.easeInOut(duration: Theme.Motion.contentFade)) {
            showCheatSheet = visible
        }
        onCheatSheetChange?(visible)
        if visible {
            cancelGlanceTimer()
        } else if mode == .glance && !isExpanded {
            startGlanceTimer()
        }
    }

    // MARK: - 上下文统一进入/退出管线（G 直达键与 Tab 的日历退出汇聚于此）
    /// 直达键统一入口：已在该上下文则退出回来源态，否则进入
    func toggleContext(_ context: PanelContext) {
        if currentContext == context { exitContext() } else { enterContext(context) }
    }

    /// 进入独立上下文：记录来源快照 → 激活目标上下文（尺寸动画由 PanelManager 窗口驱动）
    func enterContext(_ context: PanelContext) {
        guard currentContext != context else { return }
        contextReturnPoint = currentContext
        activateContext(context)
    }

    /// 退出独立上下文：恢复来源上下文；来源为一瞥且处于一瞥模式时重启 3 秒淡出倒计时
    func exitContext() {
        let returnPoint = contextReturnPoint ?? .glance
        contextReturnPoint = nil
        activateContext(returnPoint)
        if returnPoint == .glance && mode == .glance { startGlanceTimer() }
    }

    /// 激活目标上下文（状态瞬时切换，严禁包 withAnimation——双插值时钟会打架抖动）
    private func activateContext(_ context: PanelContext) {
        // 日历态瞬态：离开即清理（详情/编辑表单不跨上下文残留）
        calendar.selectedEvent = nil
        calendar.calendarEditing = nil
        switch context {
        case .glance:
            showCalendarView = false
            isExpanded = false
        case .dashboard:
            showCalendarView = false
            isExpanded = true
            cancelGlanceTimer()
        case .calendar:
            // 日历态隐含展开语义；一瞥态直达进入时原 3 秒倒计时必须取消
            showCalendarView = true
            isExpanded = true
            calendar.calendarAnchorDate = Date()
            calendar.selectedDate = Date()
            calendar.refreshCalendarData()
            cancelGlanceTimer()
        }
        onLayoutChange?()
    }

    // MARK: - 一瞥倒计时与液态流体动效
    func setHovered(_ hovering: Bool) {
        isHovered = hovering   // 移入冻结倒计时；移出从当前剩余时间继续流逝（不重置）
    }

    func resetGlanceTimer(duration: Double? = nil) {
        let d = duration ?? max(glanceDuration, 1.0)
        glanceTotalDuration = d
        glanceRemainingSeconds = d
        withAnimation(.linear(duration: Theme.Motion.progressReset)) {
            glanceProgress = 1.0
        }
        if glanceTimer == nil && mode == .glance && !isExpanded {
            startGlanceTimer()
        }
    }

    private func startGlanceTimer() {
        cancelGlanceTimer()
        glanceRemainingSeconds = max(glanceDuration, 1.0)
        glanceTotalDuration = glanceRemainingSeconds
        glanceProgress = 1.0

        glanceTimer = Timer.scheduledTimer(withTimeInterval: glanceTickInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 非一瞥 / 展开 / 悬浮 / Toast 显示中：冻结倒计时并维持微光
                if self.mode != .glance || self.isExpanded || self.isHovered || self.toastMessage != nil {
                    return
                }
                self.glanceRemainingSeconds -= self.glanceTickInterval
                self.glanceProgress = max(0.0, self.glanceRemainingSeconds / self.glanceTotalDuration)
                if self.glanceRemainingSeconds <= 0 {
                    self.cancelGlanceTimer()
                    self.dismiss()
                }
            }
        }
    }

    private func cancelGlanceTimer() {
        glanceTimer?.invalidate()
        glanceTimer = nil
        glanceProgress = 1.0
    }
}