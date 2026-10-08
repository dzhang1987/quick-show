import Foundation
import Carbon
import AppKit

/// 触发类型：双击修饰键（支持任意侧 / 左 / 右精确区分）与经典组合键。
///
/// 分组说明：
/// - 4 个「任意侧」双击类型（doubleCmd/Ctrl/Opt/Shift）：双击同族任一侧均触发，rawValue 为历史值，向后兼容。
/// - 8 个「左右专属」双击类型（doubleLeftXxx / doubleRightXxx）：精确到单侧 keyCode。
/// - 1 个组合键类型（hotKeyCmdShiftT）：Carbon 全局热键槽位。
enum TriggerType: String, CaseIterable, Identifiable {
    // MARK: 任意侧双击（默认，向后兼容旧 rawValue）
    case doubleCmd = "double_cmd"
    case doubleCtrl = "double_ctrl"
    case doubleOpt = "double_opt"
    case doubleShift = "double_shift"
    case hotKeyCmdShiftT = "hotkey_cmd_shift_t"

    // MARK: 左右侧专属双击（精确到单侧 keyCode）
    case doubleLeftCmd = "doubleLeftCmd"
    case doubleRightCmd = "doubleRightCmd"
    case doubleLeftCtrl = "doubleLeftCtrl"
    case doubleRightCtrl = "doubleRightCtrl"
    case doubleLeftOpt = "doubleLeftOpt"
    case doubleRightOpt = "doubleRightOpt"
    case doubleLeftShift = "doubleLeftShift"
    case doubleRightShift = "doubleRightShift"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .doubleCmd: return String(localized: "双击 Command (⌘ ⌘)")
        case .doubleCtrl: return String(localized: "双击 Control (⌃ ⌃)")
        case .doubleOpt: return String(localized: "双击 Option (⌥ ⌥)")
        case .doubleShift: return String(localized: "双击 Shift (⇧ ⇧)")
        case .hotKeyCmdShiftT: return String(localized: "组合键 ⌘ + Shift + T")
        case .doubleLeftCmd: return String(localized: "双击左侧 Command (左⌘ 左⌘)")
        case .doubleRightCmd: return String(localized: "双击右侧 Command (右⌘ 右⌘)")
        case .doubleLeftCtrl: return String(localized: "双击左侧 Control (左⌃ 左⌃)")
        case .doubleRightCtrl: return String(localized: "双击右侧 Control (右⌃ 右⌃)")
        case .doubleLeftOpt: return String(localized: "双击左侧 Option (左⌥ 左⌥)")
        case .doubleRightOpt: return String(localized: "双击右侧 Option (右⌥ 右⌥)")
        case .doubleLeftShift: return String(localized: "双击左侧 Shift (左⇧ 左⇧)")
        case .doubleRightShift: return String(localized: "双击右侧 Shift (右⇧ 右⇧)")
        }
    }

    var shortName: String {
        switch self {
        case .doubleCmd: return String(localized: "双击 ⌘")
        case .doubleCtrl: return String(localized: "双击 ⌃")
        case .doubleOpt: return String(localized: "双击 ⌥")
        case .doubleShift: return String(localized: "双击 ⇧")
        case .hotKeyCmdShiftT: return String(localized: "⌘⇧T")
        case .doubleLeftCmd: return String(localized: "双击左 ⌘")
        case .doubleRightCmd: return String(localized: "双击右 ⌘")
        case .doubleLeftCtrl: return String(localized: "双击左 ⌃")
        case .doubleRightCtrl: return String(localized: "双击右 ⌃")
        case .doubleLeftOpt: return String(localized: "双击左 ⌥")
        case .doubleRightOpt: return String(localized: "双击右 ⌥")
        case .doubleLeftShift: return String(localized: "双击左 ⇧")
        case .doubleRightShift: return String(localized: "双击右 ⇧")
        }
    }

    /// 是否为双击修饰键类型（排除 Carbon 组合键）
    var isDoubleModifier: Bool { self != .hotKeyCmdShiftT }

    /// 该类型精确命中的修饰键 keyCode 集合（互斥校验与双击判定共用单一来源）。
    /// 任意侧 = 同族两个 keyCode；左右专属 = 单侧 keyCode；组合键 = 空集。
    /// 修饰键 keyCode：左⌘54 右⌘55 / 左⌃59 右⌃62 / 左⌥58 右⌥61 / 左⇧56 右⇧60。
    var modifierKeyCodes: Set<UInt16> {
        switch self {
        case .doubleCmd: return [54, 55]
        case .doubleLeftCmd: return [54]
        case .doubleRightCmd: return [55]
        case .doubleCtrl: return [59, 62]
        case .doubleLeftCtrl: return [59]
        case .doubleRightCtrl: return [62]
        case .doubleOpt: return [58, 61]
        case .doubleLeftOpt: return [58]
        case .doubleRightOpt: return [61]
        case .doubleShift: return [56, 60]
        case .doubleLeftShift: return [56]
        case .doubleRightShift: return [60]
        case .hotKeyCmdShiftT: return []
        }
    }

    /// 双击判定所需的修饰位（同族 family flag）；组合键类型为 nil
    var modifierFlag: NSEvent.ModifierFlags? {
        switch self {
        case .doubleCmd, .doubleLeftCmd, .doubleRightCmd: return .command
        case .doubleCtrl, .doubleLeftCtrl, .doubleRightCtrl: return .control
        case .doubleOpt, .doubleLeftOpt, .doubleRightOpt: return .option
        case .doubleShift, .doubleLeftShift, .doubleRightShift: return .shift
        case .hotKeyCmdShiftT: return nil
        }
    }

    /// 互斥判定：命中 keyCode 集合相交即冲突。
    /// 例：左⌘ + 右⌘ 可共存（集合不相交）；任意⌘ + 左⌘ 冲突（左⌘∈任意⌘）；
    /// 同类型冲突；组合键与双击类型互不冲突（组合键集合为空），仅同类型冲突。
    func conflicts(with other: TriggerType) -> Bool {
        if self == other { return true }
        return !modifierKeyCodes.isDisjoint(with: other.modifierKeyCodes)
    }
}

