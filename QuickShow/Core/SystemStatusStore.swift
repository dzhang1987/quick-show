import SwiftUI
import Combine
import Foundation

// MARK: - 系统状态域
/// 5 个微标镜像（电池/WiFi/蓝牙/音频/勿扰）+ 磁盘 + 防休眠 + refreshAll/refreshBadges 管线
/// + CoreAudio audioChange 订阅 + 日历/定位授权请求。
/// 相位常量逐字搬运：badges count%5==0。
final class SystemStatusStore: ObservableObject {
    // 核心微状态（一瞥底栏）
    @Published var batteryInfo: BatteryInfo = BatteryInfo(percentage: 100, isCharging: false, isOnACPower: false, hasBattery: false)
    @Published var wifiInfo: WiFiInfo = WiFiInfo(isConnected: false, ssid: nil)
    @Published var bluetoothDevices: [BluetoothDeviceInfo] = []
    var bluetoothDevice: BluetoothDeviceInfo? { bluetoothDevices.first }
    @Published var audioInfo: AudioInfo = AudioInfo(deviceName: "系统音频", volume: 50, isMuted: false, isHeadphones: false)
    @Published var dndInfo: DNDInfo = DNDInfo(isEnabled: false)

    @Published var diskInfo: DiskInfo = DiskInfo(freeGB: 0, totalGB: 0)
    @Published var isKeepAwake: Bool = false

    // CoreAudio 属性监听订阅（外部调音量/切换默认输出设备时实时同步 audioInfo）
    private var audioChangeCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private weak var facade: AppState?

    /// CoreAudio 属性监听：键盘/控制中心等外部调音量、切换默认输出设备（AirPods 接入）时
    /// 实时同步音量状态；HAL 事件高频触发，先在主线程节流再去后台队列读值。
    /// （facade init 调用一次，对齐原 init 顺序）
    func configure(facade: AppState) {
        self.facade = facade
        audioChangeCancellable = SystemStatusProvider.shared.audioChangeSubject
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self, weak facade] _ in
                guard let self, let facade, facade.showAudio else { return }
                BackgroundQueues.statusRefresh.async {
                    let info = SystemStatusProvider.shared.getAudioInfo()
                    DispatchQueue.main.async {
                        self.audioInfo = info
                    }
                }
            }
    }

    /// 订阅主时钟：状态栏每 5 秒做一次静默微更新。
    func attach(tick: AnyPublisher<AppTick, Never>, facade: AppState) {
        self.facade = facade
        tick.sink { [weak self, weak facade] tick in
            guard let self, let facade else { return }
            if tick.count % 5 == 0 {
                self.refreshBadges(facade: facade)
            }
        }.store(in: &cancellables)
    }

    // MARK: - 系统状态刷新

    /// 刷新全部系统状态：查询在内部后台队列执行，结果统一回主线程赋值 @Published 状态。
    /// 调用方（init / show）同步返回，无需感知异步细节，主线程不再被系统查询阻塞。
    func refreshAll() {
        guard let facade else { return }
        // 在主线程同步快照展示开关，避免后台读取 @AppStorage / @Published 产生线程问题
        let perfVisible = facade.showPerformance || facade.isExpanded
        let networkVisible = facade.showNetworkSpeed || facade.isExpanded
        let wantBattery = facade.showBattery
        let wantWiFi = facade.showWiFi
        let wantBluetooth = facade.showBluetooth
        let wantAudio = facade.showAudio
        let wantDND = facade.showDND
        let wantCalendar = facade.showCalendar

        BackgroundQueues.statusRefresh.async { [weak self, weak facade] in
            guard let self, let facade else { return }

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
                if let performance = performance { facade.monitoring.performanceInfo = performance }
                if let traffic = traffic { facade.monitoring.trafficInfo = traffic }
                if let calendar = calendar { facade.calendar.calendarInfo = calendar }
            }

            // ps 高负载进程探测本身已异步（内部回主线程），保持原逻辑
            if perfVisible {
                SystemStatusProvider.shared.getTopCPUProcessAsync { [weak facade] result in
                    facade?.monitoring.topCPUProcess = result
                }
            }
        }
    }

    private func refreshBadges(facade: AppState) {
        if facade.showBattery {
            batteryInfo = SystemStatusProvider.shared.getBatteryInfo()
        }
        if facade.showWiFi {
            wifiInfo = SystemStatusProvider.shared.getWiFiInfo()
        }
        if facade.showBluetooth {
            bluetoothDevices = SystemStatusProvider.shared.getBluetoothDevices()
        } else {
            bluetoothDevices = []
        }
        if facade.showAudio {
            audioInfo = SystemStatusProvider.shared.getAudioInfo()
        }
        if facade.showDND {
            dndInfo = SystemStatusProvider.shared.getDNDInfo()
        }
    }

    // MARK: - 授权请求

    func requestCalendarAccess(completion: @escaping (Bool) -> Void) {
        SystemStatusProvider.shared.requestCalendarAccess { [weak facade] granted in
            if granted, let facade {
                facade.calendar.calendarInfo = SystemStatusProvider.shared.getNextCalendarEvent()
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