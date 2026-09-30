import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var launchAtLogin: Bool = false
    
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
            }
            
            Section("显示内容") {
                Toggle("使用 24 小时制", isOn: $appState.is24HourFormat)
                Toggle("显示秒数 (HH:mm:ss)", isOn: $appState.showSeconds)
                Toggle("显示电池状态", isOn: $appState.showBattery)
                Toggle("显示 WiFi 状态", isOn: $appState.showWiFi)
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
                    Text("1.0.0 (Build 1)")
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
        .frame(width: 380, height: 380)
        .onAppear {
            checkLaunchAtLoginStatus()
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
