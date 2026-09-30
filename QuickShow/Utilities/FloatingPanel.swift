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
    var onKeyDownAction: ((UInt16) -> Bool)?
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
                if cmdLongPressTimer == nil {
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
            } else if let handled = onKeyDownAction?(event.keyCode), handled {
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
        } else if let handled = onKeyDownAction?(event.keyCode), handled {
            return
        }
        super.keyDown(with: event)
    }
    
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
