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

// MARK: - 日程详情（时间/地点/参会人/会议链接/备注 + 一键入会 + 编辑）
struct CalendarEventDetailView: View {
    @ObservedObject var appState: AppState
    let event: EKEvent
    
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE HH:mm"
        return f
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            // 顶部操作行：返回 / 编辑
            HStack {
                Button {
                    appState.selectedEvent = nil
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: Theme.Typography.mini, weight: .bold))
                        Text("返回")
                            .font(.system(size: Theme.Typography.caption, weight: .medium))
                    }
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(Capsule().fill(Theme.Colors.surfaceButton))
                }
                .buttonStyle(.plain)
                .help("返回日程列表")
                
                Spacer()
                
                Button {
                    appState.openEventEditor(for: event)
                } label: {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Image(systemName: "pencil")
                            .font(.system(size: Theme.Typography.tiny, weight: .bold))
                        Text("编辑")
                            .font(.system(size: Theme.Typography.caption, weight: .semibold))
                    }
                    .foregroundColor(Theme.Colors.accent.opacity(0.95))
                    .padding(.horizontal, Theme.Spacing.chip)
                    .padding(.vertical, Theme.Spacing.xxxs)
                    .background(Capsule().fill(Theme.Colors.accent.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .help("编辑日程")
            }
            
            // 标题
            Text(event.title ?? "日程")
                .font(.system(size: Theme.Typography.badge, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(2)
            
            // 信息行组
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                detailRow(icon: "clock", text: timeText)
                if let location = event.location, !location.isEmpty {
                    detailRow(icon: "mappin.and.ellipse", text: location)
                }
                if let calendar = event.calendar {
                    detailRow(icon: "calendar", text: "日历：\(calendar.title)")
                }
                if let attendees = event.attendees, !attendees.isEmpty {
                    let names = attendees.compactMap { $0.name }.prefix(3).joined(separator: "、")
                    let suffix = attendees.count > 3 ? " 等 \(attendees.count) 人" : ""
                    detailRow(icon: "person.2", text: "参会人：\(names)\(suffix)")
                }
                if let notes = event.notes, !notes.isEmpty {
                    detailRow(icon: "note.text", text: notes, lineLimit: 3)
                }
            }
            
            // 一键入会
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
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(Capsule().fill(Color.pink.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .help("呼出会议客户端入会 (腾讯会议/Zoom/Teams/飞书)")
            }
            
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private var timeText: String {
        if event.isAllDay {
            return Self.dateTimeFormatter.string(from: event.startDate).components(separatedBy: " ").prefix(2).joined(separator: " ") + " · 全天"
        }
        let start = Self.dateTimeFormatter.string(from: event.startDate)
        let endFormatter = DateFormatter()
        endFormatter.dateFormat = "HH:mm"
        return "\(start) – \(endFormatter.string(from: event.endDate))"
    }
    
    private func detailRow(icon: String, text: String, lineLimit: Int = 1) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(Theme.Colors.contentTertiary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: Theme.Typography.body))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
                .lineLimit(lineLimit)
        }
    }
}

// MARK: - 日程编辑表单（自建轻量表单：macOS 无 EKEventEditViewController，EventKitUI 仅 iOS/Catalyst）
// 字段：标题 / 全天 / 日期 / 起止时间 / 地点 / 备注 / 所属日历；EKEventStore 保存
struct CalendarEventEditView: View {
    @ObservedObject var appState: AppState
    @Binding var draft: CalendarEditDraft
    @State private var writableCalendars: [EKCalendar] = []
    
    private var isNew: Bool { draft.eventID == nil }
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            // 标题行
            HStack {
                Text(isNew ? "新建日程" : "编辑日程")
                    .font(.system(size: Theme.Typography.callout, weight: .bold))
                    .foregroundColor(.primary)
                Spacer()
                if !isNew {
                    Button {
                        appState.deleteEditingEvent()
                    } label: {
                        Text("删除")
                            .font(.system(size: Theme.Typography.caption, weight: .medium))
                            .foregroundColor(Color.red.opacity(0.9))
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xxs)
                            .background(Capsule().fill(Color.red.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("删除该日程")
                }
            }
            
            // 字段网格
            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.xl, verticalSpacing: Theme.Spacing.lg) {
                GridRow {
                    fieldLabel("标题")
                    TextField("日程标题", text: $draft.title)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    fieldLabel("全天")
                    Toggle("", isOn: $draft.isAllDay)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .scaleEffect(0.7)
                        .frame(height: 18)
                }
                GridRow {
                    fieldLabel("日期")
                    DatePicker("", selection: $draft.startDate, displayedComponents: .date)
                        .labelsHidden()
                }
                if !draft.isAllDay {
                    GridRow {
                        fieldLabel("开始")
                        DatePicker("", selection: $draft.startDate, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                    GridRow {
                        fieldLabel("结束")
                        DatePicker("", selection: $draft.endDate, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }
                GridRow {
                    fieldLabel("地点")
                    TextField("选填", text: $draft.location)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    fieldLabel("日历")
                    Picker("", selection: $draft.calendarID) {
                        Text("默认日历").tag(nil as String?)
                        ForEach(writableCalendars, id: \.calendarIdentifier) { cal in
                            Text(cal.title).tag(cal.calendarIdentifier as String?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
                GridRow {
                    fieldLabel("备注")
                    TextField("选填", text: $draft.notes)
                        .textFieldStyle(.roundedBorder)
                }
            }
            
            // 操作行
            HStack {
                Spacer()
                Button {
                    appState.cancelEventEditing()
                } label: {
                    Text("取消")
                        .font(.system(size: Theme.Typography.caption, weight: .medium))
                        .foregroundColor(Theme.Colors.contentSecondaryStrong)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Capsule().fill(Theme.Colors.surfaceButton))
                }
                .buttonStyle(.plain)
                
                Button {
                    appState.saveEventEditing()
                } label: {
                    Text(isNew ? "创建" : "保存")
                        .font(.system(size: Theme.Typography.caption, weight: .bold))
                        .foregroundColor(draft.title.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.Colors.idleText : Theme.Colors.solidButtonText)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(
                            Capsule()
                                .fill(draft.title.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.Colors.surfaceBadge : Theme.Colors.solidButtonFill)
                        )
                }
                .buttonStyle(.plain)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            writableCalendars = SystemStatusProvider.shared.writableEventCalendars()
            // 新建态默认跟随系统默认日历
            if draft.calendarID == nil {
                draft.calendarID = SystemStatusProvider.shared.calendarEventStore.defaultCalendarForNewEvents?.calendarIdentifier
            }
        }
        // 开始时间变更时，若结束时间被反超则自动顺延 1 小时
        .onChange(of: draft.startDate) { newStart in
            if draft.endDate <= newStart {
                draft.endDate = newStart.addingTimeInterval(3600)
            }
        }
    }
    
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.Typography.label, weight: .semibold))
            .foregroundColor(Theme.Colors.contentSecondaryStrong)
            .frame(width: 34, alignment: .trailing)
    }
}
