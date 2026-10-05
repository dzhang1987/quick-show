import SwiftUI
import Combine
import AppKit
import EventKit

// MARK: - 门面转发层
// 属性转发：为每个迁往域 store 的存储属性写 get/set 计算转发（构成 WritableKeyPath），
// 19 处 `@ObservedObject var appState: AppState` 视图与 `$appState.xxx` Binding 零改动照常工作。
// 带副作用 setter（triggerType/aiTriggerType/appearanceMode/themeVariant/panelScaleOption/showMenuBarIcon）
// 留在门面，引用回调与 HotKeyManager/Theme，副作用原样。
extension AppState {

    // MARK: - SettingsStore 纯存储转发
    var showOnLaunch: Bool {
        get { settings.showOnLaunch }
        set { settings.showOnLaunch = newValue }
    }

    var glanceDuration: Double {
        get { settings.glanceDuration }
        set { settings.glanceDuration = newValue }
    }

    var showSeconds: Bool {
        get { settings.showSeconds }
        set { settings.showSeconds = newValue }
    }

    var is24HourFormat: Bool {
        get { settings.is24HourFormat }
        set { settings.is24HourFormat = newValue }
    }

    var showBattery: Bool {
        get { settings.showBattery }
        set { settings.showBattery = newValue }
    }

    var showWiFi: Bool {
        get { settings.showWiFi }
        set { settings.showWiFi = newValue }
    }

    var showBluetooth: Bool {
        get { settings.showBluetooth }
        set { settings.showBluetooth = newValue }
    }

    var showAudio: Bool {
        get { settings.showAudio }
        set { settings.showAudio = newValue }
    }

    var showDND: Bool {
        get { settings.showDND }
        set { settings.showDND = newValue }
    }

    var showNowPlaying: Bool {
        get { settings.showNowPlaying }
        set { settings.showNowPlaying = newValue }
    }

    var worldClockCity1Raw: String {
        get { settings.worldClockCity1Raw }
        set { settings.worldClockCity1Raw = newValue }
    }

    var worldClockCity2Raw: String {
        get { settings.worldClockCity2Raw }
        set { settings.worldClockCity2Raw = newValue }
    }

    var worldClockCity3Raw: String {
        get { settings.worldClockCity3Raw }
        set { settings.worldClockCity3Raw = newValue }
    }

    var showPerformance: Bool {
        get { settings.showPerformance }
        set { settings.showPerformance = newValue }
    }

    var showNetworkSpeed: Bool {
        get { settings.showNetworkSpeed }
        set { settings.showNetworkSpeed = newValue }
    }

    var showCalendar: Bool {
        get { settings.showCalendar }
        set { settings.showCalendar = newValue }
    }

    var enablePomodoro: Bool {
        get { settings.enablePomodoro }
        set { settings.enablePomodoro = newValue }
    }

    var worldClockCities: [WorldClockCity] { settings.worldClockCities }

    func worldClockTimeString(for city: WorldClockCity) -> String {
        settings.worldClockTimeString(for: city, at: currentTime)
    }

    // MARK: - 带副作用的设置 setter（留门面）
    var showMenuBarIcon: Bool {
        get { settings.storedShowMenuBarIcon }
        set {
            settings.storedShowMenuBarIcon = newValue
            objectWillChange.send()
            onMenuBarIconVisibilityChange?(newValue)
        }
    }

    var triggerType: TriggerType {
        get {
            TriggerType(rawValue: settings.triggerTypeRaw) ?? .doubleCmd
        }
        set {
            // 互斥校验：与 AI 热键命中键冲突则拒绝（设置 UI 亦会提示，此处兜底）
            guard !newValue.conflicts(with: aiTriggerType) else {
                NSLog("[QuickShow] 主面板热键与 AI 热键冲突，已忽略变更：\(newValue.displayName)")
                objectWillChange.send()
                return
            }
            settings.triggerTypeRaw = newValue.rawValue
            objectWillChange.send()
            HotKeyManager.shared.configure(type: newValue, aiType: aiTriggerType)
        }
    }

