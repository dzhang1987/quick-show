import SwiftUI
import Combine

enum PanelMode: Equatable {
    case hidden
    case glance   // 一瞥模式：3 秒后自动淡出
    case pinned   // 固定模式：常驻显示，直到用户按 ESC 或快捷键
}

final class AppState: ObservableObject {
    @Published var mode: PanelMode = .hidden
    @Published var currentTime: Date = Date()
    @Published var batteryInfo: BatteryInfo = BatteryInfo(percentage: 100, isCharging: false, hasBattery: false)
    @Published var wifiInfo: WiFiInfo = WiFiInfo(isConnected: false, ssid: nil)
    
    // 用户偏好设置
    @AppStorage("glanceDuration") var glanceDuration: Double = 3.0
    @AppStorage("showSeconds") var showSeconds: Bool = true
    @AppStorage("is24HourFormat") var is24HourFormat: Bool = true
    @AppStorage("showBattery") var showBattery: Bool = true
    @AppStorage("showWiFi") var showWiFi: Bool = true
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
    
    var onTogglePanel: ((PanelMode) -> Void)?
    var onDismissPanel: (() -> Void)?
    
    init() {
        refreshSystemStatus()
    }
    
    /// 响应快捷键触发
    func toggleFromHotKey() {
        switch mode {
        case .hidden:
            // 第一次按下：开启一瞥模式
            show(mode: .glance)
        case .glance:
            // 一瞥中再次按下：转为固定模式（取消倒计时）
            pin()
        case .pinned:
            // 固定中再次按下：关闭
            dismiss()
        }
    }
    
    /// 显示指定模式
    func show(mode: PanelMode) {
        self.mode = mode
        refreshSystemStatus()
        currentTime = Date()
        startClock()
        
        cancelGlanceTimer()
        if mode == .glance {
            startGlanceTimer()
        }
        
        onTogglePanel?(mode)
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
        onDismissPanel?()
    }
    
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
        // 每秒更新一次
        clockTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] newDate in
                self?.currentTime = newDate
            }
    }
    
    private func stopClock() {
        clockTimer?.cancel()
        clockTimer = nil
    }
    
    func refreshSystemStatus() {
        batteryInfo = SystemStatusProvider.shared.getBatteryInfo()
        wifiInfo = SystemStatusProvider.shared.getWiFiInfo()
    }
}
