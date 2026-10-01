import Foundation
import Carbon
import AppKit

enum TriggerType: String, CaseIterable, Identifiable {
    case doubleCmd = "double_cmd"
    case doubleCtrl = "double_ctrl"
    case doubleOpt = "double_opt"
    case doubleShift = "double_shift"
    case hotKeyCmdShiftT = "hotkey_cmd_shift_t"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .doubleCmd: return "双击 Command (⌘ ⌘)"
        case .doubleCtrl: return "双击 Control (⌃ ⌃)"
        case .doubleOpt: return "双击 Option (⌥ ⌥)"
        case .doubleShift: return "双击 Shift (⇧ ⇧)"
        case .hotKeyCmdShiftT: return "组合键 ⌘ + Shift + T"
        }
    }
    
    var shortName: String {
        switch self {
        case .doubleCmd: return "双击 ⌘"
        case .doubleCtrl: return "双击 ⌃"
        case .doubleOpt: return "双击 ⌥"
        case .doubleShift: return "双击 ⇧"
        case .hotKeyCmdShiftT: return "⌘⇧T"
        }
    }
}

/// 全局快捷与双击修饰键管理器，原生支持双击 Cmd/Ctrl/Option/Shift 以及经典组合键
final class HotKeyManager {
    static let shared = HotKeyManager()
    
    var onTrigger: (() -> Void)?
    
    private var currentType: TriggerType = .doubleCmd
    
    // 双击修饰键监听状态
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastReleaseTime: TimeInterval = 0
    private var isTargetModifierDown: Bool = false
    
    // Carbon 组合键状态
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    
    private init() {
        installCarbonEventHandler()
    }
    
    deinit {
        stopMonitoring()
        unregisterHotKey()
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
    
    /// 配置触发模式
    func configure(type: TriggerType) {
        self.currentType = type
        stopMonitoring()
        unregisterHotKey()
        
        switch type {
        case .hotKeyCmdShiftT:
            registerHotKey()
        case .doubleCmd, .doubleCtrl, .doubleOpt, .doubleShift:
            // 仅监听双击修饰键；不再默认注册 ⌘⇧T，避免抢占浏览器等高频系统快捷键
            startMonitoring()
        }
        
        NSLog("[QuickShow] 快捷触发模式更新为: \(type.displayName)")
    }
    
    // MARK: - 双击修饰键监听
    
    private func startMonitoring() {
        // 全局修饰键监听（不需要 Accessibility 权限即可监听 flagsChanged）
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleEvent(event)
        }
        
        // 应用内部按键监听
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleEvent(event)
            return event
        }
    }
    
    private func stopMonitoring() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        lastReleaseTime = 0
        isTargetModifierDown = false
    }
    
    private func handleEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // 用户在按下修饰键的同时敲击了常规字符键（例如按了 Cmd+C），打断双击判定防误触
            lastReleaseTime = 0
            return
        }
        
        guard event.type == .flagsChanged else { return }
        
        let keyCode = event.keyCode
        let flags = event.modifierFlags
        let now = ProcessInfo.processInfo.systemUptime
        
        let isTargetKey: Bool
        let isPressed: Bool
        
        switch currentType {
        case .doubleCmd:
            isTargetKey = (keyCode == 54 || keyCode == 55) // 左/右 Command
            isPressed = flags.contains(.command)
        case .doubleCtrl:
            isTargetKey = (keyCode == 59 || keyCode == 62) // 左/右 Control
            isPressed = flags.contains(.control)
        case .doubleOpt:
            isTargetKey = (keyCode == 58 || keyCode == 61) // 左/右 Option
            isPressed = flags.contains(.option)
        case .doubleShift:
            isTargetKey = (keyCode == 56 || keyCode == 60) // 左/右 Shift
            isPressed = flags.contains(.shift)
        case .hotKeyCmdShiftT:
            return
        }
        
        guard isTargetKey else {
            // 如果按下了其他修饰键，重置判定
            lastReleaseTime = 0
            isTargetModifierDown = false
            return
        }
        
        if isPressed {
            if !isTargetModifierDown {
                isTargetModifierDown = true
                let elapsed = now - lastReleaseTime
                // 380 毫秒内连续两次按下即为双击
                if elapsed > 0.04 && elapsed < 0.38 {
                    lastReleaseTime = 0
                    // NSEvent 监听回调本就在主线程，直接触发，省去一次多余的主线程跳转
                    onTrigger?()
                }
            }
        } else {
            if isTargetModifierDown {
                isTargetModifierDown = false
                lastReleaseTime = now
            }
        }
    }
    
    // MARK: - Carbon 传统组合键支持
    
    private func registerHotKey(keyCode: UInt32 = UInt32(kVK_ANSI_T), modifiers: UInt32 = UInt32(cmdKey | shiftKey)) {
        unregisterHotKey()
        
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x51534857), // "QSHW"
            id: 1
        )
        
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        
        if status != noErr {
            NSLog("[QuickShow] 注册全局快捷键失败: \(status)")
        }
    }
    
    private func unregisterHotKey() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
    
    private func installCarbonEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        let callback: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            
            DispatchQueue.main.async {
                manager.onTrigger?()
            }
            return noErr
        }
        
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
    }
}
