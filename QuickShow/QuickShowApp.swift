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

        // 注册内置富卡片（地图卡等）：须在任何聊天视图渲染前完成
        RichCardRegistry.shared.registerBuiltIns()

        // 尽早安装通知代理：通知点击可能在冷启动时先于用户交互到达
        AICompletionNotifier.shared.installDelegateIfNeeded()

        let state = AppState()
        self.appState = state
        
        // 启动时应用持久化的明暗模式（须在面板/设置窗口创建前，确保首帧外观正确）
        state.appearanceMode.apply()
        
        state.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        
        state.onMenuBarIconVisibilityChange = { [weak self] isVisible in
            self?.statusItem?.isVisible = isVisible
        }
        
        // 预热悬浮面板，确保快捷键唤醒零延迟
        PanelManager.shared.setup(with: state)
        
        // 双路分流：热键回调携带实际命中的触发类型——AI 类型 → AI 窗，其余 → 主面板
        HotKeyManager.shared.onTrigger = { [weak state] type in
            guard let state = state else { return }
            if type == state.aiTriggerType {
                AIWindowManager.shared.toggle()
            } else {
                state.toggleFromHotKey()
            }
        }
        HotKeyManager.shared.configure(type: state.triggerType, aiType: state.aiTriggerType)
        
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

        // 标准 Edit 菜单：无它则文本系统（设置窗口表单 / AI 输入框）的
        // ⌘C/⌘V/⌘X/⌘A/⌘Z 键等效派发链路缺失，粘贴、撤销等基础操作失效
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // Undo/Redo：文本系统的 ⌘Z/⇧⌘Z 键等效派发依赖主菜单存在对应 keyEquivalent 的菜单项
        // （与 ⌘C/⌘V 同理）；target 为 nil 走响应链，NSTextView 依据 canUndo/canRedo 自动启用禁用
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenuItem.submenu = editMenu

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
            // 整窗 Liquid Glass（对齐 macOS 27 系统设置「底玻璃、纸实底」）：
            // titled 标准窗口保留（交通灯/系统圆角/窗口阴影由系统 chrome 管理），
            // titlebar 透明一体化 = 交通灯坐在玻璃上（系统设置同款无标题条呈现）。
            // 26+ 玻璃作 contentView 承载设置内容，装载与两窗同款三重死锁规避
            // （sizingOptions=[] / 零时长动画上下文 / 先组装后挂窗）；设置窗惰性
            // 创建、创建即上屏（同 AI 窗时机，无挂起期）。sidebar 材质与 grouped
            // 表单卡片交给系统组件自适应（26 上即系统设置的渲染语言：双层分区
            // 明度差 + 实底表单卡片）。玻璃不设自绘圆角——titled 窗口形状由系统管理。
            // <26 保持 hostingView 直接作 contentView（窗口默认背景，观感不变）。
            window.backgroundColor = .clear
            window.isOpaque = false
            let hostingView = NSHostingView(rootView: SettingsView(appState: appState))
            if #available(macOS 26.0, *) {
                // 不设 sizingOptions=[]：那是两窗「PreferenceKey 测量链死锁」的规避手段；
                // 设置窗固定尺寸、无测量链、无动画，不需要禁 hosting 尺寸协商——禁用反而
                // 引入外层 HostingScrollView 自动滚动包装（溢出 822>506 时包装详情区，
                // 其滚动指示条退化成常驻宽体）。
                let glass = NSGlassEffectView()
                glass.style = .regular
                glass.tintColor = nil
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0
                    ctx.allowsImplicitAnimation = false
                    glass.frame = NSRect(origin: .zero, size: NSMakeSize(720, 500))
                    glass.contentView = hostingView
                })
                hostingView.autoresizingMask = [.width, .height]
                window.contentView = glass
            } else {
                window.backgroundColor = .windowBackgroundColor
                window.isOpaque = true
                window.contentView = hostingView
            }
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
