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

    /// ESC 阶段 ①：就地编辑消息优先取消编辑（返回 true = 已消费）
    var onCancelMessageEdit: (() -> Bool)?
    /// ESC 阶段 ②：会话重命名优先取消重命名（返回 true = 已消费）
    var onCancelRename: (() -> Bool)?
    /// ESC 阶段 ③：输入坞抽屉在场时取消抽屉（方案 B: 拒绝/取消并连带彻底中止大模型流式生成；
    /// 返回 true = 已消费本次 ESC，保持窗口打开）
    var onCancelDrawer: (() -> Bool)?
    /// ESC 阶段 ④：流式生成中双击确认急停（返回 true = 已消费本次 ESC，保持窗口打开）
    var onAbortStreaming: (() -> Bool)?
    /// ESC 阶段 ⑤：非流式空闲态时关窗还焦点
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
            // P0: 优先放行系统输入法 marked text 组字，让 IME 取消拼音（不落入窗口拦截）
            if event.keyCode == 53 {
                if let textView = firstResponder as? NSTextView, textView.hasMarkedText() {
                    super.sendEvent(event)
                    return
                }
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
            if let textView = firstResponder as? NSTextView, textView.hasMarkedText() {
                super.keyDown(with: event)
                return
            }
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

    /// ESC 分层处理：
    /// ① 历史消息就地编辑先退出编辑；② 会话重命名先取消重命名；
    /// ③ 抽屉在场先取消抽屉（方案 B：连带急停大模型当前生成）；
    /// ④ 纯流式中双击确认急停；⑤ 否则关窗还焦点。
    private func handleEscape() {
        if let cancelEdit = onCancelMessageEdit, cancelEdit() {
            return
        }
        if let cancelRename = onCancelRename, cancelRename() {
            return
        }
        if let cancelDrawer = onCancelDrawer, cancelDrawer() {
            return
        }
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
    /// 窗口 frame 存档键（旧单屏兼容落盘）。
    static let windowFrameKey = "ai.windowFrame"
    /// 多屏幕独立窗口 frame 存档键（字典：[DisplayIdentifier: NSStringFromRect(relativeFrame)]）。
    /// relativeFrame 记录的是相对于 screen.visibleFrame.origin 的相对偏移量与宽高。
    static let screenWindowFramesKey = "ai.windowFramesByScreen"
    /// 全局偏好尺寸存档键（供未存档的新屏幕首启时参考）。
    static let lastWindowSizeKey = "ai.lastWindowSize"
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
        // 开窗时确保清理任何残留的二次确认提醒
        MainActor.assumeIsolated {
            AIChatState.shared.cancelAbortConfirmation()
        }
        // 主面板可见则先淡出（两者互斥可见性，焦点最终交给 AI 窗，不自动回主面板）。
        // 先读取主面板记录的「原应用」，切窗后 AI 窗继承同一焦点归还目标。
        let handoffApp = PanelManager.shared.focusReturnApp
        // 切换时不归还焦点（restoreFocus: false），焦点由本管理器接管并在关窗时归还，
        // 避免主面板归还焦点与紧随其后的 AI 窗抢 active 状态
        PanelManager.shared.hidePanel(restoreFocus: false)

        // 恢复持久化的钉住态（用户可能在其他入口改过）。
        isPinned = UserDefaults.standard.bool(forKey: Self.pinnedKey)

        // A（冷启动白屏修复）：区分首建与复用。首建面板满 alpha 直接上屏、
        // 不播窗口级淡入——0.08s 的 animator alpha 动画与 SwiftUI 首帧建树的
        // CA 事务提交在同一时间窗竞态，冷启动必现主内容区消息行卡在近零透明度
        // （白屏 + 幽灵残影，切会话重渲染才恢复）；复用热路径内容已就绪，保留淡入。
        let isFreshlyBuilt = self.panel == nil
        let panel = ensurePanel()
        let screen = ScreenHelper.activeScreen
        // 鼠标在哪个屏幕，AI Chat 窗口就得在哪弹出（方案 A：同屏记忆位置，跨屏黄金分割居中；继承尺寸偏好）
        let frame = targetFrame(for: screen)
        panel.setFrame(frame, display: true)
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

        // B（冷启动白屏修复）：上屏前强制完成 SwiftUI 建树与布局，
        // 不让离屏半建状态随 orderFront 上屏后与渲染事务竞态
        panel.contentView?.layoutSubtreeIfNeeded()

        // A：alpha 必须先于 orderFront 设置（复用路径 0→1 淡入；首建满 alpha）
        panel.alphaValue = isFreshlyBuilt ? 1.0 : 0.0

        // 窗口先上屏，避免冷启动首帧卡顿
        panel.makeKeyAndOrderFront(nil)
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        // 呼出必聚焦：上屏 + 激活完成后（下一轮主线程调度）强制主输入框接管第一响应者。
        // 依赖兜底不可靠——复用路径 makeNSView 的一次性聚焦不再执行；didBecomeKey
        // 观察者遇残留 field editor（侧栏控件持焦后关窗，隐藏不清 firstResponder）
        // 按让位守卫直接放弃。此处是「每次呼出输入框必有光标」的唯一确定性入口。
        // 抽屉态（ChatInteractionCenter）是 MainActor 隔离，须在本 Task 上下文读取；
        // 抽屉展开中（AI 提问/权限确认）不发布——焦点留给抽屉的输入交互。
        Task { @MainActor [weak self, weak panel] in
            guard let self, let panel, panel.isVisible, !self.isDismissing else { return }
            guard ChatInteractionCenter.shared.request == nil else { return }
            NotificationCenter.default.post(name: .aiChatForceFocusInput, object: panel)
        }

        if !isFreshlyBuilt {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.Motion.panelFadeIn
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
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
        guard let panel = panel, panel.isVisible, !isDismissing else { return }
        // 危险工具确认 sheet 抢占 key 状态时父窗会 resignKey，属本窗内交互，
        // 不视为被动切走（sheet 关闭后焦点自然回归父窗）
        if panel.attachedSheet != nil { return }
        // 关窗隐藏时清理二次确认提醒，绝不将悬挂状态带入下次开窗
        MainActor.assumeIsolated {
            AIChatState.shared.cancelAbortConfirmation()
        }
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

    /// 落盘当前窗口 frame（同步，用于隐藏前兜底）：
    /// 1. 识别当前窗口所在屏幕（基于硬件 UUID）；
    /// 2. 计算相对坐标并保存到该屏幕专属存档中；
    /// 3. 保存全局尺寸参考并保留旧键兼容。
    private func saveFrame() {
        frameSaveWorkItem?.cancel()
        frameSaveWorkItem = nil
        guard let panel else { return }
        
        let screen = panel.screen ?? ScreenHelper.activeScreen
        let visibleFrame = screen.visibleFrame
        let currentFrame = panel.frame
        
        // 相对于当前屏幕 visibleFrame.origin 的相对位置与尺寸
        let relativeRect = NSRect(
            x: currentFrame.origin.x - visibleFrame.origin.x,
            y: currentFrame.origin.y - visibleFrame.origin.y,
            width: currentFrame.width,
            height: currentFrame.height
        )
        
        let displayId = screen.persistentDisplayIdentifier
        var dict = UserDefaults.standard.dictionary(forKey: Self.screenWindowFramesKey) as? [String: String] ?? [:]
        dict[displayId] = NSStringFromRect(relativeRect)
        UserDefaults.standard.set(dict, forKey: Self.screenWindowFramesKey)
        
        // 记录偏好尺寸供未存档新屏幕首启参考
        UserDefaults.standard.set(NSStringFromSize(currentFrame.size), forKey: Self.lastWindowSizeKey)
        // 旧单屏兼容落盘
        UserDefaults.standard.set(NSStringFromRect(currentFrame), forKey: Self.windowFrameKey)
    }

    /// 防抖落盘：拖动/缩放期间 didMove/didResize 高频触发，合并为一次写盘。
    private func scheduleFrameSave() {
        frameSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.frameSaveWorkItem = nil
            self.saveFrame()
        }
        frameSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// 计算指定屏幕下的最终窗口 frame（每个物理屏幕独立记忆自身最后位置与大小）：
    /// - 优先读取该屏幕专属的相对位置与尺寸（在当前 visibleFrame 安全 clamp）；
    /// - 兼容旧单屏历史存档迁移（若旧存档中心落在该屏幕）；
    /// - 首次在该屏幕弹出：继承最近偏好尺寸（若有），并在目标屏幕视线黄金分割正中央弹出。
    private func targetFrame(for screen: NSScreen) -> NSRect {
        let displayId = screen.persistentDisplayIdentifier
        let dict = UserDefaults.standard.dictionary(forKey: Self.screenWindowFramesKey) as? [String: String] ?? [:]
        
        // 1. 优先读取本屏幕专属记忆（相对坐标恢复）
        if let raw = dict[displayId], !raw.isEmpty {
            let relativeRect = NSRectFromString(raw)
            if relativeRect.width >= 1 && relativeRect.height >= 1 {
                let absoluteRect = NSRect(
                    x: screen.visibleFrame.origin.x + relativeRect.origin.x,
                    y: screen.visibleFrame.origin.y + relativeRect.origin.y,
                    width: relativeRect.width,
                    height: relativeRect.height
                )
                return clampedFrame(absoluteRect, on: screen)
            }
        }
        
        // 2. 兼容旧单屏存档迁移（若历史绝对坐标中心点正好处在本屏幕内）
        if let oldRaw = UserDefaults.standard.string(forKey: Self.windowFrameKey), !oldRaw.isEmpty {
            let oldRect = NSRectFromString(oldRaw)
            if oldRect.width >= 1 && oldRect.height >= 1 {
                let center = CGPoint(x: oldRect.midX, y: oldRect.midY)
                if screen.frame.contains(center) {
                    return clampedFrame(oldRect, on: screen)
                }
            }
        }
        
        // 3. 首次在该屏幕弹出：继承最近偏好尺寸，并在目标屏幕黄金分割居中
        let preferredSize: NSSize
        if let rawSize = UserDefaults.standard.string(forKey: Self.lastWindowSizeKey), !rawSize.isEmpty {
            let size = NSSizeFromString(rawSize)
            preferredSize = NSSize(
                width: min(max(size.width, minWindowSize.width), screen.visibleFrame.width),
                height: min(max(size.height, minWindowSize.height), screen.visibleFrame.height)
            )
        } else {
            preferredSize = targetAIChatSize(on: screen)
        }
        
        return ScreenHelper.centeredFrame(for: preferredSize, on: screen)
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
        // 整窗 Liquid Glass 实验（2026-10 质感专项）：26+ 恢复 NSGlassEffectView 整窗玻璃。
        // 当年移除主因是 NSGlassEffectView+NSHostingView+Button 测量死锁；现按社区成熟规避落地：
        // ① hostingView.sizingOptions=[] 禁其反推窗口尺寸；② 玻璃组装全程零时长动画上下文
        // （玻璃隐式动画会打断 SwiftUI 建树 → AttributeGraph 崩溃）；③ 先组装、最后挂 contentView。
        // <26 降级路径保持原状（hostingView 直接作 contentView + 根图层圆角裁剪）。
        if #available(macOS 26.0, *) {
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
            hostingView.autoresizingMask = [.width, .height]
            // 窗口级圆角裁剪容器（2026-10 方角残影修复）：WindowServer 在方形窗口矩形上
            // 合成 behind-window 玻璃材质，拖动/缩放重栅格化后方形玻璃从圆角缺口露出。
            // 玻璃经 GlassClipContainerView 裁剪后再作 contentView（见 GlassSurface.swift）。
            let clip = GlassClipContainerView(cornerRadius: Theme.Radius.panel)
            clip.frame = NSRect(origin: .zero, size: frame.size)
            glass.autoresizingMask = [.width, .height]
            clip.addSubview(glass)
            panel.contentView = clip
        } else {
            PanelHostingConfigurator.configure(hostingView, cornerRadius: Theme.Radius.panel)
            panel.contentView = hostingView
        }
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

        // 接线：ESC 分层（① 编辑 → ② 重命名 → ③ 抽屉连带急停 → ④ 双击流式急停 → ⑤ 关窗）
        // / ⌘K 清空 / 被动失焦隐藏。
        // ChatInteractionCenter/AIChatState 为 @MainActor，闭包恒在主线程按键路径触发，
        // assumeIsolated 同步桥接（编译期隔离检查合规，运行期零开销）
        panel.onCancelMessageEdit = {
            MainActor.assumeIsolated {
                let state = AIChatState.shared
                guard state.editingMessageId != nil else { return false }
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                    state.editingMessageId = nil
                }
                return true
            }
        }
        panel.onCancelRename = {
            MainActor.assumeIsolated {
                let state = AIChatState.shared
                guard state.renamingSessionId != nil else { return false }
                state.renamingSessionId = nil
                return true
            }
        }
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
                // 方案 B：抽屉在场按 ESC 连带彻底中止大模型当前生成，避免模型继续啰嗦回应；
                // 同步设置 0.5s 抑制期并清除二次确认状态，防止连击 ESC 穿透误弹 Toast
                let state = AIChatState.shared
                state.suppressAbortConfirmationUntil = Date().addingTimeInterval(0.5)
                state.cancelAbortConfirmation()
                if state.isStreaming {
                    state.abortAndRecallQueue()
                }
                return true
            }
        }
        panel.onAbortStreaming = {
            MainActor.assumeIsolated {
                AIChatState.shared.handleEscapeAbort()
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
            // 若当前存在未决的抽屉交互，失焦时确保向用户派发系统通知
            MainActor.assumeIsolated {
                ChatInteractionCenter.shared.notifyPendingInteractionIfInactive()
            }
            // 钉住常驻：失焦不隐藏，保持 .statusBar 置顶层级。
            // 解钉后恢复失焦自动隐藏（当次不立即隐藏，等下次失焦/ESC）。
            if self.isPinned { return }
            // 非激活即隐藏：被动失焦不夺回焦点（避免与本 App 主面板/其他窗口争抢）
            self.performHide(restoreFocus: false)
        }
        return panel
    }
}