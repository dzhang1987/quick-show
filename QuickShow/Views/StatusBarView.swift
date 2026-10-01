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
        HStack(alignment: .center, spacing: Theme.Spacing.section) {
            // 左侧状态微标群（严格控量，彻底杜绝任何省略号）
            HStack(spacing: Theme.Spacing.card) {
                // 1. 电池状态 (固定宽度，绝不压缩截断)
                if appState.showBattery && appState.batteryInfo.hasBattery {
                    Button {
                        appState.openBatterySettings()
                    } label: {
                        HStack(spacing: Theme.Spacing.smd) {
                            Image(systemName: batteryIconName)
                                .font(.system(size: Theme.Typography.iconLarge, weight: .medium))
                                .foregroundColor(batteryColor)
                            
                            Text("\(appState.batteryInfo.percentage)%")
                                .font(.system(size: Theme.Typography.callout, weight: .semibold))
                                .monospacedDigit()
                                .foregroundColor(.primary)
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
                        HStack(spacing: Theme.Spacing.chip) {
                            Image(systemName: appState.wifiInfo.isConnected ? "wifi" : "wifi.slash")
                                .font(.system(size: Theme.Typography.body, weight: .medium))
                                // 断连弱化态也需保证可读：0.50 是亮玻璃下的可读下限
                                .foregroundColor(appState.wifiInfo.isConnected ? .primary : Theme.Colors.wifiOff)
                            
                            if let ssid = appState.wifiInfo.ssid, appState.wifiInfo.isConnected {
                                Text(ssid)
                                    .font(.system(size: Theme.Typography.callout, weight: .medium))
                                    .foregroundColor(.secondary)
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
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: audioIconName)
                                .font(.system(size: Theme.Typography.body, weight: .medium))
                                .foregroundColor(appState.audioInfo.isMuted ? Color.orange : .primary)
                            
                            if appState.audioInfo.isMuted {
                                Text("静音")
                                    .font(.system(size: Theme.Typography.footnote, weight: .semibold))
                                    .foregroundColor(Color.orange)
                            } else {
                                Text("\(appState.audioInfo.volume)%")
                                    .font(.system(size: Theme.Typography.body, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
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
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: bt.iconName)
                                .font(.system(size: Theme.Typography.body, weight: .medium))
                                .foregroundColor(Theme.Colors.accent.opacity(0.9))
                            
                            if let level = bt.batteryLevel {
                                Text("\(level)%")
                                    .font(.system(size: Theme.Typography.body, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(level <= 20 ? Color.red.opacity(0.9) : .primary)
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
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "moon.fill")
                                .font(.system(size: Theme.Typography.mini, weight: .medium))
                            Text("专注")
                                .font(.system(size: Theme.Typography.footnote, weight: .medium))
                        }
                        // 语义紫色：系统 .purple 自带双模式变体，亮色下自动加深保持可读
                        .foregroundColor(Color.purple)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .background(
                            Capsule()
                                .fill(Color.purple.opacity(0.18))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("点击打开专注偏好设置 (按 D 切换)")
                    .fixedSize()
                }
                
                // 6. 咖啡因防休眠（仅在真正开启激活时，温和亮起微型咖啡图标，未激活时彻底隐形）
                if appState.isKeepAwake {
                    Button {
                        appState.toggleKeepAwake()
                    } label: {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: Theme.Typography.body, weight: .medium))
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("防休眠运行中 (点击或按 A 关闭)")
                    .fixedSize()
                }
                
                // 7. 番茄钟微标（运行中时在极简栏温和提示，支持点击暂停/继续）
                if appState.enablePomodoro && appState.pomodoroRunning && !appState.isExpanded {
                    Button {
                        appState.togglePomodoro()
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "timer")
                                .font(.system(size: Theme.Typography.body, weight: .semibold))
                            Text(appState.formattedPomodoroTime)
                                .font(.system(size: Theme.Typography.body, weight: .bold))
                                .monospacedDigit()
                        }
                        .foregroundColor(Color.orange)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xxs)
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
            
            Spacer(minLength: Theme.Spacing.xxl)
            
            // 右侧微交互功能键区：仅保留纯净、无文字的微型图钉图标（彻底干掉多余胶囊、问号与设置）
            HStack(spacing: Theme.Spacing.md) {
                // 如果处于展开态，展示精致的折叠向上箭头
                if appState.isExpanded {
                    Button {
                        appState.toggleExpanded()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: Theme.Typography.body, weight: .semibold))
                            // 交互元素对比度下限：静止态 0.60 明确可见，hover 0.95 增强反馈
                            .foregroundColor(isExpandHovered ? Theme.Colors.iconHover : Theme.Colors.iconRest)
                            .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
                            .background(
                                Circle()
                                    .fill(isExpandHovered ? Theme.Colors.iconHoverBg : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { isExpandHovered = $0 }
                    .help("收起看板 (按 Tab)")
                }
                
                // 图钉常驻切换按钮 (Toggle Pin / Unpin) - 零文字纯粹图标
                Button {
                    appState.togglePin()
                } label: {
                    Image(systemName: appState.mode == .pinned ? "pin.fill" : "pin")
                        .font(.system(size: Theme.Typography.callout, weight: .medium))
                        // 交互元素对比度下限：静止态 0.60 明确可见，hover 0.95 增强反馈（pinned 态主题强调色）
                        .foregroundColor(appState.mode == .pinned ? Theme.Colors.accent : (isPinHovered ? Theme.Colors.iconHover : Theme.Colors.iconRest))
                        .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
                        .background(
                            Circle()
                                .fill(appState.mode == .pinned ? Theme.Colors.accent.opacity(0.18) : (isPinHovered ? Theme.Colors.iconHoverBg : Color.clear))
                        )
                }
                .buttonStyle(.plain)
                .onHover { isPinHovered = $0 }
                .help(appState.mode == .pinned ? "已常驻显示 (点击或按 Space 解除)" : "点击常驻固定 (快捷键 Space)")
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
        return .primary
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
