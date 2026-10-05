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

    /// 抽屉（权限确认 / AI 提问）是否在场
    var isDrawerOpen: () -> Bool = { false }
    /// 抽屉取消动作（权限 = 拒绝 / 提问 = 取消）
    var onCancelDrawer: () -> Void = {}
    var isRenaming: () -> Bool = { false }
    var onCancelRename: () -> Void = {}
    var isZooming: () -> Bool = { false }
    var onDismissZoom: () -> Void = {}
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
        guard event.window is AIPanel else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ESC：抽屉/重命名/放大态下先行消费；其余放行给窗口层阶段语义
        if event.keyCode == 53, flags.isEmpty {
            if isDrawerOpen() { onCancelDrawer(); return nil }
            if isRenaming() { onCancelRename(); return nil }
            if isZooming() { onDismissZoom(); return nil }
            return event
        }

        guard flags == [.command] else { return event }
        switch event.keyCode {
        case 45: onNewSession(); return nil   // N
        case 11: onToggleSidebar(); return nil // B
        case 3: onFocusSearch(); return nil    // F
        default: return event
        }
    }
}
