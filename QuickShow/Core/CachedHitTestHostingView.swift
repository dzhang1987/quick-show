import AppKit
import QuartzCore
import os
import SwiftUI

/// F4：hitTest 慢路径观测日志（默认关闭，`QUICKSHOW_HITTEST_PROF=on` 开启）。
/// 文件级 Logger：`CachedHitTestHostingView` 是泛型类，泛型类型不支持 static stored
/// property，故日志器放在文件作用域。subsystem/category 便于 `log stream` 过滤。
private let hitTestProfLog = Logger(subsystem: "cn.chiproad.QuickShow", category: "HitTest")

/// F2：becomeKey 期抑制 hitTest 触碰 SwiftUI 视图图的共享门（主线程唯一，无锁）。
/// `CachedHitTestHostingView<Content>` 是泛型类，不支持 static stored property，故用
/// 非泛型 holder 承载。窗口 `becomeKeyWindow()` 在 `super` 前置位、返回后复位；
/// 抑制期内 hitTest 绝不触碰 responderNode/图。
enum BecomeKeyHitTestGate {
    /// 抑制中标志（becomeKeyWindow 的同步临界区，主线程）。
    static var isSuppressed = false

    /// 开关（默认开启；`QUICKSHOW_BECOMEKEY_HITTEST=off` 环境变量优先、UserDefaults 兜底，
    /// 关断则回原始行为）。与 QUICKSHOW_HITTEST_CACHE / QUICKSHOW_MOUSE_THROTTLE 同款模式。
    static var isEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["QUICKSHOW_BECOMEKEY_HITTEST"] {
            return raw.lowercased() != "off"
        }
        if let raw = UserDefaults.standard.string(forKey: "QUICKSHOW_BECOMEKEY_HITTEST") {
            return raw.lowercased() != "off"
        }
        return true
    }
}

enum QSFocusLogger {
    static let logURL = URL(fileURLWithPath: "/tmp/qs_focus_debug.log")
    
