import Foundation
import AppKit
import Combine
import EventKit

// MARK: - 系统状态统一提供者（薄聚合门面）
//
// 架构拆分：原单文件 10+ 采集域拆分为子 provider + 本门面。
// 对外契约 100% 不变：static shared、全部公开方法签名、@Published nowPlayingInfo、
// audioChangeSubject、静态 dayKey 等均原样保留，AppState / CalendarView / SettingsView /
// BuiltInTools 零改动。门面只做一行委托与生命周期编排，不承载任何采集逻辑。
final class SystemStatusProvider: NSObject, ObservableObject {
    static let shared = SystemStatusProvider()

    /// Now Playing 媒体状态（mediaremote-adapter 流式推送驱动，无媒体会话时为 nil，待机零轮询）。
    /// 由 NowPlayingProvider 经 onInfoUpdate 回调在 main 队列写入，保持原 publisher 语义。
    @Published var nowPlayingInfo: NowPlayingInfo? = nil

    /// 音频属性变化事件：转发子 provider 的稳定 subject 对象（每次访问返回同一实例）
    var audioChangeSubject: PassthroughSubject<Void, Never> { audioProvider.audioChangeSubject }

    // 子 provider（各域唯一归属）
    private let deviceProvider = DeviceProvider()
    private let audioProvider = AudioProvider()
    private let metricsProvider = SystemMetricsProvider()
    private let calendarProvider = CalendarProvider()

    // adapter 流解析结果回调注入门面（避免子 provider 持有 @Published）
    private lazy var nowPlayingProvider: NowPlayingProvider = {
        NowPlayingProvider { [weak self] info in
            self?.nowPlayingInfo = info
        }
    }()

    // App 退出终止钩子
    private var appTerminationObserver: NSObjectProtocol?

