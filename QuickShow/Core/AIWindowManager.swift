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

        let panel = ensurePanel()
        let screen = ScreenHelper.activeScreen
        let size = targetAIChatSize(on: screen)
        panel.setFrame(ScreenHelper.centeredFrame(for: size, on: screen), display: true)
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
    /// 写偏好持久化；窗口可见时按目标尺寸重新居中，复用统一窗口尺寸动画时长。
    func setSidebarVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: Self.sidebarVisibleKey)
        guard let panel, panel.isVisible else { return }
        let screen = panel.screen ?? ScreenHelper.activeScreen
        let frame = ScreenHelper.centeredFrame(for: targetAIChatSize(on: screen), on: screen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.windowResize
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
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
        if #available(macOS 26.0, *) {
            // 官方 Liquid Glass：与主面板同款做法，玻璃材质/高光/阴影由窗口层玻璃视图提供
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.wantsLayer = true
            glass.clipsToBounds = true
            glass.layer?.masksToBounds = true
            glass.layer?.cornerCurve = .continuous
            // 双写圆角：glass.cornerRadius 管光效形状，layer.cornerRadius 管裁剪路径
            glass.cornerRadius = Theme.Radius.panel
            glass.layer?.cornerRadius = Theme.Radius.panel
            glass.contentView = hostingView
            panel.contentView = glass
        } else {
            // 13~25 降级路径：AppKit 根图层硬件级连续曲率圆角裁剪 + SwiftUI 层 ultraThinMaterial 玻璃
            hostingView.wantsLayer = true
            hostingView.layer?.cornerRadius = Theme.Radius.panel
            hostingView.layer?.cornerCurve = .continuous
            hostingView.layer?.masksToBounds = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hostingView
        }
        panel.invalidateShadow()

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
            // 非激活即隐藏：被动失焦不夺回焦点（避免与本 App 主面板/其他窗口争抢）
            self?.performHide(restoreFocus: false)
        }
        return panel
    }
}