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
    var onKeyDownAction: ((UInt16) -> Bool)?
    var onResignKey: (() -> Void)?
    
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
        if event.type == .keyDown {
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
