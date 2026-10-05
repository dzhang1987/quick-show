import SwiftUI

// 职责来源：ExpandedMonitoringView 右卡片「🎯 专注工坊与效率日程」
struct FocusWorkCard: View {
    @ObservedObject var appState: AppState

    var body: some View {
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
                // 倒计时大字 + 番茄统计小字
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(appState.formattedPomodoroTime)
                        .font(.system(size: Theme.Typography.pomodoro, weight: .bold, design: .monospaced))
                        .foregroundColor(appState.pomodoroRunning ? .orange : .primary)
                        .shadow(color: appState.pomodoroRunning ? Color.orange.opacity(0.3) : .clear, radius: 4)
                    
                    // 番茄统计：今日完成数与连续天数，无记录时彻底隐形
                    if appState.pomodoroTodayCount > 0 || appState.pomodoroStreakDays > 0 {
                        Text("今日 \(appState.pomodoroTodayCount) 个 · 连续 \(appState.pomodoroStreakDays) 天")
                            .font(.system(size: Theme.Typography.mini, weight: .medium))
                            .foregroundStyle(Theme.Colors.contentTertiary)
                            .monospacedDigit()
                    }
                }
                
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
                        .foregroundStyle(Theme.Colors.contentTertiary)
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
                        .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    
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
                            .foregroundStyle(Theme.Colors.contentTertiary)
                    }
                } else {
                    HStack {
                        Text("未授权访问日历")
                            .font(.system(size: Theme.Typography.label))
                            .foregroundStyle(Theme.Colors.contentTertiary)
                        Spacer()
                        Button("点击授权") {
                            appState.requestCalendarAccess { _ in }
                        }
                        .font(.system(size: Theme.Typography.footnote, weight: .semibold))
                        .foregroundColor(Theme.Colors.accent)
                        .buttonStyle(.plain)
                    }
                }
                
                // 世界时钟行：独立于日历授权状态展示，城市可在偏好设置中配置
                if !appState.worldClockCities.isEmpty {
                    HStack(spacing: Theme.Spacing.lg) {
                        Image(systemName: "globe")
                            .font(.system(size: Theme.Typography.mini))
                            .foregroundStyle(Theme.Colors.contentTertiary)
                        ForEach(appState.worldClockCities) { city in
                            HStack(spacing: Theme.Spacing.xs) {
                                Text(city.displayName)
                                    .font(.system(size: Theme.Typography.mini, weight: .medium))
                                    .foregroundStyle(Theme.Colors.contentTertiary)
                                Text(appState.worldClockTimeString(for: city))
                                    .font(.system(size: Theme.Typography.caption, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, Theme.Spacing.xxs)
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
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
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
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
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
                                .foregroundColor(Theme.Colors.contentSecondaryStrong)
                                .lineLimit(1)
                            if let b = dev.batteryLevel {
                                Text("\(b)%")
                                    .font(.system(size: Theme.Typography.mini, weight: .bold))
                                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
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

    private func compactDeviceName(_ name: String) -> String {
        var s = name
        if s.hasPrefix("Keychron ") {
            s = s.replacingOccurrences(of: "Keychron ", with: "")
        }
        return s
    }
}
