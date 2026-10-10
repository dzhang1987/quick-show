// 从 AIChatScrollNavigation.swift 机械拆分：AI 会话滚动与浏览导航——AI 窗快捷键监听。

import AppKit

// MARK: - AI 窗快捷键监听

/// AI 窗级快捷键本地监听：⌘N 新会话 / ⌘B 侧栏显隐 / ⌘F 聚焦搜索。
/// 为什么不用 AIPanel.sendEvent 拦截：窗口层按键纪律（ESC/⌘K/文本聚焦放行）不允许改动；
/// 本地监听在 NSApplication 派发到窗口之前触发，既不动窗口层逻辑，又能覆盖
/// 「第一响应者非输入框」（如焦点在侧栏会话行）的路径。
/// 另承担三个 UI 态下的 ESC 先行消费：抽屉在场 → 取消抽屉（阶段 0，与窗口层同一语义）；
/// 行内重命名中 → 取消重命名；图片放大中 → 关闭放大层。
/// 非隔离类：本地监听恒在主线程事件派发路径触发，回调直接执行，避免 NSEvent 跨隔离域。
final class AIChatKeyMonitor {
    private var monitor: Any?

    var isQuickSwitcherOpen: () -> Bool = { false }
    var onDismissQuickSwitcher: () -> Void = {}
    var onQuickSwitcherUp: () -> Void = {}
    var onQuickSwitcherDown: () -> Void = {}
    var onQuickSwitcherSelect: () -> Void = {}
    var onQuickSwitcherDelete: () -> Void = {}
    var onToggleQuickSwitcher: () -> Void = {}
    var onPreviousSession: () -> Void = {}
    var onNextSession: () -> Void = {}
    var onNewSession: () -> Void = {}
    var onToggleSidebar: () -> Void = {}
    var onFocusSearch: () -> Void = {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // 只接管 AI 对话窗的按键（设置窗等其他窗口不受影响）
        guard event.window is AIPanel || (event.window == nil && NSApp.keyWindow is AIPanel) else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cleanFlags = flags.subtracting([.capsLock, .numericPad, .function])

        // Quick Switcher 在场时的专用键盘交互（↑/↓/Tab 导航，⏎ 选择，⌃D/⌘⌫ 删除，⌘P/⌘F 关闭）
        // 注意：ESC 键统一不在此处私自处理，全部交由下方的 EscapePolicyCenter 统一按 LIFO 栈调度与防穿透
        if isQuickSwitcherOpen() {
            // P0: 优先放行系统输入法 marked text 组字，让 IME 取消拼音/候选词上屏
            if let textView = event.window?.firstResponder as? NSTextView, textView.hasMarkedText() {
                return event
            }
            // ⌃D (keyCode 2) 或 ⌘⌫ (keyCode 51)：删除高亮会话
            if (cleanFlags.contains(.control) && event.keyCode == 2) || (cleanFlags == [.command] && event.keyCode == 51) {
                onQuickSwitcherDelete()
                return nil
            }
            if event.keyCode == 126 { // Up Arrow
                onQuickSwitcherUp()
                return nil
            }
            if event.keyCode == 125 { // Down Arrow
                onQuickSwitcherDown()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                onQuickSwitcherSelect()
                return nil
            }
            if event.keyCode == 48 { // Tab / Shift+Tab
                if cleanFlags.contains(.shift) {
                    onQuickSwitcherUp()
                } else {
                    onQuickSwitcherDown()
                }
                return nil
            }
            if cleanFlags == [.command] && (event.keyCode == 35 || event.keyCode == 3) {
                onDismissQuickSwitcher()
                return nil
            }
        }

        // ESC：优先交给 EscapePolicyCenter 策略化调度中心自顶向下消费
        if event.keyCode == 53 {
            // P0: 优先放行系统输入法 marked text 组字，让 IME 取消拼音
            if let textView = event.window?.firstResponder as? NSTextView, textView.hasMarkedText() {
                return event
            }
            let handled = MainActor.assumeIsolated {
                EscapePolicyCenter.shared.handleEscape()
            }
            if handled {
                return nil
            }
            return event
        }

        guard cleanFlags == [.command] else { return event }
        switch event.keyCode {
        case 35: onToggleQuickSwitcher(); return nil // ⌘P: 快速切换/搜索面板
        case 33: onPreviousSession(); return nil     // ⌘[: 上一个会话
        case 30: onNextSession(); return nil         // ⌘]: 下一个会话
        case 45: onNewSession(); return nil          // ⌘N: 新会话
        case 11: onToggleSidebar(); return nil       // ⌘B: 侧栏显隐
        case 3:  onFocusSearch(); return nil         // ⌘F: 聚焦搜索
        default: return event
        }
    }
}
