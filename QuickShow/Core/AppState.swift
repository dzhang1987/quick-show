import SwiftUI
import Combine
import EventKit

enum PanelMode: Equatable {
    case hidden
    case glance   // 一瞥模式：3 秒后自动淡出
    case pinned   // 固定模式：常驻显示，直到用户按 ESC 或快捷键
}

// MARK: - 面板上下文（独立功能 = 独立全面板视图，快捷键任意状态直达）
// 新组件接入清单：① 此处加 case ② contextHotkeys 注册直达键 ③ targetSize 尺寸映射 ④ PanelView 渲染分支
enum PanelContext: Equatable {
    case glance     // 一瞥态（大字时钟 + 底栏微标，3 秒自动淡出）
    case dashboard  // 监控看板展开态
    case calendar   // 日历视图
    // 预留未来独立组件：case aiChat / case media ...
    
    /// 上下文 → 目标面板尺寸（速查表 overlay 的尺寸策略由 PanelManager.targetSize 统一叠加）
    func targetSize(in metrics: PanelLayoutMetrics) -> NSSize {
        switch self {
        case .glance: return metrics.compactSize
        case .dashboard: return metrics.expandedSize
        case .calendar: return metrics.calendarSize
        }
    }
}

// MARK: - 日历视图模式（1/2/3 键切换）
enum CalendarViewMode: Int, CaseIterable, Identifiable {
    case month = 1
    case week = 2
    case day = 3
    
    var id: Int { rawValue }
    
    var shortName: String {
        switch self {
        case .month: return "月"
        case .week: return "周"
        case .day: return "日"
        }
    }
}

// 临近会议提醒（<5 分钟时一瞥底栏高亮倒计时胶囊）
struct UpcomingMeetingInfo: Equatable {
    var title: String
    var minutes: Int
}

enum PanelScaleOption: String, CaseIterable, Identifiable {
    case auto = "auto"
    case standard = "standard"
    case compact = "compact"
    case legacy = "legacy"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .auto: return "自动（跟随当前屏幕智能自适应，推荐）"
        case .standard: return "系统聚焦大号（宽 680 pt，红框聚焦标杆）"
        case .compact: return "适中舒适（宽 540 pt）"
        case .legacy: return "极简小巧（宽 440 pt）"
        }
    }
}

// MARK: - 世界时钟城市（时区可配置，rawValue 即 IANA 时区标识符）
enum WorldClockCity: String, CaseIterable, Identifiable {
    case none = "none"
    case beijing = "Asia/Shanghai"
    case tokyo = "Asia/Tokyo"
    case singapore = "Asia/Singapore"
    case london = "Europe/London"
    case paris = "Europe/Paris"
    case berlin = "Europe/Berlin"
    case newYork = "America/New_York"
    case sanFrancisco = "America/Los_Angeles"
    case sydney = "Australia/Sydney"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .none: return "无"
        case .beijing: return "北京"
        case .tokyo: return "东京"
        case .singapore: return "新加坡"
        case .london: return "伦敦"
        case .paris: return "巴黎"
        case .berlin: return "柏林"
        case .newYork: return "纽约"
        case .sanFrancisco: return "旧金山"
        case .sydney: return "悉尼"
        }
    }
    
    var timeZone: TimeZone? { TimeZone(identifier: rawValue) }
}

final class AppState: ObservableObject {
    @Published var mode: PanelMode = .hidden
    @Published var isExpanded: Bool = false
    @Published var currentTime: Date = Date()
    
    // 面板实时尺寸：由 PanelManager 在窗口动画期间逐帧推送（窗口 frame 是唯一尺寸时钟）。
    // 背景：SwiftUI PreferenceKey 测量链在 NSGlassEffectView + Button 组合下会被卡死
    //（最小复现实验坐实：占位 Text 测量正常，加入任意 Button 即死锁恒 0x0），
    // 因此布局进度/字号缩放改由 AppKit 侧直接驱动，数据源是窗口 frame 本身，绝对可靠
    // 整窗 glass 已移除，该 workaround 待观察后清理。
    @Published var livePanelSize: CGSize = .zero
    
    /// PanelManager 在窗口动画每帧调用（SwiftUI 主线程）
    func updateLivePanelSize(_ size: CGSize) {
        livePanelSize = size
    }
    
    // 核心微状态（一瞥底栏）
    @Published var batteryInfo: BatteryInfo = BatteryInfo(percentage: 100, isCharging: false, isOnACPower: false, hasBattery: false)
    @Published var wifiInfo: WiFiInfo = WiFiInfo(isConnected: false, ssid: nil)
    @Published var bluetoothDevices: [BluetoothDeviceInfo] = []
    var bluetoothDevice: BluetoothDeviceInfo? { bluetoothDevices.first }
    @Published var audioInfo: AudioInfo = AudioInfo(deviceName: "系统音频", volume: 50, isMuted: false, isHeadphones: false)
    @Published var dndInfo: DNDInfo = DNDInfo(isEnabled: false)
    
    // 扩展监控状态（Tab 展开看板）
    @Published var performanceInfo: SystemPerformanceInfo = SystemPerformanceInfo(cpuUsage: 0, memoryUsagePercent: 0, memoryUsedGB: 0, memoryTotalGB: 16)
    @Published var trafficInfo: NetworkTrafficInfo = NetworkTrafficInfo(downloadSpeed: "0 KB/s", uploadSpeed: "0 KB/s")
    @Published var calendarInfo: CalendarEventInfo = CalendarEventInfo(hasEvent: false, title: "", timeDescription: "", isAuthorized: false)
    @Published var diskInfo: DiskInfo = DiskInfo(freeGB: 0, totalGB: 0)
    @Published var topCPUProcess: String? = nil
    // 网络延迟（毫秒，nil = 未知/失败/断网；仅面板展开时低频测量）
    @Published var networkLatency: Int? = nil
    // Now Playing 媒体状态（由 SystemStatusProvider adapter 流桥接，无媒体会话时为 nil）
    @Published var nowPlayingInfo: NowPlayingInfo? = nil
    private var nowPlayingCancellable: AnyCancellable?
    
