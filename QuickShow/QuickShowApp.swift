import AppKit
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private static var shared: AppDelegate?
    
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.run()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 确保在 Dock 程序坞上完全隐藏图标，仅在状态栏与快捷浮动面板常驻
        NSApp.setActivationPolicy(.accessory)
        
        let state = AppState()
        self.appState = state
        
        state.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        
        state.onMenuBarIconVisibilityChange = { [weak self] isVisible in
            self?.statusItem?.isVisible = isVisible
        }
        
        // 预热悬浮面板，确保快捷键唤醒零延迟
        PanelManager.shared.setup(with: state)
        
        HotKeyManager.shared.onTrigger = { [weak state] in
            state?.toggleFromHotKey()
        }
        HotKeyManager.shared.configure(type: state.triggerType)
        
        setupMainMenu()
        setupStatusItem()
        
        // 打开应用时，默认在屏幕中央展示一次一瞥面板
        if state.showOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak state] in
                state?.show(mode: .glance)
            }
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appState.show(mode: .glance)
        return true
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
        item.isVisible = appState.showMenuBarIcon
        self.statusItem = item
    }
    
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "偏好设置...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        
        appMenu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "退出 QuickShow", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        appMenu.addItem(quitItem)
        
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
    
    @objc private func togglePanel() {
        appState.toggleFromHotKey()
    }
    
    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbar = nil
            window.isMovableByWindowBackground = true
            window.title = "QuickShow 设置"
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(appState: appState))
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
