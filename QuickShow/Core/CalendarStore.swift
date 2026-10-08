import SwiftUI
import Combine
import EventKit

// MARK: - 日历视图模式（1/2/3 键切换）
enum CalendarViewMode: Int, CaseIterable, Identifiable {
    case month = 1
    case week = 2
    case day = 3

    var id: Int { rawValue }

    var shortName: String {
        switch self {
        case .month: return String(localized: "月")
        case .week: return String(localized: "周")
        case .day: return String(localized: "日")
        }
    }
}

// 临近会议提醒（<5 分钟时一瞥底栏高亮倒计时胶囊）
struct UpcomingMeetingInfo: Equatable {
    var title: String
    var minutes: Int
}

// MARK: - 日历域
/// 日历视图全部 @Published 状态 + 网格静态方法 + 编辑管线 + 刷新管线 + tick 订阅。
/// 上下文路由（showCalendarView / activateContext）留在门面；dismiss 清理走 resetOnDismiss()。
final class CalendarStore: ObservableObject {
    @Published var calendarViewMode: CalendarViewMode = .month
    @Published var calendarAnchorDate: Date = Date()       // 翻页锚点（月视图=当月，周=当周，日=当天）
    @Published var selectedDate: Date = Date()             // 选中日期（日程列表展示日）
    @Published var calendarGridCells: [CalendarDayCell] = []  // 网格缓存模型（月 42 格 / 周 7 格）
    @Published var dayEvents: [EKEvent] = []               // 选中日全部日程缓存
    @Published var selectedEvent: EKEvent? = nil           // 详情展示中的日程（点击条目进入）
    // 日程编辑草稿（内联编辑表单状态；nil = 未在编辑）
    @Published var calendarEditing: CalendarEditDraft? = nil
    @Published var calendarInfo: CalendarEventInfo = CalendarEventInfo(hasEvent: false, title: "", timeDescription: "", isAuthorized: false)
    // 临近会议提醒（<5 分钟高亮；主时钟秒级 tick 基于缓存开始时刻本地计算，零新增轮询）
    @Published var upcomingMeeting: UpcomingMeetingInfo? = nil
    // 跨天检测锚点（日历视图数据按天缓存，跨天自动刷新）
    private var lastTickDay: Date? = nil

    private var cancellables = Set<AnyCancellable>()
    private weak var facade: AppState?

    /// 订阅主时钟：临近会议（每 tick）+ 日历信息保鲜（count%60==10）+ 跨天检测。
    func attach(tick: AnyPublisher<AppTick, Never>, facade: AppState) {
        self.facade = facade
        tick.sink { [weak self, weak facade] tick in
            guard let self, let facade else { return }

            // 临近会议倒计时：<5 分钟时一瞥底栏高亮胶囊
            //（基于缓存的下一场开始时刻本地计算，零新增 EventKit 轮询）
            if let start = self.calendarInfo.nextEventStartDate, self.calendarInfo.hasEvent {
                let remain = start.timeIntervalSince(tick.date)
                if remain > 0 && remain < 300 {
                    let minutes = Int(ceil(remain / 60.0))
                    let next = UpcomingMeetingInfo(title: self.calendarInfo.title, minutes: minutes)
                    if self.upcomingMeeting != next {
                        self.upcomingMeeting = next
                    }
                } else if self.upcomingMeeting != nil {
                    self.upcomingMeeting = nil
                }
            } else if self.upcomingMeeting != nil {
                self.upcomingMeeting = nil
            }

            // 日历信息低频保鲜：每分钟静默刷新一次（pinned 常驻时临近提醒数据不陈旧）
            if facade.showCalendar && tick.count % 60 == 10 {
                BackgroundQueues.statusRefresh.async { [weak self] in
                    let info = SystemStatusProvider.shared.getNextCalendarEvent()
                    DispatchQueue.main.async { self?.calendarInfo = info }
                }
            }

            // 跨天检测：日历视图数据（网格农历/事件点/当日日程）按天缓存，跨天自动刷新
            if let lastDay = self.lastTickDay, !Calendar.current.isDate(tick.date, inSameDayAs: lastDay) {
                if facade.showCalendarView {
                    self.refreshCalendarData()
                }
            }
            self.lastTickDay = tick.date
        }.store(in: &cancellables)
    }

