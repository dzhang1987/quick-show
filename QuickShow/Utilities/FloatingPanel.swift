import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    var onEscapePressed: (() -> Void)?
    var onSpacePressed: (() -> Void)?
    var onTabPressed: (() -> Void)?
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
            if event.keyCode == 53 { // ESC 键
                onEscapePressed?()
                return
            } else if event.keyCode == 49 { // Space 空格键
                onSpacePressed?()
                return
            } else if event.keyCode == 48 { // Tab 键
                onTabPressed?()
                return
            }
        }
        super.sendEvent(event)
    }
    
    override func cancelOperation(_ sender: Any?) {
        onEscapePressed?()
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC 键
            onEscapePressed?()
            return
        } else if event.keyCode == 49 { // Space 空格键
            onSpacePressed?()
            return
        } else if event.keyCode == 48 { // Tab 键
            onTabPressed?()
            return
        }
        super.keyDown(with: event)
    }
    
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
