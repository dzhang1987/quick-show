import AppKit
import Foundation
import UserNotifications

// MARK: - 单实例守护者 (SingleInstanceGuard)
//
// 核心第一准则：系统中永远只能存在一个 QuickShow 主实例。
//
// 1. 进程判定：
//    - 入口处结合 NSRunningApplication 与 POSIX 文件排他锁 (flock) 双重判定；
//    - 若无其他存活实例，当前进程晋升为主实例 (Primary)，持有锁并正常启动主应用；
//    - 若已有其他实例，当前进程降级为次级中继实例 (Secondary)。
//
// 2. 次级中继实例 (Secondary) 行为：
//    - 严格阻断常规 UI/状态栏/热键/后台监控初始化；
//    - 挂载极简中继代理 (SecondaryRelayDelegate)，倾听通知点击 (UNUserNotificationCenter)；
//    - 捕获到通知点击后，将 sessionId 与唤醒指令通过 DistributedNotificationCenter 广播给主实例；
//    - 兜底超时 0.6 秒：若非通知点击唤醒（如外部 open 命令误触），广播常规唤醒指令并激活主实例；
//    - 完成转交后立即 exit(0)，寿命不超过 0.6 秒，绝不常驻系统。
//
// 3. 主实例 (Primary) 行为：
//    - 启动时注册 DistributedNotificationCenter 跨进程通知监听；
//    - 收到外部唤醒请求时：
//      - 若 action == "showAIChat"：切到目标 session 并在鼠标当前屏幕弹出 AI 对话窗；
//      - 若 action == "showPanel"：在当前屏幕弹出信息面板；
//      - 激活自身进程置顶。
final class SingleInstanceGuard: NSObject {
    static let shared = SingleInstanceGuard()
    
    static let relayNotificationName = Notification.Name("cn.chiproad.QuickShow.remoteActivation")
    
    private var lockFileDescriptor: Int32 = -1
    private var relayObserver: Any?
    
    private override init() { super.init() }
    
    deinit {
        if lockFileDescriptor >= 0 {
            close(lockFileDescriptor)
        }
    }
    
    /// 尝试抢占主实例锁。若返回 true 则当前进程为主实例；若返回 false 则为次级中继实例。
    func tryAcquirePrimaryLock() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "cn.chiproad.QuickShow"
        
        // 1. 检查系统中是否有其它同 BundleID 的活跃进程
        let otherApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
        if !otherApps.isEmpty {
            return false
        }
        
        // 2. 内核级 POSIX 文件锁（防并发毫秒级竞态）
        let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("cn.chiproad.QuickShow.instance.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 {
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                close(fd)
                return false
            }
            self.lockFileDescriptor = fd
        }
        
        return true
    }
    
    /// 主实例：开始监听来自次级实例的中继广播
    func startListeningForRelay(onActivate: @escaping (_ action: String, _ sessionId: UUID?) -> Void) {
        relayObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.relayNotificationName,
            object: nil,
            queue: .main
        ) { notification in
            let userInfo = notification.userInfo as? [String: String] ?? [:]
            let action = userInfo["action"] ?? "showPanel"
            let sessionId = userInfo["sessionId"].flatMap { UUID(uuidString: $0) }
            onActivate(action, sessionId)
        }
    }
    
    /// 次级实例：运行极简中继代理，捕获通知/唤醒事件并转交主实例后立即 exit(0)
    func runSecondaryRelay(app: NSApplication) {
        let relayDelegate = SecondaryRelayDelegate()
        app.delegate = relayDelegate
        app.run()
    }
}

// MARK: - 次级中继代理 (SecondaryRelayDelegate)

final class SecondaryRelayDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var didRelay = false
    private var timeoutTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 后台静默运行，不污染 Dock 和菜单栏
        NSApp.setActivationPolicy(.accessory)
        
        // 安装通知代理以接收可能由 LaunchServices 派发的通知点击
        UNUserNotificationCenter.current().delegate = self
        
        // 安全兜底定时器：0.6 秒内无通知点击事件（如命令行/双击拉起），转交常规唤醒后立刻退出
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.relayAndExit(action: "showPanel", sessionId: nil)
        }
    }
    
    // 点击通知横幅的回调
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo["sessionId"] as? String
        
        DispatchQueue.main.async { [weak self] in
            self?.relayAndExit(action: "showAIChat", sessionId: sessionId)
        }
        completionHandler()
    }
    
    private func relayAndExit(action: String, sessionId: String?) {
        guard !didRelay else { return }
        didRelay = true
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        
        var info: [String: String] = ["action": action]
        if let sessionId {
            info["sessionId"] = sessionId
        }
        
        // 1. 通过分布式通知中心跨进程广播给主实例
        DistributedNotificationCenter.default().postNotificationName(
            SingleInstanceGuard.relayNotificationName,
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
        
        // 2. 唤醒并激活主实例
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "cn.chiproad.QuickShow"
        if let primary = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != currentPID && !$0.isTerminated }) {
            primary.activate(options: [.activateIgnoringOtherApps])
        }
        
        // 3. 次级实例立即体面退出
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exit(0)
        }
    }
}
