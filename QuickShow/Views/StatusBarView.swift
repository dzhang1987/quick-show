import SwiftUI

struct StatusBarView: View {
    @ObservedObject var appState: AppState
    @State private var isPinHovered: Bool = false
    
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // 电池状态微标
            if appState.showBattery && appState.batteryInfo.hasBattery {
                HStack(spacing: 5) {
                    Image(systemName: batteryIconName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(batteryColor)
                    
                    Text("\(appState.batteryInfo.percentage)%")
                        .font(.system(size: 12, weight: .semibold, design: .default))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.85))
                }
            }
            
            // WiFi 状态微标
            if appState.showWiFi {
                HStack(spacing: 5) {
                    Image(systemName: appState.wifiInfo.isConnected ? "wifi" : "wifi.slash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(appState.wifiInfo.isConnected ? .white.opacity(0.85) : .white.opacity(0.35))
                    
                    if let ssid = appState.wifiInfo.ssid, appState.wifiInfo.isConnected {
                        Text(ssid)
                            .font(.system(size: 12, weight: .medium, design: .default))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
            }
            
            Spacer()
            
            // 右侧微交互图钉（小巧高贵、悬停微光、常驻点亮）
            Button {
                if appState.mode == .glance {
                    appState.pin()
                } else {
                    appState.dismiss()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: appState.mode == .pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                    
                    if appState.mode == .pinned {
                        Text("常驻")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundColor(appState.mode == .pinned ? Color.cyan : .white.opacity(isPinHovered ? 0.9 : 0.45))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(appState.mode == .pinned ? Color.cyan.opacity(0.20) : Color.white.opacity(isPinHovered ? 0.12 : 0.0))
                )
            }
            .buttonStyle(.plain)
            .onHover { isPinHovered = $0 }
            .help(appState.mode == .pinned ? "点击取消常驻 (或按 ESC)" : "点击常驻显示 (或按 Space)")
        }
    }
    
    private var batteryIconName: String {
        let pct = appState.batteryInfo.percentage
        if appState.batteryInfo.isCharging {
            return "battery.100.bolt"
        }
        if pct <= 15 { return "battery.0" }
        if pct <= 35 { return "battery.25" }
        if pct <= 65 { return "battery.50" }
        if pct <= 85 { return "battery.75" }
        return "battery.100"
    }
    
    private var batteryColor: Color {
        if appState.batteryInfo.isCharging {
            return Color(red: 0.35, green: 0.90, blue: 0.45)
        }
        if appState.batteryInfo.percentage <= 20 {
            return Color(red: 1.0, green: 0.35, blue: 0.35)
        }
        return .white.opacity(0.85)
    }
}
