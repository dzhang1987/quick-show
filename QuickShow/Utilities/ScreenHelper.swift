import AppKit

struct PanelLayoutMetrics: Equatable {
    let compactSize: NSSize
    let expandedSize: NSSize
    let calendarSize: NSSize          // 日历视图尺寸（按 G 任意状态直达日历档）
    let calendarCellHeight: CGFloat   // 日历格子行高（月视图，按档）
    let aiChatSize: NSSize            // AI 对话窗尺寸（独立窄长居中窗，跟随同一档位偏好）
}

enum ScreenHelper {
    /// 获取当前鼠标光标所在的显示器（即用户当前视线和操作所在的屏幕）
    static var activeScreen: NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
    
    /// 计算指定屏幕和档位下的内容自然包裹物理尺寸（精密系统性排版，彻底杜绝任何黑洞）
    /// 尺寸值统一引用 Theme.Layout 令牌（单一来源），此处仅保留档位选择逻辑
    static func metrics(for screen: NSScreen, option: PanelScaleOption) -> PanelLayoutMetrics {
        switch option {
        case .standard: // 系统聚焦大号（宽 680 / 高 340，展开 740 / 高 520，日历 740 / 高 640）
            return PanelLayoutMetrics(
                compactSize: Theme.Layout.standardCompact,
                expandedSize: Theme.Layout.standardExpanded,
                calendarSize: Theme.Layout.standardCalendar,
                calendarCellHeight: Theme.Layout.calendarCellStandard,
                aiChatSize: Theme.Layout.standardAIChat
            )
        case .compact: // 适中舒适（宽 540 / 高 280，展开 620 / 高 460，日历 620 / 高 560）
            return PanelLayoutMetrics(
                compactSize: Theme.Layout.comfortCompact,
                expandedSize: Theme.Layout.comfortExpanded,
                calendarSize: Theme.Layout.comfortCalendar,
                calendarCellHeight: Theme.Layout.calendarCellComfort,
                aiChatSize: Theme.Layout.comfortAIChat
            )
        case .legacy: // 极简小巧（宽 440 / 高 230，展开 520 / 高 400，日历 520 / 高 500）
            return PanelLayoutMetrics(
                compactSize: Theme.Layout.legacyCompact,
                expandedSize: Theme.Layout.legacyExpanded,
                calendarSize: Theme.Layout.legacyCalendar,
                calendarCellHeight: Theme.Layout.calendarCellLegacy,
                aiChatSize: Theme.Layout.legacyAIChat
            )
        case .auto:
            // 依据当前活跃屏幕有效宽高智能匹配最佳自然贴合档位
            let width = screen.frame.width
            let height = screen.frame.height
            
            // 用户当前高分屏 1800 x 1169，或外接大屏 2560 x 1440
            if width >= 1600 || height >= 1000 {
                // 14/16寸高分屏与外接大屏：680 x 340 黄金高宽比，时间绝对主角
                return PanelLayoutMetrics(
                    compactSize: Theme.Layout.standardCompact,
                    expandedSize: Theme.Layout.standardExpanded,
                    calendarSize: Theme.Layout.standardCalendar,
                    calendarCellHeight: Theme.Layout.calendarCellStandard,
                    aiChatSize: Theme.Layout.standardAIChat
                )
            } else {
                // 标准分辨率屏（<= 1512 宽且 < 1000 高）
                return PanelLayoutMetrics(
                    compactSize: Theme.Layout.comfortCompact,
                    expandedSize: Theme.Layout.comfortExpanded,
                    calendarSize: Theme.Layout.comfortCalendar,
                    calendarCellHeight: Theme.Layout.calendarCellComfort,
                    aiChatSize: Theme.Layout.comfortAIChat
                )
            }
        }
    }
    
    /// 计算面板在指定屏幕正中央的起始坐标 (基于 panel 宽高)
    static func centeredFrame(for size: NSSize, on screen: NSScreen = activeScreen) -> NSRect {
        let screenFrame = screen.frame
        let x = screenFrame.origin.x + (screenFrame.width - size.width) / 2.0
        // 稍微往上偏一点点（黄金分割位置，视线更舒适）
        let y = screenFrame.origin.y + (screenFrame.height - size.height) / 2.0 + Theme.Layout.centerLift
        
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