    // MARK: - 视图/翻页/选中
    func setCalendarViewMode(_ mode: CalendarViewMode) {
        guard let facade, facade.showCalendarView, calendarViewMode != mode else { return }
        calendarViewMode = mode
        selectedEvent = nil
        refreshCalendarData()
    }

    /// 翻页：月历 ±月、周历 ±周、日历 ±天（语义随当前视图）
    func calendarPageForward() { calendarPage(by: 1) }
    func calendarPageBackward() { calendarPage(by: -1) }

    private func calendarPage(by offset: Int) {
        let cal = Calendar.current
        let component: Calendar.Component
        switch calendarViewMode {
        case .month: component = .month
        case .week: component = .weekOfYear
        case .day: component = .day
        }
        guard let newAnchor = cal.date(byAdding: component, value: offset, to: calendarAnchorDate) else { return }
        calendarAnchorDate = newAnchor
        // 选中日期跟随翻页语义：月视图选中新月首日，周视图选中新周首日，日视图即当日
        switch calendarViewMode {
        case .month:
            selectedDate = cal.date(from: cal.dateComponents([.year, .month], from: newAnchor)) ?? newAnchor
        case .week:
            selectedDate = Self.gridStartDate(anchor: newAnchor, mode: .week) ?? newAnchor
        case .day:
            selectedDate = newAnchor
        }
        selectedEvent = nil
        refreshCalendarData()
    }

    /// 回到今天（顶栏「今天」按钮）
    func calendarJumpToToday() {
        calendarAnchorDate = Date()
        selectedDate = Date()
        selectedEvent = nil
        refreshCalendarData()
    }

    /// 选中某日（点击网格格子）
    func selectCalendarDate(_ date: Date) {
        selectedDate = date
        selectedEvent = nil
        refreshCalendarData()
    }

    // MARK: - 编辑管线
    /// 打开日程编辑（内联表单；nil = 新建，默认选中日下一个整点起 1 小时）
    /// 注：macOS 无 EKEventEditViewController（EventKitUI 仅 iOS/Catalyst），
    /// 故采用自建轻量表单（SwiftUI 内联于日历视图），EKEventStore 保存
    func openEventEditor(for event: EKEvent?) {
        if let event = event {
            calendarEditing = CalendarEditDraft(event: event)
        } else {
            calendarEditing = CalendarEditDraft(newOn: selectedDate)
        }
    }

    func cancelEventEditing() {
        calendarEditing = nil
    }

    /// 保存编辑草稿：新建或回写既有日程（EventKit 写操作放后台串行队列，完成回主线程刷新）
    func saveEventEditing() {
        guard let draft = calendarEditing, !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        calendarEditing = nil
        selectedEvent = nil
        BackgroundQueues.statusRefresh.async { [weak self] in
            SystemStatusProvider.shared.saveEventDraft(draft)
            DispatchQueue.main.async {
                guard let self else { return }
                // 选中日期跟随保存结果；若当前网格范围不含该日（跨月/周编辑），锚点一并跳转
                let range = Self.gridDateRange(anchor: self.calendarAnchorDate, mode: self.calendarViewMode)
                if !(draft.startDate >= range.lowerBound && draft.startDate < range.upperBound) {
                    self.calendarAnchorDate = draft.startDate
                }
                self.selectedDate = draft.startDate
                self.refreshCalendarData()
            }
        }
    }

    /// 删除正在编辑的日程（仅编辑态可用）
    func deleteEditingEvent() {
        guard let eventID = calendarEditing?.eventID else { return }
        calendarEditing = nil
        selectedEvent = nil
        BackgroundQueues.statusRefresh.async { [weak self] in
            SystemStatusProvider.shared.deleteEvent(withIdentifier: eventID)
            DispatchQueue.main.async {
                self?.refreshCalendarData()
            }
        }
    }

