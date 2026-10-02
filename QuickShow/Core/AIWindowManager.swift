import AppKit
import SwiftUI

// MARK: - AI 对话窗专用 NSPanel 子类
/// 与主面板 FloatingPanel 语义不同（无速查表 / Space Pin / Tab 等全局键），故独立子类。
/// 仅保留 AI 窗专属拦截：
/// 1. 文本编辑聚焦时其余按键全部放行（1.3.0 高危修复：窗口级拦截吞掉输入导致丢草稿）；
/// 2. ESC 两阶段语义（流式生成中先中止；否则关窗还焦点）；
/// 3. ⌘K 清空会话。
///
/// 注意：ESC/⌘K 作为「AI 窗级命令」在文本聚焦时同样优先处理（PHASE3_PLAN §2 硬性要求），
/// 其余按键（含 ⏎/⇧⏎/⌘V/输入法组字）一律放行给第一响应者，绝不劫持文本输入。
final class AIPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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

    /// ESC 两阶段：流式生成中先中止（消费 ESC）；否则关窗还焦点
    private func handleEscape() {
        if let abort = onAbortStreaming, abort() {
            return
        }
        onEscapeClose?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// MARK: - AI 窗口管理器
/// AI 对话窗生命周期：独立窄长居中 NSPanel、显隐、焦点纪律。
/// 与主面板 PanelManager 同款焦点纪律（记录 previousApp → 关窗毫秒级归还），
/// 但窗口语义独立（无 PanelContext 路由）。
final class AIWindowManager {
    static let shared = AIWindowManager()

    private var panel: AIPanel?
    private var previousApp: NSRunningApplication?
    private var isDismissing: Bool = false
    // 隐藏代次令牌：作废迟到的旧淡出 completion（与 PanelManager 同款防抖）
    private var hideGeneration = 0
    // 窗口位置/大小存档通知观察者令牌（singleton 常驻，无需移除）
    private var frameObservers: [NSObjectProtocol] = []
    // frame 落盘防抖（拖动/缩放每帧都触发 didMove/didResize，合并写盘）
    private var frameSaveWorkItem: DispatchWorkItem?

    // MARK: - 钉住 / 位置持久化

    /// 钉住键（常驻置顶：失焦不自动隐藏）。
    static let pinnedKey = "ai.pinned"
    /// 窗口 frame 存档键（NSStringFromRect 落盘）。
    static let windowFrameKey = "ai.windowFrame"
    /// 最小尺寸（与边缘 resize 热区一致）。
    private let minWindowSize = NSSize(width: 480, height: 560)

    /// 是否已钉住常驻（show() 时从 UserDefaults 恢复）。
    private(set) var isPinned: Bool = UserDefaults.standard.bool(forKey: AIWindowManager.pinnedKey)

    /// 面板当前是否可见（供流式完成通知判断）。
    var isPanelVisible: Bool { panel?.isVisible ?? false }
    /// 面板当前是否为 key 窗口（供流式完成通知判断）。
    var isPanelKey: Bool { panel?.isKeyWindow ?? false }

    private init() {}

    // MARK: - 显隐

    /// 全局热键 / I 键统一切换：可见则关，不可见则显示居中
    func toggle() {
        if let panel = panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        // 主面板可见则先淡出（两者互斥可见性，焦点最终交给 AI 窗，不自动回主面板）。
        // 先读取主面板记录的「原应用」，切窗后 AI 窗继承同一焦点归还目标。
        let handoffApp = PanelManager.shared.focusReturnApp
        // 切换时不归还焦点（restoreFocus: false），焦点由本管理器接管并在关窗时归还，
        // 避免主面板归还焦点与紧随其后的 AI 窗抢 active 状态
        PanelManager.shared.hidePanel(restoreFocus: false)

        // 恢复持久化的钉住态（用户可能在其他入口改过）。
        isPinned = UserDefaults.standard.bool(forKey: Self.pinnedKey)

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
        panel.ignoresMouseEvents = false
        panel.alphaValue = 0.0

        // 窗口先上屏，避免冷启动首帧卡顿
        panel.makeKeyAndOrderFront(nil)
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.panelFadeIn
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }
    }

    /// ESC / 热键关窗：毫秒级归还焦点给呼出前应用
    func hide() {
        performHide(restoreFocus: true)
    }

    /// - Parameter restoreFocus: true = 主动关窗（ESC/热键），归还焦点；
    ///   false = 被动失焦（切走 / 被本 App 其他窗口抢 key），焦点已自然转移，不夺回。
    private func performHide(restoreFocus: Bool) {
        guard let panel = panel, panel.isVisible, !isDismissing else { return }
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
            panel.orderOut(nil)
            panel.alphaValue = 1.0
            panel.ignoresMouseEvents = false
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
        guard let panel, panel.isVisible else { return }
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

        // 内容视图：AIChatView（Lane C 交付）。
        // AIChatView/AIChatState 为 @MainActor，本管理器非隔离——面板构建恒在主线程，
        // 用 assumeIsolated 同步桥接（编译期隔离检查合规，运行期零开销）
        let hostingView = MainActor.assumeIsolated {
            NSHostingView(rootView: AIChatView(
                state: AIChatState.shared,
                onOpenSettings: { (NSApp.delegate as? AppDelegate)?.openSettings() },
                onClose: { [weak self] in self?.hide() }
            ))
        }
        // 整窗 NSGlassEffectView 已移除（HIG：Liquid Glass 只用于功能层，内容层用标准材质）。
        // hostingView 直接作为 contentView，根图层连续曲率圆角裁剪，与主面板同一套；
        // 功能面 glass 见 AIChatView 的 GlassSurface（顶栏 / 输入坞）。
        PanelHostingConfigurator.configure(hostingView, cornerRadius: Theme.Radius.panel)
        panel.contentView = hostingView
        panel.invalidateShadow()

        // 边缘 resize 热区：直接挂在内容视图最上层（真实 AppKit 命中测试，中心区域放行给 SwiftUI）。
        let resizeView = WindowResizeHotZoneView()
        resizeView.frame = hostingView.bounds
        resizeView.autoresizingMask = [.width, .height]
        hostingView.addSubview(resizeView)

        // 位置/大小持久化：NSWindow.didMove / didResize 时落盘。
        let center = NotificationCenter.default
        frameObservers.append(center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleFrameSave()
        })
        frameObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleFrameSave()
        })

        // 接线：ESC 两阶段（直连 AIChatState） / ⌘K 清空 / 被动失焦隐藏
        // AIChatState 为 @MainActor，闭包恒在主线程按键路径触发，assumeIsolated 同步桥接
        panel.onAbortStreaming = {
            MainActor.assumeIsolated {
                let state = AIChatState.shared
                if state.isStreaming {
                    state.abortStreaming()
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