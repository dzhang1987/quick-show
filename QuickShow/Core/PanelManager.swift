import AppKit
import SwiftUI
import Darwin

final class PanelManager {
    static let shared = PanelManager()
    
    private var panel: FloatingPanel?
    private var clickMonitor: Any?
    private var escGlobalMonitor: Any?
    private var escLocalMonitor: Any?
    private weak var appState: AppState?
    
    private var previousApp: NSRunningApplication?
    private var isDismissing: Bool = false
    
    private init() {}
    
    func setup(with appState: AppState) {
        self.appState = appState
        let screen = ScreenHelper.activeScreen
        let initialSize = targetSize(on: screen)
        let frame = ScreenHelper.centeredFrame(for: initialSize, on: screen)
        let panel = FloatingPanel(contentRect: frame)
        
        let contentView = PanelView(appState: appState)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        // 关键核心：在 AppKit 根图层硬件级施加 26pt 连续曲率圆角裁剪，沉稳克制，杜绝直角
        hostingView.layer?.cornerRadius = 26
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.invalidateShadow()
        
        // ESC 快捷退出（若正在展示 CheatSheet 则优先关闭 CheatSheet）
        panel.onEscapePressed = { [weak appState] in
            guard let appState = appState else { return }
            if appState.showCheatSheet {
                appState.setCheatSheetVisible(false)
            } else {
                appState.dismiss()
            }
        }
        
        // Space 常驻切换 (Toggle Pin / Unpin)
        panel.onSpacePressed = { [weak appState] in
            appState?.togglePin()
        }
        
        // Tab 极简/展开详细监控切换
        panel.onTabPressed = { [weak appState] in
            appState?.toggleExpanded()
        }
        
        // ⌘ + , 快捷打开偏好设置
        panel.onSettingsPressed = { [weak appState] in
            appState?.openSettings()
        }
        
        // ⌘ + Q 彻底退出
        panel.onQuitPressed = { [weak appState] in
            appState?.quitApp()
        }
        
        // 长按 Command (⌘) 展示按键速查表
        panel.onCommandLongPressed = { [weak appState] in
            appState?.setCheatSheetVisible(true)
        }
        
        // 松开 Command (⌘) 自动淡出速查表
        panel.onCommandReleased = { [weak appState] in
            appState?.setCheatSheetVisible(false)
        }
        
        // 敲击 ? 键切换速查表
        panel.onQuestionMarkPressed = { [weak appState] in
            appState?.toggleCheatSheet()
        }
        
        // 全键盘盲操快捷键
        panel.onKeyDownAction = { [weak appState] keyCode in
            guard let appState = appState else { return false }
            appState.resetGlanceTimer()
            switch keyCode {
            case 46: // M: 静音 / 取消静音
                appState.toggleMute()
                return true
            case 126: // Up Arrow: 音量 +5%
                appState.adjustVolume(by: 5)
                return true
            case 125: // Down Arrow: 音量 -5%
                appState.adjustVolume(by: -5)
                return true
            case 0: // A: 咖啡因防休眠开关
                appState.toggleKeepAwake()
                return true
            case 8: // C: 一键优化清理系统内存
                appState.optimizeMemory()
                return true
            case 35: // P: 番茄钟播放 / 暂停
                appState.togglePomodoro()
                return true
            case 31: // O: 打开下载目录
                appState.openDownloadsFolder()
                return true
            case 7: // X: 剪贴板纯文本化
                appState.cleanClipboard()
                return true
            case 37: // L: 全屏立即锁屏离座
                appState.lockScreen()
                return true
            case 2: // D: 专注模式设置
                appState.openFocusSettings()
                return true
            default:
                return false
            }
        }
        
        panel.onResignKey = { [weak appState] in
            guard let appState = appState else { return }
            // 仅在一瞥模式且未固定时，失焦才自动淡出
            if appState.mode == .glance {
                appState.dismiss()
            }
        }
        
        self.panel = panel
        
        appState.onTogglePanel = { [weak self] mode in
            self?.showPanel(mode: mode)
        }
        
        appState.onDismissPanel = { [weak self] in
            self?.hidePanel()
        }
        
        appState.onExpansionChange = { [weak self] _ in
            self?.updatePanelFrameAnimated()
        }
        
        appState.onCheatSheetChange = { [weak self] _ in
            self?.updatePanelFrameAnimated()
        }
        
        appState.onCheatSheetChange = { [weak self] _ in
            self?.updatePanelFrameAnimated()
        }
        
        appState.onLayoutChange = { [weak self] in
            self?.updatePanelFrameAnimated()
        }
    }
    
