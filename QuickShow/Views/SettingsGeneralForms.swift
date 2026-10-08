// 本文件由 SettingsView.swift 拆分而来：通用 / 一瞥底栏 / 监控看板 / 关于 设置表单。

import SwiftUI
import AppKit
import ServiceManagement

// MARK: - 1. 通用设置表单
struct GeneralSettingsForm: View {
    @ObservedObject var appState: AppState
    @Binding var launchAtLogin: Bool

    /// 热键互斥被拒时的即时提示（所选未实际生效时出现，红色小字）
    @State private var conflictNotice: String?

    /// 主面板热键绑定：写入后回读 HotKeyManager 实际生效值，被互斥拒绝则即时提示。
    /// 与「快捷键设置」页的 mainTriggerBinding 同一套回读校验模式。
    private var generalTriggerBinding: Binding<TriggerType> {
        Binding(
            get: { appState.triggerType },
            set: { newValue in
                appState.triggerType = newValue
                // 互斥兜底在 AppState setter：被拒绝时实际生效值仍为旧值，与所选不同
                if HotKeyManager.shared.currentType != newValue {
                    conflictNotice = String(localized: "与 AI 对话窗热键命中键冲突，已保持原设置。请在「快捷键设置」中调整双路热键")
                } else {
                    conflictNotice = nil
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("呼出触发方式", selection: generalTriggerBinding) {
                    ForEach(TriggerType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                if let conflictNotice {
                    Text(conflictNotice)
                        .font(.system(size: Theme.Typography.label))
                        .foregroundColor(Theme.Colors.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("全局呼出")
            } footer: {
                Text("推荐「双击 Command (⌘ ⌘)」或「双击 Control (⌃ ⌃)」，敲击两下极速呼出/收起，全屏沉浸零打断。AI 对话窗热键在「快捷键设置」中独立配置。")
            }
            
            Section {
                Toggle("在系统菜单栏显示图标", isOn: $appState.showMenuBarIcon)
                
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        updateLaunchAtLogin(enabled: newValue)
                    }
                
                Toggle("打开应用时默认在屏幕中心展示一次", isOn: $appState.showOnLaunch)
            } header: {
                Text("托盘与启动")
            } footer: {
                if !appState.showMenuBarIcon {
                    Text("提示：隐藏菜单栏图标后，QuickShow 保持完全隐形后台运行。随时可通过快捷键呼出面板，在面板激活时按 ⌘, 可重新打开偏好设置。")
                }
            }
            
            Section {
                Picker("外观主题", selection: Binding(
                    get: { appState.themeVariant },
                    set: { appState.themeVariant = $0 }
                )) {
                    ForEach(ThemeVariant.allCases) { variant in
                        Text(variant.displayName).tag(variant)
                    }
                }
                
                Picker("明暗模式", selection: Binding(
                    get: { appState.appearanceMode },
                    set: { appState.appearanceMode = $0 }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("外观")
            } footer: {
                Text("「琥珀暖色」将主角时钟与高亮点缀切换为暖金琥珀调；明暗模式作用于整个 App（面板/玻璃/设置窗口），「自动」跟随系统外观。")
            }
            
            Section {
                Picker("卡片显示尺寸", selection: Binding(
                    get: { appState.panelScaleOption },
                    set: { appState.panelScaleOption = $0 }
                )) {
                    ForEach(PanelScaleOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } header: {
                Text("界面尺寸与自适应")
            } footer: {
                Text("默认「自动」将根据当前显示器分辨率精密自适应，内容自然包裹，保持高信息密度与无黑洞紧凑排版；亦可手动选择标准、紧凑或大号尺寸。")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("一瞥模式显示时长")
                        Spacer()
                        Text(String.localizedStringWithFormat(String(localized: "%.1f 秒"), appState.glanceDuration))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $appState.glanceDuration, in: 1.5...10.0, step: 0.5)
                }
                
                Toggle("使用 24 小时制", isOn: $appState.is24HourFormat)
                Toggle("显示秒数 (HH:mm:ss)", isOn: $appState.showSeconds)
            } header: {
                Text("时间与一瞥")
            } footer: {
                Text("鼠标悬停在悬浮窗上时将自动冻结倒计时，移开后平滑继续。")
            }
        }
    }
    
    private func updateLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("[QuickShow] 更新开机自启失败: \(error)")
            }
        }
    }
}

// MARK: - 2. 一瞥底栏设置表单
struct StatusBarSettingsForm: View {
    @ObservedObject var appState: AppState
    @Binding var isLocationAuthorized: Bool
    
    var body: some View {
        Form {
            Section {
                Toggle("显示电池状态与充电标识", isOn: $appState.showBattery)
                
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("显示 Wi-Fi 连接与 SSID", isOn: $appState.showWiFi)
                    
                    if appState.showWiFi {
                        HStack {
                            Text(isLocationAuthorized ? "已获得定位权限（可读取并显示真实 Wi-Fi 名称）" : "未授权定位（根据系统限制将优雅降级显示频段如 5G）")
                                .font(.system(size: Theme.Typography.body))
                                .foregroundColor(isLocationAuthorized ? .green : .secondary)
                            
                            Spacer()
                            
                            if !isLocationAuthorized {
                                Button("请求授权") {
                                    appState.requestLocationAccess { granted in
                                        isLocationAuthorized = granted
                                    }
                                }
                                .font(.system(size: Theme.Typography.body))
                            }
                        }
                    }
                }
                
                Toggle("显示蓝牙外设 (AirPods / 键鼠电量)", isOn: $appState.showBluetooth)
                Toggle("显示音频输出与音量 / 静音", isOn: $appState.showAudio)
                Toggle("显示专注 / 勿扰模式徽标", isOn: $appState.showDND)
                Toggle("显示正在播放的媒体 (Now Playing)", isOn: $appState.showNowPlaying)
            } header: {
                Text("微感知微标")
            } footer: {
                Text("悬浮面板底部默认展示的轻量感知微标，即看即走。点击各个微标可触发快捷交互；正在播放有媒体会话即点亮（暂停时弱化呈现），展开看板展示封面与进度。")
            }
        }
    }
}

// MARK: - 3. 监控看板设置表单
struct DashboardSettingsForm: View {
    @ObservedObject var appState: AppState
    @Binding var isCalendarAuthorized: Bool
    
    var body: some View {
        Form {
            Section {
                Toggle("显示 CPU & 内存系统负载监控", isOn: $appState.showPerformance)
                Toggle("显示实时网络吞吐速率 (上下行网速)", isOn: $appState.showNetworkSpeed)
            } header: {
                Text("系统监控")
            } footer: {
                Text("敲击 Tab 键展开后，实时展示双列性能与网络吞吐监控卡片。")
            }
            
            Section {
                Toggle("启用极简专注番茄钟 (25 分钟)", isOn: $appState.enablePomodoro)
                
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("显示下一场日历日程会议", isOn: $appState.showCalendar)
                        .onChange(of: appState.showCalendar) { enabled in
                            if enabled && !isCalendarAuthorized {
                                appState.requestCalendarAccess { granted in
                                    isCalendarAuthorized = granted
                                }
                            }
                        }
                    
                    if appState.showCalendar {
                        HStack {
                            Text(isCalendarAuthorized ? "已获得日历访问权限（自动识别腾讯会议/Zoom/Meet等链接）" : "未授权日历访问（需授权方可识别日程）")
                                .font(.system(size: Theme.Typography.body))
                                .foregroundColor(isCalendarAuthorized ? .green : .orange)
                            
                            Spacer()
                            
                            if !isCalendarAuthorized {
                                Button("请求授权") {
                                    appState.requestCalendarAccess { granted in
                                        isCalendarAuthorized = granted
                                    }
                                }
                                .font(.system(size: Theme.Typography.body))
                            }
                        }
                    }
                }
            } header: {
                Text("效率与生产力")
            }
            
            Section {
                Picker("第一时区", selection: worldClockCityBinding($appState.worldClockCity1Raw, fallback: .beijing)) {
                    ForEach(WorldClockCity.allCases) { city in
                        Text(city.displayName).tag(city)
                    }
                }
                Picker("第二时区", selection: worldClockCityBinding($appState.worldClockCity2Raw, fallback: .london)) {
                    ForEach(WorldClockCity.allCases) { city in
                        Text(city.displayName).tag(city)
                    }
                }
                Picker("第三时区", selection: worldClockCityBinding($appState.worldClockCity3Raw, fallback: .newYork)) {
                    ForEach(WorldClockCity.allCases) { city in
                        Text(city.displayName).tag(city)
                    }
                }
            } header: {
                Text("世界时钟")
            } footer: {
                Text("展开看板日程区展示 2~3 个时区的当前时间，选择「无」可隐藏对应槽位。")
            }
        }
    }
    
    /// 世界时钟槽位绑定：rawValue（IANA 时区标识）与枚举互转
    private func worldClockCityBinding(_ raw: Binding<String>, fallback: WorldClockCity) -> Binding<WorldClockCity> {
        Binding(
            get: { WorldClockCity(rawValue: raw.wrappedValue) ?? fallback },
            set: { raw.wrappedValue = $0.rawValue }
        )
    }
}

// MARK: - 5. 关于表单
struct AboutSettingsForm: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.16, green: 0.16, blue: 0.20),
                                        Color(red: 0.08, green: 0.08, blue: 0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 56, height: 56)
                            .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 2)
                        
                        Image(systemName: "sparkles")
                            .font(.system(size: Theme.Typography.settingsIcon, weight: .bold))
                            .foregroundColor(.cyan)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("QuickShow")
                            .font(.system(size: Theme.Typography.title, weight: .bold))
                        // 版本号读取自 Info.plist，避免文档与实际版本漂移
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0")")
                            .font(.system(size: Theme.Typography.callout))
                            .foregroundColor(.secondary)
                        Text("专为全屏沉浸与极简工作流打造的 macOS 原生极速信息悬浮窗。")
                            .font(.system(size: Theme.Typography.callout))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            
            Section {
                LabeledContent("开发团队", value: "cn.chiproad")
                LabeledContent("技术架构", value: "Swift 5.9 · AppKit + SwiftUI")
                LabeledContent("运行状态", value: String(localized: "0 外部依赖 · 纯原生零泄漏"))
                LabeledContent("开源协议", value: "MIT License")
            } header: {
                Text("软件信息")
            } footer: {
                Text("Now Playing 数据能力由 mediaremote-adapter（BSD-3-Clause）提供。")
                    .font(.system(size: Theme.Typography.label))
                    .foregroundColor(.secondary)
            }
        }
    }
}
