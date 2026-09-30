import SwiftUI

struct ExpandedMonitoringView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 8) {
            // 微光分割细线
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
                .padding(.horizontal, 22)
            
            VStack(spacing: 7) {
                // 1. 系统性能负载模块 (CPU & RAM)
                if appState.showPerformance {
                    HStack(spacing: 16) {
                        // CPU
                        HStack(spacing: 6) {
                            Image(systemName: "cpu")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.cyan)
                            
                            Text("CPU")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                            
                            Text(String(format: "%.0f%%", appState.performanceInfo.cpuUsage))
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundColor(cpuColor)
                            
                            // 极简微进度槽
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.1))
                                    Capsule()
                                        .fill(cpuColor)
                                        .frame(width: max(0, min(geo.size.width * CGFloat(appState.performanceInfo.cpuUsage / 100.0), geo.size.width)))
                                }
                            }
                            .frame(height: 4)
                        }
                        
                        // RAM
                        HStack(spacing: 6) {
                            Image(systemName: "memorychip")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.mint)
                            
                            Text("RAM")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                            
                            Text(String(format: "%.0f%%", appState.performanceInfo.memoryUsagePercent))
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundColor(ramColor)
                            
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.1))
                                    Capsule()
                                        .fill(ramColor)
                                        .frame(width: max(0, min(geo.size.width * CGFloat(appState.performanceInfo.memoryUsagePercent / 100.0), geo.size.width)))
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                    .frame(height: 18)
                }
                
                // 2. 实时网络吞吐与番茄钟/日历综合行
                HStack(spacing: 12) {
                    // 实时网速
                    if appState.showNetworkSpeed {
                        HStack(spacing: 8) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.green.opacity(0.9))
                                Text(appState.trafficInfo.downloadSpeed)
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.cyan.opacity(0.9))
                                Text(appState.trafficInfo.uploadSpeed)
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundColor(.white.opacity(0.85))
                            }
                        }
                    }
                    
                    Spacer(minLength: 4)
                    
                    // 番茄钟极简快捷操作
                    if appState.enablePomodoro {
                        HStack(spacing: 6) {
                            Button {
                                appState.togglePomodoro()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: appState.pomodoroRunning ? "pause.fill" : "play.fill")
                                        .font(.system(size: 9))
                                    Text(appState.formattedPomodoroTime)
                                        .font(.system(size: 11, weight: .semibold))
                                        .monospacedDigit()
                                }
                                .foregroundColor(appState.pomodoroRunning ? .orange : .white.opacity(0.8))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(appState.pomodoroRunning ? Color.orange.opacity(0.18) : Color.white.opacity(0.08))
                                )
                            }
                            .buttonStyle(.plain)
                            
                            Button {
                                appState.resetPomodoro()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .help("重置番茄钟为 25 分钟")
                        }
                    }
                }
                .frame(height: 18)
                
                // 3. 日历日程提醒（若开启且有日程/权限）
                if appState.showCalendar {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.pink.opacity(0.9))
                        
                        if appState.calendarInfo.isAuthorized {
                            if appState.calendarInfo.hasEvent {
                                Text(appState.calendarInfo.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineLimit(1)
                                
                                Text(appState.calendarInfo.timeDescription)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.pink.opacity(0.85))
                                    .lineLimit(1)
                            } else {
                                Text(appState.calendarInfo.title.isEmpty ? "今日暂无紧邻日程" : appState.calendarInfo.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                                Text(appState.calendarInfo.timeDescription)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        } else {
                            Text("未授权日历访问")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                            
                            Button("去授权") {
                                appState.requestCalendarAccess { _ in }
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.cyan)
                            .buttonStyle(.plain)
                        }
                        
                        Spacer()
                    }
                    .frame(height: 18)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 2)
            
            // 底部按键提示
            HStack {
                Spacer()
                Text("Tab 极简模式 · Space 常驻 · ESC 退出")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.white.opacity(0.35))
                Spacer()
            }
            .padding(.bottom, 6)
        }
    }
    
    private var cpuColor: Color {
        let usage = appState.performanceInfo.cpuUsage
        if usage > 85 {
            return Color.red.opacity(0.9)
        } else if usage > 60 {
            return Color.orange.opacity(0.9)
        }
        return Color.cyan.opacity(0.9)
    }
    
    private var ramColor: Color {
        let usage = appState.performanceInfo.memoryUsagePercent
        if usage > 90 {
            return Color.red.opacity(0.9)
        } else if usage > 75 {
            return Color.orange.opacity(0.9)
        }
        return Color.mint.opacity(0.9)
    }
}
