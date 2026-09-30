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
    private let panelSize = NSSize(width: 360, height: 172)
    
    private var previousApp: NSRunningApplication?
    private var isDismissing: Bool = false
    
    private init() {}
    
    func setup(with appState: AppState) {
        self.appState = appState
        let frame = ScreenHelper.centeredFrame(for: panelSize)
        let panel = FloatingPanel(contentRect: frame)
        
        let contentView = PanelView(appState: appState)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.invalidateShadow()
        
        panel.onEscapePressed = { [weak appState] in
            appState?.dismiss()
        }
        
        panel.onSpacePressed = { [weak appState] in
            if appState?.mode == .glance {
                appState?.pin()
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
    }
    
    func showPanel(mode: PanelMode) {
        guard let panel = panel else { return }
        
        // 每次呼出都重新计算鼠标当前屏幕居中位置，支持多屏动态切换
        let newFrame = ScreenHelper.centeredFrame(for: panelSize)
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
    
    func hidePanel() {
        guard let panel = panel, panel.isVisible, !isDismissing else { return }
        isDismissing = true
        
        stopClickOutsideMonitor()
        stopEscMonitor()
        
        // 1. 立即停止捕获鼠标事件
        panel.ignoresMouseEvents = true
        
        // 2. 核心优化：瞬间将焦点归还给呼出前的应用，彻底根除键盘焦点的“粘滞停顿感”！
        if let prev = previousApp, prev.bundleIdentifier != Bundle.main.bundleIdentifier {
            prev.activate(options: [.activateIgnoringOtherApps])
        }
        previousApp = nil
        
        // 3. 极速灵动淡出（0.08 秒 easeOut，第 1 帧即刻衰减，干脆利落不拖泥带水）
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.alphaValue = 1.0
            panel.ignoresMouseEvents = false
            self?.isDismissing = false
            
            // 极致内存优化：在面板隐退后，通知系统释放闲置内存，完全保留预热视图保证下次零延迟唤醒
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
        
        // 本地按键监听（同步立刻响应，不推迟到下一个 runloop）
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
            guard let self = self, let panel = self.panel, panel.isVisible else { return }
            let clickLocation = NSEvent.mouseLocation
            if !panel.frame.contains(clickLocation) {
                // 点击了面板外区域，自动淡出
                DispatchQueue.main.async {
                    self.appState?.dismiss()
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
