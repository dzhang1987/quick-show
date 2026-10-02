import AppKit
import SwiftUI

// MARK: - 窗口拖动 / 吸附 / 边缘 resize
//
// 无边框 AIPanel 的自定义窗口操作三件套：
// 1. 顶部拖动条：自定义 mouseDragged 循环逐帧 setFrame（不用 performDrag，才能逐帧吸附计算）；
// 2. 拖动吸附（松手才吸附）：拖动全程窗口自由跟随鼠标（free frame + 屏内约束），
//    吸附检测（左右边缘半屏 / 顶边全高 / 中心居中，磁滞阈值防抖）只驱动窗口级 overlay 的区域预览；
//    松手时若命中则以短动画落到吸附目标，未命中则留在原地；
// 3. 边缘 resize：8 向热区（四边 5pt / 四角 12pt），对应系统光标，最小 480×560、最大屏幕可见区。
//
// 全部视觉走既有 DesignTokens 令牌，不新增令牌。

// MARK: - 吸附类型

/// 拖动吸附状态（OptionSet：顶边全高可与中心 X 磁吸叠加）。
struct WindowSnapState: OptionSet {
    let rawValue: Int
    static let centerX = WindowSnapState(rawValue: 1 << 0)
    static let centerY = WindowSnapState(rawValue: 1 << 1)
    static let leftHalf = WindowSnapState(rawValue: 1 << 2)
    static let rightHalf = WindowSnapState(rawValue: 1 << 3)
    static let topFull = WindowSnapState(rawValue: 1 << 4)

    /// 是否命中左右半屏。
    var hasEdgeHalf: Bool { contains(.leftHalf) || contains(.rightHalf) }
}

// MARK: - 吸附预览 overlay（窗口级）

/// 吸附预览窗口：无边框透明、忽略鼠标、层级高于 .statusBar 面板。
/// 拖动命中吸附区时显示目标区域预览，命中消失或拖动结束时 orderOut 移除。
final class SnapGuideOverlayWindow: NSWindow {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        // 与 AIPanel 同为 .statusBar，预览需再高一档才不被面板盖住
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = SnapGuideView(frame: .zero)
    }
}

/// 吸附区域预览：仅画一块圆角矩形 = 松手后窗口将落到的 frame（与 snappedFrame 结果一致）。
/// 柔和语言：accent 低透明度填充 + 细描边（描边略实于填充出层次），连续曲率圆角与面板一致。
final class SnapGuideView: NSView {
    /// 屏幕可见区（全局坐标，用于把全局矩形换算到本视图局部坐标）。
    var screenFrame: NSRect = .zero
    /// 吸附目标预览矩形（全局坐标；.zero 表示无预览、不绘制）。
    var previewRect: NSRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        guard previewRect != .zero else { return }
        let accent = NSColor(Theme.Colors.accent)
        let local = NSRect(
            x: previewRect.origin.x - screenFrame.origin.x,
            y: previewRect.origin.y - screenFrame.origin.y,
            width: previewRect.width,
            height: previewRect.height
        )
        let path = NSBezierPath(
            roundedRect: local,
            xRadius: Theme.Radius.panel,
            yRadius: Theme.Radius.panel
        )
        accent.withAlphaComponent(0.10).setFill()
        path.fill()
        accent.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - 顶部拖动条 NSView

/// 顶部拖动条：记录窗口偏移，拖动全程自由跟随鼠标（free frame 逐帧 setFrame），
/// 吸附检测仅驱动 overlay 区域预览；松手才应用吸附结果（短动画落位）。
/// 拖动约束：窗口至少 100pt 宽/高留在当前屏幕内。
final class WindowDragHandleNSView: NSView {
    private var dragStartMouse: NSPoint = .zero
    /// 拖动基准 frame：拖动开始时的窗口 frame（free frame 每帧由它 + 位移直接算出，无中途锚点重置）。
    private var dragBaseFrame: NSRect = .zero
    private var activeSnap: WindowSnapState = []
    private let overlay = SnapGuideOverlayWindow()

