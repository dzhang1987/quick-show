import Foundation
import IOKit.ps
import CoreWLAN
import CoreAudio
import IOBluetooth
import CoreBluetooth
import EventKit
import Darwin

// MARK: - 数据模型定义

struct BatteryInfo: Equatable {
    var percentage: Int
    var isCharging: Bool
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

struct CalendarEventInfo: Equatable {
    var hasEvent: Bool
    var title: String
    var timeDescription: String
    var isAuthorized: Bool
}

// MARK: - 系统状态统一提供者

final class SystemStatusProvider {
    static let shared = SystemStatusProvider()
    
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
    
    private init() {}
    
    // MARK: - 电池信息 (IOKit)
    func getBatteryInfo() -> BatteryInfo {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            return BatteryInfo(percentage: 100, isCharging: false, hasBattery: false)
        }
        
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            
            let curCapacity = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCapacity = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            let isPresent = (description[kIOPSIsPresentKey] as? Bool) ?? true
            
            if isPresent && maxCapacity > 0 {
                let percent = Int((Double(curCapacity) / Double(maxCapacity)) * 100.0)
                return BatteryInfo(percentage: min(max(percent, 0), 100), isCharging: isCharging, hasBattery: true)
            }
        }
        
        return BatteryInfo(percentage: 100, isCharging: false, hasBattery: false)
    }
    
    // MARK: - WiFi 信息 (CoreWLAN)
    func getWiFiInfo() -> WiFiInfo {
        let client = CWWiFiClient.shared()
        guard let iface = client.interface() else {
            return WiFiInfo(isConnected: false, ssid: nil)
        }
        
        let powerOn = iface.powerOn()
        let ssid = iface.ssid()
        
        return WiFiInfo(isConnected: powerOn && ssid != nil, ssid: ssid)
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
    func getAudioInfo() -> AudioInfo {
        var defaultOutputDeviceID = AudioDeviceID(0)
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
            &defaultOutputDeviceID
        )
        
        guard status == noErr, defaultOutputDeviceID != 0 else {
            return AudioInfo(deviceName: "系统音频", volume: 50, isMuted: false, isHeadphones: false)
        }
        
        // 音量
        var volAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 0.0
        var volSize = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(defaultOutputDeviceID, &volAddress, 0, nil, &volSize, &volume) != noErr {
            volAddress.mElement = 1 // 降级左声道尝试
            _ = AudioObjectGetPropertyData(defaultOutputDeviceID, &volAddress, 0, nil, &volSize, &volume)
        }
        let volumePercent = Int(round(volume * 100))
        
        // 静音
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isMutedInt: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(defaultOutputDeviceID, &muteAddress, 0, nil, &muteSize, &isMutedInt)
        let isMuted = (isMutedInt != 0)
        
        // 设备名称
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devName = "音频输出"
        var nameCF: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        if AudioObjectGetPropertyData(defaultOutputDeviceID, &nameAddress, 0, nil, &nameSize, &nameCF) == noErr,
           let cf = nameCF?.takeRetainedValue() {
            devName = cf as String
        }
        
        let lower = devName.lowercased()
        let isHeadphones = lower.contains("airpod") || lower.contains("headphone") || lower.contains("ear") || lower.contains("buds") || lower.contains("bose") || lower.contains("sony")
        
        return AudioInfo(deviceName: devName, volume: volumePercent, isMuted: isMuted, isHeadphones: isHeadphones)
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
        
        return CalendarEventInfo(
            hasEvent: true,
            title: next.title ?? "日历日程",
            timeDescription: timeDesc,
            isAuthorized: true
        )
    }
}
