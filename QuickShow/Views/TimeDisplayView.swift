import SwiftUI

struct TimeDisplayView: View {
    @ObservedObject var appState: AppState
    var panelWidth: CGFloat = 680
    
    private var clockFontSize: CGFloat {
        // 系统聚焦级大字排版：440宽为84pt，540宽为98pt，680宽为124pt，顶天立地主角气场
        min(max(panelWidth * 0.183, 84.0), 126.0)
    }
    
    private var secondsFontSize: CGFloat {
        clockFontSize * 0.42
    }
    
    private var periodFontSize: CGFloat {
        clockFontSize * 0.22
    }
    
    // 静态缓存 DateFormatter，避免每秒重复分配 ICU 字典与本地化对象
    private static let hourMinute24: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    
    private static let hourMinute12: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()
    
    private static let secFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "ss"
        return f
    }()
    
    private static let ampmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "a"
        return f
    }()
    
    private var hourMinute: String {
        let formatter = appState.is24HourFormat ? Self.hourMinute24 : Self.hourMinute12
        return formatter.string(from: appState.currentTime)
    }
    
    private var seconds: String {
        Self.secFormatter.string(from: appState.currentTime)
    }
    
    private var period: String? {
        guard !appState.is24HourFormat else { return nil }
        return Self.ampmFormatter.string(from: appState.currentTime)
    }
    
    private var dateFormatted: String {
        let calendar = Calendar.current
        let date = appState.currentTime
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let weekday = calendar.component(.weekday, from: date)
        
        let weekdayNames = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        let weekdayStr = (weekday >= 1 && weekday <= 7) ? weekdayNames[weekday - 1] : ""
        let year = calendar.component(.year, from: date)
        
        return "\(year)年\(month)月\(day)日 · \(weekdayStr)"
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // 顶部日期徽章与灵动微反馈系统 (Zero-UI Toast)
            Group {
                if let toast = appState.toastMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color.green.opacity(0.95))
                        
                        Text(toast)
                            .font(.system(size: 12.5, weight: .semibold, design: .default))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4.5)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                            )
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    Button {
                        appState.openCalendarApp()
                    } label: {
                        Text(dateFormatted)
                            .font(.system(size: 13, weight: .semibold, design: .default))
                            .tracking(1.2)
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4.5)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.08))
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("点击打开系统日历")
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: appState.toastMessage)
            
            // 核心大字时钟：原生超大字重、纯正黑曜石光感
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                if let period = period {
                    Text(period)
                        .font(.system(size: periodFontSize, weight: .bold, design: .default))
                        .foregroundColor(.white.opacity(0.70))
                        .padding(.trailing, 2)
                }
                
                // 时与分：原生 104pt 大字号 Medium 字重，结实有力，纯白高对比
                Text(hourMinute)
                    .font(.system(size: clockFontSize, weight: .medium, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white, Color(white: 0.94)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Color.black.opacity(0.40), radius: 6, x: 0, y: 3)
                
                // 秒数：紧凑清晰副排版
                if appState.showSeconds {
                    HStack(spacing: 2) {
                        Text(":")
                            .font(.system(size: secondsFontSize, weight: .light, design: .default))
                            .foregroundColor(.white.opacity(0.40))
                            .offset(y: -2)
                        
                        Text(seconds)
                            .font(.system(size: secondsFontSize, weight: .semibold, design: .default))
                            .monospacedDigit()
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.95), Color.white.opacity(0.75)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 2)
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }
}
