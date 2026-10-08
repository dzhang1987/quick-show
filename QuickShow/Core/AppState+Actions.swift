import SwiftUI
import AppKit
import Foundation

// MARK: - 门面便利动作（纯方法 extension）
// toast / 音量静音 / 防休眠 / 剪贴板 / 锁屏 / open* / quit / joinMeeting / 番茄钟控制。
// 瞬态 Toast 状态本身留在门面（toastMessage/toastTimer），此处仅方法。
extension AppState {

    // MARK: - Toast 与微服务
    func showToast(_ message: String) {
        resetGlanceTimer()
        toastTimer?.invalidate()
        withAnimation(.easeInOut(duration: Theme.Motion.contentFade)) {
            toastMessage = message
        }
        toastTimer = Timer.scheduledTimer(withTimeInterval: Theme.Motion.toastDuration, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: Theme.Motion.toastOut)) {
                    self?.toastMessage = nil
                }
                // Toast 播完后，若处于一瞥模式且未展开，重新给 3 秒倒计时平滑退场
                if self?.mode == .glance && self?.isExpanded == false {
                    self?.resetGlanceTimer()
                }
            }
        }
    }

    func toggleMute() {
        resetGlanceTimer()
        let isMuted = SystemStatusProvider.shared.toggleMute()
        status.audioInfo.isMuted = isMuted
        showToast(isMuted ? String(localized: "已静音") : String(localized: "已恢复音量 (\(status.audioInfo.volume)%)"))
    }

    func adjustVolume(by step: Int) {
        resetGlanceTimer()
        let newVol = SystemStatusProvider.shared.adjustVolume(by: step)
        status.audioInfo.volume = newVol
        status.audioInfo.isMuted = false
        showToast(String(localized: "音量: \(newVol)%"))
    }

    func toggleKeepAwake() {
        resetGlanceTimer()
        let active = SystemStatusProvider.shared.toggleKeepAwake()
        status.isKeepAwake = active
        showToast(active ? String(localized: "已开启防休眠 ☕️") : String(localized: "已恢复系统节能"))
    }

    func copyLocalIP() {
        resetGlanceTimer()
        if let ip = SystemStatusProvider.shared.getLocalIPAddress() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
            showToast(String(localized: "已复制局域网 IP: \(ip)"))
        } else {
            showToast(String(localized: "未检测到有效局域网 IP"))
        }
    }

    func cleanClipboard() {
        resetGlanceTimer()
        let pb = NSPasteboard.general
        if let str = pb.string(forType: .string), !str.isEmpty {
            pb.clearContents()
            pb.setString(str, forType: .string)
            let preview = String(str.trimmingCharacters(in: .whitespacesAndNewlines).prefix(14))
            showToast(String(localized: "已纯文本化: \"\(preview)...\""))
        } else {
            showToast(String(localized: "剪贴板为空"))
        }
    }

    func lockScreen() {
        dismiss()
        SystemStatusProvider.shared.lockScreen()
    }

    func optimizeMemory() {
        resetGlanceTimer()
        let released = SystemStatusProvider.shared.optimizeMemory()
        monitoring.performanceInfo = SystemStatusProvider.shared.getSystemPerformanceInfo()
        showToast(String.localizedStringWithFormat(String(localized: "已优化释放 %.0f MB 内存"), released))
    }

    // MARK: - 番茄钟控制
    func togglePomodoro() {
        resetGlanceTimer()
        pomodoro.pomodoroRunning.toggle()
        showToast(pomodoro.pomodoroRunning ? String(localized: "番茄钟已启动") : String(localized: "番茄钟已暂停"))
    }

    func resetPomodoro(durationMinutes: Int = 25) {
        pomodoro.pomodoroRunning = false
        pomodoro.pomodoroRemainingSeconds = durationMinutes * 60
        pomodoro.pomodoroIsRestSession = durationMinutes < 25
    }

    func cyclePomodoroDuration() {
        resetGlanceTimer()
        if pomodoro.pomodoroRemainingSeconds > 25 * 60 {
            resetPomodoro(durationMinutes: 5)
            showToast(String(localized: "番茄钟: 5 分钟短休息"))
        } else if pomodoro.pomodoroRemainingSeconds > 5 * 60 {
            resetPomodoro(durationMinutes: 45)
            showToast(String(localized: "番茄钟: 45 分钟深度专注"))
        } else {
            resetPomodoro(durationMinutes: 25)
            showToast(String(localized: "番茄钟: 25 分钟标准专注"))
        }
    }

    // MARK: - 打开外部应用 / 设置 / 退出
    func openActivityMonitor() {
        SystemStatusProvider.shared.openActivityMonitor()
        dismiss()
    }

    func openDownloadsFolder() {
        SystemStatusProvider.shared.openDownloadsFolder()
        dismiss()
    }

    func openCalendarApp() {
        SystemStatusProvider.shared.openCalendarApp()
        dismiss()
    }

    func openNetworkSettings() {
        SystemStatusProvider.shared.openNetworkSettings()
        dismiss()
    }

    func openBatterySettings() {
        SystemStatusProvider.shared.openBatterySettings()
        dismiss()
    }

    func openFocusSettings() {
        SystemStatusProvider.shared.openFocusSettings()
        dismiss()
    }

    func openSettings() {
        dismiss()
        onOpenSettings?()
    }

    func quitApp() {
        NSApp.terminate(nil)
    }

    func joinMeeting(url: URL) {
        NSWorkspace.shared.open(url)
        dismiss()
    }
}