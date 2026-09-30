import SwiftUI

struct StatusBarView: View {
    @ObservedObject var appState: AppState
    @State private var isPinHovered: Bool = false
    @State private var isExpandHovered: Bool = false
    
    // 只在极简底栏展示具有电量上报的关键外设 (如 AirPods、带电量鼠键)
    private var peripheralsWithBattery: [BluetoothDeviceInfo] {
        appState.bluetoothDevices.filter { $0.batteryLevel != nil }
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // 左侧状态微标群（严格控量，彻底杜绝任何省略号）
            HStack(spacing: 12) {
                // 1. 电池状态 (固定宽度，绝不压缩截断)
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
                    .fixedSize()
                }
                
                // 2. WiFi 状态
                // 极简模式下仅展示图标，展开模式下展示 SSID
                if appState.showWiFi {
                    HStack(spacing: 5) {
                        Image(systemName: appState.wifiInfo.isConnected ? "wifi" : "wifi.slash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(appState.wifiInfo.isConnected ? .white.opacity(0.85) : .white.opacity(0.35))
                        
                        if appState.isExpanded, let ssid = appState.wifiInfo.ssid, appState.wifiInfo.isConnected {
                            Text(ssid)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.80))
                                .lineLimit(1)
                        }
                    }
                    .fixedSize()
                }
                
                // 3. 音频输出 / 音量微标
                if appState.showAudio {
                    HStack(spacing: 4) {
                        Image(systemName: audioIconName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(appState.audioInfo.isMuted ? Color.orange : .white.opacity(0.85))
                        
                        if appState.audioInfo.isMuted {
                            Text("静音")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color.orange)
                        } else {
                            Text("\(appState.audioInfo.volume)%")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundColor(.white.opacity(0.85))
                        }
                    }
                    .fixedSize()
                }
                
                // 4. 关键外设电量（仅当存在电量上报时展示，如 AirPods 85%，无电量外设收纳至展开面板）
                if appState.showBluetooth && !peripheralsWithBattery.isEmpty {
                    ForEach(peripheralsWithBattery.prefix(2), id: \.name) { bt in
                        HStack(spacing: 4) {
                            Image(systemName: bt.iconName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color.cyan.opacity(0.9))
                            
                            if let level = bt.batteryLevel {
                                Text("\(level)%")
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(level <= 20 ? Color.red.opacity(0.9) : .white.opacity(0.85))
                            }
                        }
                        .fixedSize()
                    }
                }
                
                // 5. 勿扰 / 专注模式（仅在生效时点亮优雅微胶囊）
                if appState.showDND && appState.dndInfo.isEnabled {
                    HStack(spacing: 3) {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 9, weight: .medium))
                        Text("专注")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(Color(red: 0.7, green: 0.6, blue: 1.0))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.4, green: 0.3, blue: 0.8).opacity(0.25))
                    )
                    .fixedSize()
                }
                
                // 6. 番茄钟微标（运行中时在极简栏温和提示）
                if appState.enablePomodoro && appState.pomodoroRunning && !appState.isExpanded {
                    HStack(spacing: 3) {
                        Image(systemName: "timer")
                            .font(.system(size: 10, weight: .semibold))
                        Text(appState.formattedPomodoroTime)
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                    }
                    .foregroundColor(Color.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.18))
                    )
                    .fixedSize()
                }
            }
            
            Spacer(minLength: 12)
            
            // 右侧微交互功能键区
            HStack(spacing: 8) {
                // Tab 展开 / 收起微胶囊按钮
                Button {
                    appState.toggleExpanded()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: appState.isExpanded ? "chevron.up" : "gauge.with.needle")
                            .font(.system(size: 10, weight: .medium))
                        
                        Text(appState.isExpanded ? "收起" : "Tab")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(appState.isExpanded ? Color.cyan : .white.opacity(isExpandHovered ? 0.95 : 0.50))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(appState.isExpanded ? Color.cyan.opacity(0.20) : Color.white.opacity(isExpandHovered ? 0.12 : 0.04))
                    )
                }
                .buttonStyle(.plain)
                .onHover { isExpandHovered = $0 }
                .help(appState.isExpanded ? "收起监控看板 (按 Tab)" : "展开性能与效率看板 (按 Tab)")
                
                // 图钉常驻切换按钮
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
                    .foregroundColor(appState.mode == .pinned ? Color.cyan : .white.opacity(isPinHovered ? 0.95 : 0.50))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(appState.mode == .pinned ? Color.cyan.opacity(0.20) : Color.white.opacity(isPinHovered ? 0.12 : 0.04))
                    )
                }
                .buttonStyle(.plain)
                .onHover { isPinHovered = $0 }
                .help(appState.mode == .pinned ? "点击取消常驻 (或按 ESC)" : "点击常驻显示 (或按 Space)")
            }
            .fixedSize()
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