    // 便捷操作与瞬态 Toast 微徽章
    @Published var toastMessage: String? = nil
    @Published var isKeepAwake: Bool = false
    private var toastTimer: Timer?
    
    // 鼠标悬停态与液态微光一瞥进度 (1.0 -> 0.0)
    @Published var isHovered: Bool = false
    @Published var glanceProgress: CGFloat = 1.0
    private var glanceTotalDuration: Double = 3.0
    private var glanceRemainingSeconds: Double = 3.0
    private let glanceTickInterval: Double = 0.04
    
    // 番茄钟状态
    @Published var pomodoroRunning: Bool = false
    @Published var pomodoroRemainingSeconds: Int = 25 * 60
    
    // 快捷键速查卡片 (CheatSheet) 浮层状态
    @Published var showCheatSheet: Bool = false
    
    // MARK: - 面板上下文路由（独立功能 = 独立全面板视图）
    // showCalendarView 是「当前上下文 == .calendar」的存储载体（视图绑定直接读它）；
    // 未来新组件接入时按需新增同类存储属性
    @Published var showCalendarView: Bool = false
    // 进入独立上下文前的来源快照（exitContext 退出时恢复；dismiss 时清零防脏状态）
    private var contextReturnPoint: PanelContext? = nil
    
    /// 当前面板上下文（派生语义：日历 > 看板 > 一瞥）
    var currentContext: PanelContext {
        if showCalendarView { return .calendar }
        return isExpanded ? .dashboard : .glance
    }
    
    /// 组件直达键注册表：keyCode → 上下文（新组件在此注册一行即接入「任意状态直达」）
    static let contextHotkeys: [UInt16: PanelContext] = [
        5: .calendar,   // G: 日历视图
    ]
    @Published var calendarViewMode: CalendarViewMode = .month
    @Published var calendarAnchorDate: Date = Date()       // 翻页锚点（月视图=当月，周=当周，日=当天）
    @Published var selectedDate: Date = Date()             // 选中日期（日程列表展示日）
    @Published var calendarGridCells: [CalendarDayCell] = []  // 网格缓存模型（月 42 格 / 周 7 格）
    @Published var dayEvents: [EKEvent] = []               // 选中日全部日程缓存
    @Published var selectedEvent: EKEvent? = nil           // 详情展示中的日程（点击条目进入）
    // 日程编辑草稿（内联编辑表单状态；nil = 未在编辑）
    @Published var calendarEditing: CalendarEditDraft? = nil
    // 临近会议提醒（<5 分钟高亮；主时钟秒级 tick 基于缓存开始时刻本地计算，零新增轮询）
    @Published var upcomingMeeting: UpcomingMeetingInfo? = nil
    // 跨天检测锚点（日历视图数据按天缓存，跨天自动刷新）
    private var lastTickDay: Date? = nil
    
    // 用户偏好设置
    @AppStorage("showOnLaunch") var showOnLaunch: Bool = true
    @AppStorage("glanceDuration") var glanceDuration: Double = 3.0
    @AppStorage("showSeconds") var showSeconds: Bool = true
    @AppStorage("is24HourFormat") var is24HourFormat: Bool = true
    @AppStorage("showMenuBarIcon") private var storedShowMenuBarIcon: Bool = true
    
    var showMenuBarIcon: Bool {
        get { storedShowMenuBarIcon }
        set {
            storedShowMenuBarIcon = newValue
            objectWillChange.send()
            onMenuBarIconVisibilityChange?(newValue)
        }
    }
    
    // 一瞥底栏微标展示开关
    @AppStorage("showBattery") var showBattery: Bool = true
    @AppStorage("showWiFi") var showWiFi: Bool = true
    @AppStorage("showBluetooth") var showBluetooth: Bool = true
    @AppStorage("showAudio") var showAudio: Bool = true
    @AppStorage("showDND") var showDND: Bool = true
    @AppStorage("showNowPlaying") var showNowPlaying: Bool = true
    
    // 世界时钟三槽位配置（可在偏好设置改为「无」隐藏对应槽位，默认北京/伦敦/纽约）
    @AppStorage("worldClockCity1") var worldClockCity1Raw: String = WorldClockCity.beijing.rawValue
    @AppStorage("worldClockCity2") var worldClockCity2Raw: String = WorldClockCity.london.rawValue
    @AppStorage("worldClockCity3") var worldClockCity3Raw: String = WorldClockCity.newYork.rawValue
    
    // 番茄钟统计（持久化：今日完成数与连续天数，跨天自动重置）
    @AppStorage("pomodoroTodayCount") var pomodoroTodayCount: Int = 0
    @AppStorage("pomodoroTodayKey") private var pomodoroTodayKey: String = ""       // yyyy-MM-dd，今日计数锚点
    @AppStorage("pomodoroStreakDays") var pomodoroStreakDays: Int = 0
    @AppStorage("pomodoroStreakLastDay") private var pomodoroStreakLastDay: String = "" // yyyy-MM-dd，连续判定锚点
    
    // 扩展监控展示开关
    @AppStorage("showPerformance") var showPerformance: Bool = true
    @AppStorage("showNetworkSpeed") var showNetworkSpeed: Bool = true
    @AppStorage("showCalendar") var showCalendar: Bool = false
    @AppStorage("enablePomodoro") var enablePomodoro: Bool = false
    
    @AppStorage("triggerType") var triggerTypeRaw: String = TriggerType.doubleCmd.rawValue
    // AI 对话窗全局热键（独立分流；默认双击 ⌥⌥）。rawValue 存储，旧值（任意侧）继续有效。
    @AppStorage("aiTriggerTypeRaw") var aiTriggerTypeRaw: String = TriggerType.doubleOpt.rawValue
    
