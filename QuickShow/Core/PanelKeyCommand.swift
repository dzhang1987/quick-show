// PanelKeyCommand.swift
// QuickShow 键盘盲操事件策略协议与注册分发总线
// 遵循 SOLID / OCP 原则：将按键事件与具体业务解耦，消灭裸键码魔法数字与巨型 switch-case。

import AppKit
import Foundation

// MARK: - KeyEquivalentCode (macOS ANSI 虚拟键码强类型枚举)

/// macOS 语义化虚拟键码枚举 (彻底消灭裸数字魔数)
enum KeyEquivalentCode: UInt16, Sendable, CaseIterable {
    // 字母键
    case a = 0
    case s = 1
    case d = 2
    case f = 3
    case h = 4
    case g = 5
    case z = 6
    case x = 7
    case c = 8
    case v = 9
    case b = 11
    case q = 12
    case w = 13
    case e = 14
    case r = 15
    case y = 16
    case t = 17
    case o = 31
    case u = 32
    case i = 34
    case p = 35
    case l = 37
    case j = 38
    case k = 40
    case n = 45
    case m = 46

    // 数字键 (主键盘区)
    case num1 = 18
    case num2 = 19
    case num3 = 20
    case num4 = 21
    case num6 = 22
    case num5 = 23
    case equal = 24
    case num9 = 25
    case num7 = 26
    case minus = 27
    case num8 = 28
    case num0 = 29

    // 符号与标点
    case rightBracket = 30
    case leftBracket = 33
    case quote = 39
    case semicolon = 41
    case backslash = 42
    case comma = 43
    case slash = 44
    case dot = 47
    case backquote = 50

    // 功能键与控制键
    case returnKey = 36
    case tab = 48
    case space = 49
    case delete = 51
    case escape = 53
    case keypadEnter = 76

    // 小键盘数字键 (Keypad)
    case keypad0 = 82
    case keypad1 = 83
    case keypad2 = 84
    case keypad3 = 85
    case keypad4 = 86
    case keypad5 = 87
    case keypad6 = 88
    case keypad7 = 89
    case keypad8 = 91
    case keypad9 = 92

    // 方向键
    case leftArrow = 123
    case rightArrow = 124
    case downArrow = 125
    case upArrow = 126
}

// MARK: - PanelKeyCommand 策略协议

/// 键盘盲操命令策略契约 (对扩展开放，对修改关闭)
@MainActor
protocol PanelKeyCommand: Sendable {
    /// 命令唯一标识
    var id: String { get }

    /// 目标触发键码
    var key: KeyEquivalentCode { get }

    /// 修饰键要求 (默认无修饰键)
    var modifiers: NSEvent.ModifierFlags { get }

    /// 仲裁优先级 (数值越大越先判定，默认 0)
    var priority: Int { get }

    /// 判定该命令在当前面板上下文与应用状态下是否可生效
    func canHandle(in context: PanelContext, state: AppState) -> Bool

    /// 执行动作，返回 true 表示消费该事件（不向底层系统传递）
    func execute(state: AppState) -> Bool
}

extension PanelKeyCommand {
    var modifiers: NSEvent.ModifierFlags { [] }
    var priority: Int { 0 }
    func canHandle(in context: PanelContext, state: AppState) -> Bool { true }
}

// MARK: - 系统控制与工具类命令

struct MuteToggleCommand: PanelKeyCommand {
    let id = "system.mute_toggle"
    let key = KeyEquivalentCode.m

    func execute(state: AppState) -> Bool {
        state.toggleMute()
        return true
    }
}

struct VolumeUpCommand: PanelKeyCommand {
    let id = "system.volume_up"
    let key = KeyEquivalentCode.upArrow

    func execute(state: AppState) -> Bool {
        state.adjustVolume(by: 5)
        return true
    }
}

struct VolumeDownCommand: PanelKeyCommand {
    let id = "system.volume_down"
    let key = KeyEquivalentCode.downArrow

