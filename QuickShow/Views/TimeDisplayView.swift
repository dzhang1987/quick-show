import SwiftUI

struct TimeDisplayView: View {
    @ObservedObject var appState: AppState
    // 面板实际渲染宽度（随窗口动画逐帧连续变化），驱动下方字号连续缩放，主角时钟永不跳档；
    // 首帧布局尚未测得实际宽度时，由调用方传入目标尺寸作兜底
    var panelWidth: CGFloat = 680
    
    private var clockFontSize: CGFloat {
        // 系统聚焦级大字排版：440宽为84pt，540宽为98pt，680宽为124pt，顶天立地主角气场
        min(max(panelWidth * Theme.Typography.clockScale, Theme.Typography.clockMin), Theme.Typography.clockMax)
    }
    
    private var secondsFontSize: CGFloat {
        clockFontSize * Theme.Typography.secondsRatio
    }
    
    private var periodFontSize: CGFloat {
        clockFontSize * Theme.Typography.periodRatio
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
        VStack(spacing: Theme.Spacing.lg) {
            // 顶部日期徽章与灵动微反馈系统 (Zero-UI Toast)
            Group {
                if let toast = appState.toastMessage {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: Theme.Typography.body, weight: .semibold))
                            .foregroundColor(Color.green.opacity(0.95))
                        
                        Text(toast)
                            .font(.system(size: Theme.Typography.toast, weight: .semibold, design: .default))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Theme.Spacing.xxxl)
                    .padding(.vertical, Theme.Spacing.smd)
                    .background(
                        // 语义色：primary 随玻璃明暗自动翻转；
                        // toast 是强提示，胶囊底/描边需明显高于普通徽章，亮玻璃下依然可感知
                        Capsule()
                            .fill(Theme.Colors.toastFill)
                            .overlay(
                                Capsule()
                                    .stroke(Theme.Colors.toastStroke, lineWidth: 0.5)
                            )
                    )
                    .transition(.opacity.combined(with: .scale(scale: Theme.Motion.toastScale)))
                } else {
                    Button {
                        appState.openCalendarApp()
                    } label: {
                        Text(dateFormatted)
                            .font(.system(size: Theme.Typography.badge, weight: .semibold, design: .default))
                            .tracking(Theme.Typography.badgeTracking)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, Theme.Spacing.xxxl)
                            .padding(.vertical, Theme.Spacing.smd)
                            .background(
                                // 日期徽章底/描边上调对比度下限：黑色低 alpha 在亮玻璃下会"洗白"消失
                                Capsule()
                                    .fill(Theme.Colors.badgeFill)
                                    .overlay(
                                        Capsule()
                                            .stroke(Theme.Colors.badgeStroke, lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("点击打开系统日历")
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: Theme.Motion.contentFade), value: appState.toastMessage)
            
            // 核心大字时钟：原生超大字重、纯正黑曜石光感
            HStack(alignment: .lastTextBaseline, spacing: Theme.Spacing.md) {
                if let period = period {
                    Text(period)
                        .font(.system(size: periodFontSize, weight: .bold, design: .default))
                        .foregroundColor(.secondary)
                        .padding(.trailing, Theme.Spacing.xxs)
                }
                
                // 时与分：原生 104pt 大字号 Medium 字重，结实有力，高对比主角（primary 随玻璃明暗自动翻转）
                Text(hourMinute)
                    .font(.system(size: clockFontSize, weight: .medium, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.Colors.clockGradientTop, Theme.Colors.clockGradientBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                
                // 秒数：紧凑清晰副排版
                if appState.showSeconds {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Text(":")
                            .font(.system(size: secondsFontSize, weight: .light, design: .default))
                            .foregroundStyle(.tertiary)
                            .offset(y: -2)
                        
                        Text(seconds)
                            .font(.system(size: secondsFontSize, weight: .semibold, design: .default))
                            .monospacedDigit()
                            .foregroundStyle(
                                // 三级副排版：primary 低透明度渐变，保留细腻质感且随玻璃翻转
                                LinearGradient(
                                    colors: [Theme.Colors.secondsGradientTop, Theme.Colors.secondsGradientBottom],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    .padding(.leading, Theme.Spacing.xxs)
                }
            }
        }
    }
}
