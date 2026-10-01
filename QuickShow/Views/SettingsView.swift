import SwiftUI
import ServiceManagement
import EventKit

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general = "通用"
    case statusBar = "一瞥底栏"
    case dashboard = "监控看板"
    case aiService = "AI 服务"
    case shortcuts = "快捷键设置"
    case about = "关于"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .statusBar: return "sparkles"
        case .dashboard: return "gauge.with.needle.fill"
        case .aiService: return "brain.head.profile"
        case .shortcuts: return "command"
        case .about: return "info.circle.fill"
        }
    }
    
    var iconColor: Color {
        switch self {
        case .general: return Color.gray
        case .statusBar: return Color.cyan
        case .dashboard: return Color.blue
        case .aiService: return Color.indigo
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
                            .font(.system(size: Theme.Typography.badge, weight: .medium))
                    } icon: {
                        Image(systemName: tab.iconName)
                            .font(.system(size: Theme.Typography.body, weight: .bold))
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
                case .aiService:
                    AIServiceSettingsForm(appState: appState)
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

// MARK: - 4. 快捷键设置表单 (Shortcuts)
struct ShortcutsSettingsForm: View {
    @ObservedObject var appState: AppState
    
    /// 热键互斥被拒时的即时提示（所选未实际生效时出现，红色小字）
    @State private var conflictNotice: String?
    
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: Theme.Typography.title, weight: .bold))
                        .foregroundColor(.orange)
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("长按 Command (⌘) 速查特性")
                            .font(.system(size: Theme.Typography.badge, weight: .semibold))
                        Text("在悬浮面板激活时，只需按住 ⌘ 键约 0.35 秒或敲击「?」键，屏幕将浮现半透明速查表；手指松开 ⌘ 自动收起。")
                            .font(.system(size: Theme.Typography.callout))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            
            Section {
                Picker("主面板呼出 / 关闭", selection: mainTriggerBinding) {
                    triggerOptions()
                }
                Picker("AI 对话窗呼出 / 关闭", selection: aiTriggerBinding) {
                    triggerOptions()
                }
                HStack {
                    Text("备用全局组合键呼出")
                    Spacer()
                    KeyBadge(key: "⌘ ⇧ T")
                }
                HStack {
                    Text("主面板激活时打开 AI 对话窗")
                    Spacer()
                    KeyBadge(key: "I")
                }
            } header: {
                Text("全局唤醒")
            } footer: {
                if let conflictNotice = conflictNotice {
                    Text(conflictNotice)
                        .font(.system(size: Theme.Typography.label))
                        .foregroundColor(.red)
                } else {
                    Text("主面板与 AI 对话窗热键各自独立、并行生效；两者命中键冲突时后设置者被拒绝并保持原设置（左⌘ + 右⌘ 可共存，任意⌘ + 左⌘ 冲突）。")
                }
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
                    Text("切换日历视图 (任意状态直达)")
                    Spacer()
                    KeyBadge(key: "G")
                }
                HStack {
                    Text("日历 月 / 周 / 日 视图切换")
                    Spacer()
                    KeyBadge(key: "1 / 2 / 3")
                }
                HStack {
                    Text("日历翻页 (日历视图内优先于媒体切歌)")
                    Spacer()
                    KeyBadge(key: "← / →")
                }
            } header: {
                Text("日历视图")
            } footer: {
                Text("任意状态按 G 直达日历视图（含农历、节气、当日日程）；再按 G 或 Tab 回到进入前状态（一瞥进入回一瞥，看板进入回看板）。")
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
            
            Section {
                HStack {
                    Text("媒体播放 / 暂停切换")
                    Spacer()
                    KeyBadge(key: "⏎")
                }
                HStack {
                    Text("上一首 / 下一首")
                    Spacer()
                    KeyBadge(key: "← / →")
                }
                HStack {
                    Text("快退 / 快进 15 秒")
                    Spacer()
                    KeyBadge(key: ", / .")
                }
            } header: {
                Text("媒体控制")
            } footer: {
                Text("仅在系统存在媒体会话（音乐 / 视频 / 播客等，含网页播放源）时生效，无会话时按键无副作用。")
            }
        }
    }
    
    // MARK: 热键绑定与选项
    
    /// 主面板热键绑定：写入后读取 HotKeyManager 实际生效值，被互斥拒绝则即时回退并提示。
    private var mainTriggerBinding: Binding<TriggerType> {
        Binding(
            get: { appState.triggerType },
            set: { newValue in
                appState.triggerType = newValue
                // 互斥兜底在 AppState setter：被拒绝时实际生效值仍为旧值，与所选不同
                if HotKeyManager.shared.currentType != newValue {
                    conflictNotice = "与 AI 对话窗热键冲突，已保持原设置"
                } else {
                    conflictNotice = nil
                }
            }
        )
    }
    
    /// AI 对话窗热键绑定：同上，读取 aiTriggerType 实际生效值做即时校验。
    private var aiTriggerBinding: Binding<TriggerType> {
        Binding(
            get: { appState.aiTriggerType },
            set: { newValue in
                appState.aiTriggerType = newValue
                if HotKeyManager.shared.aiTriggerType != newValue {
                    conflictNotice = "与主面板热键冲突，已保持原设置"
                } else {
                    conflictNotice = nil
                }
            }
        )
    }
    
    /// 13 案触发类型选项：按 ⌘ / ⌃ / ⌥ / ⇧ 四族分组（每族 任意侧 / 左 / 右），外加组合键分组。
    @ViewBuilder
    private func triggerOptions() -> some View {
        Section("双击 ⌘（Command）") {
            Text("双击 ⌘（任意侧）").tag(TriggerType.doubleCmd)
            Text("双击左⌘").tag(TriggerType.doubleLeftCmd)
            Text("双击右⌘").tag(TriggerType.doubleRightCmd)
        }
        Section("双击 ⌃（Control）") {
            Text("双击 ⌃（任意侧）").tag(TriggerType.doubleCtrl)
            Text("双击左⌃").tag(TriggerType.doubleLeftCtrl)
            Text("双击右⌃").tag(TriggerType.doubleRightCtrl)
        }
        Section("双击 ⌥（Option）") {
            Text("双击 ⌥（任意侧）").tag(TriggerType.doubleOpt)
            Text("双击左⌥").tag(TriggerType.doubleLeftOpt)
            Text("双击右⌥").tag(TriggerType.doubleRightOpt)
        }
        Section("双击 ⇧（Shift）") {
            Text("双击 ⇧（任意侧）").tag(TriggerType.doubleShift)
            Text("双击左⇧").tag(TriggerType.doubleLeftShift)
            Text("双击右⇧").tag(TriggerType.doubleRightShift)
        }
        Section("组合键") {
            Text("⌘⇧T 组合键").tag(TriggerType.hotKeyCmdShiftT)
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
                LabeledContent("运行状态", value: "0 外部依赖 · 纯原生零泄漏")
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

// MARK: - AI 接口协议选项
/// AI 接口协议选项（rawValue 与 AIChatService.APIProtocol 保持一致："chat" / "responses"）。
/// 说明：并行实现的 AIChatService.APIProtocol 公开接口暂不可见时，本表单按同键
/// `@AppStorage("ai.apiProtocol")` 私有绑定，读写同一份 UserDefaults 原始值，后续可无痛切换到服务接口。
private enum AIProtocolOption: String, CaseIterable, Identifiable {
    case chat = "chat"
    case responses = "responses"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .chat: return "Chat Completions（通用兼容）"
        case .responses: return "Responses（OpenAI 官方新协议）"
        }
    }
}

