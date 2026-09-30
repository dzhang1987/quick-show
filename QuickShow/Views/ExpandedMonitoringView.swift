import SwiftUI

struct ExpandedMonitoringView: View {
    @ObservedObject var appState: AppState
    
    // 监控区理想总高：分割线 0.5 + 间距 8 + 卡片 225 + 卡片上下 padding 2+6
    // PanelView 展开/收起时以此值为占位高度目标做 0.18s 连续插值（Hero 生长/收拢）
    static let contentHeight: CGFloat = 241.5
    
    // 适配展开态 (520pt 高度) 的 Bento 卡片黄金高度：225 pt
    private let cardHeight: CGFloat = 225
    
    var body: some View {
        VStack(spacing: 8) {
            // 细若游丝的微光渐隐分割线
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.0),
                            Color.primary.opacity(0.25),
                            Color.primary.opacity(0.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
                .padding(.horizontal, 20)
            
            // 核心双列卡片 Bento Grid (左右对称卡片网格，卡片高度 205pt)
            HStack(spacing: 12) {
                // MARK: - 左卡片：⚡️ 系统性能与网络吞吐
                VStack(alignment: .leading, spacing: 10) {
                    // 1. 顶部微标头
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: "cpu.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.cyan.opacity(0.95))
                            Text("系统性能与网络")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundColor(.primary)
                        }
                        
                        Spacer()
                        
                        Button {
                            appState.openActivityMonitor()
                        } label: {
                            HStack(spacing: 3) {
                                Text("活动监视器")
                                    .font(.system(size: 9.5, weight: .medium))
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 8.5))
                            }
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                        .help("双击卡片或点击打开系统活动监视器")
                    }
                    
                    // 2. CPU 负载槽
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("CPU 负载")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            if let topProc = appState.topCPUProcess {
                                Text(topProc)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.orange.opacity(0.95))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.orange.opacity(0.18)))
                                    .lineLimit(1)
                            } else {
                                Text("平稳运行")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            
                            Text(String(format: "%2.0f%%", appState.performanceInfo.cpuUsage))
                                .font(.system(size: 11.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundColor(cpuColor)
                                .frame(width: 36, alignment: .trailing)
                        }
                        
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.06))
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [cpuColor.opacity(0.8), cpuColor],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(0, min(geo.size.width * CGFloat(appState.performanceInfo.cpuUsage / 100.0), geo.size.width)))
                            }
                        }
                        .frame(height: 5)
                    }
                    
                    // 3. RAM 内存槽
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("内存占用")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Text("\(String(format: "%.1f", appState.performanceInfo.memoryUsedGB))G / \(Int(appState.performanceInfo.memoryTotalGB))G")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                            
                            // 一键内存优化清理微按钮
                            Button {
                                appState.optimizeMemory()
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 8, weight: .bold))
                                    Text("清理")
                                        .font(.system(size: 8.5, weight: .semibold))
                                }
                                .foregroundColor(.mint.opacity(0.95))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.mint.opacity(0.16)))
                            }
                            .buttonStyle(.plain)
                            .help("一键优化清理系统内存 (按 C)")
                            
                            Text(String(format: "%2.0f%%", appState.performanceInfo.memoryUsagePercent))
                                .font(.system(size: 11.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundColor(ramColor)
                                .frame(width: 36, alignment: .trailing)
                        }
                        
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.06))
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [ramColor.opacity(0.8), ramColor],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(0, min(geo.size.width * CGFloat(appState.performanceInfo.memoryUsagePercent / 100.0), geo.size.width)))
                            }
                        }
                        .frame(height: 5)
                    }
                    
                    // 4. 本地磁盘存储空间 (Disk)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "internaldrive")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                                Text("系统磁盘")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if appState.diskInfo.totalGB > 0 {
                                Text("\(Int(appState.diskInfo.freeGB))G 可用 / \(Int(appState.diskInfo.totalGB))G")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            
                            Button {
                                appState.openDownloadsFolder()
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: 8))
                                    Text("下载")
                                        .font(.system(size: 8.5, weight: .medium))
                                }
                                .foregroundColor(.cyan.opacity(0.85))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.cyan.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .help("秒开 Downloads 下载目录 (按 O)")
                        }
                        
                        GeometryReader { geo in
                            let usedRatio: CGFloat = appState.diskInfo.totalGB > 0 ? CGFloat((appState.diskInfo.totalGB - appState.diskInfo.freeGB) / appState.diskInfo.totalGB) : 0.5
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.06))
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.purple.opacity(0.8), Color.indigo.opacity(0.9)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(0, min(geo.size.width * usedRatio, geo.size.width)))
                            }
                        }
                        .frame(height: 5)
                    }
                    
                    Spacer(minLength: 2)
                    
                    // 5. 实时网络吞吐与本机 IP
                    HStack {
                        // 吞吐速率
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.green.opacity(0.95))
                                Text(appState.trafficInfo.downloadSpeed)
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                            }
                            
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.cyan.opacity(0.95))
                                Text(appState.trafficInfo.uploadSpeed)
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                            }
                        }
                        
                        Spacer()
                        
                        // 局域网 IP (点击复制)
                        Button {
                            appState.copyLocalIP()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(.tertiary)
                                Text("复制内网 IP")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                        .help("点击一键复制局域网 IP")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.09), lineWidth: 0.75)
                )
                .onTapGesture(count: 2) {
                    appState.openActivityMonitor()
                }
                
                // MARK: - 右卡片：🎯 专注工坊与效率日程
                VStack(alignment: .leading, spacing: 10) {
                    // 1. 顶部微标头
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: "timer")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.orange.opacity(0.95))
                            Text("专注与日常工作流")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundColor(.primary)
                        }
                        
                        Spacer()
                        
                        Text(appState.pomodoroRunning ? "专注中" : "就绪")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(appState.pomodoroRunning ? .orange : Color.primary.opacity(0.35))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(appState.pomodoroRunning ? Color.orange.opacity(0.18) : Color.primary.opacity(0.04))
                            )
                    }
                    
                    // 2. 番茄钟工作台
                    HStack(spacing: 10) {
                        // 倒计时大字
                        Text(appState.formattedPomodoroTime)
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(appState.pomodoroRunning ? .orange : .primary)
                            .shadow(color: appState.pomodoroRunning ? Color.orange.opacity(0.3) : .clear, radius: 4)
                        
                        // 预设时长快捷切换胶囊 (25m / 45m / 5m)
                        HStack(spacing: 4) {
                            PomodoroPresetButton(title: "25m", minutes: 25, appState: appState)
                            PomodoroPresetButton(title: "45m", minutes: 45, appState: appState)
                            PomodoroPresetButton(title: "5m", minutes: 5, appState: appState)
                        }
                        
                        Spacer()
                        
                        // 播放 / 暂停按钮
                        Button {
                            appState.togglePomodoro()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: appState.pomodoroRunning ? "pause.fill" : "play.fill")
                                    .font(.system(size: 9))
                                Text(appState.pomodoroRunning ? "暂停" : "开始")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            // 实心高亮按钮：底用 primary（暗色=白/亮色=黑自动翻转），
                            // 文字用 windowBackground 反色保证双模式对比；运行中橙底白字保留
                            .foregroundColor(appState.pomodoroRunning ? .white : Color(.windowBackgroundColor))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(appState.pomodoroRunning ? Color.orange : Color.primary.opacity(0.92))
                            )
                        }
                        .buttonStyle(.plain)
                        .help("播放/暂停番茄钟 (按 P)")
                        
                        // 重置
                        Button {
                            appState.resetPomodoro()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .help("重置番茄钟")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.02))
                    )
                    
                    // 3. 紧邻日历日程微卡片
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Image(systemName: "calendar")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.pink.opacity(0.85))
                            
                            Text("紧邻日程")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            if appState.calendarInfo.isAuthorized && appState.calendarInfo.hasEvent {
                                Text(appState.calendarInfo.timeDescription)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundColor(.pink.opacity(0.90))
                                    .lineLimit(1)
                            }
                        }
                        
                        if appState.calendarInfo.isAuthorized {
                            if appState.calendarInfo.hasEvent {
                                HStack {
                                    Button {
                                        appState.openCalendarApp()
                                    } label: {
                                        Text(appState.calendarInfo.title)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.plain)
                                    .help("点击打开系统日历")
                                    
                                    Spacer()
                                    
                                    if let meetingURL = appState.calendarInfo.meetingURL {
                                        Button {
                                            appState.joinMeeting(url: meetingURL)
                                        } label: {
                                            HStack(spacing: 3) {
                                                Image(systemName: "video.fill")
                                                    .font(.system(size: 8))
                                                Text("一键入会")
                                                    .font(.system(size: 9, weight: .bold))
                                            }
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2.5)
                                            .background(Capsule().fill(Color.pink.opacity(0.85)))
                                        }
                                        .buttonStyle(.plain)
                                        .help("呼出会议客户端入会 (腾讯会议/Zoom/Teams/飞书)")
                                    }
                                }
                            } else {
                                Text("今日暂无紧邻日程 · 保持专注")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            HStack {
                                Text("未授权访问日历")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Button("点击授权") {
                                    appState.requestCalendarAccess { _ in }
                                }
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.cyan)
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.02))
                    )
                    
                    Spacer(minLength: 2)
                    
                    // 4. 快捷效率小工具条
                    HStack(spacing: 8) {
                        // 锁屏微工具 (按 L)
                        Button {
                            appState.lockScreen()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8.5))
                                Text("锁屏 (L)")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .help("一键锁屏离座 (按 L)")
                        
                        // 纯文本化剪贴板 (按 X)
                        Button {
                            appState.cleanClipboard()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 8.5))
                                Text("洗文本 (X)")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .help("一键将剪贴板清洗为纯文本 (按 X)")
                        
                        Spacer()
                        
                        // 已连接外设清单
                        if !appState.bluetoothDevices.isEmpty {
                            ForEach(appState.bluetoothDevices.prefix(1), id: \.name) { dev in
                                HStack(spacing: 3) {
                                    Image(systemName: dev.iconName)
                                        .font(.system(size: 9))
                                        .foregroundColor(Color.cyan.opacity(0.90))
                                    Text(compactDeviceName(dev.name))
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                    if let b = dev.batteryLevel {
                                        Text("\(b)%")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.cyan.opacity(0.08)))
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.09), lineWidth: 0.75)
                )
            }
            .frame(height: cardHeight)
            .padding(.horizontal, 18)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
    }
    
    private func compactDeviceName(_ name: String) -> String {
        var s = name
        if s.hasPrefix("Keychron ") {
            s = s.replacingOccurrences(of: "Keychron ", with: "")
        }
        return s
    }
    
    private var cpuColor: Color {
        let usage = appState.performanceInfo.cpuUsage
        if usage > 85 { return Color.red.opacity(0.95) }
        if usage > 60 { return Color.orange.opacity(0.95) }
        return Color.cyan.opacity(0.95)
    }
    
    private var ramColor: Color {
        let usage = appState.performanceInfo.memoryUsagePercent
        if usage > 90 { return Color.red.opacity(0.95) }
        if usage > 75 { return Color.orange.opacity(0.95) }
        return Color.mint.opacity(0.95)
    }
}

// MARK: - 番茄钟预设选择按钮
struct PomodoroPresetButton: View {
    let title: String
    let minutes: Int
    @ObservedObject var appState: AppState
    
    private var isSelected: Bool {
        let currentMinutes = appState.pomodoroRemainingSeconds / 60
        return currentMinutes == minutes
    }
    
    var body: some View {
        Button {
            appState.resetPomodoro(durationMinutes: minutes)
        } label: {
            Text(title)
                .font(.system(size: 9.5, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? .orange : Color.primary.opacity(0.55))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.orange.opacity(0.20) : Color.primary.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
    }
}

