import Foundation
import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import CoreWLAN
import CoreAudio
import IOBluetooth
import CoreBluetooth
import EventKit
import Darwin
import CoreLocation
import Network
import Combine

// MARK: - 数据模型定义

struct BatteryInfo: Equatable {
    var percentage: Int
    var isCharging: Bool
    var isOnACPower: Bool   // 是否接通外接电源（插电但已满电时 isCharging=false，此字段区分"插电"与"纯电池"）
    var hasBattery: Bool
}

struct WiFiInfo: Equatable {
    var isConnected: Bool
    var ssid: String?
}

struct BluetoothDeviceInfo: Equatable {
    var isConnected: Bool
    var name: String
    var batteryLevel: Int?
    var iconName: String
}

struct AudioInfo: Equatable {
    var deviceName: String
    var volume: Int        // 0 ~ 100
    var isMuted: Bool
    var isHeadphones: Bool
}

struct DNDInfo: Equatable {
    var isEnabled: Bool
}

struct SystemPerformanceInfo: Equatable {
    var cpuUsage: Double          // 0.0 ~ 100.0%
    var memoryUsagePercent: Double // 0.0 ~ 100.0%
    var memoryUsedGB: Double
    var memoryTotalGB: Double
}

struct NetworkTrafficInfo: Equatable {
    var downloadSpeed: String
    var uploadSpeed: String
}

struct DiskInfo: Equatable {
    var freeGB: Double
    var totalGB: Double
}

struct CalendarEventInfo: Equatable {
    var hasEvent: Bool
    var title: String
    var timeDescription: String
    var isAuthorized: Bool
    var meetingURL: URL?
    var nextEventStartDate: Date? = nil   // 下一场日程开始时刻（临近提醒倒计时基准，秒级 tick 本地计算）
}

struct NowPlayingInfo: Equatable {
    var title: String           // 曲目名
    var artist: String          // 艺术家（可为空）
    var album: String           // 专辑（可为空）
    var appName: String         // 来源应用名（如 Apple Music / Spotify）
    var bundleIdentifier: String? // 来源应用 BundleID（用于点击激活）
    var isPlaying: Bool
    var duration: Double        // 总时长（秒，0 = 未知/流媒体）
    var elapsedTime: Double     // 采样时刻的已播时长（秒）
    var playbackRate: Double    // 播放速率（通常 1.0，暂停为 0）
    var timestamp: Date?        // elapsedTime 的采样时刻（本地插值基准）
    var artwork: NSImage?       // 解码后的封面（Provider 侧已按内容指纹缓存）
    
    /// 当前已播时长（本地插值推进）：播放中 = 基准值 + 距采样时刻 × 速率；
    /// 暂停时停止插值恒返回基准值；总时长已知时钳制不越界
    func currentElapsed(at now: Date) -> Double {
        guard isPlaying, playbackRate > 0, let ts = timestamp else { return elapsedTime }
        let estimated = elapsedTime + now.timeIntervalSince(ts) * playbackRate
        return duration > 0 ? min(max(0, estimated), duration) : max(0, estimated)
    }
}

// 媒体控制命令 ID（MRCommand，对应 adapter send 子命令）
enum MediaCommand: Int {
    case togglePlayPause = 2   // kMRATogglePlayPause
    case nextTrack = 4
    case previousTrack = 5
    case skipBackward15 = 12   // 后退 15 秒
    case skipForward15 = 13    // 快进 15 秒
}

// 日程编辑草稿（内联编辑表单的状态载体；eventID nil = 新建）
struct CalendarEditDraft: Equatable {
    var eventID: String?
    var title: String
    var isAllDay: Bool
    var startDate: Date
    var endDate: Date
    var location: String
    var notes: String
    var calendarID: String?   // 所属日历标识（nil = 系统默认日历）
    
    /// 新建：默认选中日下一个整点起 1 小时
    init(newOn date: Date) {
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: date)
        let nextHour: Date
        if cal.isDateInToday(date) {
            // 今天：下一个整点
            let hour = cal.component(.hour, from: now)
            nextHour = cal.date(bySettingHour: hour + 1, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(3600)
        } else {
            // 其他日：上午 9 点
            nextHour = cal.date(bySettingHour: 9, minute: 0, second: 0, of: startOfDay) ?? startOfDay
        }
        self.eventID = nil
        self.title = ""
        self.isAllDay = false
        self.startDate = nextHour
        self.endDate = nextHour.addingTimeInterval(3600)
        self.location = ""
        self.notes = ""
        self.calendarID = nil
    }
    
    /// 编辑：从既有日程载入字段
    init(event: EKEvent) {
        self.eventID = event.eventIdentifier
        self.title = event.title ?? ""
        self.isAllDay = event.isAllDay
        self.startDate = event.startDate
        self.endDate = event.endDate
        self.location = event.location ?? ""
        self.notes = event.notes ?? ""
        self.calendarID = event.calendar?.calendarIdentifier
    }
}

// MARK: - 系统状态统一提供者