    private func targetSize(on screen: NSScreen = ScreenHelper.activeScreen) -> NSSize {
        let metrics = appState?.currentMetrics(for: screen) ?? ScreenHelper.metrics(for: screen, option: .auto)
        let isExpandedOrCheat = (appState?.isExpanded == true || appState?.showCheatSheet == true)
        return isExpandedOrCheat ? metrics.expandedSize : metrics.compactSize
    }
    
    func showPanel(mode: PanelMode) {
        guard let panel = panel else { return }
        
        let screen = ScreenHelper.activeScreen
        let size = targetSize(on: screen)
        let newFrame = ScreenHelper.centeredFrame(for: size, on: screen)
        
        panel.setFrame(newFrame, display: true)
        panel.invalidateShadow()
        
        if !panel.isVisible {
            // 记录呼出前的最前台应用，以便退出时瞬间归还焦点
            previousApp = NSWorkspace.shared.frontmostApplication
            isDismissing = false
            panel.ignoresMouseEvents = false
            panel.alphaValue = 0.0
            panel.makeKeyAndOrderFront(nil)
            panel.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
        
        startClickOutsideMonitor()
        startEscMonitor()
    }
    
    func updatePanelFrameAnimated() {
        guard let panel = panel, panel.isVisible else { return }
        let screen = ScreenHelper.activeScreen
        let targetFrame = ScreenHelper.centeredFrame(for: targetSize(on: screen), on: screen)
        
        // 与 SwiftUI 0.18s easeInEaseOut 动画完全同步，并在完成时立即重建精准阴影
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }, completionHandler: { [weak panel] in
            panel?.invalidateShadow()
        })
    }
    
    func handleExpansionChange(_ isExpanded: Bool) {
        updatePanelFrameAnimated()
    }
    
    func hidePanel() {
        guard let panel = panel, panel.isVisible, !isDismissing else { return }
        isDismissing = true
        
        stopClickOutsideMonitor()
        stopEscMonitor()
        
        // 1. 立即停止捕获鼠标事件
        panel.ignoresMouseEvents = true
        
        // 2. 瞬间将焦点归还给呼出前的应用
        if let prev = previousApp, prev.bundleIdentifier != Bundle.main.bundleIdentifier {
            prev.activate(options: [.activateIgnoringOtherApps])
        }
        previousApp = nil
        
        // 3. 极速灵动淡出
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            guard let self = self else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1.0
            panel.ignoresMouseEvents = false
            self.isDismissing = false
            
            // 重置尺寸回默认紧凑态
            let screen = ScreenHelper.activeScreen
            let metrics = self.appState?.currentMetrics(for: screen) ?? ScreenHelper.metrics(for: screen, option: .auto)
            let resetFrame = ScreenHelper.centeredFrame(for: metrics.compactSize, on: screen)
            panel.setFrame(resetFrame, display: false)
            
            // 释放闲置内存
            malloc_zone_pressure_relief(nil, 0)
        }
    }
    
    private func startEscMonitor() {
        stopEscMonitor()
        
        // 全局键盘监听备用
        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isVisible else { return }
            if event.keyCode == 53 { // ESC 键
                DispatchQueue.main.async {
                    self.appState?.dismiss()
                }
            }
        }
        
        // 本地按键监听（同步立刻响应）
        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isVisible else { return event }
            if event.keyCode == 53 { // ESC 键
                self.appState?.dismiss()
                return nil
            }
            return event
        }
    }
    
    private func stopEscMonitor() {
        if let monitor = escGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            escGlobalMonitor = nil
        }
        if let monitor = escLocalMonitor {
            NSEvent.removeMonitor(monitor)
            escLocalMonitor = nil
        }
    }
    
    private func startClickOutsideMonitor() {
        stopClickOutsideMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isVisible, let appState = self.appState else { return }
            let clickLocation = NSEvent.mouseLocation
            if !panel.frame.contains(clickLocation) {
                if appState.mode == .glance {
                    DispatchQueue.main.async {
                        self.appState?.dismiss()
                    }
                }
            }
        }
    }
    
    private func stopClickOutsideMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
}