    static func log(_ message: String) {
        let ts = String(format: "%.3f", CACurrentMediaTime())
        let line = "[\(ts)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forUpdating: logURL) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

/// NSHostingView 包装：hitTest 单 runloop pass 缓存（治聚焦迟滞）。
///
/// **根因（聚焦）**：双击 ⌥ 呼出 AI Chat 窗、点击窗口恢复聚焦时，主线程热点在
/// `-[NSWindow _handleLeftMouseDownEvent:] → _NXShowKeyAndMain → -[NSWindow becomeKeyWindow]
/// → +[_NSTrackingAreaManager _setCursorForCurrentMouseLocation] → -[NSView _hitTestForContext:...]`
/// 多层递归 → `NSHostingView.hitTest` → SwiftUI `ViewResponder.hitTest` 全树递归。
/// AI 窗内容是大 SwiftUI 树（视口 ±2 屏 × 每消息上百块 × cursor/hover 注册叶子），
/// 每次聚焦都递归命中整树 → 迟滞。该 cursor 设置发生在 `becomeKeyWindow` 的 super 调用栈内部，
/// 无公开 API 可跳过。
///
/// **机制依据**：mouseDown 派发的目标 hitTest 与 `becomeKeyWindow → setCursor` 的 hitTest
/// 发生在**同一次事件派发的同一 runloop pass 内**，两点之间无任何布局/渲染 pass 介入，
/// 树必然静态；因此同一 pass 内的命中测试结果可安全复用。
///
/// **实现**：命中后写入缓存，并挂一个主队列异步块——该块在当次 runloop pass 结束后才执行，
/// 清空缓存。于是同一 pass 内的多次 hitTest（事件路由 + cursor 设置）命中缓存，
/// 下个 pass 必失效，绝不跨 pass 复用。
///
/// **缓存键**：窗口指针 + raw point（父坐标系）。NSHostingView 是 contentView 的直接子级，
/// 同一窗口内 point 一致即可；带窗口指针防跨窗口误命中。
///
/// **兜底关断**：默认开启；`QUICKSHOW_HITTEST_CACHE=off`（环境变量优先，其次 UserDefaults
/// 同名键，供 `open` 启动路径）可完全回退到原始行为。
/// **F4 观测**：`QUICKSHOW_HITTEST_PROF=on` 开启 `super.hitTest` 段 >16ms 的日志打点
/// （os.Logger，subsystem `cn.chiproad.QuickShow` / category `HitTest`）；默认关闭、只观测不改行为。
/// **F2 抑制**：`AIPanel.becomeKeyWindow()` 在 `super` 前置 `BecomeKeyHitTestGate.isSuppressed`、
/// 返回后复位；抑制期内 hitTest 不触碰 responderNode/图（回缓存或 nil）。开关
/// `QUICKSHOW_BECOMEKEY_HITTEST=off` 关断回原始行为。
/// （mouseMoved 节流合并见 AIPanel.sendEvent——`sendEvent` 是 NSWindow 方法，
///  NSHostingView/NSView 上不存在、不可 override，拦截点必须在窗口级。）
final class CachedHitTestHostingView<Content: View>: NSHostingView<Content> {

    /// 缓存键：窗口身份 + 父坐标系 point。point 用 NSEqualPoints 比较（避免 CGFloat 位相等陷阱）。
    private struct CacheKey: Equatable {
        let window: ObjectIdentifier?
        let point: NSPoint

        static func == (lhs: CacheKey, rhs: CacheKey) -> Bool {
            lhs.window == rhs.window && NSEqualPoints(lhs.point, rhs.point)
        }
    }

    private var cachedKey: CacheKey?
    /// 命中结果在 pass 内强持有：机制前提「同一 pass 树静态」下该 view 本就不会被销毁，
    /// 强持有一整个 pass 不会延长其实际生命周期；同时避免弱引用中途变 nil 导致
    /// 第二次 hitTest 误返回 nil、破坏鼠标路由。pass 结束（清缓存）即释放。
    private var cachedResult: NSView?
    private var cacheScheduled = false

    /// 关断兜底：环境变量优先，其次 UserDefaults 同名键。
    private static var isEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["QUICKSHOW_HITTEST_CACHE"] {
            return raw.lowercased() != "off"
        }
        if let raw = UserDefaults.standard.string(forKey: "QUICKSHOW_HITTEST_CACHE") {
            return raw.lowercased() != "off"
        }
        return true
    }

    // MARK: - F4：hitTest 慢路径观测（只打点，不改行为）

    /// 观测开关。默认关闭；仅显式 `=on` 开启（环境变量优先，UserDefaults 兜底，供 open 启动路径）。
    private static var isHitTestProfilingEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["QUICKSHOW_HITTEST_PROF"] {
            return raw.lowercased() == "on"
        }
        if let raw = UserDefaults.standard.string(forKey: "QUICKSHOW_HITTEST_PROF") {
            return raw.lowercased() == "on"
        }
        return false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let t0 = CACurrentMediaTime()
        // F2：becomeKey 同步栈内（becomeKeyWindow → setCursor 的光标 hit-test）绝不触碰
        // 视图图——直接回本 pass 内最近一次缓存命中视图（校验同窗口）；无缓存/窗口不匹配
        // 则返回 nil。返回 nil 仅表示光标形状本次未更新（纯装饰性偏差），不参与事件路由：
        // 事件路由 hitTest 发生在 becomeKeyWindow 返回之后，已脱离抑制窗口。
        if BecomeKeyHitTestGate.isSuppressed {
            if let cached = cachedResult, cached.window === window { return cached }
            QSFocusLogger.log("hitTest SUPPRESSED during key state change")
            return nil
        }

        // F7（快速通道 Fast Path）：在原生 AppKit 子视图树中优先进行几何命中测试。
        // 若落点命中了真实的 AppKit 交互视图（如输入框 NSTextView、窗口拖拽区、边缘缩放区、NSControl 等），
        // 直接通过 AppKit 原生几何树返回该叶子视图，彻底绕开 NSHostingView.super.hitTest
        // 对整棵庞大 SwiftUI 消息树的递归求值（耗时从 ~1.5s 直降至 ~0.005ms）。
        if let fastHit = nativeFastPathHitTest(point) {
            let t1 = CACurrentMediaTime()
            QSFocusLogger.log(String(format: "hitTest FAST-PATH HIT: %@ (耗时: %.3fms)", String(describing: type(of: fastHit)), (t1 - t0) * 1000))
            return fastHit
        }

        let key = CacheKey(window: window.map(ObjectIdentifier.init), point: point)
        if cachedKey == key {
            return cachedResult
        }

        let result = super.hitTest(point)
        let t1 = CACurrentMediaTime()
        let elapsed = (t1 - t0) * 1000
        if elapsed > 2.0 {
            QSFocusLogger.log(String(format: "hitTest SLOW super.hitTest: %@ (耗时: %.2fms, pt: %@)", String(describing: result.map { type(of: $0) }), elapsed, NSStringFromPoint(point)))
        }
        cachedKey = key
        cachedResult = result
        scheduleInvalidation()
        return result
    }

