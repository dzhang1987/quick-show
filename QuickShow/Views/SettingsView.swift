import SwiftUI
import ServiceManagement
import EventKit

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general = "通用"
    case statusBar = "一瞥底栏"
    case dashboard = "监控看板"
    case shortcuts = "快捷键设置"
    case about = "关于"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .statusBar: return "sparkles"
        case .dashboard: return "gauge.with.needle.fill"
        case .shortcuts: return "command"
        case .about: return "info.circle.fill"
        }
    }
    
    var iconColor: Color {
        switch self {
        case .general: return Color.gray
        case .statusBar: return Color.cyan
        case .dashboard: return Color.blue
        case .shortcuts: return Color.orange
        case .about: return Color.purple
        }
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: SettingsTab? = .general
    @State private var launchAtLogin: Bool = false
    @State private var isCalendarAuthorized: Bool = false
    @State private var isLocationAuthorized: Bool = false
    
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.doubleColumn)) {
            // 左侧原生 macOS 侧边栏
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                NavigationLink(value: tab) {
                    Label {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .medium))
                    } icon: {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .fill(tab.iconColor)
                            )
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 240)
            .safeAreaInset(edge: .top) {
                // 留出左上角沉浸式红绿灯避让间距
                Spacer().frame(height: 32)
            }
        } detail: {
            // 右侧详情：纯正的 macOS 原生 .formStyle(.grouped)
            Group {
                switch selectedTab ?? .general {
                case .general:
                    GeneralSettingsForm(appState: appState, launchAtLogin: $launchAtLogin)
                case .statusBar:
                    StatusBarSettingsForm(appState: appState, isLocationAuthorized: $isLocationAuthorized)
                case .dashboard:
                    DashboardSettingsForm(appState: appState, isCalendarAuthorized: $isCalendarAuthorized)
                case .shortcuts:
                    ShortcutsSettingsForm(appState: appState)
                case .about:
                    AboutSettingsForm()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(selectedTab?.rawValue ?? "设置")
        }
        .frame(minWidth: 700, minHeight: 480)
        .onAppear {
            checkLaunchAtLoginStatus()
            checkCalendarStatus()
            checkLocationStatus()
        }
    }
    
    private func checkLocationStatus() {
        isLocationAuthorized = appState.isLocationAuthorized
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
}

// MARK: - 1. 通用设置表单
struct GeneralSettingsForm: View {
    @ObservedObject var appState: AppState
    @Binding var launchAtLogin: Bool
    
    var body: some View {
        Form {
            Section {
                Picker("呼出触发方式", selection: Binding(
                    get: { appState.triggerType },
                    set: { appState.triggerType = $0 }
                )) {
                    ForEach(TriggerType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
            } header: {
                Text("全局呼出")
            } footer: {
                Text("推荐「双击 Command (⌘ ⌘)」或「双击 Control (⌃ ⌃)」，敲击两下极速呼出/收起，全屏沉浸零打断。")
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
                        Text(String(format: "%.1f 秒", appState.glanceDuration))
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
                                .font(.system(size: 11))
                                .foregroundColor(isLocationAuthorized ? .green : .secondary)
                            
                            Spacer()
                            
                            if !isLocationAuthorized {
                                Button("请求授权") {
                                    appState.requestLocationAccess { granted in
                                        isLocationAuthorized = granted
                                    }
                                }
                                .font(.system(size: 11))
                            }
                        }
                    }
                }
                
                Toggle("显示蓝牙外设 (AirPods / 键鼠电量)", isOn: $appState.showBluetooth)
                Toggle("显示音频输出与音量 / 静音", isOn: $appState.showAudio)
                Toggle("显示专注 / 勿扰模式徽标", isOn: $appState.showDND)
            } header: {
                Text("微感知微标")
            } footer: {
                Text("悬浮面板底部默认展示的轻量感知微标，即看即走。点击各个微标可触发快捷交互。")
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
            } header: {
                Text("效率与生产力")
            }
        }
    }
}