    /// 日历视图数据刷新：网格缓存模型 + 选中日日程，后台串行队列查询，结果回主线程。
    /// 仅在进入视图/翻页/视图切换/选中变更/编辑保存/跨天时调用，避免每秒 tick 全量查询；
    /// 未授权时日程与事件点为空（视图层显示授权引导），农历/节气不依赖权限照常可用。
    func refreshCalendarData() {
        guard let facade, facade.showCalendarView else { return }
        let mode = calendarViewMode
        let anchor = calendarAnchorDate
        let selected = selectedDate
        let authorized = SystemStatusProvider.shared.isCalendarAuthorized
        BackgroundQueues.statusRefresh.async { [weak self] in
            guard let self else { return }
            let provider = SystemStatusProvider.shared
            let range = Self.gridDateRange(anchor: anchor, mode: mode)
            let eventDays = authorized ? provider.getEventDaySet(from: range.lowerBound, to: range.upperBound) : []
            let cells = Self.buildGridCells(anchor: anchor, mode: mode, eventDays: eventDays)
            let events = authorized ? provider.getEvents(on: selected) : []
            DispatchQueue.main.async {
                self.calendarGridCells = cells
                self.dayEvents = events
            }
        }
    }

    /// 面板 dismiss 时的日历瞬态清理（对齐原 dismiss 内联清理；lastTickDay 不重置）
    func resetOnDismiss() {
        selectedEvent = nil
        calendarEditing = nil
        calendarGridCells = []
        dayEvents = []
        upcomingMeeting = nil
    }

    // MARK: - 网格静态方法
    /// 网格起始日（周一为首列，贴合中文习惯）：月视图 = 当月 1 号所在周的周一，周视图 = 锚点所在周周一
    static func gridStartDate(anchor: Date, mode: CalendarViewMode) -> Date? {
        gridDateRange(anchor: anchor, mode: mode).lowerBound
    }

    /// 网格覆盖的日期范围（月视图 42 格 / 周视图 7 格 / 日视图当天）
    static func gridDateRange(anchor: Date, mode: CalendarViewMode) -> (lowerBound: Date, upperBound: Date) {
        let cal = Calendar.current
        switch mode {
        case .month:
            let comps = cal.dateComponents([.year, .month], from: anchor)
            let firstOfMonth = cal.date(from: comps) ?? anchor
            let weekday = cal.component(.weekday, from: firstOfMonth)   // 1 = 周日
            let offset = (weekday + 5) % 7                              // 距周一的天数
            let start = cal.date(byAdding: .day, value: -offset, to: firstOfMonth) ?? firstOfMonth
            let end = cal.date(byAdding: .day, value: 42, to: start) ?? start
            return (start, end)
        case .week:
            let weekday = cal.component(.weekday, from: anchor)
            let offset = (weekday + 5) % 7
            let start = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: anchor)) ?? anchor
            let end = cal.date(byAdding: .day, value: 7, to: start) ?? start
            return (start, end)
        case .day:
            let start = cal.startOfDay(for: anchor)
            let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
            return (start, end)
        }
    }

    /// 生成日历网格缓存模型（月视图 42 格 / 周视图 7 格；农历/节气本地计算，事件点来自 EventKit）
    private static func buildGridCells(anchor: Date, mode: CalendarViewMode, eventDays: Set<String>) -> [CalendarDayCell] {
        guard mode != .day else { return [] }
        let cal = Calendar.current
        let range = gridDateRange(anchor: anchor, mode: mode)
        let count = (mode == .month) ? 42 : 7
        var cells: [CalendarDayCell] = []
        for i in 0..<count {
            guard let date = cal.date(byAdding: .day, value: i, to: range.lowerBound) else { continue }
            let festival = LunarCalendar.festival(for: date)
            let term = LunarCalendar.solarTerm(for: date)
            cells.append(CalendarDayCell(
                date: date,
                day: cal.component(.day, from: date),
                isToday: cal.isDateInToday(date),
                isInCurrentScope: mode == .month ? cal.isDate(date, equalTo: anchor, toGranularity: .month) : true,
                lunarText: LunarCalendar.dayText(for: date),
                festival: festival,
                solarTerm: term,
                hasEvents: eventDays.contains(SystemStatusProvider.dayKey(date))
            ))
        }
        return cells
    }
}