    /// 吸附获取阈值（预览出现）。
    private let acquireThreshold: CGFloat = 20
    /// 命中后的释放阈值（磁滞 30：预览显隐防抖，避免在边界处来回闪烁）。
    private let releaseThreshold: CGFloat = 30
    /// 拖出屏幕前必须保留在屏内的最小边长。
    private let minOnScreen: CGFloat = 100

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStartMouse = NSEvent.mouseLocation
        dragBaseFrame = window.frame
        activeSnap = []
        overlay.orderOut(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = screenContaining(mouse)
        let visible = screen.visibleFrame

        // 窗口始终自由跟随鼠标，绝不即时跳到吸附目标
        let free = dragBaseFrame.offsetBy(
            dx: mouse.x - dragStartMouse.x,
            dy: mouse.y - dragStartMouse.y
        )
        window.setFrame(constrain(free, to: visible), display: true)
        window.invalidateShadow()

        // 吸附检测只驱动预览：预览矩形 = 松手时 snappedFrame 将给到的目标 frame（含屏内约束，与落点严格一致）
        activeSnap = detectSnap(free: free, screenFrame: visible, currentlyActive: activeSnap)
        let preview = activeSnap.isEmpty
            ? .zero
            : constrain(snappedFrame(activeSnap, free: free, screenFrame: visible), to: visible)
        updateOverlay(for: screen, preview: preview)
    }

    override func mouseUp(with event: NSEvent) {
        // 无论命中与否，overlay 都要收掉（先收预览，再落位，避免预览框挂在动画上）
        let snap = activeSnap
        activeSnap = []
        overlay.orderOut(nil)
        guard !snap.isEmpty, let window else { return }

        let mouse = NSEvent.mouseLocation
        let visible = screenContaining(mouse).visibleFrame
        let free = dragBaseFrame.offsetBy(
            dx: mouse.x - dragStartMouse.x,
            dy: mouse.y - dragStartMouse.y
        )
        let target = constrain(snappedFrame(snap, free: free, screenFrame: visible), to: visible)
        // 短促平滑地落到吸附目标（节奏复用窗口尺寸动画令牌，与全窗口 resize 语言一致）
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.windowResize
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(target, display: true)
        }
    }

    // MARK: 吸附计算

    /// 逐帧探测吸附类型（仅供预览显隐，磁滞防抖）。
    /// 组合语义与 snappedFrame 一致：顶边全高可与中心 X 叠加；左右半屏期间不判 centerX、
    /// 全高期间不判 centerY（这些组合在 snappedFrame 中会互相覆盖，预览须与落点严格一致）。
    private func detectSnap(free: NSRect, screenFrame vf: NSRect, currentlyActive active: WindowSnapState) -> WindowSnapState {
        let threshold = active.isEmpty ? acquireThreshold : releaseThreshold
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= threshold }

        var state: WindowSnapState = []
        if near(free.minX, vf.minX) {
            state.insert(.leftHalf)
        } else if near(free.maxX, vf.maxX) {
            state.insert(.rightHalf)
        }
        if near(free.maxY, vf.maxY) {
            state.insert(.topFull)
        }
        if !state.hasEdgeHalf, near(free.midX, vf.midX) {
            state.insert(.centerX)
        }
        if !state.contains(.topFull), near(free.midY, vf.midY) {
            state.insert(.centerY)
        }
        return state
    }

    /// 吸附目标 frame（预览与松手落位的唯一来源，两者严格一致）：
    /// 左右边缘 → 半屏（全高）；顶边 → 全高（宽度位置保持）；中心 → 按当前尺寸居中（centerX/centerY 可各自独立叠加）。
    private func snappedFrame(_ state: WindowSnapState, free: NSRect, screenFrame vf: NSRect) -> NSRect {
        var frame = free
        if state.contains(.leftHalf) {
            frame.origin.x = vf.minX
            frame.size.width = vf.width / 2
            frame.origin.y = vf.minY
            frame.size.height = vf.height
        } else if state.contains(.rightHalf) {
            frame.origin.x = vf.midX
            frame.size.width = vf.width / 2
            frame.origin.y = vf.minY
            frame.size.height = vf.height
        } else if state.contains(.topFull) {
            frame.size.height = vf.height
            frame.origin.y = vf.minY
        }
        if state.contains(.centerX) { frame.origin.x = vf.midX - frame.width / 2 }
        if state.contains(.centerY) { frame.origin.y = vf.midY - frame.height / 2 }
        return frame
    }

    /// 窗口至少保留 minOnScreen 边长在可见区内。
    private func constrain(_ frame: NSRect, to vf: NSRect) -> NSRect {
        var result = frame
        let minX = vf.minX - (result.width - minOnScreen)
        let maxX = vf.maxX - minOnScreen
        result.origin.x = min(max(result.origin.x, minX), max(minX, maxX))
        let minY = vf.minY - (result.height - minOnScreen)
        let maxY = vf.maxY - minOnScreen
        result.origin.y = min(max(result.origin.y, minY), max(minY, maxY))
        return result
    }

    private func screenContaining(_ point: NSPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? window?.screen
            ?? ScreenHelper.activeScreen
    }

    /// 预览显隐：preview 为 .zero（未命中）时收起 overlay，否则贴屏显示目标区域预览。
    private func updateOverlay(for screen: NSScreen, preview: NSRect) {
        guard preview != .zero else {
            overlay.orderOut(nil)
            return
        }
        let visible = screen.visibleFrame
        overlay.setFrame(visible, display: false)
        if let guide = overlay.contentView as? SnapGuideView {
            guide.screenFrame = visible
            guide.previewRect = preview
            guide.needsDisplay = true
        }
        overlay.orderFrontRegardless()
    }
}

