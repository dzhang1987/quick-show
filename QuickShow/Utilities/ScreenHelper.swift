import AppKit

enum ScreenHelper {
    /// 获取当前鼠标光标所在的显示器（即用户当前视线和操作所在的屏幕）
    static var activeScreen: NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
    
    /// 计算面板在活跃屏幕正中央的起始坐标 (基于 panel 宽高)
    static func centeredFrame(for size: NSSize) -> NSRect {
        let screen = activeScreen
        let screenFrame = screen.frame
        
        let x = screenFrame.origin.x + (screenFrame.width - size.width) / 2.0
        // 稍微往上偏一点点（黄金分割位置，视线更舒服），大约偏上 5%
        let y = screenFrame.origin.y + (screenFrame.height - size.height) / 2.0 + 30.0
        
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