    var triggerType: TriggerType {
        get {
            TriggerType(rawValue: triggerTypeRaw) ?? .doubleCmd
        }
        set {
            // 互斥校验：与 AI 热键命中键冲突则拒绝（设置 UI 亦会提示，此处兜底）
            guard !newValue.conflicts(with: aiTriggerType) else {
                NSLog("[QuickShow] 主面板热键与 AI 热键冲突，已忽略变更：\(newValue.displayName)")
                objectWillChange.send()
                return
            }
            triggerTypeRaw = newValue.rawValue
            objectWillChange.send()
            HotKeyManager.shared.configure(type: newValue, aiType: aiTriggerType)
        }
    }
    
    var aiTriggerType: TriggerType {
        get {
            TriggerType(rawValue: aiTriggerTypeRaw) ?? .doubleOpt
        }
        set {
            guard !newValue.conflicts(with: triggerType) else {
                NSLog("[QuickShow] AI 热键与主面板热键冲突，已忽略变更：\(newValue.displayName)")
                objectWillChange.send()
                return
            }
            aiTriggerTypeRaw = newValue.rawValue
            objectWillChange.send()
            HotKeyManager.shared.configure(type: triggerType, aiType: newValue)
        }
    }
    
    // 界面尺寸与屏幕自适应
    @AppStorage("panelScaleOption") var panelScaleOptionRaw: String = PanelScaleOption.auto.rawValue
    
    // 外观主题变体（默认黑曜石 / 琥珀暖色）
    @AppStorage("themeVariant") var themeVariantRaw: String = ThemeVariant.standard.rawValue
    
    // 明暗模式（自动 / 浅色 / 深色，全 App 范围）
    @AppStorage("appearanceMode") var appearanceModeRaw: String = AppearanceMode.dark.rawValue
    
    var appearanceMode: AppearanceMode {
        get {
            AppearanceMode(rawValue: appearanceModeRaw) ?? .auto
        }
        set {
            appearanceModeRaw = newValue.rawValue
            // 即时应用到全 App：NSApp.appearance 联动所有窗口的玻璃与语义色翻转，内容层零改动
            newValue.apply()
            objectWillChange.send()
        }
    }
    
    var themeVariant: ThemeVariant {
        get {
            ThemeVariant(rawValue: themeVariantRaw) ?? .standard
        }
        set {
            themeVariantRaw = newValue.rawValue
            // 写入 Theme 读取通道并触发全视图树 re-render（Theme.Colors 变体通道重新求值，即时生效）
            Theme.variant = newValue
            objectWillChange.send()
        }
    }
    
    var panelScaleOption: PanelScaleOption {
        get {
            PanelScaleOption(rawValue: panelScaleOptionRaw) ?? .auto
        }
        set {
            panelScaleOptionRaw = newValue.rawValue
            objectWillChange.send()
            onLayoutChange?()
        }
    }
    
    func currentMetrics(for screen: NSScreen = ScreenHelper.activeScreen) -> PanelLayoutMetrics {
        ScreenHelper.metrics(for: screen, option: panelScaleOption)
    }
    
    private var glanceTimer: Timer?
    private var clockTimer: AnyCancellable?
    private var tickCounter: Int = 0
    // 高负载进程探测进行中标记：ps 未返回前跳过新一轮，防止任务堆积
    private var isFetchingTopCPU = false
    
    var onTogglePanel: ((PanelMode) -> Void)?
    var onDismissPanel: (() -> Void)?
    var onExpansionChange: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onMenuBarIconVisibilityChange: ((Bool) -> Void)?
    var onCheatSheetChange: ((Bool) -> Void)?
    var onLayoutChange: (() -> Void)?
    