// MARK: - 4. 快捷键设置表单 (Shortcuts)
struct ShortcutsSettingsForm: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.orange)
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("长按 Command (⌘) 速查特性")
                            .font(.system(size: 13, weight: .semibold))
                        Text("在悬浮面板激活时，只需按住 ⌘ 键约 0.35 秒或敲击「?」键，屏幕将浮现半透明速查表；手指松开 ⌘ 自动收起。")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            
            Section {
                HStack {
                    Text("全局呼出 / 关闭悬浮面板")
                    Spacer()
                    KeyBadge(key: appState.triggerType.displayName)
                }
                HStack {
                    Text("备用全局组合键呼出")
                    Spacer()
                    KeyBadge(key: "⌘ ⇧ T")
                }
            } header: {
                Text("全局唤醒")
            }
            
            Section {
                HStack {
                    Text("展开 / 收起监控看板")
                    Spacer()
                    KeyBadge(key: "Tab")
                }
                HStack {
                    Text("切换图钉常驻 (Pin / Unpin)")
                    Spacer()
                    KeyBadge(key: "Space")
                }
                HStack {
                    Text("打开偏好设置窗口")
                    Spacer()
                    KeyBadge(key: "⌘ ,")
                }
                HStack {
                    Text("彻底退出应用")
                    Spacer()
                    KeyBadge(key: "⌘ Q")
                }
                HStack {
                    Text("关闭 / 退出悬浮面板")
                    Spacer()
                    KeyBadge(key: "ESC")
                }
            } header: {
                Text("基础交互控制")
            }
            
            Section {
                HStack {
                    Text("一键切换静音 / 取消静音")
                    Spacer()
                    KeyBadge(key: "M")
                }
                HStack {
                    Text("微调系统主音量 (步进 ±5%)")
                    Spacer()
                    KeyBadge(key: "↑ / ↓")
                }
                HStack {
                    Text("咖啡因防休眠开关 (阻止息屏)")
                    Spacer()
                    KeyBadge(key: "A")
                }
                HStack {
                    Text("一键优化整理系统内存 (释放缓存)")
                    Spacer()
                    KeyBadge(key: "C")
                }
                HStack {
                    Text("极简番茄钟 播放 / 暂停")
                    Spacer()
                    KeyBadge(key: "P")
                }
                HStack {
                    Text("在访达中瞬间打开「下载目录」")
                    Spacer()
                    KeyBadge(key: "O")
                }
                HStack {
                    Text("剪贴板格式净化 (转为纯文本)")
                    Spacer()
                    KeyBadge(key: "X")
                }
                HStack {
                    Text("全屏立即锁屏离座")
                    Spacer()
                    KeyBadge(key: "L")
                }
                HStack {
                    Text("打开系统专注 / 勿扰模式偏好")
                    Spacer()
                    KeyBadge(key: "D")
                }
                HStack {
                    Text("切换快捷键速查卡片浮层")
                    Spacer()
                    KeyBadge(key: "?")
                }
            } header: {
                Text("单键盲操与效率")
            }
        }
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
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.cyan)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("QuickShow")
                            .font(.system(size: 18, weight: .bold))
                        Text("版本 1.1.0")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("专为全屏沉浸与极简工作流打造的 macOS 原生极速信息悬浮窗。")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            
            Section {
                LabeledContent("开发团队", value: "cn.chiproad")
                LabeledContent("技术架构", value: "Swift 5.9 · AppKit + SwiftUI")
                LabeledContent("运行状态", value: "0 外部依赖 · 纯原生零泄漏")
                LabeledContent("开源协议", value: "MIT License")
            } header: {
                Text("软件信息")
            }
        }
    }
}

// MARK: - 基础组件: 按键微胶囊
struct KeyBadge: View {
    let key: String
    
    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(.primary.opacity(0.88))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.90))
                    .shadow(color: Color.black.opacity(0.08), radius: 1, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.75)
            )
    }
}
