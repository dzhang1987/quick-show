import SwiftUI
import EventKit

// MARK: - 日历网格单元缓存模型
// 由 AppState.refreshCalendarData() 在后台队列预生成（农历/节气/事件点），
// 视图层纯渲染，避免秒级 tick 重算农历
struct CalendarDayCell: Equatable, Identifiable {
    let date: Date
    let day: Int              // 公历日
    let isToday: Bool
    let isInCurrentScope: Bool // 月视图下是否属于当前月（前后月灰显）
    let lunarText: String     // 农历日次/月名
    let festival: String?     // 传统节日
    let solarTerm: String?    // 节气
    let hasEvents: Bool
    
    var id: Date { date }
    
    /// 格子小字优先级：传统节日 > 节气 > 农历日
    var badgeText: String { festival ?? solarTerm ?? lunarText }
}

// MARK: - 日历视图（监控看板态按 G 进入；月/周/日三视图 + 农历节气 + 当日日程）
struct CalendarPanelView: View {
    @ObservedObject var appState: AppState
    
    private var metrics: PanelLayoutMetrics { appState.currentMetrics() }
    
    // 月历格子行高（按档令牌：日历态整面板填充，垂直空间充裕）
    private var cellHeight: CGFloat { metrics.calendarCellHeight }
    
