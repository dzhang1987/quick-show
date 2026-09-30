import SwiftUI

struct StatusBarView: View {
    @ObservedObject var appState: AppState
    @State private var isPinHovered: Bool = false
    @State private var isExpandHovered: Bool = false
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // 左侧状态微标群（自适应弹性流式排列）
            HStack(spacing: 10) {
                // 1. 电池状态
                if appState.showBattery && appState.batteryInfo.hasBattery {
                    HStack(spacing: 4) {
                        Image(systemName: batteryIconName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(batteryColor)
                        
                        Text("\(appState.batteryInfo.percentage)%")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
                
                // 2. WiFi 状态
                if appState.showWiFi {
                    HStack(spacing: 4) {
                        Image(systemName: appState.wifiInfo.isConnected ? "wifi" : "wifi.slash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(appState.wifiInfo.isConnected ? .white.opacity(0.85) : .white.opacity(0.35))
                        
                        if let ssid = appState.wifiInfo.ssid, appState.wifiInfo.isConnected {
                            Text(ssid)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                }
                
                // 3. 蓝牙外设与电量（支持已连接的耳机、键盘、鼠标等）
                if appState.showBluetooth && !appState.bluetoothDevices.isEmpty {
                    ForEach(appState.bluetoothDevices.prefix(2), id: \.name) { bt in
                        HStack(spacing: 4) {
                            Image(systemName: bt.iconName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color.cyan.opacity(0.85))
                            
                            if let level = bt.batteryLevel {
                                Text("\(level)%")
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(.white.opacity(0.85))
                            } else {
                                Text(bt.name)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .lineLimit(1)
                                    .frame(maxWidth: 85, alignment: .leading)
                            }
                        }
                    }
                }
                
                // 4. 音频输出设备与音量
                if appState.showAudio {
                    HStack(spacing: 4) {
                        Image(systemName: audioIconName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(appState.audioInfo.isMuted ? Color.orange.opacity(0.9) : .white.opacity(0.85))
                        
                        if appState.audioInfo.isMuted {
                            Text("静音")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color.orange.opacity(0.9))
                        } else {
                            Text("\(appState.audioInfo.volume)%")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundColor(.white.opacity(0.85))
                        }
                    }
                }
                
                // 5. 勿扰 / 专注模式（仅在启用勿扰时高亮提示）
                if appState.showDND && appState.dndInfo.isEnabled {
                    HStack(spacing: 3) {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.indigo.opacity(0.9))
                        Text("专注")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.indigo.opacity(0.9))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.indigo.opacity(0.20))
                    )
                }
                
                // 6. 番茄钟微标（运行中时常驻展示）
                if appState.enablePomodoro && appState.pomodoroRunning {
                    HStack(spacing: 3) {
                        Image(systemName: "timer")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color.orange)
                        Text(appState.formattedPomodoroTime)
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                            .foregroundColor(Color.orange)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.18))
                    )
                }
            }
            .lineLimit(1)
            
            Spacer(minLength: 6)
            
            // 右侧微交互功能键区
            HStack(spacing: 6) {
                // 详细性能与监控展开按钮 (Tab 键联动)
                Button {
                    appState.toggleExpanded()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: appState.isExpanded ? "chevron.up" : "gauge.with.needle")
                            .font(.system(size: 10, weight: .medium))
                        
                        Text(appState.isExpanded ? "收起" : "Tab")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(appState.isExpanded ? Color.cyan : .white.opacity(isExpandHovered ? 0.9 : 0.45))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(appState.isExpanded ? Color.cyan.opacity(0.20) : Color.white.opacity(isExpandHovered ? 0.12 : 0.0))
                    )
                }
                .buttonStyle(.plain)
                .onHover { isExpandHovered = $0 }
                .help(appState.isExpanded ? "收起监控面板 (按 Tab)" : "展开详细性能与效率面板 (按 Tab)")
                
                // 图钉固定按钮 (Space 键联动)
                Button {
                    if appState.mode == .glance {
                        appState.pin()
                    } else {
                        appState.dismiss()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: appState.mode == .pinned ? "pin.fill" : "pin")
                            .font(.system(size: 10, weight: .medium))
                        
                        if appState.mode == .pinned {
                            Text("常驻")
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .foregroundColor(appState.mode == .pinned ? Color.cyan : .white.opacity(isPinHovered ? 0.9 : 0.45))
                    .padding(.horizontal, 6)
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
    
    private var audioIconName: String {
        if appState.audioInfo.isMuted {
            return "speaker.slash.fill"
        }
        if appState.audioInfo.isHeadphones {
            return "headphones"
        }
        let vol = appState.audioInfo.volume
        if vol == 0 { return "speaker.fill" }
        if vol < 40 { return "speaker.wave.1.fill" }
        if vol < 75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
