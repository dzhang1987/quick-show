import Foundation
import EventKit

// MARK: - 日历事件提醒 / 日历视图数据 (EventKit)
// 唯一持有 EKEventStore：提醒、按日/范围查询、草稿保存/删除、会议链接识别均归本类
final class CalendarProvider {
    // 日历 EventStore（唯一归属）
    private let eventStore = EKEventStore()

    // MARK: - 日历事件提醒 (EventKit)
    func getCalendarAuthorizationStatus() -> EKAuthorizationStatus {
        return EKEventStore.authorizationStatus(for: .event)
    }
    
    func requestCalendarAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        }
    }
    
    func getNextCalendarEvent() -> CalendarEventInfo {
        let authStatus = EKEventStore.authorizationStatus(for: .event)
        let isAuthorized: Bool
        if #available(macOS 14.0, *) {
            isAuthorized = (authStatus == .fullAccess || authStatus == .authorized)
        } else {
            isAuthorized = (authStatus == .authorized)
        }
        
        guard isAuthorized else {
            return CalendarEventInfo(hasEvent: false, title: "", timeDescription: "", isAuthorized: false)
        }
        
        let now = Date()
        let calendar = Calendar.current
        // 查询接下来 18 个小时内的事件
        guard let endDate = calendar.date(byAdding: .hour, value: 18, to: now) else {
            return CalendarEventInfo(hasEvent: false, title: "", timeDescription: "", isAuthorized: true)
        }
        
        let predicate = eventStore.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: endDate, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
        
        guard let next = events.first else {
            return CalendarEventInfo(hasEvent: false, title: String(localized: "暂无紧邻日程"), timeDescription: String(localized: "尽情专注"), isAuthorized: true)
        }
        
        let timeDesc: String
        if next.startDate <= now && next.endDate > now {
            let leftMinutes = max(1, Int(next.endDate.timeIntervalSince(now) / 60))
            timeDesc = String(localized: "进行中 · 剩 \(leftMinutes) 分钟")
        } else {
            let startMinutes = max(1, Int(next.startDate.timeIntervalSince(now) / 60))
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let startStr = formatter.string(from: next.startDate)
            if startMinutes < 60 {
                timeDesc = String(localized: "\(startStr) · 还有 \(startMinutes) 分钟")
            } else {
                let hours = startMinutes / 60
                let remMin = startMinutes % 60
                if remMin > 0 {
                    timeDesc = String(localized: "\(startStr) · 还有 \(hours)小时\(remMin)分")
                } else {
                    timeDesc = String(localized: "\(startStr) · 还有 \(hours)小时")
                }
            }
        }
        
        let meetingURL = extractMeetingURL(from: [next.notes, next.url?.absoluteString, next.location])
        
        return CalendarEventInfo(
            hasEvent: true,
            title: next.title ?? String(localized: "日历日程"),
            timeDescription: timeDesc,
            isAuthorized: true,
            meetingURL: meetingURL,
            nextEventStartDate: next.startDate
        )
    }
    
    // MARK: - 日历视图数据（EventKit 按日/范围查询；均为同步查询，调用方负责后台线程）
    
    /// EKEventStore 只读暴露（EKEventEditViewController sheet 需要注入同一 store）
    var calendarEventStore: EKEventStore { eventStore }
    
    /// 当前是否已授权日历访问
    var isCalendarAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess || status == .authorized
        }
        return status == .authorized
    }
    
    /// 查询指定日期的全部日程（含全天事件），按开始时间排序
    func getEvents(on date: Date) -> [EKEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }
    
    /// 查询范围内有日程的日期集合（月历/周历格子事件点用），元素为 yyyy-MM-dd 键；
    /// 跨天事件覆盖其经过的每一天
    func getEventDaySet(from start: Date, to end: Date) -> Set<String> {
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
        let cal = Calendar.current
        var days = Set<String>()
        for event in events {
            var day = cal.startOfDay(for: event.startDate)
            let endDay = cal.startOfDay(for: event.endDate)
            while day <= endDay {
                days.insert(Self.dayKey(day))
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
                // 防御：极端超长事件最多遍历 400 天
                if days.count > 400 { break }
            }
        }
        return days
    }
    
    /// 日期键（事件点集合 / 网格缓存共用）
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func dayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }
    
    /// 可写日历列表（编辑表单的所属日历选择项）
    func writableEventCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .event).filter { $0.allowsContentModifications }
    }
    
    /// 保存日程草稿：新建或回写既有日程；全天事件按 EventKit 惯例 end = start + 1 天。
    /// 均为同步写操作，调用方负责后台线程
    func saveEventDraft(_ draft: CalendarEditDraft) {
        let event: EKEvent
        if let id = draft.eventID, let existing = eventStore.event(withIdentifier: id) {
            event = existing
        } else {
            event = EKEvent(eventStore: eventStore)
        }
        event.title = draft.title
        event.isAllDay = draft.isAllDay
        if draft.isAllDay {
            let cal = Calendar.current
            let start = cal.startOfDay(for: draft.startDate)
            event.startDate = start
            event.endDate = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        } else {
            event.startDate = draft.startDate
            // 保证结束晚于开始（防止用户把结束时间拨到开始之前）
            event.endDate = max(draft.endDate, draft.startDate.addingTimeInterval(15 * 60))
        }
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        // 所属日历：指定且可写则采用；否则保持原日历/系统默认
        if let calID = draft.calendarID,
           let target = eventStore.calendars(for: .event).first(where: { $0.calendarIdentifier == calID }),
           target.allowsContentModifications {
            event.calendar = target
        } else if event.calendar == nil {
            event.calendar = eventStore.defaultCalendarForNewEvents
        }
        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            NSLog("[QuickShow] 保存日程失败: \(error)")
        }
    }
    
    /// 删除日程（按标识；同步写操作，调用方负责后台线程）
    func deleteEvent(withIdentifier identifier: String) {
        guard let event = eventStore.event(withIdentifier: identifier) else { return }
        do {
            try eventStore.remove(event, span: .thisEvent)
        } catch {
            NSLog("[QuickShow] 删除日程失败: \(error)")
        }
    }
    
    private static let meetingPatterns = [
        "https?://[a-zA-Z0-9.-]*meeting\\.tencent\\.com/[^\\s>\"]+",
        "https?://[a-zA-Z0-9.-]*zoom\\.us/j/[^\\s>\"]+",
        "https?://meet\\.google\\.com/[a-z0-9\\-]+[^\\s>\"]*",
        "https?://teams\\.microsoft\\.com/l/meetup-join/[^\\s>\"]+",
        "https?://[a-zA-Z0-9.-]*feishu\\.cn/vc/[^\\s>\"]+",
        "https?://[a-zA-Z0-9.-]*larksuite\\.com/vc/[^\\s>\"]+"
    ]
    
    /// 从候选文本（备注/链接/地点）中识别会议链接（腾讯会议/Zoom/Meet/Teams/飞书），日历视图列表与详情复用
    func extractMeetingURL(from strings: [String?]) -> URL? {
        for str in strings {
            guard let text = str, !text.isEmpty else { continue }
            for pattern in Self.meetingPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
                   let range = Range(match.range, in: text) {
                    let urlStr = String(text[range])
                    if let url = URL(string: urlStr) {
                        return url
                    }
                }
            }
        }
        return nil
    }
}