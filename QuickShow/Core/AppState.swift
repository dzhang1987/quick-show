import SwiftUI
import Combine

enum PanelMode: Equatable {
    case hidden
    case glance   // 一瞥模式：3 秒后自动淡出
    case pinned   // 固定模式：常驻显示，直到用户按 ESC 或快捷键
}

final class AppState: ObservableObject {
    @Published var mode: PanelMode = .hidden
    @Published var isExpanded: Bool = false
    @Published var currentTime: Date = Date()
    
    // P0 系统状态
    @Published var batteryInfo: BatteryInfo = BatteryInfo(percentage: 100, isCharging: false, hasBattery: false)
    @Published var wifiInfo: WiFiInfo = WiFiInfo(isConnected: false, ssid: nil)
    @Published var bluetoothDevices: [BluetoothDeviceInfo] = []
    var bluetoothDevice: BluetoothDeviceInfo? { bluetoothDevices.first }
    @Published var audioInfo: AudioInfo = AudioInfo(deviceName: "系统音频", volume: 50, isMuted: false, isHeadphones: false)
    @Published var dndInfo: DNDInfo = DNDInfo(isEnabled: false)
    
    // P1 扩展监控状态
    @Published var performanceInfo: SystemPerformanceInfo = SystemPerformanceInfo(cpuUsage: 0, memoryUsagePercent: 0, memoryUsedGB: 0, memoryTotalGB: 16)
    @Published var trafficInfo: NetworkTrafficInfo = NetworkTrafficInfo(downloadSpeed: "0 KB/s", uploadSpeed: "0 KB/s")
    @Published var calendarInfo: CalendarEventInfo = CalendarEventInfo(hasEvent: false, title: "", timeDescription: "", isAuthorized: false)
    
    // 番茄钟状态
    @Published var pomodoroRunning: Bool = false
    @Published var pomodoroRemainingSeconds: Int = 25 * 60
    
    // 用户偏好设置
    @AppStorage("showOnLaunch") var showOnLaunch: Bool = true
    @AppStorage("glanceDuration") var glanceDuration: Double = 3.0
    @AppStorage("showSeconds") var showSeconds: Bool = true
    @AppStorage("is24HourFormat") var is24HourFormat: Bool = true
    
    // P0 微标展示开关
    @AppStorage("showBattery") var showBattery: Bool = true
    @AppStorage("showWiFi") var showWiFi: Bool = true
    @AppStorage("showBluetooth") var showBluetooth: Bool = true
    @AppStorage("showAudio") var showAudio: Bool = true
    @AppStorage("showDND") var showDND: Bool = true
    
    // P1 扩展监控展示开关
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
    
    private var glanceTimer: Timer?
    private var clockTimer: AnyCancellable?
    private var tickCounter: Int = 0
    
    var onTogglePanel: ((PanelMode) -> Void)?
    var onDismissPanel: (() -> Void)?
    var onExpansionChange: ((Bool) -> Void)?
    
    init() {
        refreshAllSystemStatus()
    }
    
    /// 响应快捷键触发
    func toggleFromHotKey() {
        switch mode {
        case .hidden:
            show(mode: .glance)
        case .glance:
            pin()
        case .pinned:
            dismiss()
        }
    }
    
    /// 显示指定模式
    func show(mode: PanelMode) {
        self.mode = mode
        refreshAllSystemStatus()
        currentTime = Date()
        startClock()
        
        cancelGlanceTimer()
        if mode == .glance {
            startGlanceTimer()
        }
        
        onTogglePanel?(mode)
    }
    
    /// 切换详细展开监控视图
    func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isExpanded.toggle()
        }
        if isExpanded && mode == .glance {
            // 用户展开了详细视图，自动转为固定常驻或延长一瞥，避免看着看着突然关闭
            cancelGlanceTimer()
        }
        onExpansionChange?(isExpanded)
    }
    
    /// 固定面板
    func pin() {
        guard mode != .pinned else { return }
        cancelGlanceTimer()
        mode = .pinned
        onTogglePanel?(.pinned)
    }
    
    /// 关闭/隐藏面板
    func dismiss() {
        cancelGlanceTimer()
        stopClock()
        mode = .hidden
        isExpanded = false
        onDismissPanel?()
    }
    
    // MARK: - 番茄钟控制
    func togglePomodoro() {
        pomodoroRunning.toggle()
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
    
    // MARK: - 定时调度器
    private func startGlanceTimer() {
        let duration = max(glanceDuration, 1.0)
        glanceTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismiss()
            }
        }
    }
    
    private func cancelGlanceTimer() {
        glanceTimer?.invalidate()
        glanceTimer = nil
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
                    }
                }
                
                // 实时网速：每秒更新
                if self.isExpanded && self.showNetworkSpeed {
                    self.trafficInfo = SystemStatusProvider.shared.getNetworkTrafficInfo()
                }
                
                // 性能负载 (CPU & RAM)：展开时每 2 秒刷新一次，降低开销
                if self.isExpanded && self.showPerformance && (self.tickCounter % 2 == 0) {
                    self.performanceInfo = SystemStatusProvider.shared.getSystemPerformanceInfo()
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
        if showPerformance || isExpanded {
            performanceInfo = SystemStatusProvider.shared.getSystemPerformanceInfo()
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
}
