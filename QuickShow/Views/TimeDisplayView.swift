import SwiftUI

struct TimeDisplayView: View {
    @ObservedObject var appState: AppState
    
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
            // 顶部日期徽章：精美磨砂微胶囊，层次分明
            Text(dateFormatted)
                .font(.system(size: 12, weight: .semibold, design: .default))
                .tracking(1.2)
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                )
            
            // 核心大字时钟：具有力量感与张力的 SF Pro 饱满排版（绝非干瘪细线）
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                if let period = period {
                    Text(period)
                        .font(.system(size: 18, weight: .bold, design: .default))
                        .foregroundColor(.white.opacity(0.70))
                        .padding(.trailing, 2)
                }
                
                // 时与分：68pt Medium 字重，结实有力，纯白高对比
                Text(hourMinute)
                    .font(.system(size: 68, weight: .medium, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white, Color(white: 0.94)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 2)
                
                // 秒数：32pt 紧凑清晰副排版
                if appState.showSeconds {
                    HStack(spacing: 2) {
                        Text(":")
                            .font(.system(size: 32, weight: .light, design: .default))
                            .foregroundColor(.white.opacity(0.40))
                            .offset(y: -2)
                        
                        Text(seconds)
                            .font(.system(size: 32, weight: .semibold, design: .default))
                            .monospacedDigit()
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.95), Color.white.opacity(0.75)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: Color.black.opacity(0.30), radius: 3, x: 0, y: 1)
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }
}