    override private init() {
        super.init()
        nowPlayingProvider.start()
        audioProvider.start()
        // 单例不会 deinit，App 退出时经 willTerminate 主动回收 stream 进程（SIGTERM）
        appTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.nowPlayingProvider.shutdown()
        }
    }

    deinit {
        if let observer = appTerminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        nowPlayingProvider.shutdown()
    }

    // MARK: - Now Playing 媒体控制（adapter send 子命令）
    func sendMediaCommand(_ command: MediaCommand) {
        nowPlayingProvider.sendMediaCommand(command)
    }

    // MARK: - 定位权限管理 (用于读取真实 Wi-Fi SSID)
    func isLocationAuthorized() -> Bool {
        deviceProvider.isLocationAuthorized()
    }
    
    func requestLocationAccess(completion: @escaping (Bool) -> Void) {
        deviceProvider.requestLocationAccess(completion: completion)
    }
    
    // MARK: - 电池信息 (IOKit)
    func getBatteryInfo() -> BatteryInfo {
        deviceProvider.getBatteryInfo()
    }
    
    // MARK: - WiFi 信息 (CoreWLAN)
    func getWiFiInfo() -> WiFiInfo {
        deviceProvider.getWiFiInfo()
    }
    
    // MARK: - 局域网 IP 读取 (用于一键复制)
    func getLocalIPAddress() -> String? {
        deviceProvider.getLocalIPAddress()
    }
    
    // MARK: - 蓝牙外设与电量 (IOKit HID + IOBluetooth)
    func getBluetoothDevices() -> [BluetoothDeviceInfo] {
        deviceProvider.getBluetoothDevices()
    }
    
    func getBluetoothDeviceInfo() -> BluetoothDeviceInfo? {
        deviceProvider.getBluetoothDeviceInfo()
    }
    
    // MARK: - 音频输出设备与音量 (CoreAudio HAL)
    func getAudioInfo() -> AudioInfo {
        audioProvider.getAudioInfo()
    }

    func setVolume(to percent: Int) {
        audioProvider.setVolume(to: percent)
    }

    func toggleMute() -> Bool {
        audioProvider.toggleMute()
    }

    func adjustVolume(by step: Int) -> Int {
        audioProvider.adjustVolume(by: step)
    }

    // MARK: - 勿扰 / 专注模式 (Do Not Disturb)
    func getDNDInfo() -> DNDInfo {
        deviceProvider.getDNDInfo()
    }
    
    // MARK: - 系统性能负载 (CPU / 内存)
    func getSystemPerformanceInfo() -> SystemPerformanceInfo {
        metricsProvider.getSystemPerformanceInfo()
    }
    
    // MARK: - 实时网络速率 (getifaddrs)
    func getNetworkTrafficInfo() -> NetworkTrafficInfo {
        metricsProvider.getNetworkTrafficInfo()
    }
    
    // MARK: - 网络延迟测量 (多目标 TCP connect 握手计时)
    func measureNetworkLatency(completion: @escaping (Int?) -> Void) {
        metricsProvider.measureNetworkLatency(completion: completion)
    }
    
    // MARK: - 日历事件提醒 (EventKit)
    func getCalendarAuthorizationStatus() -> EKAuthorizationStatus {
        calendarProvider.getCalendarAuthorizationStatus()
    }
    
    func requestCalendarAccess(completion: @escaping (Bool) -> Void) {
        calendarProvider.requestCalendarAccess(completion: completion)
    }
    
    func getNextCalendarEvent() -> CalendarEventInfo {
        calendarProvider.getNextCalendarEvent()
    }
    
    // MARK: - 日历视图数据（EventKit 按日/范围查询；均为同步查询，调用方负责后台线程）
    var calendarEventStore: EKEventStore { calendarProvider.calendarEventStore }
    
    var isCalendarAuthorized: Bool { calendarProvider.isCalendarAuthorized }
    
    func getEvents(on date: Date) -> [EKEvent] {
        calendarProvider.getEvents(on: date)
    }
    
    func getEventDaySet(from start: Date, to end: Date) -> Set<String> {
        calendarProvider.getEventDaySet(from: start, to: end)
    }
    
    static func dayKey(_ date: Date) -> String { CalendarProvider.dayKey(date) }
    
    func writableEventCalendars() -> [EKCalendar] {
        calendarProvider.writableEventCalendars()
    }
    
    func saveEventDraft(_ draft: CalendarEditDraft) {
        calendarProvider.saveEventDraft(draft)
    }
    
    func deleteEvent(withIdentifier identifier: String) {
        calendarProvider.deleteEvent(withIdentifier: identifier)
    }
    
    func extractMeetingURL(from strings: [String?]) -> URL? {
        calendarProvider.extractMeetingURL(from: strings)
    }
    
    // MARK: - 咖啡因 / 防休眠模式 (Caffeine / Keep Awake)
    func isKeepAwakeActive() -> Bool {
        SystemActions.isKeepAwakeActive()
    }
    
    func toggleKeepAwake() -> Bool {
        SystemActions.toggleKeepAwake()
    }
    
    func disableKeepAwake() {
        SystemActions.disableKeepAwake()
    }
    
    // MARK: - 磁盘存储空间感知 (Disk Info)
    func getDiskInfo() -> DiskInfo {
        metricsProvider.getDiskInfo()
    }
    
    // MARK: - 锁屏
    func lockScreen() {
        SystemActions.lockScreen()
    }
    
    // MARK: - 内存一键优化整理
    func optimizeMemory() -> Double {
        SystemActions.optimizeMemory(metrics: metricsProvider)
    }
    
    // MARK: - 高负载进程探测 (Top CPU Process)
    func getTopCPUProcess() -> String? {
        metricsProvider.getTopCPUProcess()
    }
    
    /// 异步探测高负载进程：ps 子进程在后台队列执行，避免 fork + waitUntilExit 阻塞主线程
    func getTopCPUProcessAsync(completion: @escaping (String?) -> Void) {
        metricsProvider.getTopCPUProcessAsync(completion: completion)
    }
    
    // MARK: - 系统快捷应用打开
    func openActivityMonitor() {
        SystemActions.openActivityMonitor()
    }
    
    func openDownloadsFolder() {
        SystemActions.openDownloadsFolder()
    }
    
    func openCalendarApp() {
        SystemActions.openCalendarApp()
    }
    
    func openNetworkSettings() {
        SystemActions.openNetworkSettings()
    }
    
    func openBatterySettings() {
        SystemActions.openBatterySettings()
    }
    
    func openFocusSettings() {
        SystemActions.openFocusSettings()
    }
}