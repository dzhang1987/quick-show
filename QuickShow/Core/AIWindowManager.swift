import AppKit
import SwiftUI

// MARK: - AI 对话窗专用 NSPanel 子类
/// 与主面板 FloatingPanel 语义不同（无速查表 / Space Pin / Tab 等全局键），故独立子类。
/// 仅保留 AI 窗专属拦截：
/// 1. 文本编辑聚焦时其余按键全部放行（1.3.0 高危修复：窗口级拦截吞掉输入导致丢草稿）；
/// 2. ESC 三阶段语义（⓪ 抽屉在场先取消抽屉；① 流式生成中先中止；② 否则关窗还焦点）；
/// 3. ⌘K 清空会话。
///
/// 注意：ESC/⌘K 作为「AI 窗级命令」在文本聚焦时同样优先处理（PHASE3_PLAN §2 硬性要求），
/// 其余按键（含 ⏎/⇧⏎/⌘V/输入法组字）一律放行给第一响应者，绝不劫持文本输入。
final class AIPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// F2：becomeKeyWindow（Swift 名 `becomeKey()`）→ `_setCursorForCurrentMouseLocation` →
    /// 光标 hit-test 在**同一次同步调用栈内**直接命中大 SwiftUI 树；若此刻视图图脏/未温，
    /// responderNode 懒获取会原地强制全图重建（~1.5s）+ display cycle 布局刷新（~1.9s）。
    /// 这里用一个极短的同步抑制窗口包住 `super.becomeKey()`：期内
    /// `CachedHitTestHostingView.hitTest` 不触碰视图图（只回本 pass 缓存或 nil），
    /// 把可能的强制重建挪到其后的 display cycle。覆盖 makeKey / makeKeyAndOrderFront
    /// 触发的 becomeKey（统一走本覆写）。
    /// 风险：光标可能短暂显示旧形状，下一次 mouseMoved（8ms 节流内）即纠正——纯装饰性偏差。
    override func becomeKey() {
        let t0 = CACurrentMediaTime()
        QSFocusLogger.log("AIPanel.becomeKey START")
        if BecomeKeyHitTestGate.isEnabled {
            BecomeKeyHitTestGate.isSuppressed = true
            defer { BecomeKeyHitTestGate.isSuppressed = false }
            super.becomeKey()
        } else {
            super.becomeKey()
        }
        let t1 = CACurrentMediaTime()
        QSFocusLogger.log(String(format: "AIPanel.becomeKey END (耗时: %.2fms)", (t1 - t0) * 1000))
    }

    /// ESC 阶段 ⓪：输入坞抽屉在场时优先取消抽屉（权限 = 拒绝 / 提问 = 取消；
    /// 返回 true = 已消费本次 ESC，保持窗口打开）
    var onCancelDrawer: (() -> Bool)?
    /// ESC 第一阶段：流式生成中中止（返回 true = 已消费本次 ESC，保持窗口打开）
    var onAbortStreaming: (() -> Bool)?
    /// ESC 第二阶段：非流式时关窗还焦点
    var onEscapeClose: (() -> Void)?
    /// ⌘K 清空会话
    var onClearSession: (() -> Void)?
    /// 其余按键（Lane C 接非文本聚焦下的输入框语义等）
    var onAIKeyDown: ((NSEvent) -> Bool)?
    /// 失去 key 状态（切走 / 被本 App 其他窗口抢焦点）
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
        // NSPanel 默认 hidesOnDeactivate=true：应用失活时 AppKit 会直接 orderOut，
        // 绕过 onResignKey 的钉住门控，导致「钉住常驻」失效。置 false 后失焦只走 resignKey，
        // 由 onResignKey 依据 isPinned 决定隐藏或常驻。
        hidesOnDeactivate = false
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
        if event.type == .leftMouseDown {
            let t0 = CACurrentMediaTime()
            QSFocusLogger.log(String(format: "AIPanel.sendEvent leftMouseDown START at (%.1f, %.1f)", event.locationInWindow.x, event.locationInWindow.y))
            super.sendEvent(event)
            let t1 = CACurrentMediaTime()
            QSFocusLogger.log(String(format: "AIPanel.sendEvent leftMouseDown END (耗时: %.2fms)", (t1 - t0) * 1000))
            return
        }
        // mouseMoved 节流合并：SwiftUI 对每个 mouseMoved 都做全树 hitTest（HoverEvent →
        // HitTestBindingResponder 从根全树递归，调研已源码级确证）。窗口级丢弃中间帧、
        // 仅转发每 8ms 最新一帧 + 尾帧补发，把全树递归频率压到 ~120Hz。
        // 其余事件类型一律直通（时序敏感，零节流）。
        if event.type == .mouseMoved, Self.isMouseThrottleEnabled {
            throttleMouseMoved(event)
            return
        }
        if event.type == .keyDown {
            // ESC 优先：输入框聚焦时仍走 AI 窗两阶段语义，不落入 field editor 的 cancelOperation
            if event.keyCode == 53 {
                handleEscape()
                return
            }
            // ⌘K 是 AI 窗命令而非文本编辑操作，聚焦时同样拦截
            if event.modifierFlags.contains(.command) && event.keyCode == 40 {
                onClearSession?()
                return
            }
            // 文本编辑聚焦时其余按键全部放行给第一响应者
            // （编辑表单 field editor 即 NSTextView；窗口级拦截先于第一响应者，
            //  会吞掉 ⏎/⇧⏎/←→/输入法组字，导致无法输入并误触全局动作）
            if firstResponder is NSTextView {
                super.sendEvent(event)
                return
            }
            if let handled = onAIKeyDown?(event), handled {
                return
            }
        }
        super.sendEvent(event)
    }

    // MARK: - mouseMoved 节流合并状态

    /// 8ms ≈ 120Hz，高于 60Hz 显示刷新，hover 观感无差；右缘刻度轨 onContinuousHover
    /// 依赖 mouseMoved，120Hz 输入足够流畅。若实测刻度轨 hover 有滞感，可下调至 0.006。
    private static var mouseThrottleInterval: TimeInterval { 0.008 }
    /// 上次真正转发给 super 的单调时间（CACurrentMediaTime，单调递增，不受挂钟调整影响）。
    private var lastMouseForwardTime: TimeInterval = 0
    /// 窗口内被丢弃、仅保留的「最后一帧」鼠标事件（尾帧补发，保证 hover 终态不错位）。
    private var pendingMouseEvent: NSEvent?
    /// 尾帧补发任务；新事件到达时先取消再重挂，防补发堆积。
    private var pendingMouseWorkItem: DispatchWorkItem?

    private func throttleMouseMoved(_ event: NSEvent) {
        let now = CACurrentMediaTime()
        if now - lastMouseForwardTime >= Self.mouseThrottleInterval {
            // 节流窗口已过：取消可能残留的尾帧补发，立即转发本次事件（首帧零延迟）。
            cancelPendingMouseForward()
            lastMouseForwardTime = now
            super.sendEvent(event)
        } else {
            // 窗口内：丢弃本帧，仅保留最后一帧，并挂 8ms 后的尾帧补发（旧任务先取消）。
            pendingMouseEvent = event
            cancelPendingMouseForward()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let pending = self.pendingMouseEvent
                self.pendingMouseEvent = nil
                self.pendingMouseWorkItem = nil
                guard let pending else { return }
                self.lastMouseForwardTime = CACurrentMediaTime()
                self.forwardDirectly(pending)
            }
            pendingMouseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.mouseThrottleInterval, execute: work)
        }
    }

    /// 转发给 NSWindow 原始实现（`super.sendEvent` 不能在逃逸闭包内直接调用，包一层）。
    private func forwardDirectly(_ event: NSEvent) {
        super.sendEvent(event)
    }

    /// 取消并清空尾帧补发任务 + 待发事件（新事件到达时调用，防补发堆积）。
    private func cancelPendingMouseForward() {
        pendingMouseWorkItem?.cancel()
        pendingMouseWorkItem = nil
        pendingMouseEvent = nil
    }

    /// 节流关断兜底：环境变量优先，其次 UserDefaults 同名键（`open` 启动路径用）。
    private static var isMouseThrottleEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["QUICKSHOW_MOUSE_THROTTLE"] {
            return raw.lowercased() != "off"
        }
        if let raw = UserDefaults.standard.string(forKey: "QUICKSHOW_MOUSE_THROTTLE") {
            return raw.lowercased() != "off"
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        // 兜住 keyDown 直投路径（与 sendEvent 分支同理）
        if event.keyCode == 53 {
            handleEscape()
            return
        }
        if event.modifierFlags.contains(.command) && event.keyCode == 40 {
            onClearSession?()
            return
        }
        if firstResponder is NSTextView {
            super.keyDown(with: event)
            return
        }
        if let handled = onAIKeyDown?(event), handled {
            return
        }
        super.keyDown(with: event)
    }

    /// ESC 三阶段：⓪ 抽屉在场先取消抽屉（权限 = 拒绝 / 提问 = 取消）；
    /// ① 流式生成中先中止（消费 ESC）；② 否则关窗还焦点
    private func handleEscape() {
        if let cancelDrawer = onCancelDrawer, cancelDrawer() {
            return
        }
        if let abort = onAbortStreaming, abort() {
            return
        }
        onEscapeClose?()
    }

    /// F5：resignKey 与 becomeKey 对称抑制——`super.resignKey()` 内部同样触发
    /// `_setCursorForCurrentMouseLocation` → hitTest 全树递归；抑制期内
    /// CachedHitTestHostingView.hitTest 不触碰视图图（回缓存或 nil）。
    override func resignKey() {
        let t0 = CACurrentMediaTime()
        QSFocusLogger.log("AIPanel.resignKey START")
        if BecomeKeyHitTestGate.isEnabled {
            BecomeKeyHitTestGate.isSuppressed = true
            defer { BecomeKeyHitTestGate.isSuppressed = false }
            super.resignKey()
        } else {
            super.resignKey()
        }
        let t1 = CACurrentMediaTime()
        onResignKey?()
        let t2 = CACurrentMediaTime()
        QSFocusLogger.log(String(format: "AIPanel.resignKey END (super耗时: %.2fms, onResignKey耗时: %.2fms, 总耗时: %.2fms)", (t1 - t0) * 1000, (t2 - t1) * 1000, (t2 - t0) * 1000))
    }
}

