import SwiftUI
import ServiceManagement
import EventKit

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var launchAtLogin: Bool = false
    @State private var isCalendarAuthorized: Bool = false
    
    var body: some View {
        Form {
            Section("快捷唤醒") {
                Picker("呼出触发方式", selection: Binding(
                    get: { appState.triggerType },
                    set: { appState.triggerType = $0 }
                )) {
                    ForEach(TriggerType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                
                Text("推荐「双击 Command (⌘ ⌘)」或「双击 Control (⌃ ⌃)」，一只大拇指敲两下即可极速唤起，全屏沉浸不打断。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Section("通用设置") {
                Toggle("打开应用时默认展示一次", isOn: $appState.showOnLaunch)
                
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        updateLaunchAtLogin(enabled: newValue)
                    }
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("一瞥模式显示时长")
                        Spacer()
                        Text(String(format: "%.1f 秒", appState.glanceDuration))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $appState.glanceDuration, in: 1.5...10.0, step: 0.5)
                }
                
                Toggle("使用 24 小时制", isOn: $appState.is24HourFormat)
                Toggle("显示秒数 (HH:mm:ss)", isOn: $appState.showSeconds)
            }
            
            Section("系统微状态栏 (P0)") {
                Toggle("显示电池状态与充电标识", isOn: $appState.showBattery)
                Toggle("显示 WiFi 连接与 SSID", isOn: $appState.showWiFi)
                Toggle("显示蓝牙外设 (耳机 / 键鼠电量)", isOn: $appState.showBluetooth)
                Toggle("显示音频输出与音量 / 静音", isOn: $appState.showAudio)
                Toggle("显示专注 / 勿扰模式徽标", isOn: $appState.showDND)
            }
            
            Section("扩展监控看板 (P1 · 按 Tab 键展开)") {
                Text("面板激活时，敲击「Tab 键」可无缝切换极简一瞥 / 详细监控看板。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Toggle("显示 CPU & 内存系统负载条", isOn: $appState.showPerformance)
                Toggle("显示实时网络吞吐速率 (上下行)", isOn: $appState.showNetworkSpeed)
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
                            Text(isCalendarAuthorized ? "已获得日历访问权限" : "未授权日历访问")
                                .font(.system(size: 11))
                                .foregroundColor(isCalendarAuthorized ? .green : .orange)
                            
                            Spacer()
                            
                            if !isCalendarAuthorized {
                                Button("请求授权") {
                                    appState.requestCalendarAccess { granted in
                                        isCalendarAuthorized = granted
                                    }
                                }
                                .font(.system(size: 11))
                            }
                        }
                    }
                }
            }
            
            Section("关于") {
                HStack {
                    Text("应用名称")
                    Spacer()
                    Text("QuickShow")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("应用版本")
                    Spacer()
                    Text("1.1.0 (P0 & P1 Release)")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("开发团队")
                    Spacer()
                    Text("cn.chiproad")
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 520)
        .onAppear {
            checkLaunchAtLoginStatus()
            checkCalendarStatus()
        }
    }
    
    private func checkCalendarStatus() {
        let status = SystemStatusProvider.shared.getCalendarAuthorizationStatus()
        if #available(macOS 14.0, *) {
            isCalendarAuthorized = (status == .fullAccess || status == .authorized)
        } else {
            isCalendarAuthorized = (status == .authorized)
        }
    }
    
    private func checkLaunchAtLoginStatus() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
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