/// SwiftUI 包装：顶部拖动条。
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragHandleNSView {
        WindowDragHandleNSView()
    }

    func updateNSView(_ nsView: WindowDragHandleNSView, context: Context) {}
}

// MARK: - 边缘 resize 热区

/// resize 方向（8 向可组合）。
struct ResizeDirection: OptionSet {
    let rawValue: Int
    static let left = ResizeDirection(rawValue: 1 << 0)
    static let right = ResizeDirection(rawValue: 1 << 1)
    static let top = ResizeDirection(rawValue: 1 << 2)
    static let bottom = ResizeDirection(rawValue: 1 << 3)
}

/// 边缘热区：覆盖窗口整层，hitTest 仅在四边 5pt / 四角 12pt 命中，其余放行给下层 SwiftUI。
/// 由 AIWindowManager 直接挂到 contentView 最上层（真实 AppKit 命中测试，避免 SwiftUI overlay 拦截歧义）。
final class WindowResizeHotZoneView: NSView {
    private var activeDirection: ResizeDirection = []
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero

    /// 边热区宽度。
    private let edgeBand: CGFloat = 5
    /// 角热区边长。
    private let cornerBand: CGFloat = 12
    /// 最小尺寸（与 AIWindowManager 恢复校验一致）。
    private let minSize = NSSize(width: 480, height: 560)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// 仅热区命中 self，中心区域返回 nil 透传给 SwiftUI 内容。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local: NSPoint
        if let superview {
            local = convert(point, from: superview)
        } else {
            local = convert(point, from: nil)
        }
        return direction(at: local).isEmpty ? nil : self
    }

    private func direction(at point: NSPoint) -> ResizeDirection {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0, bounds.contains(point) else { return [] }

        // 角优先（12pt 方形区），再判边（5pt）
        if point.x <= cornerBand, point.y <= cornerBand { return [.left, .bottom] }
        if point.x <= cornerBand, point.y >= height - cornerBand { return [.left, .top] }
        if point.x >= width - cornerBand, point.y <= cornerBand { return [.right, .bottom] }
        if point.x >= width - cornerBand, point.y >= height - cornerBand { return [.right, .top] }
        if point.x <= edgeBand { return [.left] }
        if point.x >= width - edgeBand { return [.right] }
        if point.y <= edgeBand { return [.bottom] }
        if point.y >= height - edgeBand { return [.top] }
        return []
    }

    override func resetCursorRects() {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }
        // 角（12pt 方形区）
        addCursorRect(NSRect(x: 0, y: height - cornerBand, width: cornerBand, height: cornerBand), cursor: resizeCursor([.left, .top]))
        addCursorRect(NSRect(x: width - cornerBand, y: 0, width: cornerBand, height: cornerBand), cursor: resizeCursor([.right, .bottom]))
        addCursorRect(NSRect(x: 0, y: 0, width: cornerBand, height: cornerBand), cursor: resizeCursor([.left, .bottom]))
        addCursorRect(NSRect(x: width - cornerBand, y: height - cornerBand, width: cornerBand, height: cornerBand), cursor: resizeCursor([.right, .top]))
        // 边（5pt）
        let verticalSpan = max(0, height - 2 * cornerBand)
        let horizontalSpan = max(0, width - 2 * cornerBand)
        addCursorRect(NSRect(x: 0, y: cornerBand, width: edgeBand, height: verticalSpan), cursor: resizeCursor([.left]))
        addCursorRect(NSRect(x: width - edgeBand, y: cornerBand, width: edgeBand, height: verticalSpan), cursor: resizeCursor([.right]))
        addCursorRect(NSRect(x: cornerBand, y: 0, width: horizontalSpan, height: edgeBand), cursor: resizeCursor([.bottom]))
        addCursorRect(NSRect(x: cornerBand, y: height - edgeBand, width: horizontalSpan, height: edgeBand), cursor: resizeCursor([.top]))
    }

    /// 8 向 resize 光标：macOS 15+ 用官方 frameResize；13/14 降级为系统边光标（对角用 crosshair 中性表达）。
    private func resizeCursor(_ direction: ResizeDirection) -> NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: framePosition(direction), directions: .all)
        }
        let isCorner = direction.contains(.left) || direction.contains(.right)
            ? (direction.contains(.top) || direction.contains(.bottom))
            : false
        if isCorner { return .crosshair }
        if direction.contains(.left) || direction.contains(.right) { return .resizeLeftRight }
        if direction.contains(.top) || direction.contains(.bottom) { return .resizeUpDown }
        return .arrow
    }

    @available(macOS 15.0, *)
    private func framePosition(_ direction: ResizeDirection) -> NSCursor.FrameResizePosition {
        let left = direction.contains(.left)
        let right = direction.contains(.right)
        let top = direction.contains(.top)
        let bottom = direction.contains(.bottom)
        if left && top { return .topLeft }
        if right && top { return .topRight }
        if left && bottom { return .bottomLeft }
        if right && bottom { return .bottomRight }
        if left { return .left }
        if right { return .right }
        if top { return .top }
        if bottom { return .bottom }
        return .top
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        activeDirection = direction(at: local)
        guard !activeDirection.isEmpty, let window else { return }
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard !activeDirection.isEmpty, let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = window.screen ?? ScreenHelper.activeScreen
        let visible = screen.visibleFrame
        let frame = resizedFrame(
            direction: activeDirection,
            start: startFrame,
            dx: mouse.x - startMouse.x,
            dy: mouse.y - startMouse.y,
            limits: visible
        )
        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }

    override func mouseUp(with event: NSEvent) {
        activeDirection = []
    }

    /// 按方向调整 frame，并夹到 [最小尺寸, 屏幕可见区]。
    private func resizedFrame(
        direction: ResizeDirection,
        start: NSRect,
        dx: CGFloat,
        dy: CGFloat,
        limits visible: NSRect
    ) -> NSRect {
        var frame = start
        if direction.contains(.right) { frame.size.width = start.width + dx }
        if direction.contains(.left) {
            frame.origin.x = start.origin.x + dx
            frame.size.width = start.width - dx
        }
        if direction.contains(.top) { frame.size.height = start.height + dy }
        if direction.contains(.bottom) {
            frame.origin.y = start.origin.y + dy
            frame.size.height = start.height - dy
        }

        let maxWidth = visible.width
        let maxHeight = visible.height
        // 最小/最大宽度（保持对侧边固定）
        if frame.width < minSize.width {
            if direction.contains(.left) { frame.origin.x = start.maxX - minSize.width }
            frame.size.width = minSize.width
        }
        if frame.width > maxWidth {
            if direction.contains(.left) { frame.origin.x = start.maxX - maxWidth }
            frame.size.width = maxWidth
        }
        // 最小/最大高度
        if frame.height < minSize.height {
            if direction.contains(.bottom) { frame.origin.y = start.maxY - minSize.height }
            frame.size.height = minSize.height
        }
        if frame.height > maxHeight {
            if direction.contains(.bottom) { frame.origin.y = start.maxY - maxHeight }
            frame.size.height = maxHeight
        }

        // 夹进可见区（防止拖出屏幕）
        if direction.contains(.left), frame.minX < visible.minX {
            frame.origin.x = visible.minX
            frame.size.width = start.maxX - visible.minX
        }
        if direction.contains(.right), frame.maxX > visible.maxX {
            frame.size.width = visible.maxX - frame.origin.x
        }
        if direction.contains(.bottom), frame.minY < visible.minY {
            frame.origin.y = visible.minY
            frame.size.height = start.maxY - visible.minY
        }
        if direction.contains(.top), frame.maxY > visible.maxY {
            frame.size.height = visible.maxY - frame.origin.y
        }
        return frame
    }
}