    func execute(state: AppState) -> Bool {
        state.adjustVolume(by: -5)
        return true
    }
}

struct KeepAwakeToggleCommand: PanelKeyCommand {
    let id = "system.keep_awake_toggle"
    let key = KeyEquivalentCode.a

    func execute(state: AppState) -> Bool {
        state.toggleKeepAwake()
        return true
    }
}

struct MemoryOptimizeCommand: PanelKeyCommand {
    let id = "system.memory_optimize"
    let key = KeyEquivalentCode.c

    func execute(state: AppState) -> Bool {
        state.optimizeMemory()
        return true
    }
}

struct PomodoroToggleCommand: PanelKeyCommand {
    let id = "pomodoro.toggle"
    let key = KeyEquivalentCode.p

    func execute(state: AppState) -> Bool {
        state.togglePomodoro()
        return true
    }
}

struct OpenDownloadsCommand: PanelKeyCommand {
    let id = "system.open_downloads"
    let key = KeyEquivalentCode.o

    func execute(state: AppState) -> Bool {
        state.openDownloadsFolder()
        return true
    }
}

struct CleanClipboardCommand: PanelKeyCommand {
    let id = "system.clean_clipboard"
    let key = KeyEquivalentCode.x

    func execute(state: AppState) -> Bool {
        state.cleanClipboard()
        return true
    }
}

struct LockScreenCommand: PanelKeyCommand {
    let id = "system.lock_screen"
    let key = KeyEquivalentCode.l

    func execute(state: AppState) -> Bool {
        state.lockScreen()
        return true
    }
}

struct FocusSettingsCommand: PanelKeyCommand {
    let id = "system.focus_settings"
    let key = KeyEquivalentCode.d

    func execute(state: AppState) -> Bool {
        state.openFocusSettings()
        return true
    }
}

struct OpenAIWindowCommand: PanelKeyCommand {
    let id = "ai.toggle_window"
    let key = KeyEquivalentCode.i

    func execute(state: AppState) -> Bool {
        AIWindowManager.shared.toggle()
        return true
    }
}

// MARK: - 日历模块命令 (优先处理)

struct CalendarViewModeCommand: PanelKeyCommand {
    let id: String
    let key: KeyEquivalentCode
    let mode: CalendarViewMode
    let priority: Int = 100

    func canHandle(in context: PanelContext, state: AppState) -> Bool {
        context == .calendar
    }

    func execute(state: AppState) -> Bool {
        state.setCalendarViewMode(mode)
        return true
    }
}

struct CalendarPageBackwardCommand: PanelKeyCommand {
    let id = "calendar.page_backward"
    let key = KeyEquivalentCode.leftArrow
    let priority = 100

    func canHandle(in context: PanelContext, state: AppState) -> Bool {
        context == .calendar
    }

    func execute(state: AppState) -> Bool {
        state.calendarPageBackward()
        return true
    }
}

struct CalendarPageForwardCommand: PanelKeyCommand {
    let id = "calendar.page_forward"
    let key = KeyEquivalentCode.rightArrow
    let priority = 100

    func canHandle(in context: PanelContext, state: AppState) -> Bool {
        context == .calendar
    }

    func execute(state: AppState) -> Bool {
        state.calendarPageForward()
        return true
    }
}

// MARK: - 媒体播放命令 (仅存在媒体会话时消费)

struct MediaPreviousTrackCommand: PanelKeyCommand {
    let id = "media.previous_track"
    let key = KeyEquivalentCode.leftArrow
    let priority = 50

    func execute(state: AppState) -> Bool {
        state.mediaPreviousTrack()
        return state.hasNowPlayingSession
    }
}

struct MediaNextTrackCommand: PanelKeyCommand {
    let id = "media.next_track"
    let key = KeyEquivalentCode.rightArrow
    let priority = 50

