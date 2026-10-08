import SwiftUI
import Foundation

// MARK: - 面板尺寸档位
enum PanelScaleOption: String, CaseIterable, Identifiable {
    case auto = "auto"
    case standard = "standard"
    case compact = "compact"
    case legacy = "legacy"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "自动（跟随当前屏幕智能自适应，推荐）")
        case .standard: return String(localized: "系统聚焦大号（宽 680 pt，红框聚焦标杆）")
        case .compact: return String(localized: "适中舒适（宽 540 pt）")
        case .legacy: return String(localized: "极简小巧（宽 440 pt）")
        }
    }
}

// MARK: - 世界时钟城市（时区可配置，rawValue 即 IANA 时区标识符）
enum WorldClockCity: String, CaseIterable, Identifiable {
    case none = "none"
    case beijing = "Asia/Shanghai"
    case tokyo = "Asia/Tokyo"
    case singapore = "Asia/Singapore"
    case london = "Europe/London"
    case paris = "Europe/Paris"
    case berlin = "Europe/Berlin"
    case newYork = "America/New_York"
    case sanFrancisco = "America/Los_Angeles"
    case sydney = "Australia/Sydney"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return String(localized: "无")
        case .beijing: return String(localized: "北京")
        case .tokyo: return String(localized: "东京")
        case .singapore: return String(localized: "新加坡")
        case .london: return String(localized: "伦敦")
        case .paris: return String(localized: "巴黎")
        case .berlin: return String(localized: "柏林")
        case .newYork: return String(localized: "纽约")
        case .sanFrancisco: return String(localized: "旧金山")
        case .sydney: return String(localized: "悉尼")
        }
    }

    var timeZone: TimeZone? { TimeZone(identifier: rawValue) }
}

// MARK: - 用户偏好设置域
/// 全部 @AppStorage 持久化偏好的唯一存储；门面 AppState 通过 AppState+Forwarding 转发。
/// 带副作用的类型化 setter（triggerType/appearanceMode/themeVariant/panelScaleOption/showMenuBarIcon）
/// 留在门面扩展，引用回调与 HotKeyManager/Theme，副作用原样。
final class SettingsStore: ObservableObject {
    @AppStorage("showOnLaunch") var showOnLaunch: Bool = true
    @AppStorage("glanceDuration") var glanceDuration: Double = 3.0
    @AppStorage("showSeconds") var showSeconds: Bool = true
    @AppStorage("is24HourFormat") var is24HourFormat: Bool = true
    @AppStorage("showMenuBarIcon") var storedShowMenuBarIcon: Bool = true

    // 一瞥底栏微标展示开关
    @AppStorage("showBattery") var showBattery: Bool = true
    @AppStorage("showWiFi") var showWiFi: Bool = true
    @AppStorage("showBluetooth") var showBluetooth: Bool = true
    @AppStorage("showAudio") var showAudio: Bool = true
    @AppStorage("showDND") var showDND: Bool = true
    @AppStorage("showNowPlaying") var showNowPlaying: Bool = true

    // 世界时钟三槽位配置（可在偏好设置改为「无」隐藏对应槽位，默认北京/伦敦/纽约）
    @AppStorage("worldClockCity1") var worldClockCity1Raw: String = WorldClockCity.beijing.rawValue
    @AppStorage("worldClockCity2") var worldClockCity2Raw: String = WorldClockCity.london.rawValue
    @AppStorage("worldClockCity3") var worldClockCity3Raw: String = WorldClockCity.newYork.rawValue

    // 扩展监控展示开关
    @AppStorage("showPerformance") var showPerformance: Bool = true
    @AppStorage("showNetworkSpeed") var showNetworkSpeed: Bool = true
    @AppStorage("showCalendar") var showCalendar: Bool = false
    @AppStorage("enablePomodoro") var enablePomodoro: Bool = false

    @AppStorage("triggerType") var triggerTypeRaw: String = TriggerType.doubleCmd.rawValue
    // AI 对话窗全局热键（独立分流；默认双击 ⌥⌥）。rawValue 存储，旧值（任意侧）继续有效。
    @AppStorage("aiTriggerTypeRaw") var aiTriggerTypeRaw: String = TriggerType.doubleOpt.rawValue

    // 界面尺寸与屏幕自适应
    @AppStorage("panelScaleOption") var panelScaleOptionRaw: String = PanelScaleOption.auto.rawValue
    // 外观主题变体（默认黑曜石 / 琥珀暖色）
    @AppStorage("themeVariant") var themeVariantRaw: String = ThemeVariant.standard.rawValue
    // 明暗模式（自动 / 浅色 / 深色，全 App 范围）
    @AppStorage("appearanceMode") var appearanceModeRaw: String = AppearanceMode.dark.rawValue

    // MARK: - 世界时钟派生
    /// 生效的世界时钟城市列表（剔除「无」并去重，保持槽位顺序）
    var worldClockCities: [WorldClockCity] {
        var seen = Set<String>()
        return [worldClockCity1Raw, worldClockCity2Raw, worldClockCity3Raw]
            .compactMap { WorldClockCity(rawValue: $0) }
            .filter { $0 != .none && seen.insert($0.rawValue).inserted }
    }

    // 复用单实例 Formatter：面板每秒刷新时钟，避免反复创建
    private let worldClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    func worldClockTimeString(for city: WorldClockCity, at date: Date) -> String {
        guard let tz = city.timeZone else { return "--:--" }
        worldClockFormatter.timeZone = tz
        return worldClockFormatter.string(from: date)
    }
}