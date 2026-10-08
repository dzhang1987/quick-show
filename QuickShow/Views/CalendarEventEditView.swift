import SwiftUI
import EventKit

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
                Text(isNew ? String(localized: "新建日程") : String(localized: "编辑日程"))
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
                    fieldLabel(String(localized: "标题"))
                    TextField("日程标题", text: $draft.title)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    fieldLabel(String(localized: "全天"))
                    Toggle("", isOn: $draft.isAllDay)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .scaleEffect(0.7)
                        .frame(height: 18)
                }
                GridRow {
                    fieldLabel(String(localized: "日期"))
                    DatePicker("", selection: $draft.startDate, displayedComponents: .date)
                        .labelsHidden()
                }
                if !draft.isAllDay {
                    GridRow {
                        fieldLabel(String(localized: "开始"))
                        DatePicker("", selection: $draft.startDate, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                    GridRow {
                        fieldLabel(String(localized: "结束"))
                        DatePicker("", selection: $draft.endDate, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }
                GridRow {
                    fieldLabel(String(localized: "地点"))
                    TextField("选填", text: $draft.location)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    fieldLabel(String(localized: "日历"))
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
                    fieldLabel(String(localized: "备注"))
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
                    Text(isNew ? String(localized: "创建") : String(localized: "保存"))
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
