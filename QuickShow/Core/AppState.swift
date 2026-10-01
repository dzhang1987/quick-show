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
        refreshAllSystemStatus()
        currentTime = Date()
        startClock()
        
        cancelGlanceTimer()
        if mode == .glance && !isExpanded {
            startGlanceTimer()
        }
        
        onTogglePanel?(mode)
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
    func togglePomodoro() {
        resetGlanceTimer()
        pomodoroRunning.toggle()
        showToast(pomodoroRunning ? "番茄钟已启动" : "番茄钟已暂停")
    }
    
    func resetPomodoro(durationMinutes: Int = 25) {
        pomodoroRunning = false
        pomodoroRemainingSeconds = durationMinutes * 60
    }
    
    var formattedPomodoroTime: String {
        let m = pomodoroRemainingSeconds / 60
        let s = pomodoroRemainingSeconds % 60
        return String(format: "%02d:%02d", m, s)
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
                        self.showToast("🎉 番茄专注时段已完成！")
                    }
                }
                
                // 实时网速：每秒更新
                if self.isExpanded && self.showNetworkSpeed {
                    self.trafficInfo = SystemStatusProvider.shared.getNetworkTrafficInfo()
                }
                
                // 性能负载 (CPU & RAM)：展开时每 2 秒刷新一次，降低开销
                if self.isExpanded && self.showPerformance && (self.tickCounter % 2 == 0) {
                    self.performanceInfo = SystemStatusProvider.shared.getSystemPerformanceInfo()
                    self.topCPUProcess = SystemStatusProvider.shared.getTopCPUProcess()
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
    
    // MARK: - 系统状态刷新
    func refreshAllSystemStatus() {
        refreshStatusBadges()
        isKeepAwake = SystemStatusProvider.shared.isKeepAwakeActive()
        diskInfo = SystemStatusProvider.shared.getDiskInfo()
        if showPerformance || isExpanded {
            performanceInfo = SystemStatusProvider.shared.getSystemPerformanceInfo()
            topCPUProcess = SystemStatusProvider.shared.getTopCPUProcess()
        }
        if showNetworkSpeed || isExpanded {
            trafficInfo = SystemStatusProvider.shared.getNetworkTrafficInfo()
        }
        if showCalendar {
            calendarInfo = SystemStatusProvider.shared.getNextCalendarEvent()
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