// MARK: - AI 窗口管理器
/// AI 对话窗生命周期：独立窄长居中 NSPanel、显隐、焦点纪律。
/// 与主面板 PanelManager 同款焦点纪律（记录 previousApp → 关窗毫秒级归还），
/// 但窗口语义独立（无 PanelContext 路由）。
final class AIWindowManager {
    static let shared = AIWindowManager()

    /// macOS 26+ 整窗玻璃材质选择：
    /// - 默认 false：走传统 NSVisualEffectView vibrancy 路径（PanelHostingConfigurator
    ///   + SwiftUI liquidPanelBackground——Apple 长期优化的合成路径，性能可靠）。
    /// - 手动开（QUICKSHOW_GLASS=on）：走 NSGlassEffectView Liquid Glass 整窗"看穿"特效
    ///   （26 beta 早期 WindowServer 合成成本高，性能待 Apple 后续版本优化）。
    private static var isGlassEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["QUICKSHOW_GLASS"] {
            return raw.lowercased() == "on"
        }
        if let raw = UserDefaults.standard.string(forKey: "QUICKSHOW_GLASS") {
            return raw.lowercased() == "on"
        }
        return false
    }

    /// 隐藏模式开关（性能诊断 A/B）：`QUICKSHOW_HIDE_MODE=orderout`（环境变量优先，
    /// UserDefaults 兜底）走传统 orderOut 脱窗隐藏；默认 alpha 视觉隐藏（F1）。
    private static var useOrderOutHide: Bool {
        if let raw = ProcessInfo.processInfo.environment["QUICKSHOW_HIDE_MODE"] {
            return raw.lowercased() == "orderout"
        }
        if let raw = UserDefaults.standard.string(forKey: "QUICKSHOW_HIDE_MODE") {
            return raw.lowercased() == "orderout"
        }
        return false
    }

    private var panel: AIPanel?
    private var previousApp: NSRunningApplication?
    private var isDismissing: Bool = false
    // 隐藏代次令牌：作废迟到的旧淡出 completion（与 PanelManager 同款防抖）
    private var hideGeneration = 0
    // 延迟变 key 代次令牌：防止过期的延迟 makeKey 在隐藏后触发（与 hideGeneration 同款）
    private var keyGeneration: UInt = 0
    // 窗口位置/大小存档通知观察者令牌（singleton 常驻，无需移除）
    private var frameObservers: [NSObjectProtocol] = []
    // frame 落盘防抖（拖动/缩放每帧都触发 didMove/didResize，合并写盘）
    private var frameSaveWorkItem: DispatchWorkItem?

    // A1：数据未加载完时的挂起显示请求（后台加载完成后回主线程补显示）。
    private var pendingShow = false
    // A2：面板是否已「首次上屏」。与 panel==nil 解耦——预热会让 panel 提前存在，
    // 但首显仍按原语义满 alpha 直接上屏（不播窗口级淡入，规避历史冷启动白屏竞态）。
    private var hasPresented = false

    // F1：逻辑可见真源。orderOut/orderFront 脱窗-再上屏会制造「失活环境翻转 + 脱窗」
    // 两个脏化源（重聚焦的 becomeKeyWindow→setCursor 光标 hit-test 撞上脏视图图 →
    // responderNode 懒获取原地强制全图重建 ~1.5s）。改为失焦只做视觉隐藏（alpha 0 +
    // 不接收鼠标），窗口此后恒 `isVisible == true`，显隐判定一律读本标志。
    // 读写点：isPanelVisible / toggle() / performHide(guard) / setSidebarVisible(guard) /
    // presentPanel(置 true) / performHide completion(置 false)。
    private var isLogicallyVisible = false

    // MARK: - 钉住 / 位置持久化

    /// 钉住键（常驻置顶：失焦不自动隐藏）。
    static let pinnedKey = "ai.pinned"
    /// 窗口 frame 存档键（NSStringFromRect 落盘）。
    static let windowFrameKey = "ai.windowFrame"
    /// 最小尺寸（与边缘 resize 热区一致）。
    private let minWindowSize = NSSize(width: 480, height: 560)

    /// 是否已钉住常驻（show() 时从 UserDefaults 恢复）。
    private(set) var isPinned: Bool = UserDefaults.standard.bool(forKey: AIWindowManager.pinnedKey)

    /// 面板当前是否可见（供流式完成通知判断）。F1：读逻辑标志而非 `panel.isVisible`
    /// （orderOut 退役后窗口恒 isVisible，物理可见性不再反映用户可见语义）。
    var isPanelVisible: Bool { isLogicallyVisible }
    /// 面板当前是否为 key 窗口（供流式完成通知判断）。
    var isPanelKey: Bool { panel?.isKeyWindow ?? false }

    private init() {}

    // MARK: - 显隐

    /// 全局热键 / I 键统一切换：可见则关，不可见则显示居中
    func toggle() {
        if isLogicallyVisible {
            hide()
        } else {
            show()
        }
    }

    /// 全局热键 / I 键统一显隐入口。
    func show() {
        // A1：会话数据未后台加载完时挂起本次显示——绝不退回主线程同步全量解码。
        // 启动即后台预加载，正常热路径 isLoaded 已为真，走同步快路径零额外延迟；
        // 冷启动抢跑场景挂到加载完成回调（主线程），加载完补显示。
        MainActor.assumeIsolated {
            if ChatSessionStore.shared.isLoaded {
                presentPanel()
            } else {
                pendingShow = true
                ChatSessionStore.shared.whenLoaded { [weak self] in
                    guard let self, self.pendingShow else { return }
                    self.pendingShow = false
                    self.presentPanel()
                }
            }
        }
    }

    /// A2 预热：App 启动后主队列 idle 时调用。等后台数据就绪后预构建 AI 面板
    /// （不显示、不激活），并强制一次整树布局——把首显的建树/布局成本移出 show() 路径，
    /// 使首次 show() 只剩 setFrame + orderFront。幂等：已构建则跳过。
    func prewarm() {
        MainActor.assumeIsolated {
            ChatSessionStore.shared.startBackgroundLoad()
            ChatSessionStore.shared.whenLoaded { [weak self] in
                guard let self, self.panel == nil else { return }
                let panel = self.ensurePanel()
                panel.contentView?.layoutSubtreeIfNeeded()
                // 建树+布局在预热期完成；无需 CA flush——面板不抢 key 焦点，
                // controlActiveState 不翻转，树不脏化，首帧 orderFront 即热路径。
            }
        }
    }

    /// 实际呈现面板（原 show() 主体）。仅在会话数据已加载完成时调用。
    private func presentPanel() {
        // 主面板可见则先淡出（两者互斥可见性，焦点最终交给 AI 窗，不自动回主面板）。
        // 先读取主面板记录的「原应用」，切窗后 AI 窗继承同一焦点归还目标。
        let handoffApp = PanelManager.shared.focusReturnApp
        // 切换时不归还焦点（restoreFocus: false），焦点由本管理器接管并在关窗时归还，
        // 避免主面板归还焦点与紧随其后的 AI 窗抢 active 状态
        PanelManager.shared.hidePanel(restoreFocus: false)

        // 恢复持久化的钉住态（用户可能在其他入口改过）。
        isPinned = UserDefaults.standard.bool(forKey: Self.pinnedKey)

        // A（冷启动白屏修复）：区分首显与复用。首显面板满 alpha 直接上屏、
        // 不播窗口级淡入——0.08s 的 animator alpha 动画与 SwiftUI 首帧建树的
        // CA 事务提交在同一时间窗竞态，冷启动必现主内容区消息行卡在近零透明度
        // （白屏 + 幽灵残影，切会话重渲染才恢复）；复用热路径内容已就绪，保留淡入。
        // A2 预热后 panel 可能已存在，故用 hasPresented 而非 panel==nil 判定首显。
        let isFirstPresentation = !hasPresented
        let panel = ensurePanel()
        let screen = ScreenHelper.activeScreen
        // 有有效存档则恢复记忆的位置/大小；否则走居中默认尺寸（首启）。
        if let restored = restoredFrame() {
            panel.setFrame(restored, display: true)
        } else {
            let size = targetAIChatSize(on: screen)
            panel.setFrame(ScreenHelper.centeredFrame(for: size, on: screen), display: true)
        }
        panel.invalidateShadow()

        // 焦点纪律：优先继承主面板的「呼出前应用」，否则取当前最前台（排除自身）
        if let handoff = handoffApp, handoff.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = handoff
        } else if let front = NSWorkspace.shared.frontmostApplication,
                  front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        } else {
            previousApp = nil
        }

        isDismissing = false
        hideGeneration += 1
        // F1：进入逻辑可见态（窗口恒在屏，显隐由 alpha/鼠标接收表达）。
        isLogicallyVisible = true
        panel.ignoresMouseEvents = false

        // ▶ 聚焦性能打点 0：入口
        let t0 = CFAbsoluteTimeGetCurrent()

        // B（冷启动白屏修复）：上屏前强制完成 SwiftUI 建树与布局，
        // 不让离屏半建状态随 orderFront 上屏后与渲染事务竞态
        panel.contentView?.layoutSubtreeIfNeeded()
        let t1 = CFAbsoluteTimeGetCurrent()

        // A：alpha 必须先于 orderFront 设置（复用路径 0→1 淡入；首次上屏满 alpha）
        panel.alphaValue = isFirstPresentation ? 1.0 : 0.0

        // ▶ 不强 key 焦点：仅 orderFront 浮到顶层，不触发 makeKey → 不翻转
        // controlActiveState → SwiftUI 树不脏化 → CA 零成本。用户点输入框时窗口
        // 自然变 key（NSPanel 默认点击即变 key），此时 controlActiveState 翻转的
        // 300ms CA 成本被用户"点击→打字"的天然延时容忍吸收。
        panel.orderFront(nil)
        let t2 = CFAbsoluteTimeGetCurrent()
        let t3 = t2  // makeKey/activate 已移除，保持计时字段对齐
        hasPresented = true

        // ▶ 延迟变 key：200ms 后在后台静默 makeKey。窗口先闪现（瞬时），
        // 用户观察内容 + 移动鼠标时 300ms CA 提交悄然完成。点击输入框时
        // 窗口已是 key 态 → 打字也瞬时。若用户提前点击则走自然变 key 路径。
        keyGeneration &+= 1
        let expectedGen = keyGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak panel] in
            guard let self = self, let panel = panel,
                  self.keyGeneration == expectedGen,
                  self.isLogicallyVisible,
                  !self.isDismissing,
                  !panel.isKeyWindow else { return }
            panel.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }

        if !isFirstPresentation {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.Motion.panelFadeIn
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        }
        let t4 = CFAbsoluteTimeGetCurrent()
        // ▶ 聚焦性能打点（无 makeKey 路径：controlActiveState 不变，CA 无脏树提交）
        writeFocusTiming(t0, t1, t2, t3, t4, tag: "CODE")
    }

    /// 聚焦性能打点辅助：写入 /tmp/qs_focus_timing.log
    private func writeFocusTiming(_ t0: CFAbsoluteTime, _ t1: CFAbsoluteTime, _ t2: CFAbsoluteTime,
                                  _ t3: CFAbsoluteTime, _ t4: CFAbsoluteTime, tag: String, t5: CFAbsoluteTime? = nil) {
        let total = (t5 ?? t4) - t0
        let msg: String
        if let t5 = t5 {
            msg = String(format: "[QS-FOCUS %@] code=%.1fms caCommit=%.1fms e2e=%.1fms\n",
                         tag, (t4-t0)*1000, (t5-t4)*1000, total*1000)
        } else {
            msg = String(format: "[QS-FOCUS %@] layout=%.1fms orderFront=%.1fms makeKey=%.1fms rest=%.1fms total=%.1fms\n",
                         tag, (t1-t0)*1000, (t2-t1)*1000, (t3-t2)*1000, (t4-t3)*1000, total*1000)
        }
        if let data = msg.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/qs_focus_timing.log")
            if let fh = try? FileHandle(forUpdating: url) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// ESC / 热键关窗：毫秒级归还焦点给呼出前应用
    func hide() {
        performHide(restoreFocus: true)
    }

    /// - Parameter restoreFocus: true = 主动关窗（ESC/热键），归还焦点；
    ///   false = 被动失焦（切走 / 被本 App 其他窗口抢 key），焦点已自然转移，不夺回。
    private func performHide(restoreFocus: Bool) {
        guard let panel = panel, isLogicallyVisible, !isDismissing else { return }
        // 危险工具确认 sheet 抢占 key 状态时父窗会 resignKey，属本窗内交互，
        // 不视为被动切走（sheet 关闭后焦点自然回归父窗）
        if panel.attachedSheet != nil { return }
        // 隐藏前落盘当前位置/大小，确保本次移动被记住。
        saveFrame()
        isDismissing = true
        hideGeneration += 1
        let token = hideGeneration

        // 1. 立即停止捕获鼠标事件
        panel.ignoresMouseEvents = true

        // 2. 瞬间将焦点归还给呼出前的应用（仅主动关窗时）
        if restoreFocus, let prev = previousApp, prev.bundleIdentifier != Bundle.main.bundleIdentifier {
            prev.activate(options: [.activateIgnoringOtherApps])
        }
        previousApp = nil

        // 3. 极速灵动淡出
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.panelFadeOut
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            guard let self = self, self.isDismissing, self.hideGeneration == token else { return }
            // 隐藏模式开关（性能诊断 A/B）：
            // - alpha（默认，F1）：不 orderOut，终态 alpha 0 + ignoresMouseEvents 保持 true，
            //   窗口恒在屏——保 SwiftUI 树温热；代价：玻璃窗恒在屏使 WindowServer 保留
            //   整窗 blur 合成链（玻璃模式下可能反向加重聚焦合成成本，实验对比用）。
            // - orderout（QUICKSHOW_HIDE_MODE=orderout）：传统脱窗——窗口完全退出合成，
            //   WindowServer 零占用；代价：重新上屏触发脱窗-再上屏环境翻转（树脏化源）。
            if Self.useOrderOutHide {
                panel.orderOut(nil)
                panel.alphaValue = 1.0
                panel.ignoresMouseEvents = false
            }
            self.isLogicallyVisible = false
            self.isDismissing = false
        }
    }

    // MARK: - 尺寸

    /// 侧栏显隐偏好键（AIChatView 与窗口尺寸共用单一来源；默认收起）。
    static let sidebarVisibleKey = "ai.sidebarVisible"

    /// 读取用户尺寸档位偏好（与主面板共用 panelScaleOption），返回 AI 窗基础尺寸
    private func aiChatSize(on screen: NSScreen) -> NSSize {
        let raw = UserDefaults.standard.string(forKey: "panelScaleOption") ?? PanelScaleOption.auto.rawValue
        let option = PanelScaleOption(rawValue: raw) ?? .auto
        return ScreenHelper.metrics(for: screen, option: option).aiChatSize
    }

    /// 目标尺寸：基础尺寸 + 侧栏附加宽度（侧栏展开时整体加宽，高度不变）。
    private func targetAIChatSize(on screen: NSScreen) -> NSSize {
        var size = aiChatSize(on: screen)
        if UserDefaults.standard.bool(forKey: Self.sidebarVisibleKey) {
            size.width += AIChatLayout.sidebarWidth
        }
        return size
    }

    /// 侧栏显隐联动（由 AIChatView ⌘B / 折叠按钮调用）：
    /// 写偏好持久化；窗口可见时**保锚点缩放**——不再居中重排，
    /// 保持当前左上角（若贴右缘则保右缘），宽度 ±sidebarWidth，clamp 到屏幕内。
    func setSidebarVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: Self.sidebarVisibleKey)
        guard let panel, isLogicallyVisible else { return }
        let screen = panel.screen ?? ScreenHelper.activeScreen
        let visibleFrame = screen.visibleFrame
        let delta = AIChatLayout.sidebarWidth * (visible ? 1 : -1)

        var frame = panel.frame
        let wasRightAnchored = abs(frame.maxX - visibleFrame.maxX) <= 20
        let oldMaxX = frame.maxX
        frame.size.width += delta
        if wasRightAnchored {
            // 贴右缘：保持右缘不动，向左扩展/收缩
            frame.origin.x = oldMaxX - frame.size.width
        }
        frame = clampedFrame(frame, on: screen)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.windowResize
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: - 钉住

    /// 切换钉住常驻：立即落盘。钉住时失焦不自动隐藏；解钉后恢复失焦隐藏（当次不立即隐藏）。
    func togglePin() {
        isPinned.toggle()
        UserDefaults.standard.set(isPinned, forKey: Self.pinnedKey)
    }

    // MARK: - 位置/大小持久化

    /// 落盘当前窗口 frame（同步，用于隐藏前兜底）。
    private func saveFrame() {
        frameSaveWorkItem?.cancel()
        frameSaveWorkItem = nil
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.windowFrameKey)
    }

    /// 防抖落盘：拖动/缩放期间 didMove/didResize 高频触发，合并为一次写盘。
    private func scheduleFrameSave() {
        frameSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.frameSaveWorkItem = nil
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.windowFrameKey)
        }
        frameSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// 读取并校验存档 frame：需与任一屏幕可见区有 ≥100×100 实质交集，随后 clamp 到 [min, 屏幕可见区] 且完整可见。
    private func restoredFrame() -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: Self.windowFrameKey), !raw.isEmpty else { return nil }
        let rect = NSRectFromString(raw)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        guard let screen = NSScreen.screens.first(where: { screen in
            let intersection = screen.visibleFrame.intersection(rect)
            return intersection.width >= 100 && intersection.height >= 100
        }) else { return nil }
        return clampedFrame(rect, on: screen)
    }

    /// 把 frame 夹到最小尺寸与指定屏幕可见区内（宽高 clamp + 完整可见）。
    private func clampedFrame(_ frame: NSRect, on screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        var size = frame.size
        size.width = min(max(size.width, minWindowSize.width), visibleFrame.width)
        size.height = min(max(size.height, minWindowSize.height), visibleFrame.height)
        var origin = frame.origin
        origin.x = min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width))
        origin.y = min(max(origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
        return NSRect(origin: origin, size: size)
    }

    // MARK: - 窗口构建

    private func ensurePanel() -> AIPanel {
        if let panel = panel { return panel }
        let created = makePanel()
        panel = created
        return created
    }

    private func makePanel() -> AIPanel {
        let screen = ScreenHelper.activeScreen
        let frame = ScreenHelper.centeredFrame(for: targetAIChatSize(on: screen), on: screen)
        let panel = AIPanel(contentRect: frame)
        // F1：预热（prewarm）会在未 show 时提前建面板——初始即视觉隐藏，避免一个
        // 可见的空窗闪现。首次 presentPanel 会按首显语义设 alpha 并复位鼠标接收。
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true

        // 内容视图：AIChatView（Lane C 交付）。
        // AIChatView/AIChatState 为 @MainActor，本管理器非隔离——面板构建恒在主线程，
        // 用 assumeIsolated 同步桥接（编译期隔离检查合规，运行期零开销）
        // 用 CachedHitTestHostingView 包一层：同一 runloop pass 内复用 hitTest 结果，
        // 消除聚焦时 becomeKeyWindow→setCursor 对 AI 大 SwiftUI 树的全树递归命中（详见该类注释）。
        let hostingView = MainActor.assumeIsolated {
            CachedHitTestHostingView(rootView: AIChatView(
                state: AIChatState.shared,
                onOpenSettings: { (NSApp.delegate as? AppDelegate)?.openSettings() },
                onClose: { [weak self] in self?.hide() }
            )
            .environment(\.controlActiveState, ControlActiveState.key))
        }
        // 整窗 Liquid Glass 实验（2026-10 质感专项）：26+ 恢复 NSGlassEffectView 整窗玻璃。
        // 当年移除主因是 NSGlassEffectView+NSHostingView+Button 测量死锁；现按社区成熟规避落地：
        // ① hostingView.sizingOptions=[] 禁其反推窗口尺寸；② 玻璃组装全程零时长动画上下文
        // （玻璃隐式动画会打断 SwiftUI 建树 → AttributeGraph 崩溃）；③ 先组装、最后挂 contentView。
        // <26 降级路径保持原状（hostingView 直接作 contentView + 根图层圆角裁剪）。
        // 性能诊断开关（QUICKSHOW_GLASS=off，环境变量优先/UserDefaults 兜底）：旁路整窗
        // 玻璃，走 <26 降级路径（hostingView 直接作 contentView + SwiftUI 层材质背景）
        // ——用于 A/B 玻璃合成成本（WindowServer 侧 blur 采样不在本进程主线程堆栈里）。
        if #available(macOS 26.0, *), Self.isGlassEnabled {
            hostingView.sizingOptions = []
            let glass = NSGlassEffectView()
            glass.style = .regular          // 文字为主 → regular（自适应明暗保可读性）
            glass.cornerRadius = Theme.Radius.panel
            glass.tintColor = nil
            // 基础项补齐：材质渲染层面尊重圆角（仅此项不够，见容器注释）
            glass.clipsToBounds = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                glass.frame = NSRect(origin: .zero, size: frame.size)
                glass.contentView = hostingView   // 唯一受保证的装载方式（勿 addSubview）
            })
            // hosting 填满玻璃 + resize 热区挂载均依赖 autoresizing 跟随
            hostingView.autoresizingMask = [NSView.AutoresizingMask.width, .height]
            // 窗口级圆角裁剪容器（2026-10 方角残影修复）：WindowServer 在方形窗口矩形上
            // 合成 behind-window 玻璃材质，拖动/缩放重栅格化后方形玻璃从圆角缺口露出。
            // 玻璃经 GlassClipContainerView 裁剪后再作 contentView（见 GlassSurface.swift）。
            let clip = GlassClipContainerView(cornerRadius: Theme.Radius.panel)
            clip.frame = NSRect(origin: .zero, size: frame.size)
            glass.autoresizingMask = [NSView.AutoresizingMask.width, .height]
            clip.addSubview(glass)
            panel.contentView = clip
        } else {
            // 26+ 默认材质路径：NSVisualEffectView 做整窗毛玻璃背景（Apple 长期优化的合成
            // 路径，性能远优于 NSGlassEffectView）。SwiftUI 层 liquidPanelBackground 在 26+
            // 填 .clear（透出玻璃），NSVisualEffectView 提供背后模糊。
            let bg = NSVisualEffectView()
            bg.autoresizingMask = [NSView.AutoresizingMask.width, .height]
            bg.material = .fullScreenUI
            bg.blendingMode = .withinWindow
            bg.state = .active
            bg.wantsLayer = true
            bg.layer?.cornerRadius = Theme.Radius.panel
            bg.layer?.cornerCurve = .continuous
            bg.layer?.masksToBounds = true
            bg.frame = NSRect(origin: .zero, size: frame.size)

            hostingView.frame = bg.bounds
            hostingView.autoresizingMask = [NSView.AutoresizingMask.width, .height]
            bg.addSubview(hostingView)
            panel.contentView = bg
        }
        panel.invalidateShadow()

        // 边缘 resize 热区：直接挂在内容视图最上层（真实 AppKit 命中测试，中心区域放行给 SwiftUI）。
        let resizeView = WindowResizeHotZoneView()
        resizeView.frame = hostingView.bounds
        resizeView.autoresizingMask = [NSView.AutoresizingMask.width, .height]
        hostingView.addSubview(resizeView)

        // 位置/大小持久化：NSWindow.didMove / didResize 时落盘。
        let center = NotificationCenter.default
        frameObservers.append(center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            // 透明窗口的系统阴影由不透明像素推导，拖动后不自动重算——手动失效，
            // 否则保留方形轮廓，与圆角缺口处的材质残影叠加成「四个方角」
            self?.panel?.invalidateShadow()
            self?.scheduleFrameSave()
        })
        frameObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            // 同上：缩放改变窗口形状后阴影需随圆角轮廓重算
            self?.panel?.invalidateShadow()
            self?.scheduleFrameSave()
        })
        frameObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            QSFocusLogger.log(">> NSApplication.didResignActive (App 失活)")
        })
        frameObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            QSFocusLogger.log(">> NSApplication.didBecomeActive (App 激活)")
        })

        // 接线：ESC 三阶段（⓪ 抽屉 → ① 中止流式 → ② 关窗，直连交互中心与 AIChatState）
        // / ⌘K 清空 / 被动失焦隐藏。
        // ChatInteractionCenter/AIChatState 为 @MainActor，闭包恒在主线程按键路径触发，
        // assumeIsolated 同步桥接（编译期隔离检查合规，运行期零开销）
        panel.onCancelDrawer = {
            MainActor.assumeIsolated {
                let center = ChatInteractionCenter.shared
                guard let request = center.request else { return false }
                switch request {
                case .toolConfirmation:
                    // 权限抽屉 ESC = 拒绝（安全默认值）
                    center.resolveConfirmation(.denied)
                case .userQuestions:
                    // 提问抽屉 ESC = 取消
                    center.cancelQuestions()
                }
                return true
            }
        }
        panel.onAbortStreaming = {
            MainActor.assumeIsolated {
                let state = AIChatState.shared
                if state.isStreaming {
                    // ESC 中止：除落定 .aborted 外，还需把当前会话待注入队列（steering/follow-up）
                    // 全部回填输入框，避免用户排队内容随中止丢失。
                    state.abortAndRecallQueue()
                    return true
                }
                return false
            }
        }
        panel.onEscapeClose = { [weak self] in
            self?.hide()
        }
        panel.onClearSession = {
            MainActor.assumeIsolated { AIChatState.shared.clearSession() }
        }
        panel.onResignKey = { [weak self] in
            guard let self else { return }
            // 钉住常驻：失焦不隐藏，保持 .statusBar 置顶层级。
            // 解钉后恢复失焦自动隐藏（当次不立即隐藏，等下次失焦/ESC）。
            if self.isPinned { return }
            // 非激活即隐藏：被动失焦不夺回焦点（避免与本 App 主面板/其他窗口争抢）
            self.performHide(restoreFocus: false)
        }
        return panel
    }
}