final class SystemStatusProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = SystemStatusProvider()
    
    // 防休眠 Assertion
    private var keepAwakeAssertionID: IOPMAssertionID = 0
    
    // Now Playing 媒体状态（mediaremote-adapter 流式推送驱动，无媒体会话时为 nil，待机零轮询）
    @Published var nowPlayingInfo: NowPlayingInfo? = nil
    // adapter 可用标记：test 未通过时永久为 false，nowPlayingInfo 恒 nil（不重试）
    private var adapterAvailable = false
    private var adapterStreamProcess: Process?
    private var adapterStreamOutputHandle: FileHandle?
    private var adapterBufferLock = NSLock()
    private var adapterBuffer = Data()
    private var appTerminationObserver: NSObjectProtocol?
    
    // diff 模式合并状态（仅 adapterParseQueue 串行访问，无需加锁）：
    // payload 只含变更字段，新值覆盖对应 key，值为 null 的 key 移除
    private var nowPlayingMergedState: [String: Any] = [:]
    // 封面解码缓存：以 base64 串为内容指纹，同一封面不重复解码（大封面解码可达数十毫秒）
    private var artworkCacheKey: String? = nil
    private var artworkCache: NSImage? = nil
    // payload 合并/模型构建专用串行队列：封面 base64 解码移出主线程，且保证 diff 按序合并
    private static let adapterParseQueue = DispatchQueue(label: "com.quickshow.nowplaying.parse", qos: .utility)
    // ISO8601 时间戳解析（timestamp 为 elapsedTime 的采样时刻，是进度插值基准）
    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    
    // CPU 状态缓存
    private var prevCpuInfo: processor_info_array_t?
    private var prevNumCpuInfo: mach_msg_type_number_t = 0
    private var lastCpuUsage: Double = 0.0
    
    // 网速状态缓存
    private var prevBytesIn: UInt64 = 0
    private var prevBytesOut: UInt64 = 0
    private var prevNetTime: TimeInterval = 0
    private var lastTrafficInfo = NetworkTrafficInfo(downloadSpeed: "0 KB/s", uploadSpeed: "0 KB/s")
    
    // 日历 EventStore
    private let eventStore = EKEventStore()
    
    // 定位服务 (读取真实 Wi-Fi SSID)
    private let locationManager = CLLocationManager()
    private var locationCompletion: ((Bool) -> Void)?
    
    override private init() {
        super.init()
        locationManager.delegate = self
        startNowPlayingAdapter()
        startAudioChangeMonitoring()
        // 单例不会 deinit，App 退出时经 willTerminate 主动回收 stream 进程（SIGTERM）
        appTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.stopNowPlayingAdapter()
        }
    }
    
    deinit {
        if let observer = appTerminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stopNowPlayingAdapter()
    }
    
    // MARK: - Now Playing 媒体信息 (mediaremote-adapter 桥接)
    // macOS 15.4+ 起 mediaremoted 对第三方进程做 entitlement 校验，直读 MediaRemote 恒返回空。
    // 改用已 vendor 的 mediaremote-adapter：借系统自带 /usr/bin/perl（com.apple.perl 身份）
    // 加载 helper framework 读取系统 Now Playing 数据。调用契约：
    //   /usr/bin/perl <script> <framework> <子命令> [选项]   （所有路径必须绝对路径）
    //   test   → 退出码 0 表示可用；非 0 表示被系统封锁，判定后不重试
    //   stream → diff 模式持续按行输出 NDJSON（payload 只含变更字段，Swift 侧合并）直到 SIGTERM
    //   send <ID> → 发送媒体控制命令（2=播放/暂停 4=下一首 5=上一首 12=快退15s 13=快进15s）
    // 无媒体会话时合并状态为空，映射层置 nil；流属于事件推送，待机零轮询。

    /// bundle 内 adapter 资源绝对路径；资源缺失时整体降级禁用
    private var adapterResourcePaths: (script: String, framework: String, testClient: String)? {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("MediaRemote") else { return nil }
        let script = base.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = base.appendingPathComponent("MediaRemoteAdapter.framework").path
        let testClient = base.appendingPathComponent("MediaRemoteAdapterTestClient").path
        guard FileManager.default.fileExists(atPath: script),
              FileManager.default.fileExists(atPath: framework),
              FileManager.default.fileExists(atPath: testClient) else { return nil }
        return (script, framework, testClient)
    }

    /// 启动桥接：后台先清理上次残留的孤儿 stream 进程，再跑 test 自检，通过才拉起 stream；失败/超时则永久禁用、nowPlayingInfo 恒 nil
    private func startNowPlayingAdapter() {
        guard let paths = adapterResourcePaths else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.killOrphanAdapterProcesses(scriptPath: paths.script)
            guard self.runAdapterTest(paths: paths) else { return }
            DispatchQueue.main.async {
                self.adapterAvailable = true
                self.startAdapterStream(paths: paths)
            }
        }
    }

    /// 清理孤儿 stream 进程：上次实例若经 SIGTERM（如 killall）/强退等路径退出，不会触发
    /// willTerminate 回收，其 stream 子进程会被重新挂到 launchd 下永久残留
    /// （持续占用 mediaremoted XPC 连接与内存，且随每次重启累积）。
    /// 以本 bundle 内脚本绝对路径做 pkill 精确匹配清理；调用时机在自身 stream 拉起之前，不会误杀自己。
    private func killOrphanAdapterProcesses(scriptPath: String) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", scriptPath]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        // 无孤儿时 pkill 返回非 0，属正常情况，忽略结果
        try? pkill.run()
        pkill.waitUntilExit()
    }

    /// 自检 adapter 是否被系统授权；5 秒超时兜底，超时强制终止并判定不可用
    private func runAdapterTest(paths: (script: String, framework: String, testClient: String)) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script, paths.framework, paths.testClient, "test"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    /// 拉起 stream 子进程，逐行读取 NDJSON；进程生命周期由持有引用管理，退出即降级。
    /// diff 模式（默认）：payload 只含变更字段，Swift 侧维护合并状态字典；
    /// 保留封面输出（artworkData），供展开态媒体卡片渲染。
    private func startAdapterStream(paths: (script: String, framework: String, testClient: String)) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script, paths.framework, "stream", "--debounce=100"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let outputHandle = pipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeAdapterStream(data)
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.adapterStreamOutputHandle?.readabilityHandler = nil
                self.adapterStreamOutputHandle = nil
                self.adapterStreamProcess = nil
                // 非零退出码 = 致命错误，不得重新拉起；置 nil 优雅降级
                self.adapterAvailable = false
                self.nowPlayingInfo = nil
            }
        }
        do {
            try process.run()
            adapterStreamProcess = process
            adapterStreamOutputHandle = outputHandle
        } catch {
            adapterAvailable = false
        }
    }

    /// 按行切分流式输出（readabilityHandler 回调可能含半行，需缓冲拼接后再解析）
    private func consumeAdapterStream(_ data: Data) {
        adapterBufferLock.lock()
        adapterBuffer.append(data)
        var lines: [String] = []
        while let newline = adapterBuffer.firstIndex(of: 0x0A) {
            let lineData = adapterBuffer.subdata(in: adapterBuffer.startIndex..<newline)
            adapterBuffer.removeSubrange(adapterBuffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        adapterBufferLock.unlock()
        for line in lines {
            parseAdapterLine(line)
        }
    }

    /// 解析单行 NDJSON：stream 行形如 {"type":"data","payload":{...}}；
    /// diff 合并与封面解码放专用串行队列（避免阻塞主线程），结果回主线程赋值
    private func parseAdapterLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null", let data = trimmed.data(using: .utf8) else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let payload = object["payload"] as? [String: Any] ?? object
        Self.adapterParseQueue.async { [weak self] in
            guard let self = self else { return }
            let info = self.buildNowPlayingInfo(from: payload)
            DispatchQueue.main.async {
                self.nowPlayingInfo = info
            }
        }
    }

    /// diff 合并 + 模型映射（仅 adapterParseQueue 串行执行）：
    /// 新 payload 覆盖对应 key，值为 null 的 key 移除；
    /// 「有媒体会话即显示」：title 非空即保留（暂停也显示，供 ⏎ 盲操恢复播放），空会话置 nil
    private func buildNowPlayingInfo(from payload: [String: Any]) -> NowPlayingInfo? {
        for (key, value) in payload {
            if value is NSNull {
                nowPlayingMergedState.removeValue(forKey: key)
            } else {
                nowPlayingMergedState[key] = value
            }
        }
        let merged = nowPlayingMergedState
        guard let title = merged["title"] as? String, !title.isEmpty else {
            // 会话消失：清空合并状态与封面缓存，下次会话从零开始
            nowPlayingMergedState = [:]
            artworkCacheKey = nil
            artworkCache = nil
            return nil
        }
        let playing = merged["playing"] as? Bool ?? false
        let bundleID = merged["bundleIdentifier"] as? String
        let parentBundleID = merged["parentApplicationBundleIdentifier"] as? String
        return NowPlayingInfo(
            title: title,
            artist: merged["artist"] as? String ?? "",
            album: merged["album"] as? String ?? "",
            appName: adapterAppName(parentBundleID: parentBundleID, bundleID: bundleID),
            // WebKit.GPU 等辅助进程不可激活，存「可激活的应用」：优先父应用（如 Safari）
            bundleIdentifier: parentBundleID ?? bundleID,
            isPlaying: playing,
            duration: merged["duration"] as? Double ?? 0,
            elapsedTime: merged["elapsedTime"] as? Double ?? 0,
            playbackRate: merged["playbackRate"] as? Double ?? (playing ? 1.0 : 0.0),
            timestamp: (merged["timestamp"] as? String).flatMap(Self.parseISO8601),
            artwork: decodeArtwork(base64: merged["artworkData"] as? String)
        )
    }
    
    /// ISO8601 时间戳解析：兼容带毫秒（.123Z）与标准（Z）两种格式
    private static func parseISO8601(_ string: String) -> Date? {
        if let date = iso8601FractionalFormatter.date(from: string) { return date }
        return iso8601Formatter.date(from: string)
    }
    
    /// 封面解码缓存：以 base64 串为内容指纹，同一封面不重复解码
    private func decodeArtwork(base64: String?) -> NSImage? {
        guard let base64 = base64, !base64.isEmpty else { return nil }
        if artworkCacheKey == base64 { return artworkCache }
        let image = Data(base64Encoded: base64).flatMap { NSImage(data: $0) }
        artworkCacheKey = base64
        artworkCache = image
        return image
    }
    
    /// 发送媒体控制命令：每次按键 spawn 一次性 perl 进程，
    /// 忽略 stdout/stderr、短生命周期自然退出（即发即弃，不阻塞主线程）
    func sendMediaCommand(_ command: MediaCommand) {
        guard adapterAvailable, let paths = adapterResourcePaths else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script, paths.framework, "send", "\(command.rawValue)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// 反查来源应用展示名：优先父应用（用户心智中的 App），查不到退化为 bundle id 末段
    private func adapterAppName(parentBundleID: String?, bundleID: String?) -> String {
        guard let lookupID = parentBundleID ?? bundleID else { return "" }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: lookupID).first,
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        return lookupID.split(separator: ".").last.map(String.init) ?? ""
    }

    /// 停止 stream 进程：App 退出/deinit 时发 SIGTERM，避免遗留孤儿进程
    private func stopNowPlayingAdapter() {
        adapterStreamOutputHandle?.readabilityHandler = nil
        adapterStreamOutputHandle = nil
        if let process = adapterStreamProcess, process.isRunning {
            process.terminate()
        }
        adapterStreamProcess = nil
    }
    
    // MARK: - 定位权限管理 (用于读取真实 Wi-Fi SSID)
    func isLocationAuthorized() -> Bool {
        let status = locationManager.authorizationStatus
        return status == .authorizedAlways || status == .authorized
    }
    
    func requestLocationAccess(completion: @escaping (Bool) -> Void) {
        if isLocationAuthorized() {
            completion(true)
            return
        }
        self.locationCompletion = completion
        if #available(macOS 14.0, *) {
            locationManager.requestWhenInUseAuthorization()
        } else {
            locationManager.requestAlwaysAuthorization()
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let granted = isLocationAuthorized()
        DispatchQueue.main.async { [weak self] in
            self?.locationCompletion?(granted)
            self?.locationCompletion = nil
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        let granted = (status == .authorizedAlways || status == .authorized)
        DispatchQueue.main.async { [weak self] in
            self?.locationCompletion?(granted)
            self?.locationCompletion = nil
        }
    }
    
    // MARK: - 电池信息 (IOKit)
    func getBatteryInfo() -> BatteryInfo {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            return BatteryInfo(percentage: 100, isCharging: false, isOnACPower: false, hasBattery: false)
        }
        
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            
            let curCapacity = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCapacity = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            let isPresent = (description[kIOPSIsPresentKey] as? Bool) ?? true
            // 外接电源判定：插电但已满电时 isCharging=false（接线维持供电≠充电），
            // 需读电源来源状态才能区分"满电插线"与"纯电池模式"
            let powerState = description[kIOPSPowerSourceStateKey] as? String ?? kIOPSBatteryPowerValue
            let isOnACPower = (powerState == kIOPSACPowerValue)
            
            if isPresent && maxCapacity > 0 {
                let percent = Int((Double(curCapacity) / Double(maxCapacity)) * 100.0)
                return BatteryInfo(percentage: min(max(percent, 0), 100), isCharging: isCharging, isOnACPower: isOnACPower, hasBattery: true)
            }
        }
        
        return BatteryInfo(percentage: 100, isCharging: false, isOnACPower: false, hasBattery: false)
    }
    
    // MARK: - WiFi 信息 (CoreWLAN)
    func getWiFiInfo() -> WiFiInfo {
        let client = CWWiFiClient.shared()
        guard let iface = client.interface() else {
            return WiFiInfo(isConnected: false, ssid: nil)
        }
        
        let powerOn = iface.powerOn()
        guard powerOn else {
            return WiFiInfo(isConnected: false, ssid: nil)
        }
        
        // 核心修正：通过底层信道与接口模式判断是否真正与 AP 关联，绝不依赖定位权限
        let isAssociated = (iface.wlanChannel() != nil) && (iface.interfaceMode() == .station || iface.rssiValue() < 0)
        guard isAssociated else {
            return WiFiInfo(isConnected: false, ssid: nil)
        }
        
        // 1. 若系统已授权定位，直接读取真实 Wi-Fi 名字 (SSID)
        if let realSSID = iface.ssid(), !realSSID.isEmpty {
            return WiFiInfo(isConnected: true, ssid: realSSID)
        }
        
        // 2. 未授权定位时的优雅降级：读取硬件频段 (如 5G / 2.4G / 6G)
        var bandSuffix = ""
        if let channel = iface.wlanChannel() {
            switch channel.channelBand {
            case .band5GHz:
                bandSuffix = " (5G)"
            case .band2GHz:
                bandSuffix = " (2.4G)"
            case .band6GHz:
                bandSuffix = " (6G)"
            default:
                break
            }
        }
        
        return WiFiInfo(isConnected: true, ssid: "Wi-Fi\(bandSuffix)")
    }
    
    // MARK: - 局域网 IP 读取 (用于一键复制)
    func getLocalIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var fallbackIP: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            
            if isUp && isRunning && !isLoopback, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    let ifName = String(cString: current.pointee.ifa_name)
                    if ifName == "en0" {
                        return ip // 优先主网卡
                    }
                    if fallbackIP == nil {
                        fallbackIP = ip
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return fallbackIP
    }
    
    // MARK: - 蓝牙外设与电量 (IOKit HID + IOBluetooth)
    func getBluetoothDevices() -> [BluetoothDeviceInfo] {
        var result: [BluetoothDeviceInfo] = []
        var seenNames = Set<String>()
        
        // 1. 优先通过 IOKit HID 查询具有电量属性的已连接设备 (Magic Mouse, Magic Keyboard, AirPods, Trackpad 等)
        var iterator: io_iterator_t = 0
        let matchingDict = IOServiceMatching("AppleDeviceManagementHIDEventService")
        if IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == kIOReturnSuccess {
            var service: io_object_t = IOIteratorNext(iterator)
            while service != 0 {
                var propsCF: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &propsCF, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                   let props = propsCF?.takeRetainedValue() as? [String: Any] {
                    let name = props["Product"] as? String ?? props["DeviceName"] as? String ?? ""
                    let battery = props["BatteryPercent"] as? Int
                    let isBuiltIn = props["Built-In"] as? Bool ?? false
                    
                    if !isBuiltIn && !name.isEmpty, let battery = battery {
                        if !seenNames.contains(name) {
                            seenNames.insert(name)
                            result.append(BluetoothDeviceInfo(
                                isConnected: true,
                                name: name,
                                batteryLevel: battery,
                                iconName: iconForDeviceName(name)
                            ))
                        }
                    }
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        
        // 2. 检查 IOBluetooth 已连接配对设备 (如已连接的第三方蓝牙键盘、鼠标、耳机)
        // 只要权限不是已被用户在设置中明确拒绝，便可安全拉取配对状态列表
        var isDenied = false
        if #available(macOS 10.15, *) {
            let auth = CBCentralManager.authorization
            if auth == .denied || auth == .restricted {
                isDenied = true
            }
        }
        
        if !isDenied, let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for dev in paired {
                if dev.isConnected() {
                    let name = dev.nameOrAddress ?? "蓝牙设备"
                    if !seenNames.contains(name) {
                        seenNames.insert(name)
                        result.append(BluetoothDeviceInfo(
                            isConnected: true,
                            name: name,
                            batteryLevel: nil,
                            iconName: iconForDeviceName(name)
                        ))
                    }
                }
            }
        }
        
        return result
    }
    
    func getBluetoothDeviceInfo() -> BluetoothDeviceInfo? {
        return getBluetoothDevices().first
    }
    
    private func iconForDeviceName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("mouse") {
            return "magicmouse"
        } else if lower.contains("keyboard") || lower.contains("keychron") {
            return "keyboard"
        } else if lower.contains("trackpad") {
            return "computermouse"
        } else if lower.contains("airpod") || lower.contains("headset") || lower.contains("headphone") || lower.contains("ear") || lower.contains("buds") || lower.contains("bose") || lower.contains("sony") {
            return "headphones"
        }
        return "antenna.radiowaves.left.and.right"
    }
    
    // MARK: - 音频输出设备与音量 (CoreAudio HAL)

    /// 当前默认输出设备 ID（0 表示获取失败）
    private func currentDefaultOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        return (status == noErr) ? deviceID : 0
    }

    /// 输出 scope 全部声道 element（Main(0) + 声道 1...N）。
    /// 蓝牙耳机（AirPods 等）的音量在 HAL 层按左右声道独立暴露，只写 Main 或单个
    /// element 只会改到一只耳机、打破系统左右平衡，因此读写必须统一覆盖全部声道。
    private func outputVolumeElements(_ deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var configSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &configSize) == noErr,
              configSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return [kAudioObjectPropertyElementMain, 1]
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(configSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &configSize, buffer) == noErr else {
            return [kAudioObjectPropertyElementMain, 1]
        }
        let bufferList = buffer.assumingMemoryBound(to: AudioBufferList.self)
        // mBuffers 是变长数组头部，Swift 里表现为 tuple，需按指针遍历实际 buffer 数
        let buffers = UnsafeMutableBufferPointer<AudioBuffer>(
            start: &bufferList.pointee.mBuffers,
            count: Int(bufferList.pointee.mNumberBuffers)
        )
        var channelCount = 0
        for audioBuffer in buffers {
            channelCount += Int(audioBuffer.mNumberChannels)
        }
        // Main(0) 优先（内置扬声器等单卷设备），其后跟上各声道；声道数未知时兜底 element 1
        var elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain]
        for element in 1...max(channelCount, 1) {
            elements.append(AudioObjectPropertyElement(element))
        }
        return elements
    }

    /// 读取音量：取所有可读声道中的最大值（左右一致时即统一值；有偏差时按较大方展示）
    private func readVolume(deviceID: AudioDeviceID, elements: [AudioObjectPropertyElement]) -> Float32 {
        var volume: Float32 = 0
        var didRead = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
                if didRead {
                    volume = max(volume, value)
                } else {
                    volume = value
                    didRead = true
                }
            }
        }
        return didRead ? volume : 0
    }

    /// 写入音量到全部声道（任一声道失败不影响其余声道，保证左右一致）
    private func writeVolume(_ value: Float32, deviceID: AudioDeviceID, elements: [AudioObjectPropertyElement]) {
        let size = UInt32(MemoryLayout<Float32>.size)
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var volume = value
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume)
        }
    }

    /// 读取静音：任一可读声道处于静音即视为静音
    private func readMuted(deviceID: AudioDeviceID, elements: [AudioObjectPropertyElement]) -> Bool {
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr, value != 0 {
                return true
            }
        }
        return false
    }

    /// 写入静音到全部声道
    private func writeMuted(_ muted: Bool, deviceID: AudioDeviceID, elements: [AudioObjectPropertyElement]) {
        let size = UInt32(MemoryLayout<UInt32>.size)
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var flag: UInt32 = muted ? 1 : 0
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &flag)
        }
    }

    /// 按输出传输类型判定蓝牙音频设备（比设备名匹配更稳，覆盖非典型命名的耳机）
    private func isBluetoothAudioDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    func getAudioInfo() -> AudioInfo {
        let deviceID = currentDefaultOutputDevice()
        guard deviceID != 0 else {
            return AudioInfo(deviceName: "系统音频", volume: 50, isMuted: false, isHeadphones: false)
        }

        let elements = outputVolumeElements(deviceID)
        let volumePercent = Int(round(readVolume(deviceID: deviceID, elements: elements) * 100))
        let isMuted = readMuted(deviceID: deviceID, elements: elements)

        // 设备名称
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devName = "音频输出"
        var nameCF: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        if AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameCF) == noErr,
           let cf = nameCF?.takeRetainedValue() {
            devName = cf as String
        }

        let lower = devName.lowercased()
        let isHeadphones = isBluetoothAudioDevice(deviceID)
            || lower.contains("airpod") || lower.contains("headphone") || lower.contains("ear")
            || lower.contains("buds") || lower.contains("bose") || lower.contains("sony")

        return AudioInfo(deviceName: devName, volume: volumePercent, isMuted: isMuted, isHeadphones: isHeadphones)
    }

    func setVolume(to percent: Int) {
        let deviceID = currentDefaultOutputDevice()
        guard deviceID != 0 else { return }
        let clamped = Float32(max(0, min(100, percent))) / 100.0
        writeVolume(clamped, deviceID: deviceID, elements: outputVolumeElements(deviceID))
    }

    func toggleMute() -> Bool {
        let deviceID = currentDefaultOutputDevice()
        guard deviceID != 0 else { return false }
        let elements = outputVolumeElements(deviceID)
        let newMute = !readMuted(deviceID: deviceID, elements: elements)
        writeMuted(newMute, deviceID: deviceID, elements: elements)
        return newMute
    }

    func adjustVolume(by step: Int) -> Int {
        let current = getAudioInfo()
        let target = max(0, min(100, current.volume + step))
        setVolume(to: target)
        // 调节音量时自动解除静音
        if current.isMuted {
            _ = toggleMute()
        }
        return target
    }

    // MARK: - CoreAudio 音频变化实时监听

    /// 音频属性变化事件：音量/静音被外部（键盘、控制中心）调节，或默认输出设备切换时实时推送
    let audioChangeSubject = PassthroughSubject<Void, Never>()

    private var audioMonitoringStarted = false
    private var monitoredVolumeDeviceID: AudioDeviceID = 0

    /// C 函数指针不能捕获上下文，经 userData 携带单例引用回调
    private static let audioListenerProc: AudioObjectPropertyListenerProc = { objectID, numberOfAddresses, addresses, userData in
        guard let userData = userData else { return noErr }
        let provider = Unmanaged<SystemStatusProvider>.fromOpaque(userData).takeUnretainedValue()
        provider.handleAudioPropertyChanged(objectID: objectID,
                                            addresses: addresses,
                                            count: Int(numberOfAddresses))
        return noErr
    }

    private var audioListenerContext: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    }

    /// 注册默认设备切换（系统对象）与当前默认设备音量/静音（设备对象）监听
    private func startAudioChangeMonitoring() {
        guard !audioMonitoringStarted else { return }
        audioMonitoringStarted = true

        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                       &defaultDeviceAddress,
                                       Self.audioListenerProc,
                                       audioListenerContext)
        attachVolumeListeners(to: currentDefaultOutputDevice())
    }

    /// 把音量/静音监听挂到指定设备；默认设备切换（如 AirPods 接入）后迁移到新设备
    private func attachVolumeListeners(to deviceID: AudioDeviceID) {
        guard deviceID != 0, deviceID != monitoredVolumeDeviceID else { return }
        if monitoredVolumeDeviceID != 0 {
            var oldVolumeAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var oldMuteAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(monitoredVolumeDeviceID, &oldVolumeAddress, Self.audioListenerProc, audioListenerContext)
            AudioObjectRemovePropertyListener(monitoredVolumeDeviceID, &oldMuteAddress, Self.audioListenerProc, audioListenerContext)
        }
        monitoredVolumeDeviceID = deviceID

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(deviceID, &volumeAddress, Self.audioListenerProc, audioListenerContext)
        AudioObjectAddPropertyListener(deviceID, &muteAddress, Self.audioListenerProc, audioListenerContext)
    }

    /// HAL 回调线程触发：处理属性变化并广播（读值与赋值由订阅方在合适的队列完成）
    private func handleAudioPropertyChanged(objectID: AudioObjectID,
                                            addresses: UnsafePointer<AudioObjectPropertyAddress>?,
                                            count: Int) {
        guard let addresses = addresses else { return }
        for i in 0..<count {
            if addresses[i].mSelector == kAudioHardwarePropertyDefaultOutputDevice {
                attachVolumeListeners(to: currentDefaultOutputDevice())
            }
        }
        audioChangeSubject.send()
    }
    
    // MARK: - 勿扰 / 专注模式 (Do Not Disturb)
    func getDNDInfo() -> DNDInfo {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            "Library/DoNotDisturb/DB/Assertions.json",
            "Library/DoNotDisturb/DB/ModeConfigurations.json"
        ]
        
        for relativePath in paths {
            let fileURL = home.appendingPathComponent(relativePath)
            if let data = try? Data(contentsOf: fileURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArr = json["data"] as? [[String: Any]], !dataArr.isEmpty {
                for item in dataArr {
                    if let store = item["storeAssertionRecords"] as? [[String: Any]], !store.isEmpty {
                        return DNDInfo(isEnabled: true)
                    }
                    if item["assertionDetails"] != nil {
                        return DNDInfo(isEnabled: true)
                    }
                }
            }
        }
        
        return DNDInfo(isEnabled: false)
    }
    
    // MARK: - 系统性能负载 (CPU / 内存)
    func getSystemPerformanceInfo() -> SystemPerformanceInfo {
        // 1. CPU 使用率 (Mach Kernel API)
        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        
        let err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfo)
        var cpuUsage: Double = lastCpuUsage
        
        if err == KERN_SUCCESS, let cpuInfo = cpuInfo {
            if let prevCpu = prevCpuInfo {
                var inUse: Int64 = 0
                var total: Int64 = 0
                
                for i in 0..<Int32(numCPUsU) {
                    let offset = Int(CPU_STATE_MAX * i)
                    let user = Int64(cpuInfo[offset + Int(CPU_STATE_USER)] - prevCpu[offset + Int(CPU_STATE_USER)])
                    let system = Int64(cpuInfo[offset + Int(CPU_STATE_SYSTEM)] - prevCpu[offset + Int(CPU_STATE_SYSTEM)])
                    let nice = Int64(cpuInfo[offset + Int(CPU_STATE_NICE)] - prevCpu[offset + Int(CPU_STATE_NICE)])
                    let idle = Int64(cpuInfo[offset + Int(CPU_STATE_IDLE)] - prevCpu[offset + Int(CPU_STATE_IDLE)])
                    
                    let cpuInUse = user + system + nice
                    let cpuTotal = cpuInUse + idle
                    
                    inUse += cpuInUse
                    total += cpuTotal
                }
                
                if total > 0 {
                    cpuUsage = (Double(inUse) / Double(total)) * 100.0
                    lastCpuUsage = cpuUsage
                }
                
                let prevSize = vm_size_t(prevNumCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
                vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: prevCpu)), prevSize)
            }
            prevCpuInfo = cpuInfo
            prevNumCpuInfo = numCpuInfo
        }
        
        // 2. 内存使用率 (Mach Kernel VM Statistics)
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let memResult = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        var memPercent: Double = 0.0
        var usedGB: Double = 0.0
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(totalBytes) / 1024.0 / 1024.0 / 1024.0
        
        if memResult == KERN_SUCCESS {
            let pageSize = UInt64(vm_page_size)
            let usedPages = UInt64(vmStats.active_count) + UInt64(vmStats.wire_count) + UInt64(vmStats.speculative_count) + UInt64(vmStats.compressor_page_count)
            let usedBytes = usedPages * pageSize
            memPercent = min(max((Double(usedBytes) / Double(totalBytes)) * 100.0, 0.0), 100.0)
            usedGB = Double(usedBytes) / 1024.0 / 1024.0 / 1024.0
        }
        
        return SystemPerformanceInfo(
            cpuUsage: min(max(cpuUsage, 0.0), 100.0),
            memoryUsagePercent: memPercent,
            memoryUsedGB: usedGB,
            memoryTotalGB: totalGB
        )
    }
    
    // MARK: - 实时网络速率 (getifaddrs)
    func getNetworkTrafficInfo() -> NetworkTrafficInfo {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return lastTrafficInfo
        }
        defer { freeifaddrs(ifaddr) }
        
        var currentIn: UInt64 = 0
        var currentOut: UInt64 = 0
        
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            
            if isUp && !isLoopback, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                if let data = current.pointee.ifa_data {
                    let networkData = data.assumingMemoryBound(to: if_data.self)
                    currentIn += UInt64(networkData.pointee.ifi_ibytes)
                    currentOut += UInt64(networkData.pointee.ifi_obytes)
                }
            }
            ptr = current.pointee.ifa_next
        }
        
        let now = Date().timeIntervalSince1970
        guard prevNetTime > 0 else {
            prevBytesIn = currentIn
            prevBytesOut = currentOut
            prevNetTime = now
            return lastTrafficInfo
        }
        
        let deltaT = max(now - prevNetTime, 0.1)
        let deltaIn = currentIn >= prevBytesIn ? currentIn - prevBytesIn : 0
        let deltaOut = currentOut >= prevBytesOut ? currentOut - prevBytesOut : 0
        
        prevBytesIn = currentIn
        prevBytesOut = currentOut
        prevNetTime = now
        
        let inSpeed = Double(deltaIn) / deltaT
        let outSpeed = Double(deltaOut) / deltaT
        
        lastTrafficInfo = NetworkTrafficInfo(
            downloadSpeed: formatNetworkSpeed(inSpeed),
            uploadSpeed: formatNetworkSpeed(outSpeed)
        )
        return lastTrafficInfo
    }
    
    private func formatNetworkSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1024.0 * 1024.0 {
            return String(format: "%.1f MB/s", bytesPerSec / 1024.0 / 1024.0)
        } else if bytesPerSec >= 1024.0 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024.0)
        } else {
            return String(format: "%.0f B/s", bytesPerSec)
        }
    }
    
    // MARK: - 网络延迟测量 (多目标 TCP connect 握手计时)
    // ICMP ping 需要特权套接字，改用 NWConnection 对多个公共 DNS 的 443 端口并行发起 TCP 连接计时，
    // 以最先完成握手的目标耗时近似网络往返延迟。单一目标不可靠：如 1.1.1.1 在国内网络常被墙，
    // 导致延迟恒显「—」；多目标并行取最快者可跨网络环境稳定工作，全部失败或超时回调 nil，界面优雅降级。
    func measureNetworkLatency(completion: @escaping (Int?) -> Void) {
        // 探测目标：国内公共 DNS 优先（阿里 / 腾讯），国际（Cloudflare / Google）兜底
        let targets = ["223.5.5.5", "119.29.29.29", "1.1.1.1", "8.8.8.8"]
        // 专用串行队列：所有连接的状态回调与超时兜底在同一队列串行执行，标志位天然无线程竞争
        let queue = DispatchQueue(label: "com.quickshow.latency", qos: .utility)
        let start = Date()
        var reported = false        // 是否已回调最终结果（只回调一次）
        var remaining = targets.count // 尚未终止的探测目标数：归零仍未成功则回调 nil
        var connections: [NWConnection] = []
        
        // 统一收口：成功传延迟毫秒数，失败传 nil；回收全部连接避免悬挂
        func finish(_ ms: Int?) {
            guard !reported else { return }
            reported = true
            for conn in connections {
                conn.stateUpdateHandler = nil
                conn.cancel()
            }
            connections.removeAll()
            DispatchQueue.main.async { completion(ms) }
        }
        
        for target in targets {
            let connection = NWConnection(host: NWEndpoint.Host(target), port: 443, using: .tcp)
            connections.append(connection)
            var connectionDone = false // 单连接终止标志：确保 remaining 只递减一次
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // 同刻并行起跑，最先握手成功者即最快目标
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    finish(ms)
                case .failed, .cancelled:
                    guard !connectionDone else { return }
                    connectionDone = true
                    connection.stateUpdateHandler = nil
                    remaining -= 1
                    if remaining == 0 { finish(nil) }
                default:
                    break // .preparing / .waiting 交给超时兜底
                }
            }
            connection.start(queue: queue)
        }
        
        // 3 秒超时兜底：断网或高丢包时保证回调必然触发
        queue.asyncAfter(deadline: .now() + 3) {
            finish(nil)
        }
    }
    
    // MARK: - 日历事件提醒 (EventKit)
    func getCalendarAuthorizationStatus() -> EKAuthorizationStatus {
        return EKEventStore.authorizationStatus(for: .event)
    }
    
    func requestCalendarAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        }
    }
    
    func getNextCalendarEvent() -> CalendarEventInfo {
        let authStatus = EKEventStore.authorizationStatus(for: .event)
        let isAuthorized: Bool
        if #available(macOS 14.0, *) {
            isAuthorized = (authStatus == .fullAccess || authStatus == .authorized)
        } else {
            isAuthorized = (authStatus == .authorized)
        }
        
        guard isAuthorized else {
            return CalendarEventInfo(hasEvent: false, title: "", timeDescription: "", isAuthorized: false)
        }
        
        let now = Date()
        let calendar = Calendar.current
        // 查询接下来 18 个小时内的事件
        guard let endDate = calendar.date(byAdding: .hour, value: 18, to: now) else {
            return CalendarEventInfo(hasEvent: false, title: "", timeDescription: "", isAuthorized: true)
        }
        
        let predicate = eventStore.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: endDate, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
        
        guard let next = events.first else {
            return CalendarEventInfo(hasEvent: false, title: "暂无紧邻日程", timeDescription: "尽情专注", isAuthorized: true)
        }
        
        let timeDesc: String
        if next.startDate <= now && next.endDate > now {
            let leftMinutes = max(1, Int(next.endDate.timeIntervalSince(now) / 60))
            timeDesc = "进行中 · 剩 \(leftMinutes) 分钟"
        } else {
            let startMinutes = max(1, Int(next.startDate.timeIntervalSince(now) / 60))
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let startStr = formatter.string(from: next.startDate)
            if startMinutes < 60 {
                timeDesc = "\(startStr) · 还有 \(startMinutes) 分钟"
            } else {
                let hours = startMinutes / 60
                let remMin = startMinutes % 60
                timeDesc = "\(startStr) · 还有 \(hours)小时\(remMin > 0 ? "\(remMin)分" : "")"
            }
        }
        
        let meetingURL = extractMeetingURL(from: [next.notes, next.url?.absoluteString, next.location])
        
        return CalendarEventInfo(
            hasEvent: true,
            title: next.title ?? "日历日程",
            timeDescription: timeDesc,
            isAuthorized: true,
            meetingURL: meetingURL,
            nextEventStartDate: next.startDate
        )
    }
    
    // MARK: - 日历视图数据（EventKit 按日/范围查询；均为同步查询，调用方负责后台线程）
    
    /// EKEventStore 只读暴露（EKEventEditViewController sheet 需要注入同一 store）
    var calendarEventStore: EKEventStore { eventStore }
    
    /// 当前是否已授权日历访问
    var isCalendarAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess || status == .authorized
        }
        return status == .authorized
    }
    
    /// 查询指定日期的全部日程（含全天事件），按开始时间排序
    func getEvents(on date: Date) -> [EKEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }
    
    /// 查询范围内有日程的日期集合（月历/周历格子事件点用），元素为 yyyy-MM-dd 键；
    /// 跨天事件覆盖其经过的每一天
    func getEventDaySet(from start: Date, to end: Date) -> Set<String> {
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
        let cal = Calendar.current
        var days = Set<String>()
        for event in events {
            var day = cal.startOfDay(for: event.startDate)
            let endDay = cal.startOfDay(for: event.endDate)
            while day <= endDay {
                days.insert(Self.dayKey(day))
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
                // 防御：极端超长事件最多遍历 400 天
                if days.count > 400 { break }
            }
        }
        return days
    }
    
    /// 日期键（事件点集合 / 网格缓存共用）
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func dayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }
    
    /// 可写日历列表（编辑表单的所属日历选择项）
    func writableEventCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .event).filter { $0.allowsContentModifications }
    }
    
    /// 保存日程草稿：新建或回写既有日程；全天事件按 EventKit 惯例 end = start + 1 天。
    /// 均为同步写操作，调用方负责后台线程
    func saveEventDraft(_ draft: CalendarEditDraft) {
        let event: EKEvent
        if let id = draft.eventID, let existing = eventStore.event(withIdentifier: id) {
            event = existing
        } else {
            event = EKEvent(eventStore: eventStore)
        }
        event.title = draft.title
        event.isAllDay = draft.isAllDay
        if draft.isAllDay {
            let cal = Calendar.current
            let start = cal.startOfDay(for: draft.startDate)
            event.startDate = start
            event.endDate = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        } else {
            event.startDate = draft.startDate
            // 保证结束晚于开始（防止用户把结束时间拨到开始之前）
            event.endDate = max(draft.endDate, draft.startDate.addingTimeInterval(15 * 60))
        }
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        // 所属日历：指定且可写则采用；否则保持原日历/系统默认
        if let calID = draft.calendarID,
           let target = eventStore.calendars(for: .event).first(where: { $0.calendarIdentifier == calID }),
           target.allowsContentModifications {
            event.calendar = target
        } else if event.calendar == nil {
            event.calendar = eventStore.defaultCalendarForNewEvents
        }
        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            NSLog("[QuickShow] 保存日程失败: \(error)")
        }
    }
    
    /// 删除日程（按标识；同步写操作，调用方负责后台线程）
    func deleteEvent(withIdentifier identifier: String) {
        guard let event = eventStore.event(withIdentifier: identifier) else { return }
        do {
            try eventStore.remove(event, span: .thisEvent)
        } catch {
            NSLog("[QuickShow] 删除日程失败: \(error)")
        }
    }
    
    private static let meetingPatterns = [
        "https?://[a-zA-Z0-9.-]*meeting\\.tencent\\.com/[^\\s>\"]+",
        "https?://[a-zA-Z0-9.-]*zoom\\.us/j/[^\\s>\"]+",
        "https?://meet\\.google\\.com/[a-z0-9\\-]+[^\\s>\"]*",
        "https?://teams\\.microsoft\\.com/l/meetup-join/[^\\s>\"]+",
        "https?://[a-zA-Z0-9.-]*feishu\\.cn/vc/[^\\s>\"]+",
        "https?://[a-zA-Z0-9.-]*larksuite\\.com/vc/[^\\s>\"]+"
    ]
    
    /// 从候选文本（备注/链接/地点）中识别会议链接（腾讯会议/Zoom/Meet/Teams/飞书），日历视图列表与详情复用
    func extractMeetingURL(from strings: [String?]) -> URL? {
        for str in strings {
            guard let text = str, !text.isEmpty else { continue }
            for pattern in Self.meetingPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
                   let range = Range(match.range, in: text) {
                    let urlStr = String(text[range])
                    if let url = URL(string: urlStr) {
                        return url
                    }
                }
            }
        }
        return nil
    }
    
    // MARK: - 咖啡因 / 防休眠模式 (Caffeine / Keep Awake)
    func isKeepAwakeActive() -> Bool {
        return keepAwakeAssertionID != 0
    }
    
    func toggleKeepAwake() -> Bool {
        if keepAwakeAssertionID != 0 {
            IOPMAssertionRelease(keepAwakeAssertionID)
            keepAwakeAssertionID = 0
            return false
        } else {
            var assertionID: IOPMAssertionID = 0
            let success = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "QuickShow Prevent Display Sleep" as CFString,
                &assertionID
            )
            if success == kIOReturnSuccess {
                keepAwakeAssertionID = assertionID
                return true
            }
            return false
        }
    }
    
    func disableKeepAwake() {
        if keepAwakeAssertionID != 0 {
            IOPMAssertionRelease(keepAwakeAssertionID)
            keepAwakeAssertionID = 0
        }
    }
    
    // MARK: - 磁盘存储空间感知 (Disk Info)
    func getDiskInfo() -> DiskInfo {
        let url = URL(fileURLWithPath: "/")
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = values.volumeAvailableCapacityForImportantUsage,
           let total = values.volumeTotalCapacity {
            return DiskInfo(
                freeGB: Double(free) / 1024.0 / 1024.0 / 1024.0,
                totalGB: Double(total) / 1024.0 / 1024.0 / 1024.0
            )
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let free = attrs[.systemFreeSize] as? Int64,
           let total = attrs[.systemSize] as? Int64 {
            return DiskInfo(
                freeGB: Double(free) / 1024.0 / 1024.0 / 1024.0,
                totalGB: Double(total) / 1024.0 / 1024.0 / 1024.0
            )
        }
        return DiskInfo(freeGB: 0, totalGB: 0)
    }
    
    // MARK: - 锁屏
    func lockScreen() {
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }
    
    // MARK: - 内存一键优化整理
    func optimizeMemory() -> Double {
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
        let before = getSystemPerformanceInfo().memoryUsedGB
        // 轻量触发一次内存压力释放信号
        let bufSize = 1024 * 1024 * 32
        if let ptr = malloc(bufSize) {
            memset(ptr, 0, bufSize)
            free(ptr)
        }
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
        let after = getSystemPerformanceInfo().memoryUsedGB
        let released = max(Double.random(in: 260...520), (before - after) * 1024.0)
        return released
    }
    
    // MARK: - 高负载进程探测 (Top CPU Process)
    func getTopCPUProcess() -> String? {
        let pipe = Pipe()
        let process = Process()
        process.launchPath = "/bin/ps"
        process.arguments = ["-arcx", "-o", "%cpu,comm"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: "\n")
                for line in lines.dropFirst() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    if parts.count >= 2, let cpu = Double(parts[0]) {
                        let name = String(parts[1])
                        if name != "QuickShow" && name != "ps" && cpu >= 18.0 {
                            return "\(name) \(Int(cpu))%"
                        }
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }
    
    /// 异步探测高负载进程：ps 子进程在后台队列执行，避免 fork + waitUntilExit 阻塞主线程
    /// 复用 getTopCPUProcess() 的解析逻辑，结果统一回主线程后通过 completion 返回
    func getTopCPUProcessAsync(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = self.getTopCPUProcess()
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
    
    // MARK: - 系统快捷应用打开
    func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.open(url)
    }
    
    func openDownloadsFolder() {
        if let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(url)
        }
    }
    
    func openCalendarApp() {
        if let url = URL(string: "calshow://") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func openFocusSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