    func execute(state: AppState) -> Bool {
        state.mediaNextTrack()
        return state.hasNowPlayingSession
    }
}

struct MediaPlayPauseCommand: PanelKeyCommand {
    let id = "media.play_pause"
    let key = KeyEquivalentCode.returnKey

    func execute(state: AppState) -> Bool {
        state.mediaTogglePlayPause()
        return state.hasNowPlayingSession
    }
}

struct MediaSkipBackwardCommand: PanelKeyCommand {
    let id = "media.skip_backward"
    let key = KeyEquivalentCode.comma

    func execute(state: AppState) -> Bool {
        state.mediaSkipBackward()
        return state.hasNowPlayingSession
    }
}

struct MediaSkipForwardCommand: PanelKeyCommand {
    let id = "media.skip_forward"
    let key = KeyEquivalentCode.dot

    func execute(state: AppState) -> Bool {
        state.mediaSkipForward()
        return state.hasNowPlayingSession
    }
}

// MARK: - 上下文直达命令 (如 G 键直达日历)

struct ContextHotkeyCommand: PanelKeyCommand {
    let id: String
    let key: KeyEquivalentCode
    let targetContext: PanelContext
    let priority: Int = 200

    func execute(state: AppState) -> Bool {
        state.toggleContext(targetContext)
        return true
    }
}

// MARK: - PanelKeyCommandRegistry 集中注册与分发总线

@MainActor
final class PanelKeyCommandRegistry {
    static let shared = PanelKeyCommandRegistry()

    private var commands: [PanelKeyCommand] = []

    private init() {
        registerDefaultCommands()
    }

    /// 动态注册单个命令 (保持按 priority 降序排列)
    func register(_ command: PanelKeyCommand) {
        commands.append(command)
        commands.sort { $0.priority > $1.priority }
    }

    /// 批量注册命令
    func register(_ newCommands: [PanelKeyCommand]) {
        commands.append(contentsOf: newCommands)
        commands.sort { $0.priority > $1.priority }
    }

    /// 分发处理键盘事件
    func handle(event: NSEvent, context: PanelContext, state: AppState) -> Bool {
        guard let key = KeyEquivalentCode(rawValue: event.keyCode) else { return false }
        let currentModifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])

        for command in commands where command.key == key && command.modifiers == currentModifiers {
            if command.canHandle(in: context, state: state) {
                return command.execute(state: state)
            }
        }
        return false
    }

    /// 注册全系统默认键盘命令
    private func registerDefaultCommands() {
        // 1. 上下文直达键 (从 AppState.contextHotkeys 动态装配，优先级 200)
        for (key, context) in AppState.contextHotkeys {
            register(ContextHotkeyCommand(id: "context.\(context)", key: key, targetContext: context))
        }

        // 2. 日历模块命令 (优先级 100)
        register([
            CalendarPageBackwardCommand(),
            CalendarPageForwardCommand(),
            CalendarViewModeCommand(id: "calendar.mode.month", key: .num1, mode: .month),
            CalendarViewModeCommand(id: "calendar.mode.week", key: .num2, mode: .week),
            CalendarViewModeCommand(id: "calendar.mode.day", key: .num3, mode: .day)
        ])

        // 3. 媒体控制命令 (优先级 50)
        register([
            MediaPreviousTrackCommand(),
            MediaNextTrackCommand(),
            MediaPlayPauseCommand(),
            MediaSkipBackwardCommand(),
            MediaSkipForwardCommand()
        ])

        // 4. 系统控制与快捷工具 (优先级 0)
        register([
            MuteToggleCommand(),
            VolumeUpCommand(),
            VolumeDownCommand(),
            KeepAwakeToggleCommand(),
            MemoryOptimizeCommand(),
            PomodoroToggleCommand(),
            OpenDownloadsCommand(),
            CleanClipboardCommand(),
            LockScreenCommand(),
            FocusSettingsCommand(),
            OpenAIWindowCommand()
        ])
    }
}
