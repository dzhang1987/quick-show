import SwiftUI

struct StatusBarView: View {
    @ObservedObject var appState: AppState
    @State private var isPinHovered: Bool = false
    @State private var isExpandHovered: Bool = false
    @State private var isAwakeHovered: Bool = false
    @State private var isHelpHovered: Bool = false
    @State private var isSettingsHovered: Bool = false
    
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
                    Button {
                        appState.openBatterySettings()
                    } label: {
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
                    .buttonStyle(.plain)
                    .help("点击打开系统电池偏好设置")
                    .fixedSize()
                }
                
                // 2. WiFi 状态
                // 极简模式下仅展示图标，展开模式下展示 SSID
                if appState.showWiFi {
                    Button {
                        if NSEvent.modifierFlags.contains(.option) {
                            appState.openNetworkSettings()
                        } else {
                            appState.copyLocalIP()
                        }
                    } label: {
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
                    }
                    .buttonStyle(.plain)
                    .help("点击一键复制局域网 IP (Option+点击打开网络设置)")
                    .fixedSize()
                }
                
                // 3. 音频输出 / 音量微标
                if appState.showAudio {
                    Button {
                        appState.toggleMute()
                    } label: {
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
                    }
                    .buttonStyle(.plain)
                    .help("点击切换静音 (按 M 静音，↑/↓ 调音量)")
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
                    Button {
                        appState.openFocusSettings()
                    } label: {
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
                    }
                    .buttonStyle(.plain)
                    .help("点击打开专注偏好设置 (按 D 切换)")
                    .fixedSize()
                }
                
                // 6. 番茄钟微标（运行中时在极简栏温和提示，支持点击暂停/继续）
                if appState.enablePomodoro && appState.pomodoroRunning && !appState.isExpanded {
                    Button {
                        appState.togglePomodoro()
                    } label: {
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
                    }
                    .buttonStyle(.plain)
                    .help("点击暂停/继续番茄钟 (按 P 键)")
                    .fixedSize()
                }
            }
            
            Spacer(minLength: 12)
            
            // 右侧微交互功能键区
            HStack(spacing: 7) {
                // 咖啡因防休眠微胶囊按钮 (Caffeine / Keep Awake)
                Button {
                    appState.toggleKeepAwake()
                } label: {
                    Image(systemName: appState.isKeepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(appState.isKeepAwake ? Color.orange : .white.opacity(isAwakeHovered ? 0.95 : 0.45))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(appState.isKeepAwake ? Color.orange.opacity(0.20) : Color.white.opacity(isAwakeHovered ? 0.12 : 0.04))
                        )
                }
                .buttonStyle(.plain)
                .onHover { isAwakeHovered = $0 }
                .help(appState.isKeepAwake ? "防休眠已开启 (按 A 关闭)" : "开启防休眠阻止息屏 (按 A)")
                
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
                
                // 图钉常驻切换按钮 (Toggle Pin / Unpin)
                Button {
                    appState.togglePin()
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
                .help(appState.mode == .pinned ? "点击解除常驻 (按 Space)" : "点击常驻显示 (按 Space)")
                
                // 快捷键速查按钮（点击切换，长按 ⌘ 也能弹出）
                Button {
                    appState.toggleCheatSheet()
                } label: {
                    Image(systemName: "questionmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(appState.showCheatSheet ? Color.orange : .white.opacity(isHelpHovered ? 0.95 : 0.45))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(appState.showCheatSheet ? Color.orange.opacity(0.20) : Color.white.opacity(isHelpHovered ? 0.12 : 0.04))
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHelpHovered = $0 }
                .help("快捷键速查 (按 ? 或长按 ⌘)")
                
                // 偏好设置按钮（展开监控或固定常驻时呈现）
                if appState.isExpanded || appState.mode == .pinned {
                    Button {
                        appState.openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(isSettingsHovered ? 0.95 : 0.50))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(isSettingsHovered ? 0.12 : 0.04))
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { isSettingsHovered = $0 }
                    .help("偏好设置 (按 ⌘,)")
                }
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
