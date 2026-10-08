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
                        .lineLimit(1)
                }
                .layoutPriority(1)
                
                Spacer()
                
                Text(appState.pomodoroRunning ? String(localized: "专注中") : String(localized: "就绪"))
                    .font(.system(size: Theme.Typography.caption, weight: .bold))
                    .foregroundColor(appState.pomodoroRunning ? .orange : Theme.Colors.idleText)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(
                        Capsule()
                            .fill(appState.pomodoroRunning ? Color.orange.opacity(0.18) : Theme.Colors.surfaceBadge)
                    )
                    .lineLimit(1)
            }
            
            // 2. 番茄钟工作台：降载由布局真值裁决（ViewThatFits 逐级试探理想宽），
            //    让位顺序 = 统计小字（信息性）先走，预设胶囊（可操作）后退为紧凑档；
            //    倒计时时钟与播放/重置钮恒在，任何档位都不会挤压折行
            ViewThatFits(in: .horizontal) {
                pomodoroRow(showPresets: true, compactPresets: false, showStats: true, statsMaxWidth: nil)
                pomodoroRow(showPresets: true, compactPresets: false, showStats: true, statsMaxWidth: Theme.Layout.pomodoroStatsCompactWidth)
                pomodoroRow(showPresets: true, compactPresets: true, showStats: false, statsMaxWidth: nil)
                pomodoroRow(showPresets: false, compactPresets: false, showStats: false, statsMaxWidth: nil)
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
                            .truncationMode(.tail)
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
                                            .lineLimit(1)
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
                            .lineLimit(1)
                    }
                } else {
                    HStack {
                        Text("未授权访问日历")
                            .font(.system(size: Theme.Typography.label))
                            .foregroundStyle(Theme.Colors.contentTertiary)
                            .lineLimit(1)
                        Spacer()
                        Button("点击授权") {
                            appState.requestCalendarAccess { _ in }
                        }
                        .font(.system(size: Theme.Typography.footnote, weight: .semibold))
                        .foregroundColor(Theme.Colors.accent)
                        .buttonStyle(.plain)
                    }
                }
                
                // 世界时钟行：独立于日历授权状态展示，城市可在偏好设置中配置。
                // 全行拼合为单一 AttributedString 渲染：整行作为一个 lineLimit(1) 单元
                // 随宽截断——ForEach 多 Text 在窄档各自折行穿插，正是低分屏布局变形源之一
                if !appState.worldClockCities.isEmpty {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "globe")
                            .font(.system(size: Theme.Typography.mini))
                            .foregroundStyle(Theme.Colors.contentTertiary)
                        Text(worldClockText)
                            .lineLimit(1)
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
            
            // 4. 快捷效率小工具条（窄时让位蓝牙外设 chip，连接状态与键盘能力不受影响）
            ViewThatFits(in: .horizontal) {
                toolsRow(showBluetooth: true)
                toolsRow(showBluetooth: false)
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

    // MARK: - 行变体（ViewThatFits 按理想宽逐级挑选，第一个放得下的胜出）

    @ViewBuilder
    private func pomodoroRow(showPresets: Bool, compactPresets: Bool, showStats: Bool, statsMaxWidth: CGFloat?) -> some View {
        HStack(spacing: Theme.Spacing.xl) {
            // 倒计时大字 + 番茄统计小字（统计是本行最先让位的元素：单行尾省略号）
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(appState.formattedPomodoroTime)
                    .font(.system(size: Theme.Typography.pomodoro, weight: .bold, design: .monospaced))
                    .foregroundColor(appState.pomodoroRunning ? .orange : .primary)
                    .shadow(color: appState.pomodoroRunning ? Color.orange.opacity(0.3) : .clear, radius: 4)
                    .lineLimit(1)
                
                if showStats, appState.pomodoroTodayCount > 0 || appState.pomodoroStreakDays > 0 {
                    let stats = Text("今日 \(appState.pomodoroTodayCount) 个 · 连续 \(appState.pomodoroStreakDays) 天")
                        .font(.system(size: Theme.Typography.mini, weight: .medium))
                        .foregroundStyle(Theme.Colors.contentTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let statsMaxWidth {
                        stats.frame(maxWidth: statsMaxWidth, alignment: .leading)
                    } else {
                        stats
                    }
                }
            }
            .layoutPriority(1)
            
            // 预设时长快捷切换胶囊 (25m / 45m / 5m；窄档先转紧凑字距、再整组让位，
            // P 键播放与预设重置能力不受影响)
            if showPresets {
                HStack(spacing: Theme.Spacing.sm) {
                    PomodoroPresetButton(title: "25m", minutes: 25, appState: appState, compact: compactPresets)
                    PomodoroPresetButton(title: "45m", minutes: 45, appState: appState, compact: compactPresets)
                    PomodoroPresetButton(title: "5m", minutes: 5, appState: appState, compact: compactPresets)
                }
            }
            
            Spacer()
            
            // 播放 / 暂停按钮
            Button {
                appState.togglePomodoro()
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: appState.pomodoroRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: Theme.Typography.mini))
                    Text(appState.pomodoroRunning ? String(localized: "暂停") : String(localized: "开始"))
                        .font(.system(size: Theme.Typography.footnote, weight: .semibold))
                        .lineLimit(1)
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
    }

    @ViewBuilder
    private func toolsRow(showBluetooth: Bool) -> some View {
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
                        .lineLimit(1)
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
                        .lineLimit(1)
                }
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Capsule().fill(Theme.Colors.surfaceButton))
            }
            .buttonStyle(.plain)
            .help("一键将剪贴板清洗为纯文本 (按 X)")
            
            Spacer()
            
            // 已连接外设清单（底部工具条最低优先级，窄档整组让位）
            if showBluetooth && !appState.bluetoothDevices.isEmpty {
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

    // 世界时钟整行 AttributedString：城市名弱化 + 时间等宽数字加亮的双色调经属性保留，
    // 行级截断时由 SwiftUI 在任意字符处断尾（无最长词下限）
    private var worldClockText: AttributedString {
        var output = AttributedString()
        for (index, city) in appState.worldClockCities.enumerated() {
            if index > 0 { output += AttributedString("  ") }
            var name = AttributedString(city.displayName)
            name.font = .systemFont(ofSize: Theme.Typography.mini, weight: .medium)
            name.foregroundColor = NSColor(Theme.Colors.contentTertiary)
            output += name
            output += AttributedString(" ")
            var time = AttributedString(appState.worldClockTimeString(for: city))
            time.font = NSFont.monospacedDigitSystemFont(ofSize: Theme.Typography.caption, weight: .bold)
            time.foregroundColor = NSColor(Theme.Colors.contentSecondaryStrong)
            output += time
        }
        return output
    }

    private func compactDeviceName(_ name: String) -> String {
        var s = name
        if s.hasPrefix("Keychron ") {
            s = s.replacingOccurrences(of: "Keychron ", with: "")
        }
        return s
    }
}