    var aiTriggerType: TriggerType {
        get {
            TriggerType(rawValue: settings.aiTriggerTypeRaw) ?? .doubleOpt
        }
        set {
            guard !newValue.conflicts(with: triggerType) else {
                NSLog("[QuickShow] AI 热键与主面板热键冲突，已忽略变更：\(newValue.displayName)")
                objectWillChange.send()
                return
            }
            settings.aiTriggerTypeRaw = newValue.rawValue
            objectWillChange.send()
            HotKeyManager.shared.configure(type: triggerType, aiType: newValue)
        }
    }

    var appearanceMode: AppearanceMode {
        get {
            AppearanceMode(rawValue: settings.appearanceModeRaw) ?? .auto
        }
        set {
            settings.appearanceModeRaw = newValue.rawValue
            // 即时应用到全 App：NSApp.appearance 联动所有窗口的玻璃与语义色翻转，内容层零改动
            newValue.apply()
            objectWillChange.send()
        }
    }

    var themeVariant: ThemeVariant {
        get {
            ThemeVariant(rawValue: settings.themeVariantRaw) ?? .standard
        }
        set {
            settings.themeVariantRaw = newValue.rawValue
            // 写入 Theme 读取通道并触发全视图树 re-render（Theme.Colors 变体通道重新求值，即时生效）
            Theme.variant = newValue
            objectWillChange.send()
        }
    }

    var panelScaleOption: PanelScaleOption {
        get {
            PanelScaleOption(rawValue: settings.panelScaleOptionRaw) ?? .auto
        }
        set {
            settings.panelScaleOptionRaw = newValue.rawValue
            objectWillChange.send()
            onLayoutChange?()
        }
    }

    // MARK: - SystemStatusStore 转发
    var batteryInfo: BatteryInfo {
        get { status.batteryInfo }
        set { status.batteryInfo = newValue }
    }

    var wifiInfo: WiFiInfo {
        get { status.wifiInfo }
        set { status.wifiInfo = newValue }
    }

    var bluetoothDevices: [BluetoothDeviceInfo] {
        get { status.bluetoothDevices }
        set { status.bluetoothDevices = newValue }
    }

    var bluetoothDevice: BluetoothDeviceInfo? { status.bluetoothDevice }

    var audioInfo: AudioInfo {
        get { status.audioInfo }
        set { status.audioInfo = newValue }
    }

    var dndInfo: DNDInfo {
        get { status.dndInfo }
        set { status.dndInfo = newValue }
    }

    var diskInfo: DiskInfo {
        get { status.diskInfo }
        set { status.diskInfo = newValue }
    }

    var isKeepAwake: Bool {
        get { status.isKeepAwake }
        set { status.isKeepAwake = newValue }
    }

    func refreshAllSystemStatus() {
        status.refreshAll()
    }

    var isLocationAuthorized: Bool { status.isLocationAuthorized }

    func requestCalendarAccess(completion: @escaping (Bool) -> Void) {
        status.requestCalendarAccess(completion: completion)
    }

    func requestLocationAccess(completion: @escaping (Bool) -> Void) {
        status.requestLocationAccess(completion: completion)
    }

    // MARK: - MonitoringStore 转发
    var performanceInfo: SystemPerformanceInfo {
        get { monitoring.performanceInfo }
        set { monitoring.performanceInfo = newValue }
    }

    var trafficInfo: NetworkTrafficInfo {
        get { monitoring.trafficInfo }
        set { monitoring.trafficInfo = newValue }
    }

    var topCPUProcess: String? {
        get { monitoring.topCPUProcess }
        set { monitoring.topCPUProcess = newValue }
    }

    var networkLatency: Int? {
        get { monitoring.networkLatency }
        set { monitoring.networkLatency = newValue }
    }

