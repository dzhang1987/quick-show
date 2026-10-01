import SwiftUI

struct ExpandedMonitoringView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // 细若游丝的微光渐隐分割线
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.0),
                            Color.primary.opacity(Theme.Colors.dividerOpacity),
                            Color.primary.opacity(0.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: Theme.Layout.dividerHeight)
                .padding(.horizontal, Theme.Spacing.divider)
            
            // 核心双列卡片 Bento Grid (左右对称卡片网格，卡片高度 225pt)
            HStack(spacing: Theme.Spacing.xxl) {
                // MARK: - 左卡片：⚡️ 系统性能与网络吞吐
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    // 1. 顶部微标头
                    HStack {
                        HStack(spacing: Theme.Spacing.chip) {
                            Image(systemName: "cpu.fill")
                                .font(.system(size: Theme.Typography.body, weight: .bold))
                                .foregroundColor(Theme.Colors.accent.opacity(0.95))
                            Text("系统性能与网络")
                                .font(.system(size: Theme.Typography.callout, weight: .bold))
                                .foregroundColor(.primary)
                        }
                        
                        Spacer()
                        
                        Button {
                            appState.openActivityMonitor()
                        } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Text("活动监视器")
                                    .font(.system(size: Theme.Typography.caption, weight: .medium))
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: Theme.Typography.tiny))
                            }
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xxs)
                            .background(
                                Capsule()
                                    .fill(Theme.Colors.surfaceButton)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("双击卡片或点击打开系统活动监视器")
                    }
                    
                    // 2. CPU 负载槽
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack(spacing: Theme.Spacing.md) {
                            Text("CPU 负载")
                                .font(.system(size: Theme.Typography.label, weight: .semibold))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            if let topProc = appState.topCPUProcess {
                                Text(topProc)
                                    .font(.system(size: Theme.Typography.mini, weight: .bold))
                                    .foregroundColor(.orange.opacity(0.95))
                                    .padding(.horizontal, Theme.Spacing.chip)
                                    .padding(.vertical, Theme.Spacing.xxxs)
                                    .background(Capsule().fill(Color.orange.opacity(0.18)))
                                    .lineLimit(1)
                            } else {
                                Text("平稳运行")
                                    .font(.system(size: Theme.Typography.mini, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            
                            Text(String(format: "%2.0f%%", appState.performanceInfo.cpuUsage))
                                .font(.system(size: Theme.Typography.callout, weight: .bold))
                                .monospacedDigit()
                                .foregroundColor(cpuColor)
                                .frame(width: Theme.Layout.metricValueWidth, alignment: .trailing)
                        }
                        
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Theme.Colors.surfaceTrack)
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
                        .frame(height: Theme.Layout.meterHeight)
                    }
                    
                    // 3. RAM 内存槽
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack(spacing: Theme.Spacing.md) {
                            Text("内存占用")
                                .font(.system(size: Theme.Typography.label, weight: .semibold))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Text("\(String(format: "%.1f", appState.performanceInfo.memoryUsedGB))G / \(Int(appState.performanceInfo.memoryTotalGB))G")
                                .font(.system(size: Theme.Typography.caption, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                            
                            // 一键内存优化清理微按钮
                            Button {
                                appState.optimizeMemory()
                            } label: {
                                HStack(spacing: Theme.Spacing.xxs) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: Theme.Typography.tiny, weight: .bold))
                                    Text("清理")
                                        .font(.system(size: Theme.Typography.caption, weight: .semibold))
                                }
                                .foregroundColor(Theme.Colors.accent.opacity(0.95))
                                .padding(.horizontal, Theme.Spacing.chip)
                                .padding(.vertical, Theme.Spacing.xxxs)
                                .background(Capsule().fill(Theme.Colors.accent.opacity(0.16)))
                            }
                            .buttonStyle(.plain)
                            .help("一键优化清理系统内存 (按 C)")
                            
                            Text(String(format: "%2.0f%%", appState.performanceInfo.memoryUsagePercent))
                                .font(.system(size: Theme.Typography.callout, weight: .bold))
                                .monospacedDigit()
                                .foregroundColor(ramColor)
                                .frame(width: Theme.Layout.metricValueWidth, alignment: .trailing)
                        }
                        
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Theme.Colors.surfaceTrack)
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
                        .frame(height: Theme.Layout.meterHeight)
                    }
                    
                    // 4. 本地磁盘存储空间 (Disk)
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack(spacing: Theme.Spacing.md) {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "internaldrive")
                                    .font(.system(size: Theme.Typography.caption))
                                    .foregroundStyle(.tertiary)
                                Text("系统磁盘")
                                    .font(.system(size: Theme.Typography.label, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if appState.diskInfo.totalGB > 0 {
                                Text("\(Int(appState.diskInfo.freeGB))G 可用 / \(Int(appState.diskInfo.totalGB))G")
                                    .font(.system(size: Theme.Typography.caption, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            
                            Button {
                                appState.openDownloadsFolder()
                            } label: {
                                HStack(spacing: Theme.Spacing.xxs) {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: Theme.Typography.tiny))
                                    Text("下载")
                                        .font(.system(size: Theme.Typography.caption, weight: .medium))
                                }
                                .foregroundColor(Theme.Colors.accent.opacity(0.85))
                                .padding(.horizontal, Theme.Spacing.chip)
                                .padding(.vertical, Theme.Spacing.xxxs)
                                .background(Capsule().fill(Theme.Colors.accent.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .help("秒开 Downloads 下载目录 (按 O)")
                        }
                        
                        GeometryReader { geo in
                            let usedRatio: CGFloat = appState.diskInfo.totalGB > 0 ? CGFloat((appState.diskInfo.totalGB - appState.diskInfo.freeGB) / appState.diskInfo.totalGB) : 0.5
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Theme.Colors.surfaceTrack)
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
                        .frame(height: Theme.Layout.meterHeight)
                    }
                    
                    Spacer(minLength: Theme.Spacing.xxs)
                    
                    // 5. 实时网络吞吐与本机 IP
                    HStack {
                        // 吞吐速率
                        HStack(spacing: Theme.Spacing.xxl) {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: Theme.Typography.caption, weight: .bold))
                                    .foregroundColor(.green.opacity(0.95))
                                Text(appState.trafficInfo.downloadSpeed)
                                    .font(.system(size: Theme.Typography.callout, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                            }
                            
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: Theme.Typography.caption, weight: .bold))
                                    .foregroundColor(Theme.Colors.accent.opacity(0.95))
                                Text(appState.trafficInfo.uploadSpeed)
                                    .font(.system(size: Theme.Typography.callout, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                            }
                        }
                        
                        Spacer()
                        
                        // 局域网 IP (点击复制)
                        Button {
                            appState.copyLocalIP()
                        } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: Theme.Typography.tiny))
                                    .foregroundStyle(.tertiary)
                                Text("复制内网 IP")
                                    .font(.system(size: Theme.Typography.caption, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, Theme.Spacing.mdlg)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(
                                Capsule()
                                    .fill(Theme.Colors.surfaceButton)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("点击一键复制局域网 IP")
                    }
                }
                .padding(.horizontal, Theme.Spacing.card)
                .padding(.vertical, Theme.Spacing.xxxl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Theme.Colors.surfaceCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .stroke(Theme.Colors.cardStroke, lineWidth: 0.75)
                )
                .onTapGesture(count: 2) {
                    appState.openActivityMonitor()
                }
                
                // MARK: - 右卡片：🎯 专注工坊与效率日程
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    // 1. 顶部微标头
                    HStack {
                        HStack(spacing: Theme.Spacing.chip) {
                            Image(systemName: "timer")
                                .font(.system(size: Theme.Typography.body, weight: .bold))
                                .foregroundColor(.orange.opacity(0.95))
                            Text("专注与日常工作流")
                                .font(.system(size: Theme.Typography.callout, weight: .bold))
                                .foregroundColor(.primary)
                        }
                        
                        Spacer()
                        
                        Text(appState.pomodoroRunning ? "专注中" : "就绪")
                            .font(.system(size: Theme.Typography.caption, weight: .bold))
                            .foregroundColor(appState.pomodoroRunning ? .orange : Theme.Colors.idleText)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xxs)
                            .background(
                                Capsule()
                                    .fill(appState.pomodoroRunning ? Color.orange.opacity(0.18) : Theme.Colors.surfaceBadge)
                            )
                    }
                    
                    // 2. 番茄钟工作台
                    HStack(spacing: Theme.Spacing.xl) {
                        // 倒计时大字
                        Text(appState.formattedPomodoroTime)
                            .font(.system(size: Theme.Typography.pomodoro, weight: .bold, design: .monospaced))
                            .foregroundColor(appState.pomodoroRunning ? .orange : .primary)
                            .shadow(color: appState.pomodoroRunning ? Color.orange.opacity(0.3) : .clear, radius: 4)
                        
                        // 预设时长快捷切换胶囊 (25m / 45m / 5m)
                        HStack(spacing: Theme.Spacing.sm) {
                            PomodoroPresetButton(title: "25m", minutes: 25, appState: appState)
                            PomodoroPresetButton(title: "45m", minutes: 45, appState: appState)
                            PomodoroPresetButton(title: "5m", minutes: 5, appState: appState)
                        }
                        
                        Spacer()
                        
                        // 播放 / 暂停按钮
                        Button {
                            appState.togglePomodoro()
                        } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Image(systemName: appState.pomodoroRunning ? "pause.fill" : "play.fill")
                                    .font(.system(size: Theme.Typography.mini))
                                Text(appState.pomodoroRunning ? "暂停" : "开始")
                                    .font(.system(size: Theme.Typography.footnote, weight: .semibold))
                            }
                            // 实心高亮按钮：底用 primary（暗色=白/亮色=黑自动翻转），
                            // 文字用 windowBackground 反色保证双模式对比；运行中橙底白字保留
                            .foregroundColor(appState.pomodoroRunning ? .white : Theme.Colors.solidButtonText)
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, Theme.Spacing.sm)
                            .background(
                                Capsule()
                                    .fill(appState.pomodoroRunning ? Color.orange : Theme.Colors.solidButtonFill)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("播放/暂停番茄钟 (按 P)")
                        
                        // 重置
                        Button {
                            appState.resetPomodoro()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: Theme.Typography.mini))
                                .foregroundStyle(.tertiary)
                                .frame(width: Theme.Layout.miniButtonSize, height: Theme.Layout.miniButtonSize)
                                .background(Circle().fill(Theme.Colors.surfaceButton))
                        }
                        .buttonStyle(.plain)
                        .help("重置番茄钟")
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                            .fill(Theme.Colors.surfaceInset)
                    )
                    
                    // 3. 紧邻日历日程微卡片
                    VStack(alignment: .leading, spacing: Theme.Spacing.chip) {
                        HStack(spacing: Theme.Spacing.chip) {
                            Image(systemName: "calendar")
                                .font(.system(size: Theme.Typography.body, weight: .bold))
                                .foregroundColor(.pink.opacity(0.85))
                            
                            Text("紧邻日程")
                                .font(.system(size: Theme.Typography.label, weight: .semibold))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            if appState.calendarInfo.isAuthorized && appState.calendarInfo.hasEvent {
                                Text(appState.calendarInfo.timeDescription)
                                    .font(.system(size: Theme.Typography.caption, weight: .medium))
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
                                            .font(.system(size: Theme.Typography.body, weight: .medium))
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
                                            HStack(spacing: Theme.Spacing.xs) {
                                                Image(systemName: "video.fill")
                                                    .font(.system(size: Theme.Typography.tiny))
                                                Text("一键入会")
                                                    .font(.system(size: Theme.Typography.caption, weight: .bold))
                                            }
                                            // 粉底白字：彩色底上白色双模式均清晰，保留
                                            .foregroundColor(.white)
                                            .padding(.horizontal, Theme.Spacing.mdlg)
                                            .padding(.vertical, Theme.Spacing.xxs)
                                            .background(Capsule().fill(Color.pink.opacity(0.85)))
                                        }
                                        .buttonStyle(.plain)
                                        .help("呼出会议客户端入会 (腾讯会议/Zoom/Teams/飞书)")
                                    }
                                }
                            } else {
                                Text("今日暂无紧邻日程 · 保持专注")
                                    .font(.system(size: Theme.Typography.label, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            HStack {
                                Text("未授权访问日历")
                                    .font(.system(size: Theme.Typography.label))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Button("点击授权") {
                                    appState.requestCalendarAccess { _ in }
                                }
                                .font(.system(size: Theme.Typography.footnote, weight: .semibold))
                                .foregroundColor(Theme.Colors.accent)
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                            .fill(Theme.Colors.surfaceInset)
                    )
                    
                    Spacer(minLength: Theme.Spacing.xxs)
                    
                    // 4. 快捷效率小工具条
                    HStack(spacing: Theme.Spacing.lg) {
                        // 锁屏微工具 (按 L)
                        Button {
                            appState.lockScreen()
                        } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: Theme.Typography.tiny))
                                Text("锁屏 (L)")
                                    .font(.system(size: Theme.Typography.caption, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(Capsule().fill(Theme.Colors.surfaceButton))
                        }
                        .buttonStyle(.plain)
                        .help("一键锁屏离座 (按 L)")
                        
                        // 纯文本化剪贴板 (按 X)
                        Button {
                            appState.cleanClipboard()
                        } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: Theme.Typography.tiny))
                                Text("洗文本 (X)")
                                    .font(.system(size: Theme.Typography.caption, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(Capsule().fill(Theme.Colors.surfaceButton))
                        }
                        .buttonStyle(.plain)
                        .help("一键将剪贴板清洗为纯文本 (按 X)")
                        
                        Spacer()
                        
                        // 已连接外设清单
                        if !appState.bluetoothDevices.isEmpty {
                            ForEach(appState.bluetoothDevices.prefix(1), id: \.name) { dev in
                                HStack(spacing: Theme.Spacing.xs) {
                                    Image(systemName: dev.iconName)
                                        .font(.system(size: Theme.Typography.mini))
                                        .foregroundColor(Theme.Colors.accent.opacity(0.90))
                                    Text(compactDeviceName(dev.name))
                                        .font(.system(size: Theme.Typography.mini, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                    if let b = dev.batteryLevel {
                                        Text("\(b)%")
                                            .font(.system(size: Theme.Typography.mini, weight: .bold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.xs)
                                .background(Capsule().fill(Theme.Colors.accent.opacity(0.08)))
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.card)
                .padding(.vertical, Theme.Spacing.xxxl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Theme.Colors.surfaceCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .stroke(Theme.Colors.cardStroke, lineWidth: 0.75)
                )
            }
            .frame(height: Theme.Layout.monitorCardHeight)
            .padding(.horizontal, Theme.Spacing.section)
            .padding(.top, Theme.Spacing.xxs)
            .padding(.bottom, Theme.Spacing.md)
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
        // 状态语义色保持惯例：红=警告/橙=偏高 不被主题洗掉；正常态跟随主题强调色
        if usage > 85 { return Color.red.opacity(0.95) }
        if usage > 60 { return Color.orange.opacity(0.95) }
        return Theme.Colors.accent.opacity(0.95)
    }
    
    private var ramColor: Color {
        let usage = appState.performanceInfo.memoryUsagePercent
        if usage > 90 { return Color.red.opacity(0.95) }
        if usage > 75 { return Color.orange.opacity(0.95) }
        return Theme.Colors.accent.opacity(0.95)
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
                .font(.system(size: Theme.Typography.caption, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? .orange : Theme.Colors.presetText)
                .padding(.horizontal, Theme.Spacing.chip)
                .padding(.vertical, Theme.Spacing.xxs)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.orange.opacity(0.20) : Theme.Colors.surfaceBadge)
                )
        }
        .buttonStyle(.plain)
    }
}

