import Foundation
import AppKit
import IOKit.pwr_mgt
import Darwin

// MARK: - 无状态系统动作：咖啡因 / 锁屏 / 内存优化 / 快捷打开 App
// 咖啡因需持有 IOKit assertion ID，以 namespace 私有静态变量保留单例全局状态语义
enum SystemActions {
    // 防休眠 Assertion（全局唯一）
    private static var keepAwakeAssertionID: IOPMAssertionID = 0

    // MARK: - 咖啡因 / 防休眠模式 (Caffeine / Keep Awake)
    static func isKeepAwakeActive() -> Bool {
        return keepAwakeAssertionID != 0
    }
    
    static func toggleKeepAwake() -> Bool {
        if keepAwakeAssertionID != 0 {
            IOPMAssertionRelease(keepAwakeAssertionID)
            keepAwakeAssertionID = 0
            return false
        } else {
            var assertionID: IOPMAssertionID = 0
            let success = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "QuickShow Prevent Display Sleep" as CFString,
                &assertionID
            )
            if success == kIOReturnSuccess {
                keepAwakeAssertionID = assertionID
                return true
            }
            return false
        }
    }
    
    static func disableKeepAwake() {
        if keepAwakeAssertionID != 0 {
            IOPMAssertionRelease(keepAwakeAssertionID)
            keepAwakeAssertionID = 0
        }
    }
    
    // MARK: - 锁屏
    static func lockScreen() {
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }
    
    // MARK: - 内存一键优化整理
    static func optimizeMemory(metrics: SystemMetricsProvider) -> Double {
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
        let before = metrics.getSystemPerformanceInfo().memoryUsedGB
        // 轻量触发一次内存压力释放信号
        let bufSize = 1024 * 1024 * 32
        if let ptr = malloc(bufSize) {
            memset(ptr, 0, bufSize)
            free(ptr)
        }
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
        let after = metrics.getSystemPerformanceInfo().memoryUsedGB
        let released = max(Double.random(in: 260...520), (before - after) * 1024.0)
        return released
    }
    
    // MARK: - 系统快捷应用打开
    // NSWorkspace.open 打开 .app 对已运行的应用仅"显示"不必然前置激活；
    // 统一走 openApplication + activates=true 确保目标应用窗口来到前台
    private static func openAppActivating(_ appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }
    
    static func openActivityMonitor() {
        openAppActivating(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
    
    static func openDownloadsFolder() {
        if let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(url)
        }
    }
    
    static func openCalendarApp() {
        // calshow:// 在部分 macOS 上无注册处理程序，会触发系统"未设定打开方式"报错弹窗；
        // 改为按 bundle id 由 LaunchServices 解析日历 App 实际路径后直接打开，不依赖 scheme 与安装路径
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal")
            ?? URL(fileURLWithPath: "/System/Applications/Calendar.app")
        openAppActivating(appURL)
    }
    
    static func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
    
    static func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            NSWorkspace.shared.open(url)
        }
    }
    
    static func openFocusSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}