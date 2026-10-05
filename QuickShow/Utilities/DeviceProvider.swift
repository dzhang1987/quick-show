import Foundation
import IOKit
import IOKit.ps
import CoreWLAN
import IOBluetooth
import CoreBluetooth
import CoreLocation
import Darwin

// MARK: - 设备域：定位权限 / 电池 / WiFi / 本机 IP / 蓝牙 / DND
final class DeviceProvider: NSObject, CLLocationManagerDelegate {
    // 定位服务 (读取真实 Wi-Fi SSID)
    private let locationManager = CLLocationManager()
    private var locationCompletion: ((Bool) -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
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
}