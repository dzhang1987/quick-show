import SwiftUI

struct ExpandedMonitoringView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 8) {
            // 细若游丝的微光渐隐分割线
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.14),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
                .padding(.horizontal, 20)
            
            // 核心双列卡片 Bento Grid (左右对称卡片网格)
            HStack(spacing: 10) {
                // 左卡片：⚡️ 系统性能与网络
                VStack(alignment: .leading, spacing: 7) {
                    // 1. CPU 负载微槽
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.cyan)
                        
                        Text("CPU")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.65))
                            .frame(width: 25, alignment: .leading)
                        
                        Text(String(format: "%2.0f%%", appState.performanceInfo.cpuUsage))
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(cpuColor)
                            .frame(width: 28, alignment: .trailing)
                        
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.09))
                                Capsule()
                                    .fill(cpuColor)
                                    .frame(width: max(0, min(geo.size.width * CGFloat(appState.performanceInfo.cpuUsage / 100.0), geo.size.width)))
                            }
                        }
                        .frame(height: 3.5)
                    }
                    .frame(height: 14)
                    
                    // 2. RAM 内存微槽
                    HStack(spacing: 5) {
                        Image(systemName: "memorychip")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.mint)
                        
                        Text("RAM")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.65))
                            .frame(width: 25, alignment: .leading)
                        
                        Text(String(format: "%2.0f%%", appState.performanceInfo.memoryUsagePercent))
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(ramColor)
                            .frame(width: 28, alignment: .trailing)
                        
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.09))
                                Capsule()
                                    .fill(ramColor)
                                    .frame(width: max(0, min(geo.size.width * CGFloat(appState.performanceInfo.memoryUsagePercent / 100.0), geo.size.width)))
                            }
                        }
                        .frame(height: 3.5)
                    }
                    .frame(height: 14)
                    
                    Spacer(minLength: 0)
                    
                    // 3. 实时网络吞吐
                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.green.opacity(0.9))
                            Text(appState.trafficInfo.downloadSpeed)
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .foregroundColor(.white.opacity(0.85))
                        }
                        
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.cyan.opacity(0.9))
                            Text(appState.trafficInfo.uploadSpeed)
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .foregroundColor(.white.opacity(0.85))
                        }
                    }
                    .frame(height: 14)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                )
                
                // 右卡片：🎯 效率工具与已连接外设
                VStack(alignment: .leading, spacing: 7) {
                    // 1. 专注番茄钟微控件
                    HStack(spacing: 5) {
                        Image(systemName: "timer")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.orange)
                        
                        Text("番茄")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.65))
                        
                        Text(appState.formattedPomodoroTime)
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                            .foregroundColor(appState.pomodoroRunning ? .orange : .white.opacity(0.85))
                        
                        Spacer()
                        
                        // 播放 / 暂停
                        Button {
                            appState.togglePomodoro()
                        } label: {
                            Image(systemName: appState.pomodoroRunning ? "pause.fill" : "play.fill")
                                .font(.system(size: 8))
                                .foregroundColor(appState.pomodoroRunning ? .orange : .white.opacity(0.8))
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        
                        // 重置
                        Button {
                            appState.resetPomodoro()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(height: 14)
                    
                    // 2. 日历日程微胶囊
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.pink.opacity(0.85))
                        
                        if appState.calendarInfo.isAuthorized {
                            if appState.calendarInfo.hasEvent {
                                Text(appState.calendarInfo.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.90))
                                    .lineLimit(1)
                                
                                Text(appState.calendarInfo.timeDescription)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.pink.opacity(0.85))
                                    .lineLimit(1)
                            } else {
                                Text("今日暂无紧邻日程")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white.opacity(0.50))
                            }
                        } else {
                            Text("未授权日历")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.40))
                            Button("授权") {
                                appState.requestCalendarAccess { _ in }
                            }
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.cyan)
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(height: 14)
                    
                    Spacer(minLength: 0)
                    
                    // 3. 已连接外设清单 (Keychron、蓝牙鼠标等)
                    if !appState.bluetoothDevices.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(appState.bluetoothDevices.prefix(2), id: \.name) { dev in
                                HStack(spacing: 3) {
                                    Image(systemName: dev.iconName)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(Color.cyan.opacity(0.85))
                                    
                                    Text(compactDeviceName(dev.name))
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(.white.opacity(0.75))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(0.06))
                                )
                            }
                        }
                        .frame(height: 14)
                    } else {
                        Text("未连接蓝牙外设")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.35))
                            .frame(height: 14)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                )
            }
            .frame(height: 78)
            .padding(.horizontal, 18)
            .padding(.top, 2)
            
            // 底部轻巧按键提示
            HStack {
                Spacer()
                Text("Tab 极简模式 · Space 常驻 · ESC 退出")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.white.opacity(0.30))
                Spacer()
            }
            .padding(.bottom, 6)
        }
    }
    
    private func compactDeviceName(_ name: String) -> String {
        // 去除多余前缀，展示精炼设备名
        var s = name
        if s.hasPrefix("Keychron ") {
            s = s.replacingOccurrences(of: "Keychron ", with: "")
        }
        return s
    }
    
    private var cpuColor: Color {
        let usage = appState.performanceInfo.cpuUsage
        if usage > 85 { return Color.red.opacity(0.9) }
        if usage > 60 { return Color.orange.opacity(0.9) }
        return Color.cyan.opacity(0.9)
    }
    
    private var ramColor: Color {
        let usage = appState.performanceInfo.memoryUsagePercent
        if usage > 90 { return Color.red.opacity(0.9) }
        if usage > 75 { return Color.orange.opacity(0.9) }
        return Color.mint.opacity(0.9)
    }
}