    /// Fast Path：在原生 AppKit 子视图树中优先测试是否命中了真实的可交互 NSView。
    /// point 入参为 superview 坐标系（AppKit hitTest 规范）。
    private func nativeFastPathHitTest(_ point: NSPoint) -> NSView? {
        let pointInSelf = superview != nil ? convert(point, from: superview) : point
        guard bounds.contains(pointInSelf) else { return nil }
        for subview in subviews.reversed() {
            guard !subview.isHidden, subview.alphaValue > 0.001 else { continue }
            let pointInSub = convert(pointInSelf, to: subview)
            guard subview.bounds.contains(pointInSub) else { continue }
            // AppKit 契约：subview.hitTest 接收其父视图（即 self）坐标系下的坐标
            if let hit = subview.hitTest(pointInSelf), isInteractiveNativeView(hit) {
                return hit
            }
        }
        return nil
    }

    /// 判定一个 NSView 是否是明确的原生交互组件。
    private func isInteractiveNativeView(_ view: NSView) -> Bool {
        if view is NSTextView { return true }
        if view is NSControl { return true }
        if view is NSScroller { return true }
        let className = NSStringFromClass(type(of: view))
        if className.contains("WindowDragHandle") || className.contains("WindowResizeHotZone") {
            return true
        }
        return false
    }

    /// `super.hitTest` 段耗时超过 1 帧预算（16ms）时打日志，附窗口上下文。
    /// 「重聚焦期」近似判据：`isKeyWindow == false`（becomeKeyWindow 调用栈内 key 态尚未
    /// 提交）且窗口可见/未遮挡。仅观测，绝不改变返回结果或缓存路径。
    private func logHitTestSlow(start: TimeInterval, point: NSPoint) {
        let elapsed = CACurrentMediaTime() - start
        guard elapsed > 0.016 else { return }
        let win = window
        let isKey = win?.isKeyWindow ?? false
        let isVisible = win?.isVisible ?? false
        let isOccluded = win.map { !$0.occlusionState.contains(.visible) } ?? false
        hitTestProfLog.log(
            "hitTest slow \(elapsed * 1000, format: .fixed(precision: 1))ms key=\(isKey) visible=\(isVisible) occluded=\(isOccluded) becomingKey=\(!isKey && isVisible && !isOccluded) pt=(\(point.x, format: .fixed(precision: 1)),\(point.y, format: .fixed(precision: 1)))"
        )
    }

    /// 主队列异步块在当次 runloop pass 结束后执行 → 清空缓存，保证下个 pass 重新计算。
    private func scheduleInvalidation() {
        guard !cacheScheduled else { return }
        cacheScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cachedKey = nil
            self.cachedResult = nil
            self.cacheScheduled = false
        }
    }
}