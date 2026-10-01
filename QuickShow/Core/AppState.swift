import SwiftUI
import Combine

enum PanelMode: Equatable {
    case hidden
    case glance   // 一瞥模式：3 秒后自动淡出
    case pinned   // 固定模式：常驻显示，直到用户按 ESC 或快捷键
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
    
    var triggerType: TriggerType {
        get {
            TriggerType(rawValue: triggerTypeRaw) ?? .doubleCmd
        }
        set {
            triggerTypeRaw = newValue.rawValue
            objectWillChange.send()
            HotKeyManager.shared.configure(type: newValue)
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