    // MARK: - MediaStore 转发
    var nowPlayingInfo: NowPlayingInfo? {
        get { media.nowPlayingInfo }
        set { media.nowPlayingInfo = newValue }
    }

    var hasNowPlayingSession: Bool { media.hasNowPlayingSession }

    func mediaTogglePlayPause() { media.togglePlayPause() }
    func mediaPreviousTrack() { media.previousTrack() }
    func mediaNextTrack() { media.nextTrack() }
    func mediaSkipBackward() { media.skipBackward() }
    func mediaSkipForward() { media.skipForward() }
    func activateNowPlayingApp() { media.activateNowPlayingApp() }

    // MARK: - PomodoroStore 转发
    var pomodoroRunning: Bool {
        get { pomodoro.pomodoroRunning }
        set { pomodoro.pomodoroRunning = newValue }
    }

    var pomodoroRemainingSeconds: Int {
        get { pomodoro.pomodoroRemainingSeconds }
        set { pomodoro.pomodoroRemainingSeconds = newValue }
    }

    var pomodoroTodayCount: Int {
        get { pomodoro.pomodoroTodayCount }
        set { pomodoro.pomodoroTodayCount = newValue }
    }

    var pomodoroStreakDays: Int {
        get { pomodoro.pomodoroStreakDays }
        set { pomodoro.pomodoroStreakDays = newValue }
    }

    var formattedPomodoroTime: String { pomodoro.formattedPomodoroTime }

    // MARK: - CalendarStore 转发
    var calendarViewMode: CalendarViewMode {
        get { calendar.calendarViewMode }
        set { calendar.calendarViewMode = newValue }
    }

    var calendarAnchorDate: Date {
        get { calendar.calendarAnchorDate }
        set { calendar.calendarAnchorDate = newValue }
    }

    var selectedDate: Date {
        get { calendar.selectedDate }
        set { calendar.selectedDate = newValue }
    }

    var calendarGridCells: [CalendarDayCell] {
        get { calendar.calendarGridCells }
        set { calendar.calendarGridCells = newValue }
    }

    var dayEvents: [EKEvent] {
        get { calendar.dayEvents }
        set { calendar.dayEvents = newValue }
    }

    var selectedEvent: EKEvent? {
        get { calendar.selectedEvent }
        set { calendar.selectedEvent = newValue }
    }

    var calendarEditing: CalendarEditDraft? {
        get { calendar.calendarEditing }
        set { calendar.calendarEditing = newValue }
    }

    var calendarInfo: CalendarEventInfo {
        get { calendar.calendarInfo }
        set { calendar.calendarInfo = newValue }
    }

    var upcomingMeeting: UpcomingMeetingInfo? {
        get { calendar.upcomingMeeting }
        set { calendar.upcomingMeeting = newValue }
    }

    func setCalendarViewMode(_ mode: CalendarViewMode) { calendar.setCalendarViewMode(mode) }
    func calendarPageForward() { calendar.calendarPageForward() }
    func calendarPageBackward() { calendar.calendarPageBackward() }
    func calendarJumpToToday() { calendar.calendarJumpToToday() }
    func selectCalendarDate(_ date: Date) { calendar.selectCalendarDate(date) }
    func openEventEditor(for event: EKEvent?) { calendar.openEventEditor(for: event) }
    func cancelEventEditing() { calendar.cancelEventEditing() }
    func saveEventEditing() { calendar.saveEventEditing() }
    func deleteEditingEvent() { calendar.deleteEditingEvent() }
    func refreshCalendarData() { calendar.refreshCalendarData() }

    // 视图直接引用 AppState.gridDateRange，转发到 CalendarStore 静态方法
    static func gridDateRange(anchor: Date, mode: CalendarViewMode) -> (lowerBound: Date, upperBound: Date) {
        CalendarStore.gridDateRange(anchor: anchor, mode: mode)
    }

    static func gridStartDate(anchor: Date, mode: CalendarViewMode) -> Date? {
        CalendarStore.gridStartDate(anchor: anchor, mode: mode)
    }
}