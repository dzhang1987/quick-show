import AppKit
import SwiftUI

// MARK: - 窗口拖动 / 吸附 / 边缘 resize
//
// 无边框 AIPanel 的自定义窗口操作三件套：
// 1. 顶部拖动条：自定义 mouseDragged 循环逐帧 setFrame（不用 performDrag，才能逐帧吸附计算）；
// 2. 拖动吸附：中心线磁吸 + 左右边缘半屏 + 顶边全高，磁滞阈值防抖，窗口级 overlay 显示辅助线/预览；
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

// MARK: - 吸附辅助线 overlay（窗口级）

/// 吸附辅助线窗口：无边框透明、忽略鼠标、层级高于 .statusBar 面板。
/// 拖动时显示，拖动结束 orderOut 移除。
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
        // 与 AIPanel 同为 .statusBar，辅助线需再高一档才不被面板盖住
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = SnapGuideView(frame: .zero)
    }
}

/// 辅助线绘制：中心线 1pt accent 60%，半屏/全高预览 accent 10% 填充 + 1pt 描边。
final class SnapGuideView: NSView {
    /// 当前吸附状态（决定画哪条中心线）。
    var state: WindowSnapState = []
    /// 屏幕可见区（全局坐标，用于把全局矩形换算到本视图局部坐标）。
    var screenFrame: NSRect = .zero
    /// 半屏/全高预览轮廓（全局坐标）。
    var previewRect: NSRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor(Theme.Colors.accent)

        if state.contains(.centerX) {
            let x = screenFrame.midX - screenFrame.origin.x
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
            path.lineWidth = 1
            accent.withAlphaComponent(0.6).setStroke()
            path.stroke()
        }
        if state.contains(.centerY) {
            let y = screenFrame.midY - screenFrame.origin.y
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: bounds.width, y: y))
            path.lineWidth = 1
            accent.withAlphaComponent(0.6).setStroke()
            path.stroke()
        }

        guard previewRect != .zero else { return }
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
        accent.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - 顶部拖动条 NSView

/// 顶部拖动条：记录窗口偏移，逐帧 setFrame + 吸附计算 + 辅助线显示。
/// 拖动约束：窗口至少 100pt 宽/高留在当前屏幕内。
final class WindowDragHandleNSView: NSView {
    private var dragStartMouse: NSPoint = .zero
    /// 拖动基准 frame：拖动开始或吸附状态切换时的窗口 frame（避免尺寸吸附逐帧抖动）。
    private var dragBaseFrame: NSRect = .zero
    private var activeSnap: WindowSnapState = []
    private let overlay = SnapGuideOverlayWindow()

    /// 水平/垂直中心磁吸与边缘吸附的获取阈值。
    private let acquireThreshold: CGFloat = 20
    /// 已吸附后的释放阈值（磁滞，放宽到 30 避免边界抖动）。
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
        updateOverlay(for: screenContaining(dragStartMouse), state: [], preview: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = screenContaining(mouse)
        let visible = screen.visibleFrame

        var free = dragBaseFrame.offsetBy(
            dx: mouse.x - dragStartMouse.x,
            dy: mouse.y - dragStartMouse.y
        )
        let detected = detectSnap(free: free, screenFrame: visible, currentlyActive: activeSnap)

        if detected != activeSnap {
            // 状态切换（获取/释放）：以当前窗口 frame 为新锚点，防止逐帧来回跳变
            activeSnap = detected
            dragBaseFrame = window.frame
            dragStartMouse = mouse
            free = dragBaseFrame
        }

        var target: NSRect
        var preview: NSRect = .zero
        if activeSnap.isEmpty {
            target = constrain(free, to: visible)
        } else {
            target = constrain(snappedFrame(activeSnap, free: free, screenFrame: visible), to: visible)
            if activeSnap.hasEdgeHalf {
                preview = halfPreviewRect(screenFrame: visible, state: activeSnap)
            } else if activeSnap.contains(.topFull) {
                preview = NSRect(x: target.origin.x, y: visible.minY, width: target.width, height: visible.height)
            }
        }

        window.setFrame(target, display: true)
        window.invalidateShadow()
        updateOverlay(for: screen, state: activeSnap, preview: preview)
    }

    override func mouseUp(with event: NSEvent) {
        activeSnap = []
        overlay.orderOut(nil)
    }

    // MARK: 吸附计算

    /// 逐帧探测吸附类型；命中边缘半屏/顶边全高时不再判中心线，避免叠加冲突。
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

    /// 吸附目标 frame：左右边缘 → 半屏（全高）；顶边 → 全高（宽度位置保持）；中心线 → 居中。
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

    private func halfPreviewRect(screenFrame vf: NSRect, state: WindowSnapState) -> NSRect {
        if state.contains(.leftHalf) {
            return NSRect(x: vf.minX, y: vf.minY, width: vf.width / 2, height: vf.height)
        }
        if state.contains(.rightHalf) {
            return NSRect(x: vf.midX, y: vf.minY, width: vf.width / 2, height: vf.height)
        }
        return .zero
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

    private func updateOverlay(for screen: NSScreen, state: WindowSnapState, preview: NSRect) {
        guard !state.isEmpty || preview != .zero else {
            overlay.orderOut(nil)
            return
        }
        let visible = screen.visibleFrame
        overlay.setFrame(visible, display: false)
        if let guide = overlay.contentView as? SnapGuideView {
            guide.screenFrame = visible
            guide.state = state
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