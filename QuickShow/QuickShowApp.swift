import AppKit
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 确保在 Dock 程序坞上完全隐藏图标，仅在状态栏与快捷浮动面板常驻
        NSApp.setActivationPolicy(.accessory)
        
        let state = AppState()
        self.appState = state
        
        // 预热悬浮面板，确保快捷键唤醒零延迟
        PanelManager.shared.setup(with: state)
        
        HotKeyManager.shared.onTrigger = { [weak state] in
            state?.toggleFromHotKey()
        }
        HotKeyManager.shared.configure(type: state.triggerType)
        
        setupStatusItem()
    }
    
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "QuickShow")
            button.imagePosition = .imageOnly
        }
        
        let menu = NSMenu()
        
        let showItem = NSMenuItem(title: "显示信息面板 (\(appState.triggerType.shortName))", action: #selector(togglePanel), keyEquivalent: "t")
        showItem.keyEquivalentModifierMask = [.command, .shift]
        showItem.target = self
        menu.addItem(showItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "偏好设置...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "退出 QuickShow", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
        
        item.menu = menu
        self.statusItem = item
    }
    
    @objc private func togglePanel() {
        appState.toggleFromHotKey()
    }
    
    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "QuickShow 偏好设置"
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(appState: appState))
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
