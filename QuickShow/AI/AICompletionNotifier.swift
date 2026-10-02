import Foundation
import UserNotifications

// MARK: - AI 流式完成通知
//
// 仅在「成功完成一轮回复」且用户没有正在看对话窗时发送系统通知：
// - 授权按需请求：首次真正要发通知时才请求 [.alert, .sound]（不在启动即弹权限框）；
// - 被拒（或未决未授权）后本次会话静默跳过，不重复请求；
// - 点击通知 → 唤出 AI 对话窗（冷启动场景由 AppDelegate 尽早安装 delegate 保证可收到）。
//
// LSUIElement 应用照常可用通知，无需额外 Info.plist 键。
// 非隔离类：UNUserNotificationCenter 回调在任意线程，窗口唤出显式切回主线程。
final class AICompletionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AICompletionNotifier()

    /// delegate 是否已安装（避免重复设置）。
    private var delegateInstalled = false
    /// 用户是否已在本会话中拒绝/跳过通知。
    private var suppressed = false

    private override init() { super.init() }

    /// 尽早安装通知代理（AppDelegate.applicationDidFinishLaunching 调用）：
    /// 通知点击可能在冷启动时先于用户交互到达，代理需提前就位。
    func installDelegateIfNeeded() {
        guard !delegateInstalled else { return }
        delegateInstalled = true
        UNUserNotificationCenter.current().delegate = self
    }

    /// 发送一条完成通知。未授权时按需请求；被拒后静默跳过。
    func notify(title: String, body: String) {
        installDelegateIfNeeded()
        guard !suppressed else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.deliver(title: title, body: body)
            case .notDetermined:
                // 首次真正需要发送时才请求授权
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        self.deliver(title: title, body: body)
                    } else {
                        self.suppressed = true
                    }
                }
            default:
                // .denied：本次会话不再请求/发送
                self.suppressed = true
            }
        }
    }

    private func deliver(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // 时间戳 identifier：多条完成通知互不覆盖
        let identifier = "ai.completion.\(Date().timeIntervalSince1970)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 点击通知：唤出 AI 对话窗（切回主线程）。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            AIWindowManager.shared.show()
        }
        completionHandler()
    }

    /// 应用在前台时也允许横幅 + 声音（默认前台不展示，显式开启）。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}