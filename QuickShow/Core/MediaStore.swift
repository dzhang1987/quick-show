import SwiftUI
import Combine
import AppKit

// MARK: - 媒体状态域
/// Now Playing 状态桥接（Provider adapter 流式推送，无轮询）+ 媒体控制盲操命令。
/// 命令即发即弃无回执，约 100ms 内 stream 推送真实状态校正微标与卡片。
final class MediaStore: ObservableObject {
    @Published var nowPlayingInfo: NowPlayingInfo? = nil
    private var nowPlayingCancellable: AnyCancellable?
    private weak var facade: AppState?

    /// 是否存在媒体会话（无会话时媒体按键无副作用，键位分发处据此决定是否消费事件）
    var hasNowPlayingSession: Bool { nowPlayingInfo != nil }

    /// 建立 Provider → store 的状态转发桥接（facade init 调用一次）
    func configure(facade: AppState) {
        self.facade = facade
        nowPlayingCancellable = SystemStatusProvider.shared.$nowPlayingInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                self?.nowPlayingInfo = info
            }
    }

    // MARK: - 媒体控制盲操（⏎ 播放暂停 / ←→ 切歌 / ,. ±15s）
    func togglePlayPause() {
        guard hasNowPlayingSession else { return }
        SystemStatusProvider.shared.sendMediaCommand(.togglePlayPause)
        // 乐观提示：命令即发即弃无回执，约 100ms 内 stream 推送真实状态校正
        facade?.showToast(nowPlayingInfo?.isPlaying == true ? String(localized: "已暂停 ⏸") : String(localized: "继续播放 ▶"))
    }

    /// 上一首 (←)
    func previousTrack() {
        guard hasNowPlayingSession else { return }
        SystemStatusProvider.shared.sendMediaCommand(.previousTrack)
    }

    /// 下一首 (→)
    func nextTrack() {
        guard hasNowPlayingSession else { return }
        SystemStatusProvider.shared.sendMediaCommand(.nextTrack)
    }

    /// 后退 15 秒 (,)
    func skipBackward() {
        guard hasNowPlayingSession else { return }
        SystemStatusProvider.shared.sendMediaCommand(.skipBackward15)
    }

    /// 快进 15 秒 (.)
    func skipForward() {
        guard hasNowPlayingSession else { return }
        SystemStatusProvider.shared.sendMediaCommand(.skipForward15)
    }

    /// 点击 Now Playing 微标：激活来源应用并收起面板
    func activateNowPlayingApp() {
        guard let bundleID = nowPlayingInfo?.bundleIdentifier else { return }
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .activate(options: [.activateAllWindows])
        facade?.dismiss()
    }
}