// MARK: - 6. AI 服务设置表单
struct AIServiceSettingsForm: View {
    // appState 作为设置中心的统一状态入口保留（本表单配置项均为独立键，暂不依赖其成员）
    @ObservedObject var appState: AppState
    
    // Base URL / Model / System Prompt 均存 UserDefaults，键名与 AIChatService.ConfigKey 完全一致；
    // 直接以 @AppStorage 绑定同键，既能获得 SwiftUI 响应式刷新，又与 AIChatService 读写共享同一份数据。
    @AppStorage("ai.baseURL") private var baseURL: String = ""
    @AppStorage("ai.systemPrompt") private var systemPrompt: String = ""
    // API 协议：原始值 "chat" / "responses"，键名与 AIChatService 保持一致
    @AppStorage("ai.apiProtocol") private var apiProtocolRaw: String = AIProtocolOption.chat.rawValue

    /// 模型列表（显示名 + modelId，首项为默认）。由 AIChatService 读写，本表单仅做编辑态。
    @State private var modelList: [AIModel] = []
    /// 当前选中模型的 modelId。
    @State private var selectedModelId: String = ""
    /// 候选池：端点返回的全部可用 model id（只读，供搜索挑选）。
    @State private var availableModels: [String] = []
    /// 候选池搜索关键词（本地过滤，不动持久层）。
    @State private var modelFilter: String = ""
    /// 正在从 API 拉取模型列表。
    @State private var isFetchingModels = false
    /// 拉取失败的行内中文提示。
    @State private var fetchError: String?
    
