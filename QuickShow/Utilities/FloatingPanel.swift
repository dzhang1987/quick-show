import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    var onEscapePressed: (() -> Void)?
    var onSpacePressed: (() -> Void)?
    var onTabPressed: (() -> Void)?
    var onSettingsPressed: (() -> Void)?
    var onQuitPressed: (() -> Void)?
    var onCommandLongPressed: (() -> Void)?
    var onCommandReleased: (() -> Void)?
    var onQuestionMarkPressed: (() -> Void)?
    var onKeyDownAction: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?
    
    private var cmdLongPressTimer: Timer?
    
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        level = .statusBar
        backgroundColor = NSColor.clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }
    
    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            let isCmd = event.modifierFlags.contains(.command)
            if isCmd {
                // ⌘ 之外出现其他修饰键（⌥/⌃/⇧/fn），说明用户在构建组合键（如 ⌘⇧X 截屏），
                // 长按意图不再纯净，立即取消长按判定，避免误触速查表
                let hasOtherModifiers = !event.modifierFlags.intersection([.option, .control, .shift, .function]).isEmpty
                if hasOtherModifiers {
                    cmdLongPressTimer?.invalidate()
                    cmdLongPressTimer = nil
                } else if cmdLongPressTimer == nil {
                    cmdLongPressTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                        self?.cmdLongPressTimer = nil
                        self?.onCommandLongPressed?()
                    }
                }
            } else {
                cmdLongPressTimer?.invalidate()
                cmdLongPressTimer = nil
                onCommandReleased?()
            }
        } else if event.type == .keyDown {
            cmdLongPressTimer?.invalidate()
            cmdLongPressTimer = nil
            
            // 文本编辑聚焦时全部按键放行给第一响应者（编辑表单 TextField/DatePicker 的 field editor
            // 即 NSTextView）——窗口级拦截先于第一响应者，会吞掉 G/Tab/⏎/←→ 导致无法输入并误触
            // 全局动作；ESC 此时走标准 AppKit cancelOperation 结束编辑（不退出面板）
            if firstResponder is NSTextView {
                super.sendEvent(event)
                return
            }
            
            // ? 键速查表切换 (Shift + / 或 characters == "?")
            if event.characters == "?" || (event.keyCode == 44 && event.modifierFlags.contains(.shift)) {
                onQuestionMarkPressed?()
                return
            }
            
            let isCmd = event.modifierFlags.contains(.command)
            if isCmd && event.keyCode == 43 { // ⌘ + , 打开偏好设置
                onSettingsPressed?()
                return
            } else if isCmd && event.keyCode == 12 { // ⌘ + Q 退出
                onQuitPressed?()
                return
            }
            
            if event.keyCode == 53 { // ESC 键
                onEscapePressed?()
                return
            } else if event.keyCode == 49 { // Space 空格键
                onSpacePressed?()
                return
            } else if event.keyCode == 48 { // Tab 键
                onTabPressed?()
                return
            } else if let handled = onKeyDownAction?(event), handled {
                return
            }
        }
        super.sendEvent(event)
    }
    
    override func orderOut(_ sender: Any?) {
        cmdLongPressTimer?.invalidate()
        cmdLongPressTimer = nil
        super.orderOut(sender)
    }
    
    override func cancelOperation(_ sender: Any?) {
        onEscapePressed?()
    }
    
    override func keyDown(with event: NSEvent) {
        // 文本编辑聚焦时放行给第一响应者（与 sendEvent 分支同理，兜住 keyDown 直投路径）
        if firstResponder is NSTextView {
            super.keyDown(with: event)
            return
        }
        
        let isCmd = event.modifierFlags.contains(.command)
        if isCmd && event.keyCode == 43 { // ⌘ + ,
            onSettingsPressed?()
            return
        } else if isCmd && event.keyCode == 12 { // ⌘ + Q
            onQuitPressed?()
            return
        }
        
        if event.keyCode == 53 { // ESC 键
            onEscapePressed?()
            return
        } else if event.keyCode == 49 { // Space 空格键
            onSpacePressed?()
            return
        } else if event.keyCode == 48 { // Tab 键
            onTabPressed?()
            return
        } else if let handled = onKeyDownAction?(event), handled {
            return
        }
        super.keyDown(with: event)
    }
    
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