/// 全局快捷与双击修饰键管理器。
///
/// Phase 3 升级为双路分流：主面板热键与 AI 窗热键各自独立注册，
/// 双击回调携带实际命中的 TriggerType，由装配点按类型分流到对应动作。
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// 触发回调（携带实际命中的触发类型：主面板 vs AI 窗分流依据）
    var onTrigger: ((TriggerType) -> Void)?

    /// 主面板触发类型
    private(set) var currentType: TriggerType = .doubleCmd
    /// AI 窗触发类型（默认双击 ⌥⌥）
    private(set) var aiTriggerType: TriggerType = .doubleOpt

    /// 当前已注册 Carbon 组合键的归属类型（仅一个组合键槽位；主/AI 至多其一为组合键）
    private var carbonTriggerType: TriggerType?

    // 双击修饰键监听句柄
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// 每个双击目标独立计时状态（键 = 触发类型）。
    /// 两个目标（主/AI）各自维持 lastRelease/isDown，避免共享状态互相污染。
    private struct DoubleTapState {
        var lastReleaseTime: TimeInterval = 0
        var isDown: Bool = false
    }
    private var tapStates: [TriggerType: DoubleTapState] = [:]

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

    // MARK: - 配置

    /// 双路配置：主面板类型 + AI 窗类型。
    /// 互斥校验按「命中 keyCode 集合是否相交」判定（左⌘+右⌘ 可共存，任意⌘+左⌘ 冲突）。
    /// - Returns: true = 配置生效；false = 冲突被拒，且**保持原配置不变**。
    @discardableResult
    func configure(type: TriggerType, aiType: TriggerType) -> Bool {
        guard !type.conflicts(with: aiType) else {
            NSLog("[QuickShow] 热键互斥校验失败：主面板 \(type.displayName) 与 AI 窗 \(aiType.displayName) 命中键冲突，已保持原配置")
            return false
        }
        self.currentType = type
        self.aiTriggerType = aiType
        restartMonitoring()
        NSLog("[QuickShow] 快捷触发模式更新：主面板=\(type.displayName)，AI 窗=\(aiType.displayName)")
        return true
    }

    /// 单路便捷配置（保留 AI 现有配置），向后兼容旧调用点。
    @discardableResult
    func configure(type: TriggerType) -> Bool {
        configure(type: type, aiType: aiTriggerType)
    }

    /// 当前需要参与双击判定的目标集合（主 + AI，去重）
    private var doubleTapTargets: [TriggerType] {
        var targets: [TriggerType] = []
        if currentType.isDoubleModifier { targets.append(currentType) }
        if aiTriggerType.isDoubleModifier && aiTriggerType != currentType {
            targets.append(aiTriggerType)
        }
        return targets
    }

    /// 依据当前主/AI 配置重启监听（双击 flagsChanged + 可选 Carbon 组合键）
    private func restartMonitoring() {
        stopMonitoring()
        unregisterHotKey()
        carbonTriggerType = nil

        // Carbon 组合键仅一个槽位：优先认领主面板；主面板非组合键时再看 AI
        if currentType == .hotKeyCmdShiftT {
            carbonTriggerType = currentType
            registerHotKey()
        } else if aiTriggerType == .hotKeyCmdShiftT {
            carbonTriggerType = aiTriggerType
            registerHotKey()
        }

        // 任一目标为双击修饰键即开启 flagsChanged 监听（一个监听器同时判定两个目标）
        if !doubleTapTargets.isEmpty {
            startMonitoring()
        }
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
        tapStates.removeAll()
    }

    private func handleEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // 用户在按下修饰键的同时敲击常规字符键（如 Cmd+C），打断双击判定防误触：
            // 清空所有目标的 lastRelease 计时
            for target in doubleTapTargets {
                if var state = tapStates[target] {
                    state.lastReleaseTime = 0
                    tapStates[target] = state
                }
            }
            return
        }

        guard event.type == .flagsChanged else { return }

        let keyCode = event.keyCode
        let flags = event.modifierFlags
        let now = ProcessInfo.processInfo.systemUptime

        // 同时判定主/AI 两个目标；命中哪个回调哪个类型
        for target in doubleTapTargets {
            guard let flag = target.modifierFlag else { continue }
            var state = tapStates[target] ?? DoubleTapState()

            // 打断语义：到来的修饰键不属于该目标命中集合（不同族、或左右专属类型下左右交替）
            // → 重置该目标计时，要求同侧/同族连续两击
            if !target.modifierKeyCodes.contains(keyCode) {
                state.lastReleaseTime = 0
                state.isDown = false
                tapStates[target] = state
                continue
            }

            let isPressed = flags.contains(flag)
            if isPressed {
                if !state.isDown {
                    state.isDown = true
                    let elapsed = now - state.lastReleaseTime
                    // 380 毫秒内连续两次按下即为双击（0.04s 下限滤除同一次按下的抖动）
                    if elapsed > 0.04 && elapsed < 0.38 {
                        state.lastReleaseTime = 0
                        tapStates[target] = state
                        // NSEvent 监听回调本就在主线程，直接触发，省去一次多余的主线程跳转
                        onTrigger?(target)
                        continue
                    }
                }
            } else {
                if state.isDown {
                    state.isDown = false
                    state.lastReleaseTime = now
                }
            }
            tapStates[target] = state
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
                // 组合键归属主或 AI（仅一个槽位），按归属类型回调
                manager.onTrigger?(manager.carbonTriggerType ?? .hotKeyCmdShiftT)
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