    var body: some View {
        // 日历态 = 整面板 100% 归日历（无时钟/底栏/分割线），单张 Bento 大卡贴面板主边距排布
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            headerBar
            
            if let draft = appState.calendarEditing {
                // 编辑表单：替换网格与列表区（新建/编辑共用）
                CalendarEventEditView(
                    appState: appState,
                    draft: Binding(
                        get: { appState.calendarEditing ?? draft },
                        set: { appState.calendarEditing = $0 }
                    )
                )
            } else {
                // 网格（月/周视图；日视图无网格）
                if appState.calendarViewMode != .day {
                    gridView
                }
                
                // 选中日信息 + 日程列表 / 详情
                if let event = appState.selectedEvent {
                    CalendarEventDetailView(appState: appState, event: event)
                } else {
                    selectedDayHeader
                    eventListView
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, Theme.Spacing.card)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Colors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.Colors.cardStroke, lineWidth: 0.75)
        )
        .padding(.horizontal, Theme.Spacing.panel)
        .padding(.top, Theme.Layout.calendarTop)
        .padding(.bottom, Theme.Layout.calendarBottom)
    }
    
    // MARK: 顶栏：视图切换 + 年月标题 + 干支生肖 + 今天/新建
    private var headerBar: some View {
        HStack(spacing: Theme.Spacing.xl) {
            // 月/周/日 切换胶囊组（1/2/3 键同义）
            HStack(spacing: Theme.Spacing.xxs) {
                ForEach(CalendarViewMode.allCases) { mode in
                    Button {
                        appState.setCalendarViewMode(mode)
                    } label: {
                        Text(mode.shortName)
                            .font(.system(size: Theme.Typography.caption, weight: appState.calendarViewMode == mode ? .bold : .medium))
                            // 未选中态用面板二级强色（系统 .secondary 亮玻璃 ≈3.9:1 已弃用）
                            .foregroundColor(appState.calendarViewMode == mode ? Theme.Colors.solidButtonText : Theme.Colors.contentSecondaryStrong)
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, Theme.Spacing.xxs)
                            .background(
                                Capsule()
                                    .fill(appState.calendarViewMode == mode ? Theme.Colors.solidButtonFill : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("按 \(mode.rawValue) 切换")
                }
            }
            .padding(Theme.Spacing.xxs)
            .background(Capsule().fill(Theme.Colors.surfaceBadge))
            
            Spacer()
            
            // 标题：随视图语义（月=年月，周=日期范围，日=具体日）+ 干支生肖年小字
            VStack(alignment: .center, spacing: Theme.Spacing.xxxs) {
                Text(headerTitle)
                    .font(.system(size: Theme.Typography.calendarTitle, weight: .bold))
                    .foregroundColor(.primary)
                Text(LunarCalendar.ganzhiZodiacYear(for: appState.calendarAnchorDate))
                    .font(.system(size: Theme.Typography.calendarLunar, weight: .medium))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }
            
            Spacer()
            
            // 回到今天（底色加深一档衬出文字，避免 0.65 灰字与 0.05 灰底粘连）
            Button {
                appState.calendarJumpToToday()
            } label: {
                Text("今天")
                    .font(.system(size: Theme.Typography.caption, weight: .medium))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(Capsule().fill(Theme.Colors.badgeFill))
            }
            .buttonStyle(.plain)
            .help("回到今天")
            
            // 新建日程
            Button {
                appState.openEventEditor(for: nil)
            } label: {
                HStack(spacing: Theme.Spacing.xxs) {
                    Image(systemName: "plus")
                        .font(.system(size: Theme.Typography.tiny, weight: .bold))
                    Text("新建日程")
                        .font(.system(size: Theme.Typography.caption, weight: .semibold))
                }
                .foregroundColor(Theme.Colors.accent.opacity(0.95))
                .padding(.horizontal, Theme.Spacing.chip)
                .padding(.vertical, Theme.Spacing.xxxs)
                .background(Capsule().fill(Theme.Colors.accent.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .help("新建日程（内联表单）")
        }
    }
    
    private var headerTitle: String {
        let cal = Calendar.current
        let anchor = appState.calendarAnchorDate
        switch appState.calendarViewMode {
        case .month:
            return String(format: "%d 年 %d 月", cal.component(.year, from: anchor), cal.component(.month, from: anchor))
        case .week:
            let range = AppState.gridDateRange(anchor: anchor, mode: .week)
            let start = range.lowerBound
            let end = cal.date(byAdding: .day, value: -1, to: range.upperBound) ?? start
            return String(format: "%d月%d日 – %d月%d日",
                          cal.component(.month, from: start), cal.component(.day, from: start),
                          cal.component(.month, from: end), cal.component(.day, from: end))
        case .day:
            return String(format: "%d 年 %d 月 %d 日",
                          cal.component(.year, from: anchor), cal.component(.month, from: anchor), cal.component(.day, from: anchor))
        }
    }
    
    // MARK: 网格（周标题 + 6×7 / 1×7）
    private var gridView: some View {
        VStack(spacing: Theme.Spacing.xxs) {
            // 周标题（周一为首列，贴合中文习惯；表头不能比内容还弱——11pt + 二级强色）
            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { d in
                    Text(d)
                        .font(.system(size: Theme.Typography.calendarWeekday, weight: .medium))
                        .foregroundColor(Theme.Colors.contentSecondaryStrong)
                        .frame(maxWidth: .infinity)
                }
            }
            
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: Theme.Spacing.xxs) {
                ForEach(appState.calendarGridCells) { cell in
                    CalendarDayCellView(
                        cell: cell,
                        height: appState.calendarViewMode == .week ? cellHeight * 1.4 : cellHeight,
                        isSelected: Calendar.current.isDate(cell.date, inSameDayAs: appState.selectedDate)
                    )
                    .onTapGesture {
                        appState.selectCalendarDate(cell.date)
                    }
                }
            }
        }
    }
    
    // MARK: 选中日信息行：「10月1日 星期四 · 八月二十 · 中秋节」
    private var selectedDayHeader: some View {
        let cal = Calendar.current
        let date = appState.selectedDate
        let weekdays = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        var parts = [String(format: "%d月%d日 %@", cal.component(.month, from: date), cal.component(.day, from: date), weekdays[cal.component(.weekday, from: date)])]
        parts.append(LunarCalendar.dayText(for: date))
        if let festival = LunarCalendar.festival(for: date) { parts.append(festival) }
        if let term = LunarCalendar.solarTerm(for: date) { parts.append(term) }
        
        return HStack(spacing: Theme.Spacing.sm) {
            Text(parts.joined(separator: " · "))
                .font(.system(size: Theme.Typography.label, weight: .semibold))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
            Spacer()
            Text("\(appState.dayEvents.count) 场日程")
                .font(.system(size: Theme.Typography.mini, weight: .medium))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
        }
    }
    
    // MARK: 日程列表（未授权优雅降级；农历/节气不受权限影响）
    private var eventListView: some View {
        Group {
            if !appState.calendarInfo.isAuthorized {
                HStack {
                    Text("未授权访问日历，无法读取日程（农历与节气不受影响）")
                        .font(.system(size: Theme.Typography.label))
                        .foregroundStyle(Theme.Colors.contentTertiary)
                    Spacer()
                    Button("点击授权") {
                        appState.requestCalendarAccess { _ in
                            appState.refreshCalendarData()
                        }
                    }
                    .font(.system(size: Theme.Typography.footnote, weight: .semibold))
                    .foregroundColor(Theme.Colors.accent)
                    .buttonStyle(.plain)
                }
                .frame(maxHeight: .infinity)
            } else if appState.dayEvents.isEmpty {
                Text("当日暂无日程 · 保持专注")
                    .font(.system(size: Theme.Typography.label, weight: .medium))
                    .foregroundStyle(Theme.Colors.contentTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: Theme.Spacing.xs) {
                        ForEach(appState.dayEvents, id: \.eventIdentifier) { event in
                            CalendarEventRow(appState: appState, event: event)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: - 月/周日历格子
struct CalendarDayCellView: View {
    let cell: CalendarDayCell
    let height: CGFloat
    let isSelected: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // 公历日数字（格子主内容：13.5pt semibold；今日 accent 圆底 + 深色字高对比高亮）
            Text("\(cell.day)")
                .font(.system(size: Theme.Typography.calendarDay, weight: cell.isToday ? .bold : .semibold))
                .foregroundColor(dayColor)
                .frame(width: 19, height: 19)
                .background(
                    Circle()
                        .fill(cell.isToday ? Theme.Colors.accent : Color.clear)
                )
                .padding(.top, Theme.Spacing.xxs)
            
            // 农历小字（传统节日 > 节气 > 农历日次；10pt medium，彩色实色不半透明——
            // 彩色半透明细体在亮玻璃上比灰字更糊；框高 11 与数字框 19 + 顶部 2 恰填满 legacy 档 32pt 格子）
            Text(cell.badgeText)
                .font(.system(size: Theme.Typography.calendarLunar, weight: .medium))
                .foregroundColor(badgeColor)
                .lineLimit(1)
                .frame(height: 11)
            
            Spacer(minLength: 0)
            
            // 事件点（legacy 档格子高度紧张时压缩内容不压字号：隐藏事件点，日程仍在下方列表展示）
            if height >= 36 {
                Circle()
                    .fill(cell.hasEvents ? Theme.Colors.accent : Color.clear)
                    .frame(width: 4, height: 4)
                    .padding(.bottom, Theme.Spacing.xxs)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .fill(isSelected && !cell.isToday ? Theme.Colors.surfaceTrack : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .stroke(isSelected && !cell.isToday ? Theme.Colors.badgeStroke : Color.clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
    
    private var dayColor: Color {
        // 今日：accent（亮青）圆底上压深色字（双模式 ≈8:1，白字压 cyan 仅 ≈2:1 不达标）
        if cell.isToday { return Color.black.opacity(0.8) }
        // 非当月日期承载信息（可点击翻页选中），不能用装饰档弱化到融进背景：
        // 数字走三级说明档（0.55），与农历弱档（0.45）拉开层级
        return cell.isInCurrentScope ? .primary : Theme.Colors.contentTertiary
    }
    
    private var badgeColor: Color {
        if cell.festival != nil { return Color.orange }
        if cell.solarTerm != nil { return Theme.Colors.accent }
        // 农历日次：普通日走三级说明色（≈4.7:1 达标），非当前月保持弱档装饰性灰显（层级差）
        return cell.isInCurrentScope ? Theme.Colors.contentTertiary : Theme.Colors.idleText
    }
}

// MARK: - 日程行（时间 / 日历色条 / 标题 / 一键入会；点击进详情）
struct CalendarEventRow: View {
    @ObservedObject var appState: AppState
    let event: EKEvent
    
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // 开始时间（全天日程显示「全天」）
            Text(event.isAllDay ? "全天" : Self.timeFormatter.string(from: event.startDate))
                .font(.system(size: Theme.Typography.caption, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
                .frame(width: 34, alignment: .leading)
            
            // 日历来源色条
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(event.calendar.map { Color(cgColor: $0.cgColor) } ?? Theme.Colors.accent)
                .frame(width: 3, height: 14)
            
            Text(event.title ?? "日程")
                .font(.system(size: Theme.Typography.body, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            
            Spacer(minLength: 0)
            
            // 会议类型微胶囊（一键入会）
            if let meetingURL = SystemStatusProvider.shared.extractMeetingURL(from: [event.notes, event.url?.absoluteString, event.location]) {
                Button {
                    appState.joinMeeting(url: meetingURL)
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "video.fill")
                            .font(.system(size: Theme.Typography.tiny))
                        Text("一键入会")
                            .font(.system(size: Theme.Typography.caption, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, Theme.Spacing.mdlg)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(Capsule().fill(Color.pink.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .help("呼出会议客户端入会 (腾讯会议/Zoom/Teams/飞书)")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .fill(Theme.Colors.surfaceBadge)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedEvent = event
        }
    }
}