    /// Keychain 中已存 API Key（仅用于掩码展示，绝不持久化到 UserDefaults）
    @State private var storedKey: String = ""
    /// 新输入的 API Key（仅内存态，保存成功后清空）
    @State private var apiKeyInput: String = ""
    
    var body: some View {
        Form {
            Section {
                Picker("API 协议", selection: apiProtocolBinding) {
                    ForEach(AIProtocolOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } header: {
                Text("API 协议")
            } footer: {
                Text("Chat Completions 兼容大多数 OpenAI 兼容端点（中转 / Ollama / vLLM 等）；Responses 为 OpenAI 官方新协议，仅官方端点支持。选择 Responses 时 Base URL 填官方地址。")
            }
            
            Section {
                // 占位文案用中性描述且以 verbatim 传入，避免 URL 被 Markdown 自动识别成蓝色链接；
                // prompt 压成 contentTertiary 灰，与其他字段（如「输入 API Key」）的占位观感一致。
                TextField("Base URL", text: $baseURL, prompt: Text(verbatim: "例如 api.openai.com/v1").foregroundColor(Theme.Colors.contentTertiary))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Base URL")
            } footer: {
                // verbatim 纯文本：footer 中的示例地址不做 Markdown 链接着色，保持普通灰白说明文字。
                Text(verbatim: "OpenAI 兼容端点的根地址，程序会自动用所选协议拼接请求路径。官方端点填 https://api.openai.com/v1；本地 Ollama / vLLM 填 http://localhost:端口/v1。")
            }
            
            Section {
                if storedKey.isEmpty {
                    SecureField("输入 API Key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                } else {
                    HStack {
                        Text("已存储 ····\(maskedKeySuffix)")
                            .font(.system(size: Theme.Typography.body))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("清除") { clearAPIKey() }
                            .font(.system(size: Theme.Typography.body))
                    }
                    SecureField("输入新的 API Key 以替换", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                }
                
                if !trimmedAPIKeyInput.isEmpty {
                    HStack {
                        Spacer()
                        Button("保存 API Key") { saveAPIKey() }
                            .font(.system(size: Theme.Typography.body, weight: .medium))
                    }
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("API Key 仅保存于系统钥匙串（Keychain），绝不写入配置文件或 UserDefaults，避免随 iCloud / Time Machine 备份被明文带走。")
            }
            
            Section {
                if modelList.isEmpty {
                    Text("尚未配置模型，请添加一项，或从下方「可用模型」中添加。")
                        .font(.system(size: Theme.Typography.body))
                        .foregroundColor(.secondary)
                } else {
                    // 当前使用的模型（我的模型通常仅几条，Picker 不卡）
                    Picker("当前模型", selection: selectedModelBinding) {
                        ForEach(modelList) { item in
                            Text(item.name.isEmpty ? item.modelId : item.name).tag(item.modelId)
                        }
                    }

                    ForEach(Array(modelList.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("显示名", text: nameBinding(at: index))
                                    .textFieldStyle(.roundedBorder)
                                TextField("模型 ID", text: modelIdBinding(at: index))
                                    .textFieldStyle(.roundedBorder)
                                if index == 0 {
                                    Text("默认")
                                        .font(.system(size: Theme.Typography.mini, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            HStack(spacing: 10) {
                                Button("上移") { moveModel(from: index, to: index - 1) }
                                    .disabled(index == 0)
                                Button("下移") { moveModel(from: index, to: index + 1) }
                                    .disabled(index == modelList.count - 1)
                                Button("设为默认") { setDefaultModel(at: index) }
                                    .disabled(index == 0)
                                Button("删除", role: .destructive) { removeModel(at: index) }
                                Spacer(minLength: 0)
                                if selectedModelId == item.modelId {
                                    Text("当前使用")
                                        .font(.system(size: Theme.Typography.mini))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .font(.system(size: Theme.Typography.body))
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }

                    Button("添加模型") { addModel() }
                        .font(.system(size: Theme.Typography.body))
                }
            } header: {
                Text("我的模型")
            } footer: {
                Text("列表首项为默认模型；AI 窗的模型切换菜单只显示这里（我的模型）的条目。图片输入需端点与模型支持 vision。")
            }

            Section {
                // 候选池：只读、可搜索、可挑选加入「我的模型」；几百条也保持流畅。
                TextField("搜索模型 ID", text: $modelFilter)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Text(modelFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "共 \(availableModels.count) 个"
                         : "匹配 \(filteredAvailableModels.count) / \(availableModels.count)")
                        .font(.system(size: Theme.Typography.footnote))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Button("从 API 拉取") { fetchModelsFromAPI() }
                        .font(.system(size: Theme.Typography.body, weight: .medium))
                        .disabled(isFetchingModels)
                    if isFetchingModels {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let fetchError {
                    Text(fetchError)
                        .font(.system(size: Theme.Typography.body))
                        .foregroundColor(Theme.Colors.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if availableModels.isEmpty {
                    Text("候选池为空，点击「从 API 拉取」获取端点可用模型。")
                        .font(.system(size: Theme.Typography.body))
                        .foregroundColor(.secondary)
                } else {
                    // 固定高度 + LazyVStack：只渲染可视行，几百条滚动不卡；行内严禁 TextField。
                    // 滚动条隐藏：默认叠加式滚动条会压住行尾的「+」按钮，内容已有搜索过滤，无需滚动条存在感。
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredAvailableModels, id: \.self) { modelId in
                                HStack(spacing: 8) {
                                    Text(modelId)
                                        .font(.system(size: Theme.Typography.body))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundColor(isModelAdded(modelId) ? .secondary : .primary)
                                    Spacer(minLength: 0)
                                    if isModelAdded(modelId) {
                                        Text("已添加")
                                            .font(.system(size: Theme.Typography.mini))
                                            .foregroundColor(.secondary)
                                    } else {
                                        Button {
                                            addModelFromPool(modelId)
                                        } label: {
                                            Image(systemName: "plus.circle")
                                                .font(.system(size: Theme.Typography.body))
                                        }
                                        .buttonStyle(.borderless)
                                        .help("加入我的模型")
                                    }
                                }
                                .padding(.vertical, 1)
                                // 行尾让出安全边距：确保「+」按钮不被列表右缘裁切
                                .padding(.trailing, 6)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 末行完整可见：底部留出滚动余量
                        .padding(.bottom, 4)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 220)

                    if !filteredAvailableModels.isEmpty || !modelFilter.isEmpty {
                        Button("清空候选池", role: .destructive) { clearAvailableModels() }
                            .font(.system(size: Theme.Typography.footnote))
                    }
                }
            } header: {
                Text("可用模型")
            } footer: {
                Text("端点返回的全部模型候选，仅供挑选；点击 + 加入「我的模型」。候选池清空不影响我的模型。")
            }
            
            Section {
                TextField("留空则不发送 system 消息", text: $systemPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
            } header: {
                Text("System Prompt（可选）")
            } footer: {
                Text("可选的角色设定 / 前置指令，留空则不发送 system 消息。")
            }
            
            Section {
                HStack {
                    Text("打开 AI 对话窗")
                    Spacer()
                    KeyBadge(key: "双击 ⌥ / I")
                }
            } header: {
                Text("使用")
            } footer: {
                Text("全局双击 ⌥⌥ 随时唤出 / 关闭 AI 对话窗（热键可在「快捷键设置」中更改）；主面板激活时按 I 键亦可进入。")
            }
        }
        .onAppear {
            loadStoredKey()
            loadModelList()
        }
    }
    
    /// API 协议绑定：原始值字符串与枚举互转，默认 Chat Completions
    private var apiProtocolBinding: Binding<AIProtocolOption> {
        Binding(
            get: { AIProtocolOption(rawValue: apiProtocolRaw) ?? .chat },
            set: { apiProtocolRaw = $0.rawValue }
        )
    }
    
    /// 已存 key 的末 4 位掩码文本
    private var maskedKeySuffix: String {
        String(storedKey.suffix(4))
    }
    
    private var trimmedAPIKeyInput: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Keychain 读取走 AIChatService 公开接口（@MainActor），用 MainActor Task 包裹，
    /// 避免在非隔离的 View 上下文中直接调用产生隔离告警。
    private func loadStoredKey() {
        Task { @MainActor in
            storedKey = AIChatService.shared.apiKey ?? ""
        }
    }
    
    private func saveAPIKey() {
        let key = trimmedAPIKeyInput
        guard !key.isEmpty else { return }
        Task { @MainActor in
            AIChatService.shared.saveAPIKey(key)
            storedKey = key
            apiKeyInput = ""
        }
    }
    
    private func clearAPIKey() {
        Task { @MainActor in
            AIChatService.shared.deleteAPIKey()
            storedKey = ""
            apiKeyInput = ""
        }
    }

    // MARK: - 模型列表编辑

    /// 当前模型绑定：写回服务层，对下一轮请求生效。
    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { selectedModelId },
            set: { newValue in
                selectedModelId = newValue
                persistModelList()
            }
        )
    }

    private func nameBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { index < modelList.count ? modelList[index].name : "" },
            set: { newValue in
                guard index < modelList.count else { return }
                modelList[index].name = newValue
                persistModelList()
            }
        )
    }

    private func modelIdBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { index < modelList.count ? modelList[index].modelId : "" },
            set: { newValue in
                guard index < modelList.count else { return }
                let oldValue = modelList[index].modelId
                modelList[index].modelId = newValue
                if selectedModelId == oldValue {
                    selectedModelId = newValue
                }
                persistModelList()
            }
        )
    }

    private func loadModelList() {
        Task { @MainActor in
            modelList = AIChatService.shared.modelList
            selectedModelId = AIChatService.shared.selectedModel
            availableModels = AIChatService.shared.availableModels
        }
    }

    private func persistModelList() {
        let snapshot = modelList
        let selected = selectedModelId
        Task { @MainActor in
            var list = snapshot
            // 清理空 modelId 项，避免写入无效条目
            list.removeAll { $0.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            AIChatService.shared.modelList = list
            // 仅当选中项仍在列表中才写回，否则交由 setter 的校正逻辑兜底。
            if list.contains(where: { $0.modelId == selected }) {
                AIChatService.shared.selectedModel = selected
            }
        }
    }

    private func persistAvailableModels() {
        let snapshot = availableModels
        Task { @MainActor in
            AIChatService.shared.availableModels = snapshot
        }
    }

    private func addModel() {
        modelList.append(AIModel(name: "", modelId: ""))
        persistModelList()
    }

    private func removeModel(at index: Int) {
        guard index < modelList.count else { return }
        let removed = modelList.remove(at: index)
        if selectedModelId == removed.modelId, let first = modelList.first {
            selectedModelId = first.modelId
        }
        persistModelList()
    }

    private func moveModel(from index: Int, to target: Int) {
        guard modelList.indices.contains(index), modelList.indices.contains(target) else { return }
        modelList.swapAt(index, target)
        persistModelList()
    }

    /// 设为默认：移到首项并切换为当前模型。
    private func setDefaultModel(at index: Int) {
        guard modelList.indices.contains(index) else { return }
        let item = modelList.remove(at: index)
        modelList.insert(item, at: 0)
        selectedModelId = item.modelId
        persistModelList()
    }

    // MARK: - 候选池

    /// 本地过滤（忽略大小写，匹配 modelId），不动持久层。
    private var filteredAvailableModels: [String] {
        let keyword = modelFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return availableModels }
        return availableModels.filter { $0.lowercased().contains(keyword) }
    }

    private func isModelAdded(_ modelId: String) -> Bool {
        modelList.contains { $0.modelId == modelId }
    }

    /// 从候选池加入「我的模型」（显示名默认 = modelId）。
    private func addModelFromPool(_ modelId: String) {
        guard !isModelAdded(modelId) else { return }
        modelList.append(AIModel(name: modelId, modelId: modelId))
        persistModelList()
    }

    /// 清空候选池（条目都是拉来的，无需确认；不影响我的模型）。
    private func clearAvailableModels() {
        availableModels = []
        modelFilter = ""
        persistAvailableModels()
    }

    /// 从 API 拉取模型：结果只合并进候选池（去重），绝不直接进「我的模型」。
    private func fetchModelsFromAPI() {
        isFetchingModels = true
        fetchError = nil
        Task { @MainActor in
            do {
                let ids = try await AIChatService.shared.fetchModels()
                var existing = Set(availableModels)
                for id in ids where !existing.contains(id) {
                    availableModels.append(id)
                    existing.insert(id)
                }
                if availableModels.isEmpty {
                    fetchError = "接口未返回任何模型。"
                }
                persistAvailableModels()
            } catch {
                fetchError = error.localizedDescription
            }
            isFetchingModels = false
        }
    }
}

// MARK: - 基础组件: 按键微胶囊
struct KeyBadge: View {
    let key: String
    
    var body: some View {
        Text(key)
            .font(.system(size: Theme.Typography.keyCap, weight: .bold, design: .monospaced))
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
