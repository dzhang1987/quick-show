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
    var onNavigateUp: () -> Bool = { false }
    var onNavigateDown: () -> Bool = { false }
    var onNavigateLeft: () -> Bool = { false }
    var onNavigateRight: () -> Bool = { false }

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
            if (cleanFlags.contains(.control) && event.keyCode == KeyEquivalentCode.d.rawValue) || (cleanFlags == [.command] && event.keyCode == KeyEquivalentCode.delete.rawValue) {
                onQuickSwitcherDelete()
                return nil
            }
            if event.keyCode == KeyEquivalentCode.upArrow.rawValue { // Up Arrow
                onQuickSwitcherUp()
                return nil
            }
            if event.keyCode == KeyEquivalentCode.downArrow.rawValue { // Down Arrow
                onQuickSwitcherDown()
                return nil
            }
            if event.keyCode == KeyEquivalentCode.returnKey.rawValue || event.keyCode == KeyEquivalentCode.keypadEnter.rawValue { // Return / Enter
                onQuickSwitcherSelect()
                return nil
            }
            if event.keyCode == KeyEquivalentCode.tab.rawValue { // Tab / Shift+Tab
                if cleanFlags.contains(.shift) {
                    onQuickSwitcherUp()
                } else {
                    onQuickSwitcherDown()
                }
                return nil
            }
            if cleanFlags == [.command] && (event.keyCode == KeyEquivalentCode.p.rawValue || event.keyCode == KeyEquivalentCode.f.rawValue) {
                onDismissQuickSwitcher()
                return nil
            }
        }

        // ESC：统一交由 EscapePolicyCenter 策略化调度中心按 LIFO 栈自顶向下消费与防穿透
        if event.keyCode == KeyEquivalentCode.escape.rawValue {
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

        // 抽屉在场时的键盘盲操：⏎ 执行/提交，⌘⏎ 允许并记忆/强制提交
        if event.keyCode == KeyEquivalentCode.returnKey.rawValue || event.keyCode == KeyEquivalentCode.keypadEnter.rawValue {
            if let textView = event.window?.firstResponder as? NSTextView, textView.hasMarkedText() {
                return event
            }
            let handledDrawer = MainActor.assumeIsolated { () -> Bool in
                guard let req = ChatInteractionCenter.shared.request else { return false }
                switch req {
                case .toolConfirmation(let confirmation):
                    if cleanFlags == [.command] {
                        if !confirmation.riskLevel.isDestructive {
                            if let scope = confirmation.suggestedScope {
                                ChatInteractionCenter.shared.resolveConfirmation(.allowSuggestedScope(scope))
                            } else {
                                ChatInteractionCenter.shared.resolveConfirmation(.alwaysAllowThisSession)
                            }
                            return true
                        }
                    } else if cleanFlags.isEmpty {
                        // 焦点在文本输入区且已有文字时（用户正在草稿或对话输入），普通回车放行给输入框发送，绝不可被抽屉盲操抢先吞掉
                        if let textView = event.window?.firstResponder as? NSTextView, !textView.string.isEmpty {
                            return false
                        }
                        NotificationCenter.default.post(name: .quickShowExecuteToolConfirmation, object: nil)
                        return true
                    }
                case .userQuestions:
                    // 提问抽屉在场时：回车统一作为提交主动作（与按钮「提交答案 ⏎」语义严格一致）
                    NotificationCenter.default.post(name: .quickShowSubmitUserQuestions, object: nil)
                    return true
                }
                return false
            }
            if handledDrawer {
                return nil
            }
        }

        // 提问抽屉在场时的键盘盲操：Tab / ↑ / ↓ 切换题目焦点，数字键 1-9 切换选项
        // Tab / Shift+Tab：切换题目焦点（提问抽屉在场时，Tab 均用于切题）
        if event.keyCode == KeyEquivalentCode.tab.rawValue {
            let step = cleanFlags.contains(.shift) ? -1 : 1
            let handledTab = MainActor.assumeIsolated { () -> Bool in
                guard let req = ChatInteractionCenter.shared.request,
                      case .userQuestions(let userQuestionsReq) = req else { return false }
                if userQuestionsReq.questions.count > 1 {
                    NotificationCenter.default.post(
                        name: .quickShowNavigateQuestion,
                        object: nil,
                        userInfo: ["step": step]
                    )
                }
                return true
            }
            if handledTab { return nil }
        }

        // 方向键 ↑ / ↓ 切换题目焦点
        if event.keyCode == KeyEquivalentCode.upArrow.rawValue || event.keyCode == KeyEquivalentCode.downArrow.rawValue {
            let step = (event.keyCode == KeyEquivalentCode.upArrow.rawValue) ? -1 : 1
            let handledArrow = MainActor.assumeIsolated { () -> Bool in
                guard let req = ChatInteractionCenter.shared.request,
                      case .userQuestions(let userQuestionsReq) = req,
                      userQuestionsReq.questions.count > 1 else { return false }
                // 若当前正处于行内自定义打字编辑态，方向键保留给文本输入光标移动
                if ChatInteractionCenter.shared.isQuestionInlineEditing {
                    return false
                }
                NotificationCenter.default.post(
                    name: .quickShowNavigateQuestion,
                    object: nil,
                    userInfo: ["step": step]
                )
                return true
            }
            if handledArrow { return nil }
        }

        // 数字键 1-9 快速切换选项
        if cleanFlags.isEmpty {
            let numberKeyCodes: [UInt16: Int] = [
                KeyEquivalentCode.num1.rawValue: 0,
                KeyEquivalentCode.num2.rawValue: 1,
                KeyEquivalentCode.num3.rawValue: 2,
                KeyEquivalentCode.num4.rawValue: 3,
                KeyEquivalentCode.num5.rawValue: 4,
                KeyEquivalentCode.num6.rawValue: 5,
                KeyEquivalentCode.num7.rawValue: 6,
                KeyEquivalentCode.num8.rawValue: 7,
                KeyEquivalentCode.num9.rawValue: 8,
                KeyEquivalentCode.keypad1.rawValue: 0,
                KeyEquivalentCode.keypad2.rawValue: 1,
                KeyEquivalentCode.keypad3.rawValue: 2,
                KeyEquivalentCode.keypad4.rawValue: 3,
                KeyEquivalentCode.keypad5.rawValue: 4,
                KeyEquivalentCode.keypad6.rawValue: 5,
                KeyEquivalentCode.keypad7.rawValue: 6,
                KeyEquivalentCode.keypad8.rawValue: 7,
                KeyEquivalentCode.keypad9.rawValue: 8
            ]
            if let optionIndex = numberKeyCodes[event.keyCode] {
                let handledNumber = MainActor.assumeIsolated { () -> Bool in
                    guard let req = ChatInteractionCenter.shared.request, case .userQuestions = req else {
                        return false
                    }
                    // 状态机核心：若处于行内打字编辑态，数字键 1-9 100% 原生放行打字输入！
                    if ChatInteractionCenter.shared.isQuestionInlineEditing {
                        return false
                    }
                    NotificationCenter.default.post(
                        name: .quickShowSelectQuestionOption,
                        object: nil,
                        userInfo: ["index": optionIndex]
                    )
                    return true
                }
                if handledNumber {
                    return nil
                }
            }
        }

        guard cleanFlags == [.command] else { return event }
        switch event.keyCode {
        case KeyEquivalentCode.p.rawValue: onToggleQuickSwitcher(); return nil // ⌘P: 快速切换/搜索面板
        case KeyEquivalentCode.leftBracket.rawValue: onPreviousSession(); return nil     // ⌘[: 上一个会话
        case KeyEquivalentCode.rightBracket.rawValue: onNextSession(); return nil         // ⌘]: 下一个会话
        case KeyEquivalentCode.n.rawValue: onNewSession(); return nil          // ⌘N: 新会话
        case KeyEquivalentCode.b.rawValue: onToggleSidebar(); return nil       // ⌘B: 侧栏显隐
        case KeyEquivalentCode.f.rawValue: onFocusSearch(); return nil         // ⌘F: 聚焦搜索
        case KeyEquivalentCode.upArrow.rawValue: return onNavigateUp() ? nil : event   // ⌘↑: 返回主 Agent
        case KeyEquivalentCode.downArrow.rawValue: return onNavigateDown() ? nil : event // ⌘↓: 钻入子 Agent
        case KeyEquivalentCode.leftArrow.rawValue: return onNavigateLeft() ? nil : event // ⌘←: 切换到前一个同级子 Agent
        case KeyEquivalentCode.rightArrow.rawValue: return onNavigateRight() ? nil : event // ⌘→: 切换到后一个同级子 Agent
        default: return event
        }
        return event
    }
}
