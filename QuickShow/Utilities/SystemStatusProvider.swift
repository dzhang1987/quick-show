import Foundation
import IOKit.ps
import CoreWLAN

struct BatteryInfo: Equatable {
    var percentage: Int
    var isCharging: Bool
    var hasBattery: Bool
}

struct WiFiInfo: Equatable {
    var isConnected: Bool
    var ssid: String?
}

final class SystemStatusProvider {
    static let shared = SystemStatusProvider()
    
    private init() {}
    
    /// 获取当前电池信息
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
    
    /// 获取当前 WiFi 信息
    func getWiFiInfo() -> WiFiInfo {
        let client = CWWiFiClient.shared()
        guard let iface = client.interface() else {
            return WiFiInfo(isConnected: false, ssid: nil)
        }
        
        let powerOn = iface.powerOn()
        let ssid = iface.ssid()
        
        return WiFiInfo(isConnected: powerOn && ssid != nil, ssid: ssid)
    }
}
