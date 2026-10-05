import SwiftUI

// 职责来源：ExpandedMonitoringView 左卡片「⚡️ 系统性能与网络吞吐」
struct PerformanceCard: View {
    @ObservedObject var appState: AppState

    var body: some View {
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
                    .foregroundStyle(Theme.Colors.contentTertiary)
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
                        .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    
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
                            .foregroundStyle(Theme.Colors.contentTertiary)
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
                        .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    
                    Spacer()
                    
                    Text("\(String(format: "%.1f", appState.performanceInfo.memoryUsedGB))G / \(Int(appState.performanceInfo.memoryTotalGB))G")
                        .font(.system(size: Theme.Typography.caption, weight: .medium))
                        .foregroundStyle(Theme.Colors.contentTertiary)
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
                            .foregroundStyle(Theme.Colors.contentTertiary)
                        Text("系统磁盘")
                            .font(.system(size: Theme.Typography.label, weight: .semibold))
                            .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    }
                    
                    Spacer()
                    
                    if appState.diskInfo.totalGB > 0 {
                        Text("\(Int(appState.diskInfo.freeGB))G 可用 / \(Int(appState.diskInfo.totalGB))G")
                            .font(.system(size: Theme.Typography.caption, weight: .medium))
                            .foregroundColor(Theme.Colors.contentSecondaryStrong)
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
            
            // 4.5 正在播放媒体条（存在媒体会话时出现，无会话彻底隐形不占位；
            //     高度 ~32pt 嵌入底部弹性区，不挤压上方槽组）
            if appState.showNowPlaying, let nowPlaying = appState.nowPlayingInfo {
                NowPlayingCardRow(nowPlaying: nowPlaying, now: appState.currentTime)
            }
            
            // 5. 实时网络吞吐、延迟与本机 IP
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
                    
                    // 网络延迟（TCP 握手计时，失败/断网显示「—」）
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "network")
                            .font(.system(size: Theme.Typography.caption, weight: .bold))
                            .foregroundStyle(Theme.Colors.contentTertiary)
                        Text(appState.networkLatency.map { "\($0) ms" } ?? "—")
                            .font(.system(size: Theme.Typography.callout, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    }
                    .help("到 1.1.1.1:443 的 TCP 连接延迟，每 5 秒测量一次")
                }
                
                Spacer()
                
                // 局域网 IP (点击复制)
                Button {
                    appState.copyLocalIP()
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "square.on.square")
                            .font(.system(size: Theme.Typography.tiny))
                            .foregroundStyle(Theme.Colors.contentTertiary)
                        Text("复制内网 IP")
                            .font(.system(size: Theme.Typography.caption, weight: .medium))
                            .foregroundColor(Theme.Colors.contentSecondaryStrong)
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
