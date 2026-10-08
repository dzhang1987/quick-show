import SwiftUI
import EventKit

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
            Text(event.title ?? String(localized: "日程"))
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
                    detailRow(icon: "calendar", text: String(localized: "日历：\(calendar.title)"))
                }
                if let attendees = event.attendees, !attendees.isEmpty {
                    let names = attendees.compactMap { $0.name }.prefix(3).joined(separator: "、")
                    let suffix = attendees.count > 3 ? " " + String(localized: "等 \(attendees.count) 人") : ""
                    detailRow(icon: "person.2", text: String(localized: "参会人：\(names)\(suffix)"))
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
            return Self.dateTimeFormatter.string(from: event.startDate).components(separatedBy: " ").prefix(2).joined(separator: " ") + " " + String(localized: "· 全天")
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