    init() {
        // 启动时同步主题变体到 Theme 读取通道（确保首帧渲染即使用持久化的主题）
        Theme.variant = themeVariant
        // 桥接 Now Playing 状态：Provider 内部 adapter 流式推送零轮询，此处仅做状态转发
        nowPlayingCancellable = SystemStatusProvider.shared.$nowPlayingInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                self?.nowPlayingInfo = info
            }
        refreshAllSystemStatus()
    }
    
    /// 响应快捷键触发（纯粹的显示/隐藏全局开关）
    func toggleFromHotKey() {
        switch mode {
        case .hidden:
            show(mode: .glance)
        case .glance, .pinned:
            dismiss()
        }
    }
    
    /// 显示指定模式
    func show(mode: PanelMode) {
        self.mode = mode
        self.isHovered = false
        currentTime = Date()
        startClock()
        
        cancelGlanceTimer()
        if mode == .glance && !isExpanded {
            startGlanceTimer()
        }
        
        // 窗口先上屏，状态后刷新：refreshAllSystemStatus 内部异步执行，
        // 避免 WiFi/蓝牙等阻塞式系统查询拖慢双击呼出的即时响应
        onTogglePanel?(mode)
        refreshAllSystemStatus()
    }
    
    /// 切换详细展开监控视图
    func toggleExpanded() {
        // 日历视图内按 Tab：切回进入前上下文（一瞥进入回一瞥，看板进入回看板）
        if showCalendarView {
            exitContext()
            return
        }
        // 状态瞬时切换：面板尺寸动画的唯一时钟是 PanelManager 的窗口 setFrame 动画，
        // SwiftUI 内容立即进入最终布局并弹性填充 hosting view，空间由窗口逐帧供给自然 reflow，
        // 此处绝不能再包 withAnimation，否则内容与窗口两套插值时钟打架导致布局抖动
        isExpanded.toggle()
        if isExpanded {
            // 用户展开了详细视图，若处于一瞥模式则暂停倒计时，避免看着看着突然关闭
            if mode == .glance {
                cancelGlanceTimer()
            }
        } else {
            // 用户收起了详细视图，若处于一瞥模式，重新启动倒计时平滑退场
            if mode == .glance {
                startGlanceTimer()
            }
        }
        onExpansionChange?(isExpanded)
    }
    
    /// 切换常驻状态 (Space 键 / 图钉按钮)
    func togglePin() {
        if mode == .pinned {
            unpin()
        } else {
            pin()
        }
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
        // 若当前未展开详细视图，恢复一瞥倒计时自动淡出
        if !isExpanded {
            startGlanceTimer()
        }
        onTogglePanel?(.glance)
    }
    
    /// 关闭/隐藏面板
    func dismiss() {
        cancelGlanceTimer()
        stopClock()
        mode = .hidden
        isExpanded = false
        isHovered = false
        showCheatSheet = false
        // 日历视图状态归位：下次呼出回到默认看板语义，上下文来源快照清零防脏状态；
        // 网格/日程缓存一并清空（避免上次翻到的月份在下次 G 首帧残留闪烁）
        showCalendarView = false
        selectedEvent = nil
        calendarEditing = nil
        calendarGridCells = []
        dayEvents = []
        contextReturnPoint = nil
        upcomingMeeting = nil
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
    
    /// 明确设置快捷键速查表显示状态（用于长按 ⌘ 弹出 / 松开淡出）
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
    
    // MARK: - 便捷操作微服务
    func showToast(_ message: String) {
        resetGlanceTimer()
        toastTimer?.invalidate()
        withAnimation(.easeInOut(duration: Theme.Motion.contentFade)) {
            toastMessage = message
        }
        toastTimer = Timer.scheduledTimer(withTimeInterval: Theme.Motion.toastDuration, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: Theme.Motion.toastOut)) {
                    self?.toastMessage = nil
                }
                // Toast 播完后，若处于一瞥模式且未展开，重新给 3 秒倒计时平滑退场
                if self?.mode == .glance && self?.isExpanded == false {
                    self?.resetGlanceTimer()
                }
            }
        }
    }
    
    func toggleMute() {
        resetGlanceTimer()
        let isMuted = SystemStatusProvider.shared.toggleMute()
        audioInfo.isMuted = isMuted
        showToast(isMuted ? "已静音" : "已恢复音量 (\(audioInfo.volume)%)")
    }
    
    func adjustVolume(by step: Int) {
        resetGlanceTimer()
        let newVol = SystemStatusProvider.shared.adjustVolume(by: step)
        audioInfo.volume = newVol
        audioInfo.isMuted = false
        showToast("音量: \(newVol)%")
    }
    
    func toggleKeepAwake() {
        resetGlanceTimer()
        let active = SystemStatusProvider.shared.toggleKeepAwake()
        isKeepAwake = active
        showToast(active ? "已开启防休眠 ☕️" : "已恢复系统节能")
    }
    
    func copyLocalIP() {
        resetGlanceTimer()
        if let ip = SystemStatusProvider.shared.getLocalIPAddress() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
            showToast("已复制局域网 IP: \(ip)")
        } else {
            showToast("未检测到有效局域网 IP")
        }
    }
    
    func cleanClipboard() {
        resetGlanceTimer()
        let pb = NSPasteboard.general
        if let str = pb.string(forType: .string), !str.isEmpty {
            pb.clearContents()
            pb.setString(str, forType: .string)
            let preview = str.trimmingCharacters(in: .whitespacesAndNewlines).prefix(14)
            showToast("已纯文本化: \"\(preview)...\"")
        } else {
            showToast("剪贴板为空")
        }
    }
    
    func lockScreen() {
        dismiss()
        SystemStatusProvider.shared.lockScreen()
    }
    
    func optimizeMemory() {
        resetGlanceTimer()
        let released = SystemStatusProvider.shared.optimizeMemory()
        performanceInfo = SystemStatusProvider.shared.getSystemPerformanceInfo()
        showToast(String(format: "已优化释放 %.0f MB 内存", released))
    }
    
    func cyclePomodoroDuration() {
        resetGlanceTimer()
        if pomodoroRemainingSeconds > 25 * 60 {
            resetPomodoro(durationMinutes: 5)
            showToast("番茄钟: 5 分钟短休息")
        } else if pomodoroRemainingSeconds > 5 * 60 {
            resetPomodoro(durationMinutes: 45)
            showToast("番茄钟: 45 分钟深度专注")
        } else {
            resetPomodoro(durationMinutes: 25)
            showToast("番茄钟: 25 分钟标准专注")
        }
    }
    
    func openActivityMonitor() {
        SystemStatusProvider.shared.openActivityMonitor()
        dismiss()
    }
    
    func openDownloadsFolder() {
        SystemStatusProvider.shared.openDownloadsFolder()
        dismiss()
    }
    
    func openCalendarApp() {
        SystemStatusProvider.shared.openCalendarApp()
        dismiss()
    }
    
    func openNetworkSettings() {
        SystemStatusProvider.shared.openNetworkSettings()
        dismiss()
    }
    
    func openBatterySettings() {
        SystemStatusProvider.shared.openBatterySettings()
        dismiss()
    }
    
    func openFocusSettings() {
        SystemStatusProvider.shared.openFocusSettings()
        dismiss()
    }
    
    func openSettings() {
        dismiss()
        onOpenSettings?()
    }
    
    func quitApp() {
        NSApp.terminate(nil)
    }
    
    func joinMeeting(url: URL) {
        NSWorkspace.shared.open(url)
        dismiss()
    }
    
    // MARK: - 番茄钟控制
    // 本次计时是否为短休息（5m 短休息完成不计入番茄统计）
    private var pomodoroIsRestSession: Bool = false
    
    func togglePomodoro() {
        resetGlanceTimer()
        pomodoroRunning.toggle()
        showToast(pomodoroRunning ? "番茄钟已启动" : "番茄钟已暂停")
    }
    
    func resetPomodoro(durationMinutes: Int = 25) {
        pomodoroRunning = false
        pomodoroRemainingSeconds = durationMinutes * 60
        pomodoroIsRestSession = durationMinutes < 25
    }
    
    var formattedPomodoroTime: String {
        let m = pomodoroRemainingSeconds / 60
        let s = pomodoroRemainingSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    /// 番茄钟完成统计：专注时段归零时累计今日数并维护连续天数（短休息不计数）
    private static let pomodoroDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    
    private func recordPomodoroCompletion() {
        guard !pomodoroIsRestSession else { return }
        let now = Date()
        let today = Self.pomodoroDayFormatter.string(from: now)
        // 跨天重置今日计数
        if pomodoroTodayKey != today {
            pomodoroTodayKey = today
            pomodoroTodayCount = 0
        }
        pomodoroTodayCount += 1
        // 连续天数：今日已记过保持不变；昨日有记录则累加；否则中断重计为 1
        if pomodoroStreakLastDay != today {
            let yesterday = Self.pomodoroDayFormatter.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now)
            pomodoroStreakDays = (pomodoroStreakLastDay == yesterday) ? pomodoroStreakDays + 1 : 1
            pomodoroStreakLastDay = today
        }
    }
    
    // MARK: - 世界时钟
    /// 生效的世界时钟城市列表（剔除「无」并去重，保持槽位顺序）
    var worldClockCities: [WorldClockCity] {
        var seen = Set<String>()
        return [worldClockCity1Raw, worldClockCity2Raw, worldClockCity3Raw]
            .compactMap { WorldClockCity(rawValue: $0) }
            .filter { $0 != .none && seen.insert($0.rawValue).inserted }
    }
    
    // 复用单实例 Formatter：面板每秒刷新时钟，避免反复创建
    private let worldClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    
    func worldClockTimeString(for city: WorldClockCity) -> String {
        guard let tz = city.timeZone else { return "--:--" }
        worldClockFormatter.timeZone = tz
        return worldClockFormatter.string(from: currentTime)
    }
    
    /// 点击 Now Playing 微标：激活来源应用并收起面板
    func activateNowPlayingApp() {
        guard let bundleID = nowPlayingInfo?.bundleIdentifier else { return }
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .activate(options: [.activateAllWindows])
        dismiss()
    }
    
    // MARK: - 上下文统一进入/退出管线（G 等组件直达键与 Tab 的日历退出均汇聚于此）
    
    /// 直达键统一入口：已在该上下文则退出回来源态，否则进入
    func toggleContext(_ context: PanelContext) {
        if currentContext == context {
            exitContext()
        } else {
            enterContext(context)
        }
    }
    
    /// 进入独立上下文：记录来源快照 → 激活目标上下文（尺寸动画由 PanelManager 窗口驱动）
    func enterContext(_ context: PanelContext) {
        guard currentContext != context else { return }
        contextReturnPoint = currentContext
        activateContext(context)
    }
    
    /// 退出独立上下文：恢复来源上下文（来源为一瞥且处于一瞥模式时重启 3 秒淡出倒计时；
    /// 看板保持展开无倒计时；pinned 态因 mode != .glance 天然不启动倒计时）
    func exitContext() {
        // 兜底：来源快照缺失时按一瞥语义退出（当前不变式下不可达，防御面板卡死在独立上下文）
        let returnPoint = contextReturnPoint ?? .glance
        contextReturnPoint = nil
        activateContext(returnPoint)
        if returnPoint == .glance && mode == .glance {
            startGlanceTimer()
        }
    }
    
    /// 激活目标上下文（各上下文的瞬态清理与初始化集中于此；状态瞬时切换，严禁包 withAnimation——
    /// 面板尺寸动画的唯一时钟是 PanelManager 的窗口 setFrame 动画，双插值时钟会打架抖动）
    private func activateContext(_ context: PanelContext) {
        // 日历态瞬态：离开即清理（详情/编辑表单不跨上下文残留）
        selectedEvent = nil
        calendarEditing = nil
        switch context {
        case .glance:
            showCalendarView = false
            isExpanded = false
        case .dashboard:
            // 看板展开：暂停一瞥自动淡出倒计时（与 toggleExpanded 同语义）
            showCalendarView = false
            isExpanded = true
            cancelGlanceTimer()
        case .calendar:
            // 进入日历默认：当前月 + 今日日程；日历态隐含展开语义（整面板切换，无看板残留）；
            // 暂停一瞥自动淡出倒计时（一瞥态直达进入时原 3 秒倒计时必须取消）
            showCalendarView = true
            isExpanded = true
            calendarAnchorDate = Date()
            selectedDate = Date()
            refreshCalendarData()
            cancelGlanceTimer()
        }
        // 上下文切换触发窗口尺寸动画（目标尺寸 = 上下文映射）
        onLayoutChange?()
    }
    
    func setCalendarViewMode(_ mode: CalendarViewMode) {
        guard showCalendarView, calendarViewMode != mode else { return }
        calendarViewMode = mode
        selectedEvent = nil
        refreshCalendarData()
    }
    
    /// 翻页：月历 ±月、周历 ±周、日历 ±天（语义随当前视图）
    func calendarPageForward() { calendarPage(by: 1) }
    func calendarPageBackward() { calendarPage(by: -1) }
    
    private func calendarPage(by offset: Int) {
        let cal = Calendar.current
        let component: Calendar.Component
        switch calendarViewMode {
        case .month: component = .month
        case .week: component = .weekOfYear
        case .day: component = .day
        }
        guard let newAnchor = cal.date(byAdding: component, value: offset, to: calendarAnchorDate) else { return }
        calendarAnchorDate = newAnchor
        // 选中日期跟随翻页语义：月视图选中新月首日，周视图选中新周首日，日视图即当日
        switch calendarViewMode {
        case .month:
            selectedDate = cal.date(from: cal.dateComponents([.year, .month], from: newAnchor)) ?? newAnchor
        case .week:
            selectedDate = Self.gridStartDate(anchor: newAnchor, mode: .week) ?? newAnchor
        case .day:
            selectedDate = newAnchor
        }
        selectedEvent = nil
        refreshCalendarData()
    }
    
    /// 回到今天（顶栏「今天」按钮）
    func calendarJumpToToday() {
        calendarAnchorDate = Date()
        selectedDate = Date()
        selectedEvent = nil
        refreshCalendarData()
    }
    
    /// 选中某日（点击网格格子）
    func selectCalendarDate(_ date: Date) {
        selectedDate = date
        selectedEvent = nil
        refreshCalendarData()
    }
    
    /// 打开日程编辑（内联表单；nil = 新建，默认选中日下一个整点起 1 小时）
    /// 注：macOS 无 EKEventEditViewController（EventKitUI 仅 iOS/Catalyst），
    /// 故采用自建轻量表单（SwiftUI 内联于日历视图），EKEventStore 保存
    func openEventEditor(for event: EKEvent?) {
        if let event = event {
            calendarEditing = CalendarEditDraft(event: event)
        } else {
            calendarEditing = CalendarEditDraft(newOn: selectedDate)
        }
    }
    
    func cancelEventEditing() {
        calendarEditing = nil
    }
    
    /// 保存编辑草稿：新建或回写既有日程（EventKit 写操作放后台串行队列，完成回主线程刷新）
    func saveEventEditing() {
        guard let draft = calendarEditing, !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        calendarEditing = nil
        selectedEvent = nil
        Self.statusRefreshQueue.async { [weak self] in
            SystemStatusProvider.shared.saveEventDraft(draft)
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 选中日期跟随保存结果；若当前网格范围不含该日（跨月/周编辑），锚点一并跳转
                let range = Self.gridDateRange(anchor: self.calendarAnchorDate, mode: self.calendarViewMode)
                if !(draft.startDate >= range.lowerBound && draft.startDate < range.upperBound) {
                    self.calendarAnchorDate = draft.startDate
                }
                self.selectedDate = draft.startDate
                self.refreshCalendarData()
            }
        }
    }
    
    /// 删除正在编辑的日程（仅编辑态可用）
    func deleteEditingEvent() {
        guard let eventID = calendarEditing?.eventID else { return }
        calendarEditing = nil
        selectedEvent = nil
        Self.statusRefreshQueue.async { [weak self] in
            SystemStatusProvider.shared.deleteEvent(withIdentifier: eventID)
            DispatchQueue.main.async {
                self?.refreshCalendarData()
            }
        }
    }
    
    /// 日历视图数据刷新：网格缓存模型 + 选中日日程，后台串行队列查询，结果回主线程。
    /// 仅在进入视图/翻页/视图切换/选中变更/编辑保存/跨天时调用，避免每秒 tick 全量查询；
    /// 未授权时日程与事件点为空（视图层显示授权引导），农历/节气不依赖权限照常可用。
    func refreshCalendarData() {
        guard showCalendarView else { return }
        let mode = calendarViewMode
        let anchor = calendarAnchorDate
        let selected = selectedDate
        let authorized = SystemStatusProvider.shared.isCalendarAuthorized
        Self.statusRefreshQueue.async { [weak self] in
            guard let self = self else { return }
            let provider = SystemStatusProvider.shared
            let range = Self.gridDateRange(anchor: anchor, mode: mode)
            let eventDays = authorized ? provider.getEventDaySet(from: range.lowerBound, to: range.upperBound) : []
            let cells = Self.buildGridCells(anchor: anchor, mode: mode, eventDays: eventDays)
            let events = authorized ? provider.getEvents(on: selected) : []
            DispatchQueue.main.async {
                self.calendarGridCells = cells
                self.dayEvents = events
            }
        }
    }
    
    /// 网格起始日（周一为首列，贴合中文习惯）：月视图 = 当月 1 号所在周的周一，周视图 = 锚点所在周周一
    static func gridStartDate(anchor: Date, mode: CalendarViewMode) -> Date? {
        gridDateRange(anchor: anchor, mode: mode).lowerBound
    }
    
    /// 网格覆盖的日期范围（月视图 42 格 / 周视图 7 格 / 日视图当天）
    static func gridDateRange(anchor: Date, mode: CalendarViewMode) -> (lowerBound: Date, upperBound: Date) {
        let cal = Calendar.current
        switch mode {
        case .month:
            let comps = cal.dateComponents([.year, .month], from: anchor)
            let firstOfMonth = cal.date(from: comps) ?? anchor
            let weekday = cal.component(.weekday, from: firstOfMonth)   // 1 = 周日
            let offset = (weekday + 5) % 7                              // 距周一的天数
            let start = cal.date(byAdding: .day, value: -offset, to: firstOfMonth) ?? firstOfMonth
            let end = cal.date(byAdding: .day, value: 42, to: start) ?? start
            return (start, end)
        case .week:
            let weekday = cal.component(.weekday, from: anchor)
            let offset = (weekday + 5) % 7
            let start = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: anchor)) ?? anchor
            let end = cal.date(byAdding: .day, value: 7, to: start) ?? start
            return (start, end)
        case .day:
            let start = cal.startOfDay(for: anchor)
            let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
            return (start, end)
        }
    }
    
    /// 生成日历网格缓存模型（月视图 42 格 / 周视图 7 格；农历/节气本地计算，事件点来自 EventKit）
    private static func buildGridCells(anchor: Date, mode: CalendarViewMode, eventDays: Set<String>) -> [CalendarDayCell] {
        guard mode != .day else { return [] }
        let cal = Calendar.current
        let range = gridDateRange(anchor: anchor, mode: mode)
        let count = (mode == .month) ? 42 : 7
        var cells: [CalendarDayCell] = []
        for i in 0..<count {
            guard let date = cal.date(byAdding: .day, value: i, to: range.lowerBound) else { continue }
            let festival = LunarCalendar.festival(for: date)
            let term = LunarCalendar.solarTerm(for: date)
            cells.append(CalendarDayCell(
                date: date,
                day: cal.component(.day, from: date),
                isToday: cal.isDateInToday(date),
                isInCurrentScope: mode == .month ? cal.isDate(date, equalTo: anchor, toGranularity: .month) : true,
                lunarText: LunarCalendar.dayText(for: date),
                festival: festival,
                solarTerm: term,
                hasEvents: eventDays.contains(SystemStatusProvider.dayKey(date))
            ))
        }
        return cells
    }
    
    // MARK: - 媒体控制盲操（⏎ 播放暂停 / ←→ 切歌 / ,. ±15s）
    // 仅存在媒体会话时生效，无会话按键无副作用（键位分发处据此决定是否消费事件）
    var hasNowPlayingSession: Bool { nowPlayingInfo != nil }
    
    func mediaTogglePlayPause() {
        guard hasNowPlayingSession else { return }
        SystemStatusProvider.shared.sendMediaCommand(.togglePlayPause)
        // 乐观提示：命令即发即弃无回执，约 100ms 内 stream 推送真实状态校正微标与卡片
        showToast(nowPlayingInfo?.isPlaying == true ? "已暂停 ⏸" : "继续播放 ▶")
    }
    
    /// 上一首 (←)
    func mediaPreviousTrack() {
        guard hasNowPlayingSession else { return }
        SystemStatusProvider.shared.sendMediaCommand(.previousTrack)
    }
    
    /// 下一首 (→)
    func mediaNextTrack() {
        guard hasNowPlayingSession else { return }
        SystemStatusProvider.shared.sendMediaCommand(.nextTrack)
    }
    
    /// 后退 15 秒 (,)
    func mediaSkipBackward() {
        guard hasNowPlayingSession else { return }
        SystemStatusProvider.shared.sendMediaCommand(.skipBackward15)
    }
    
    /// 快进 15 秒 (.)
    func mediaSkipForward() {
        guard hasNowPlayingSession else { return }
        SystemStatusProvider.shared.sendMediaCommand(.skipForward15)
    }
    
    // MARK: - 定时调度器与液态流体动效
    func setHovered(_ hovering: Bool) {
        isHovered = hovering
        // 鼠标移入自动冻结倒计时；移出时从当前剩余时间自然继续流逝（不重置）
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
                // 若处于非一瞥模式、展开看板、鼠标悬浮、或正在播放 Toast，冻结倒计时并维持微光
                if self.mode != .glance || self.isExpanded || self.isHovered || self.toastMessage != nil {
                    return
                }
                
                self.glanceRemainingSeconds -= self.glanceTickInterval
                let progress = max(0.0, self.glanceRemainingSeconds / self.glanceTotalDuration)
                self.glanceProgress = progress
                
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
    
    private func startClock() {
        stopClock()
        tickCounter = 0
        clockTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] newDate in
                guard let self = self else { return }
                self.currentTime = newDate
                self.tickCounter += 1
                
                // 番茄钟倒计时步进
                if self.pomodoroRunning && self.pomodoroRemainingSeconds > 0 {
                    self.pomodoroRemainingSeconds -= 1
                    if self.pomodoroRemainingSeconds == 0 {
                        self.pomodoroRunning = false
                        self.recordPomodoroCompletion()
                        self.showToast("🎉 番茄专注时段已完成！")
                    }
                }
                
                // 实时网速：每秒更新
                if self.isExpanded && self.showNetworkSpeed {
                    self.trafficInfo = SystemStatusProvider.shared.getNetworkTrafficInfo()
                }
                
                // 网络延迟：展开且开启网速展示时每 5 秒异步低频测量一次
                //（面板隐藏时主时钟停摆，天然满足"仅面板可见时测量"，待机零消耗）
                if self.isExpanded && self.showNetworkSpeed && (self.tickCounter % 5 == 2) {
                    SystemStatusProvider.shared.measureNetworkLatency { [weak self] ms in
                        self?.networkLatency = ms
                    }
                }
                
                // 性能负载 (CPU & RAM)：展开时每 2 秒刷新一次，降低开销
                if self.isExpanded && self.showPerformance && (self.tickCounter % 2 == 0) {
                    self.performanceInfo = SystemStatusProvider.shared.getSystemPerformanceInfo()
                    self.fetchTopCPUProcess()
                }
                
                // 状态栏每 5 秒做一次静默微更新
                if self.tickCounter % 5 == 0 {
                    self.refreshStatusBadges()
                }
                
                // 临近会议倒计时：<5 分钟时一瞥底栏高亮胶囊
                //（基于缓存的下一场开始时刻本地计算，零新增 EventKit 轮询）
                if let start = self.calendarInfo.nextEventStartDate, self.calendarInfo.hasEvent {
                    let remain = start.timeIntervalSince(newDate)
                    if remain > 0 && remain < 300 {
                        let minutes = Int(ceil(remain / 60.0))
                        let next = UpcomingMeetingInfo(title: self.calendarInfo.title, minutes: minutes)
                        if self.upcomingMeeting != next {
                            self.upcomingMeeting = next
                        }
                    } else if self.upcomingMeeting != nil {
                        self.upcomingMeeting = nil
                    }
                } else if self.upcomingMeeting != nil {
                    self.upcomingMeeting = nil
                }
                
                // 日历信息低频保鲜：每分钟静默刷新一次（pinned 常驻时临近提醒数据不陈旧）
                if self.showCalendar && self.tickCounter % 60 == 10 {
                    Self.statusRefreshQueue.async { [weak self] in
                        let info = SystemStatusProvider.shared.getNextCalendarEvent()
                        DispatchQueue.main.async { self?.calendarInfo = info }
                    }
                }
                
                // 跨天检测：日历视图数据（网格农历/事件点/当日日程）按天缓存，跨天自动刷新
                if let lastDay = self.lastTickDay, !Calendar.current.isDate(newDate, inSameDayAs: lastDay) {
                    if self.showCalendarView {
                        self.refreshCalendarData()
                    }
                }
                self.lastTickDay = newDate
            }
    }
    
    private func stopClock() {
        clockTimer?.cancel()
        clockTimer = nil
    }
    
    /// 异步刷新高负载进程：带防重叠闸门，ps 未返回前不再发起新一轮
    private func fetchTopCPUProcess() {
        guard !isFetchingTopCPU else { return }
        isFetchingTopCPU = true
        SystemStatusProvider.shared.getTopCPUProcessAsync { [weak self] result in
            guard let self = self else { return }
            self.isFetchingTopCPU = false
            // 面板已收起则丢弃过期结果，避免无谓刷新
            guard self.isExpanded else { return }
            self.topCPUProcess = result
        }
    }
    
    // MARK: - 系统状态刷新

    // 系统状态刷新专用串行后台队列：把 WiFi/蓝牙/音频等阻塞式系统查询移出主线程，
    // 保证面板先上屏、状态随后异步补齐；串行执行也避免查询任务相互堆叠
    private static let statusRefreshQueue = DispatchQueue(label: "com.quickshow.statusRefresh", qos: .userInitiated)

    /// 刷新全部系统状态：查询在内部后台队列执行，结果统一回主线程赋值 @Published 状态。
    /// 调用方（init / show）同步返回，无需感知异步细节，主线程不再被系统查询阻塞。
    func refreshAllSystemStatus() {
        // 在主线程同步快照展示开关，避免后台读取 @AppStorage / @Published 产生线程问题
        let perfVisible = showPerformance || isExpanded
        let networkVisible = showNetworkSpeed || isExpanded
        let wantBattery = showBattery
        let wantWiFi = showWiFi
        let wantBluetooth = showBluetooth
        let wantAudio = showAudio
        let wantDND = showDND
        let wantCalendar = showCalendar

        Self.statusRefreshQueue.async { [weak self] in
            guard let self = self else { return }

            // —— 后台执行所有可能阻塞的同步系统查询 ——
            var battery: BatteryInfo?
            if wantBattery { battery = SystemStatusProvider.shared.getBatteryInfo() }
            var wifi: WiFiInfo?
            if wantWiFi { wifi = SystemStatusProvider.shared.getWiFiInfo() }
            let bluetooth = wantBluetooth ? SystemStatusProvider.shared.getBluetoothDevices() : []
            var audio: AudioInfo?
            if wantAudio { audio = SystemStatusProvider.shared.getAudioInfo() }
            var dnd: DNDInfo?
            if wantDND { dnd = SystemStatusProvider.shared.getDNDInfo() }
            let keepAwake = SystemStatusProvider.shared.isKeepAwakeActive()
            let disk = SystemStatusProvider.shared.getDiskInfo()
            var performance: SystemPerformanceInfo?
            if perfVisible { performance = SystemStatusProvider.shared.getSystemPerformanceInfo() }
            var traffic: NetworkTrafficInfo?
            if networkVisible { traffic = SystemStatusProvider.shared.getNetworkTrafficInfo() }
            var calendar: CalendarEventInfo?
            if wantCalendar { calendar = SystemStatusProvider.shared.getNextCalendarEvent() }

            // —— 回主线程统一赋值 @Published（SwiftUI 状态必须主线程更新） ——
            DispatchQueue.main.async {
                if let battery = battery { self.batteryInfo = battery }
                if let wifi = wifi { self.wifiInfo = wifi }
                self.bluetoothDevices = bluetooth
                if let audio = audio { self.audioInfo = audio }
                if let dnd = dnd { self.dndInfo = dnd }
                self.isKeepAwake = keepAwake
                self.diskInfo = disk
                if let performance = performance { self.performanceInfo = performance }
                if let traffic = traffic { self.trafficInfo = traffic }
                if let calendar = calendar { self.calendarInfo = calendar }
            }

            // ps 高负载进程探测本身已异步（内部回主线程），保持原逻辑
            if perfVisible {
                SystemStatusProvider.shared.getTopCPUProcessAsync { [weak self] result in
                    self?.topCPUProcess = result
                }
            }
        }
    }
    
    private func refreshStatusBadges() {
        if showBattery {
            batteryInfo = SystemStatusProvider.shared.getBatteryInfo()
        }
        if showWiFi {
            wifiInfo = SystemStatusProvider.shared.getWiFiInfo()
        }
        if showBluetooth {
            bluetoothDevices = SystemStatusProvider.shared.getBluetoothDevices()
        } else {
            bluetoothDevices = []
        }
        if showAudio {
            audioInfo = SystemStatusProvider.shared.getAudioInfo()
        }
        if showDND {
            dndInfo = SystemStatusProvider.shared.getDNDInfo()
        }
    }
    
    func requestCalendarAccess(completion: @escaping (Bool) -> Void) {
        SystemStatusProvider.shared.requestCalendarAccess { [weak self] granted in
            if granted {
                self?.calendarInfo = SystemStatusProvider.shared.getNextCalendarEvent()
            }
            completion(granted)
        }
    }
    
    var isLocationAuthorized: Bool {
        SystemStatusProvider.shared.isLocationAuthorized()
    }
    
    func requestLocationAccess(completion: @escaping (Bool) -> Void) {
        SystemStatusProvider.shared.requestLocationAccess { [weak self] granted in
            if granted {
                self?.wifiInfo = SystemStatusProvider.shared.getWiFiInfo()
            }
            completion(granted)
        }
    }
}
