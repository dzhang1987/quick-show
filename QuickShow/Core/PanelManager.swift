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
    
    private let compactSize = NSSize(width: 380, height: 168)
    private let expandedSize = NSSize(width: 430, height: 286)
    
    private var previousApp: NSRunningApplication?
    private var isDismissing: Bool = false
    
    private init() {}
    
    func setup(with appState: AppState) {
        self.appState = appState
        let frame = ScreenHelper.centeredFrame(for: compactSize)
        let panel = FloatingPanel(contentRect: frame)
        
        let contentView = PanelView(appState: appState)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        // 关键核心：在 AppKit 根图层硬件级施加 26pt 连续曲率圆角裁剪，彻底杜绝窗口尺寸变化中途露出直角
        hostingView.layer?.cornerRadius = 26
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.invalidateShadow()
        
        // ESC 快捷退出
        panel.onEscapePressed = { [weak appState] in
            appState?.dismiss()
        }
        
        // Space 常驻切换
        panel.onSpacePressed = { [weak appState] in
            if appState?.mode == .glance {
                appState?.pin()
            }
        }
        
        // Tab 极简/展开详细监控切换
        panel.onTabPressed = { [weak appState] in
            appState?.toggleExpanded()
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
        
        appState.onExpansionChange = { [weak self] isExpanded in
            self?.handleExpansionChange(isExpanded)
        }
    }
    
    func showPanel(mode: PanelMode) {
        guard let panel = panel else { return }
        
        let size = (appState?.isExpanded == true) ? expandedSize : compactSize
        let newFrame = ScreenHelper.centeredFrame(for: size)
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
    
    func handleExpansionChange(_ isExpanded: Bool) {
        guard let panel = panel, panel.isVisible else { return }
        let targetSize = isExpanded ? expandedSize : compactSize
        let targetFrame = ScreenHelper.centeredFrame(for: targetSize)
        
        // 与 SwiftUI 0.18s easeInEaseOut 动画完全同步，并在完成时立即重建精准阴影
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }, completionHandler: { [weak panel] in
            panel?.invalidateShadow()
        })
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
            let resetFrame = ScreenHelper.centeredFrame(for: self.compactSize)
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
