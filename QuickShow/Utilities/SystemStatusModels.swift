import Foundation
import AppKit
import EventKit

// MARK: - 数据模型定义

struct BatteryInfo: Equatable {
    var percentage: Int
    var isCharging: Bool
    var isOnACPower: Bool   // 是否接通外接电源（插电但已满电时 isCharging=false，此字段区分"插电"与"纯电池"）
    var hasBattery: Bool
}

struct WiFiInfo: Equatable {
    var isConnected: Bool
    var ssid: String?
}

struct BluetoothDeviceInfo: Equatable {
    var isConnected: Bool
    var name: String
    var batteryLevel: Int?
    var iconName: String
}

struct AudioInfo: Equatable {
    var deviceName: String
    var volume: Int        // 0 ~ 100
    var isMuted: Bool
    var isHeadphones: Bool
}

struct DNDInfo: Equatable {
    var isEnabled: Bool
}

struct SystemPerformanceInfo: Equatable {
    var cpuUsage: Double          // 0.0 ~ 100.0%
    var memoryUsagePercent: Double // 0.0 ~ 100.0%
    var memoryUsedGB: Double
    var memoryTotalGB: Double
}

struct NetworkTrafficInfo: Equatable {
    var downloadSpeed: String
    var uploadSpeed: String
}

struct DiskInfo: Equatable {
    var freeGB: Double
    var totalGB: Double
}

struct CalendarEventInfo: Equatable {
    var hasEvent: Bool
    var title: String
    var timeDescription: String
    var isAuthorized: Bool
    var meetingURL: URL?
    var nextEventStartDate: Date? = nil   // 下一场日程开始时刻（临近提醒倒计时基准，秒级 tick 本地计算）
}

struct NowPlayingInfo: Equatable {
    var title: String           // 曲目名
    var artist: String          // 艺术家（可为空）
    var album: String           // 专辑（可为空）
    var appName: String         // 来源应用名（如 Apple Music / Spotify）
    var bundleIdentifier: String? // 来源应用 BundleID（用于点击激活）
    var isPlaying: Bool
    var duration: Double        // 总时长（秒，0 = 未知/流媒体）
    var elapsedTime: Double     // 采样时刻的已播时长（秒）
    var playbackRate: Double    // 播放速率（通常 1.0，暂停为 0）
    var timestamp: Date?        // elapsedTime 的采样时刻（本地插值基准）
    var artwork: NSImage?       // 解码后的封面（Provider 侧已按内容指纹缓存）
    
    /// 当前已播时长（本地插值推进）：播放中 = 基准值 + 距采样时刻 × 速率；
    /// 暂停时停止插值恒返回基准值；总时长已知时钳制不越界
    func currentElapsed(at now: Date) -> Double {
        guard isPlaying, playbackRate > 0, let ts = timestamp else { return elapsedTime }
        let estimated = elapsedTime + now.timeIntervalSince(ts) * playbackRate
        return duration > 0 ? min(max(0, estimated), duration) : max(0, estimated)
    }
}

// 媒体控制命令 ID（MRCommand，对应 adapter send 子命令）
enum MediaCommand: Int {
    case togglePlayPause = 2   // kMRATogglePlayPause
    case nextTrack = 4
    case previousTrack = 5
    case skipBackward15 = 12   // 后退 15 秒
    case skipForward15 = 13    // 快进 15 秒
}

// 日程编辑草稿（内联编辑表单的状态载体；eventID nil = 新建）
struct CalendarEditDraft: Equatable {
    var eventID: String?
    var title: String
    var isAllDay: Bool
    var startDate: Date
    var endDate: Date
    var location: String
    var notes: String
    var calendarID: String?   // 所属日历标识（nil = 系统默认日历）
    
    /// 新建：默认选中日下一个整点起 1 小时
    init(newOn date: Date) {
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: date)
        let nextHour: Date
        if cal.isDateInToday(date) {
            // 今天：下一个整点
            let hour = cal.component(.hour, from: now)
            nextHour = cal.date(bySettingHour: hour + 1, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(3600)
        } else {
            // 其他日：上午 9 点
            nextHour = cal.date(bySettingHour: 9, minute: 0, second: 0, of: startOfDay) ?? startOfDay
        }
        self.eventID = nil
        self.title = ""
        self.isAllDay = false
        self.startDate = nextHour
        self.endDate = nextHour.addingTimeInterval(3600)
        self.location = ""
        self.notes = ""
        self.calendarID = nil
    }
    
    /// 编辑：从既有日程载入字段
    init(event: EKEvent) {
        self.eventID = event.eventIdentifier
        self.title = event.title ?? ""
        self.isAllDay = event.isAllDay
        self.startDate = event.startDate
        self.endDate = event.endDate
        self.location = event.location ?? ""
        self.notes = event.notes ?? ""
        self.calendarID = event.calendar?.calendarIdentifier
    }
}