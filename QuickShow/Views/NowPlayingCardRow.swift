import SwiftUI

// 职责来源：ExpandedMonitoringView 左卡片内嵌正在播放媒体条
// MARK: - 正在播放媒体条（展开态左卡片内嵌）
// 紧凑单行卡：封面 32×32 + 标题 / 艺术家·来源 / 进度条+时间；
// 进度本地插值推进（随主时钟每秒刷新），暂停时停止插值并弱化封面
struct NowPlayingCardRow: View {
    let nowPlaying: NowPlayingInfo
    let now: Date   // 主时钟（AppState.currentTime）每秒推进，驱动插值刷新
    
    private var elapsed: Double { nowPlaying.currentElapsed(at: now) }
    
    // 艺术家 · 来源应用（均可为空，双空则整行隐藏）
    private var subtitle: String {
        [nowPlaying.artist, nowPlaying.appName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
    
    var body: some View {
        HStack(spacing: Theme.Spacing.xl) {
            // 封面：无封面数据时优雅降级为音符占位；暂停态降低不透明度
            ZStack {
                if let artwork = nowPlaying.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: Theme.Typography.callout, weight: .medium))
                        .foregroundStyle(Theme.Colors.contentTertiary)
                }
            }
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.surfaceBadge)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous))
            .opacity(nowPlaying.isPlaying ? 1.0 : 0.55)
            
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                // 标题 + 已播 / 总时长（mm:ss）
                HStack(spacing: Theme.Spacing.md) {
                    Text(nowPlaying.title)
                        .font(.system(size: Theme.Typography.caption, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    Spacer(minLength: 0)
                    
                    Text(timeText)
                        .font(.system(size: Theme.Typography.mini, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.contentTertiary)
                }
                
                // 艺术家 · 来源应用（双空时整行隐藏）
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: Theme.Typography.mini, weight: .medium))
                        .foregroundStyle(Theme.Colors.contentTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                
                // 进度条：总时长未知（直播流等）时不显示
                if nowPlaying.duration > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Theme.Colors.surfaceTrack)
                            Capsule()
                                .fill(Theme.Colors.accent.opacity(0.85))
                                .frame(width: max(0, min(geo.size.width * CGFloat(elapsed / nowPlaying.duration), geo.size.width)))
                        }
                    }
                    .frame(height: 3)
                }
            }
        }
    }
    
    private var timeText: String {
        if nowPlaying.duration > 0 {
            return "\(Self.formatMediaTime(elapsed)) / \(Self.formatMediaTime(nowPlaying.duration))"
        }
        return Self.formatMediaTime(elapsed)
    }
    
    /// mm:ss 格式化；超过 1 小时（长视频/播客）自动升级为 H:MM:SS
    static func formatMediaTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

