// 从 AIChatView.swift 机械拆分：AI 会话滚动与浏览导航（快捷键监听 / 滚动协调器 / AppKit 桥 / 虚拟化行 / 刻度轨）。

import AppKit
import Combine
import SwiftUI

// MARK: - AI 窗快捷键监听

/// AI 窗级快捷键本地监听：⌘N 新会话 / ⌘B 侧栏显隐 / ⌘F 聚焦搜索。
/// 为什么不用 AIPanel.sendEvent 拦截：窗口层按键纪律（ESC/⌘K/文本聚焦放行）不允许改动；
/// 本地监听在 NSApplication 派发到窗口之前触发，既不动窗口层逻辑，又能覆盖
/// 「第一响应者非输入框」（如焦点在侧栏会话行）的路径。
/// 另承担三个 UI 态下的 ESC 先行消费：抽屉在场 → 取消抽屉（阶段 0，与窗口层同一语义）；
/// 行内重命名中 → 取消重命名；图片放大中 → 关闭放大层。
/// 非隔离类：本地监听恒在主线程事件派发路径触发，回调直接执行，避免 NSEvent 跨隔离域。
final class AIChatKeyMonitor {
    private var monitor: Any?

    /// 抽屉（权限确认 / AI 提问）是否在场
    var isDrawerOpen: () -> Bool = { false }
    /// 抽屉取消动作（权限 = 拒绝 / 提问 = 取消）
    var onCancelDrawer: () -> Void = {}
    var isRenaming: () -> Bool = { false }
    var onCancelRename: () -> Void = {}
    var isZooming: () -> Bool = { false }
    var onDismissZoom: () -> Void = {}
    var onNewSession: () -> Void = {}
    var onToggleSidebar: () -> Void = {}
    var onFocusSearch: () -> Void = {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // 只接管 AI 对话窗的按键（设置窗等其他窗口不受影响）
        guard event.window is AIPanel else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ESC：抽屉/重命名/放大态下先行消费；其余放行给窗口层阶段语义
        if event.keyCode == 53, flags.isEmpty {
            if isDrawerOpen() { onCancelDrawer(); return nil }
            if isRenaming() { onCancelRename(); return nil }
            if isZooming() { onDismissZoom(); return nil }
            return event
        }

        guard flags == [.command] else { return event }
        switch event.keyCode {
        case 45: onNewSession(); return nil   // N
        case 11: onToggleSidebar(); return nil // B
        case 3: onFocusSearch(); return nil    // F
        default: return event
        }
    }
}

// MARK: - 会话滚动控制中枢（来源判定 + 程序化仲裁）

/// 滚动跟随的单一判定中枢（AI 窗一个，按会话路由）。
///
/// 第一性原理：视口偏移的变化只有两个来源——**用户输入**（滚轮/惯性/滚动条/键盘，最终都
/// 表现为 clipView bounds 的 origin 变化）与**非用户变化**（我们发起的程序化滚动、内容
/// 布局增长/塌缩引发的被动调整）。由「变化来源」直接判定 pinned 态，取代旧架构用
/// 0.5s/0.4s/0.12s 三个时间窗对「哨兵消失是谁干的」的猜测——时间窗没有时间上界语义
/// （异步渲染的 settling 可达秒级），猜测必错，这正是历次补丁反复复发的根源。
///
/// 判定规则（单一写路径）：
/// - pinned = true 只来自两处：用户输入把视口带回底部容差区 / 发送消息强制跳底；
/// - pinned = false 只来自一处：用户输入把视口推离底部容差区；
/// - 内容高度变化（documentView frame 变化）**永不**直接改 pin 态——pinned 时程序化
///   保持贴底（跟随的唯一执行点），unpinned 时绝不干预（用户阅读位置主权最高）；
/// - 程序化滚动经 `beginProgrammatic` 遮蔽窗排除在「用户输入」之外（同步滚动短窗、
///   动画滚动按动画时长 + 兜底）。
///
/// 非隔离类：全部回调恒在主线程（NSNotification 主队列 + SwiftUI 主线程回调），
/// 先例见 AIChatKeyMonitor；避免跨隔离域开销。
final class ChatScrollCoordinator {
    /// pin 态真源（按会话）。**必须放 class 内直接读写**：日志实证 @State 经通知回调写入后，
    /// 同帧读取闭包拿到的仍是旧值（写入对非渲染上下文的读取至少延迟一帧可见）——
    /// 判定路径读旧值 = 用户已解除跟随仍被逐帧贴底拽回（「走走停停被间歇拉回」根因）。
    /// 视图层的 isPinned @State 降级为纯 UI 镜像（导航簇显隐），由 onPinnedChange 同步。
    private var pinStates: [UUID: Bool] = [:]
    /// pin 态变化通知（每会话一个，视图挂载时注册）：coordinator 真源变化 → 回调写回
    /// 视图 @State 驱动 UI 刷新。UI 镜像延迟一帧无妨——它不在判定路径上。
    private var pinnedChangeHandlers: [UUID: (Bool) -> Void] = [:]

    /// 程序化滚动遮蔽——两种机制，按路径选用：
    /// - **同步作用域**（`programmaticDepths`）：`clipView.scroll(to:)` 的 bounds 通知在
    ///   调用栈内**同步**发出，进出作用域即可精确遮蔽，**零时间窗**——流式逐帧贴底
    ///   （~50ms 合帧节拍）的高频路径必须走此机制：若用时间窗，50ms 窗口背靠背覆盖
    ///   时间线，用户的滚轮输入几乎必然落在窗内被吞——pin 态永远无法解除，表现为
    ///   「流式输出中滚不上去」（被贴底循环持续拽回）。
    /// - **时间窗**（`programmaticUntil`）：仅用于动画滚动（animator 的 bounds 变化由
    ///   CA 逐帧异步驱动，作用域罩不住）与 proxy 回退路径（布局异步落定）。动画只
    ///   发生在低频路径（流结束收尾/导航跳转），不会饿死用户输入。
    /// - 兜底：无论哪种遮蔽生效中，若 origin 向**远离底部**方向移动（用户逆着程序化
    ///   滚动向上滚），立即解除遮蔽并按用户输入处理（用户主权最高，见 handleBoundsChanged）。
    private var programmaticDepths: [UUID: Int] = [:]
    private var programmaticUntil: [UUID: Date] = [:]
    /// 各会话上一次观察到的 clipView bounds origin：区分「滚动」（origin 变）与
    /// 「视口尺寸变化」（origin 不变，窗口 resize/工具条收展）——后者绝不能当作用户滚动。
    private var lastOrigins: [UUID: CGPoint] = [:]
    /// 各会话 documentView 上一次高度（frame 变化时算 delta）。
    private var lastDocHeights: [UUID: CGFloat] = [:]

    /// 底部容差区高度（pt）：与视图层 bottomTolerance 同源——判定「视口在底部」的容差。
    private let bottomTolerance: CGFloat = 18

    private struct WeakBox { weak var view: NSScrollView? }
    private var attached: [UUID: WeakBox] = [:]
    /// 各会话的通知监听 token（attach 时安装，重复 attach 先拆旧——SwiftUI 重建桥时换
    /// ScrollView 重装；会话视图销毁后 scrollView 随之释放，通知源消失，token 空转无害）。
    private var observers: [UUID: (bounds: NSObjectProtocol, frame: NSObjectProtocol)] = [:]

    // MARK: - 会话注册与 pin 真源

    /// 挂载时注册：pin 变化通知（同步视图的 isPinned UI 镜像）。常驻期间保持。
    func bind(sessionId: UUID, onPinnedChange: @escaping (Bool) -> Void) {
        pinnedChangeHandlers[sessionId] = onPinnedChange
    }

    /// 卸载时注销并清理真源。
    func unbind(sessionId: UUID) {
        pinnedChangeHandlers[sessionId] = nil
        pinStates[sessionId] = nil
    }

    /// pin 态唯一写入口：class 真源即时生效（判定路径同帧可读，零延迟），
    /// 变化时通知视图刷新 UI 镜像（导航簇显隐等，延迟一帧无妨）。
    func setPinned(_ sessionId: UUID, _ pinned: Bool) {
        let old = pinStates[sessionId] ?? true
        guard old != pinned else { return }
        pinStates[sessionId] = pinned
        pinnedChangeHandlers[sessionId]?(pinned)
    }

    /// pin 真源公开读取（视图层快照等路径必须读真源——@State 镜像写入对读取
    /// 延迟一帧可见，读镜像会存到旧值导致恢复路径走错分支）。
    func isPinnedState(of sessionId: UUID) -> Bool {
        pinStates[sessionId] ?? true
    }

    // MARK: - AppKit 桥挂载（通知安装）

    /// 桥视图解析到本会话底层 NSScrollView 后调用：安装 clipView bounds 变化与
    /// documentView frame 变化两类通知（posts 开关显式开启——两者默认都不发通知）。
    func attach(sessionId: UUID, scrollView: NSScrollView) {
        if attached[sessionId]?.view === scrollView, observers[sessionId] != nil { return }
        if let old = observers[sessionId] {
            NotificationCenter.default.removeObserver(old.bounds)
            NotificationCenter.default.removeObserver(old.frame)
            observers[sessionId] = nil
        }
        attached[sessionId] = WeakBox(view: scrollView)
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        if let doc = clipView.documentView {
            doc.postsFrameChangedNotifications = true
            lastDocHeights[sessionId] = lastDocHeights[sessionId] ?? doc.frame.height
        }
        lastOrigins[sessionId] = lastOrigins[sessionId] ?? clipView.bounds.origin
        let boundsToken = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in
            self?.handleBoundsChanged(sessionId: sessionId, scrollView: scrollView)
        }
        let frameToken = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clipView.documentView, queue: .main
        ) { [weak self] _ in
            self?.handleDocumentFrameChanged(sessionId: sessionId, scrollView: scrollView)
        }
        observers[sessionId] = (boundsToken, frameToken)
    }

    /// 底层 NSScrollView 弱引用读取（跳底直滚 / 桥可用性判定）。
    func scrollView(for sessionId: UUID) -> NSScrollView? {
        attached[sessionId]?.view
    }

    // MARK: - 程序化滚动仲裁

    /// 开程序化时间窗：窗口内的 bounds origin 变化不计为用户输入（仅动画/proxy 路径用）。
    private func beginProgrammatic(sessionId: UUID, window: TimeInterval) {
        let until = Date().addingTimeInterval(window)
        if (programmaticUntil[sessionId] ?? .distantPast) < until {
            programmaticUntil[sessionId] = until
        }
    }

    /// 解除该会话全部程序化遮蔽（作用域 + 时间窗）：用户逆程序化方向滚动的兜底。
    private func endProgrammatic(sessionId: UUID) {
        programmaticDepths[sessionId] = 0
        programmaticUntil[sessionId] = .distantPast
    }

    private func isProgrammaticActive(sessionId: UUID) -> Bool {
        (programmaticDepths[sessionId] ?? 0) > 0
            || Date() < (programmaticUntil[sessionId] ?? .distantPast)
    }

    /// 同步程序化作用域：闭包内 `clipView.scroll(to:)` 触发的 bounds 通知在调用栈内
    /// 同步发出，进出配对遮蔽——零时间窗，流式逐帧贴底（高频）的安全路径。
    private func withSyncProgrammaticScope<T>(_ sessionId: UUID, _ body: () -> T) -> T {
        programmaticDepths[sessionId, default: 0] += 1
        let result = body()
        programmaticDepths[sessionId, default: 0] -= 1
        return result
    }

    /// 程序化作用域（proxy 路径）：proxy.scrollTo 的布局/动画异步落定，作用域罩不住
    /// bounds 变化，用时间窗兜——短窗覆盖非动画落定，动画路径（0.18~0.2s）调用方传
    /// 0.28~0.35 覆盖逐帧变化。仅低频路径使用（导航/恢复定位），不构成用户输入饥饿。
    func withProgrammaticScope<T>(_ sessionId: UUID, window: TimeInterval = 0.05, _ body: () -> T) -> T {
        beginProgrammatic(sessionId: sessionId, window: window)
        return body()
    }

    // MARK: - 通知处理（判定核心）

    /// clipView bounds 变化：origin 变 = 滚动（用户，或未被遮蔽的程序化）；origin 不变
    /// = 纯视口尺寸变化（resize），pinned 会话程序化重新贴底，绝不当用户滚动。
    /// 遮蔽中的兜底：程序化贴底只会让 origin 向底部方向移动（或持平）；origin 向**远离
    /// 底部**方向移动必然来自用户输入（用户逆着程序化滚动向上滚）——立即解除遮蔽并
    /// 按用户输入处理（用户主权最高）。这保证流式逐帧贴底期间用户上滚**立即**生效
    /// （历史缺陷：贴底开 0.05s 时间窗 × 50ms 合帧节拍背靠背覆盖时间线，用户滚轮
    /// 全部被吞——「转向消息后滚不上去」的根因）。
    private func handleBoundsChanged(sessionId: UUID, scrollView: NSScrollView) {
        let origin = scrollView.contentView.bounds.origin
        let last = lastOrigins[sessionId] ?? origin
        lastOrigins[sessionId] = origin
        let originChanged = abs(origin.x - last.x) > 0.1 || abs(origin.y - last.y) > 0.1
        guard originChanged else {
            // 视口尺寸变化（非滚动）：pinned 会话保持贴底（窗口缩小会让底部内容沉下去）。
            if isPinned(sessionId) { scrollPinnedToBottom(sessionId: sessionId, animated: false) }
            return
        }
        let flipped = scrollView.contentView.documentView?.isFlipped ?? true
        // flipped 文档：向上滚 = origin.y 减小；非 flipped：origin.y 增大。
        let movedUp = flipped ? (origin.y < last.y - 0.1) : (origin.y > last.y + 0.1)
        let masked = isProgrammaticActive(sessionId: sessionId)
        if masked {
            // 兜底仅对「贴底跟随中的逆向上滚」生效（isPinned=true）；unpinned 时的
            // movedUp 可能是内容塌缩后的被动 clamp（flipped 下 offset 被压小、方向同
            // 向上），若触发兜底会把 clamp 误判为用户输入、在底部误恢复 pin——
            // 历史「塌缩瞬移」根因的复活路径，必须排除。
            guard movedUp, isPinned(sessionId) else {
                return
            }
            endProgrammatic(sessionId: sessionId)
        }
        let atBottom = isAtBottom(scrollView)
        // 方向守卫（塌缩瞬移特征排除）：用户回底必然是**向下滚**（origin 向底部移动）；
        // 「向上滚却判定在底部」（movedUp && atBottom）的矛盾组合只来自内容塌缩后
        // SwiftUI/AppKit 把 origin 压到新 maxOffset 的被动调整——日志实证的
        // 「瞬移 13915px 回底 + pin 误恢复 → 回填期间逐帧 scrollToBottom 拽回」根因。
        // 矛盾组合一律吞掉（不写 pin）；内容不满一屏区（maxOffset=0 恒 atBottom）的
        // 向上橡皮筋微滚同被吞，写同值 1 亦无语义损失。
        if movedUp, atBottom {
            return
        }
        setPinned(sessionId, atBottom)
    }

    /// documentView frame 变化（内容高度增长/塌缩）：跟随的唯一执行点。
    /// - pinned：程序化贴底（非动画，与内容布局同步，流式增量即逐帧跟随）；
    /// - unpinned：不干预——但**塌缩时必须把偏移预先 clamp 到新最大值**（等价 AppKit
    ///   即将做的调整，但由我们在遮蔽窗内完成）：否则随后 AppKit 自己 clamp 的 bounds
    ///   变化会被误判为用户滚动，把 pin 态错误翻转（历史「瞬移到底 + 回弹错位」根因）。
    private func handleDocumentFrameChanged(sessionId: UUID, scrollView: NSScrollView) {
        guard let doc = scrollView.contentView.documentView else { return }
        let newHeight = doc.frame.height
        let oldHeight = lastDocHeights[sessionId] ?? newHeight
        lastDocHeights[sessionId] = newHeight
        let delta = newHeight - oldHeight
        guard abs(delta) > 0.5 else { return }
        let pinned = isPinned(sessionId)
        if pinned {
            scrollPinnedToBottom(sessionId: sessionId, animated: false)
        } else if delta < 0 {
            // 塌缩：程序化执行 clamp 等价（同步作用域遮蔽），视觉与 AppKit 自然行为一致。
            // 额外保留 0.15s 时间窗：AppKit 在布局 pass 的后续自然 clamp（若发生）不在
            // 我们的调用栈内，同步作用域罩不住——它的 bounds 变化方向与向上滚相同
            // （offset 被压小），不遮蔽会被判定为用户输入、在底部误恢复 pin。
            let clip = scrollView.contentView
            let maxOffset = max(0, newHeight - clip.bounds.height)
            let current = doc.isFlipped ? clip.bounds.origin.y : -clip.bounds.origin.y
            if current > maxOffset {
                beginProgrammatic(sessionId: sessionId, window: 0.15)
                let target = NSPoint(x: 0, y: doc.isFlipped ? maxOffset : -maxOffset)
                withSyncProgrammaticScope(sessionId) {
                    clip.scroll(to: target)
                    scrollView.reflectScrolledClipView(clip)
                }
            }
        }
    }

    /// 视口是否在底部容差区（flipped 文档：距底溢出 ≤ 容差；内容不满一屏恒在底部）。
    private func isAtBottom(_ scrollView: NSScrollView) -> Bool {
        guard let doc = scrollView.contentView.documentView else { return true }
        let clip = scrollView.contentView
        guard doc.isFlipped else {
            return clip.bounds.origin.y <= bottomTolerance
        }
        let maxOffset = max(0, doc.bounds.height - clip.bounds.height)
        return (maxOffset - clip.bounds.origin.y) <= bottomTolerance
    }

    private func isPinned(_ sessionId: UUID) -> Bool {
        pinStates[sessionId] ?? true
    }

    // MARK: - 跳底直滚（AppKit 路径，程序化仲裁内）

    /// 程序化滚动到本会话底部。返回 false = 桥未就绪（无底层 NSScrollView 可控）。
    /// - 非动画（流式逐帧跟随的高频路径）：同步作用域遮蔽——`scroll(to:)` 的 bounds
    ///   通知在调用栈内同步发出，进出配对即可精确遮蔽，**零时间窗**（用时间窗会被
    ///   50ms 合帧节拍背靠背铺满时间线、吞掉全部用户滚轮输入）；
    /// - 动画（低频：流结束收尾/导航回底）：时间窗 = 动画时长 + 兜底（CA 逐帧异步
    ///   驱动的 bounds 变化作用域罩不住；低频路径不构成输入饥饿，且有 movedUp 兜底）。
    @discardableResult
    func scrollPinnedToBottom(sessionId: UUID, animated: Bool) -> Bool {
        guard let sv = attached[sessionId]?.view, let doc = sv.contentView.documentView else {
            return false
        }
        let bottomY = doc.isFlipped
            ? max(0, doc.bounds.height - sv.contentView.bounds.height)
            : 0
        let target = NSPoint(x: 0, y: bottomY)
        if animated {
            beginProgrammatic(sessionId: sessionId, window: 0.34)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sv.contentView.animator().setBoundsOrigin(target)
            })
        } else {
            withSyncProgrammaticScope(sessionId) {
                sv.contentView.scroll(to: target)
                sv.reflectScrolledClipView(sv.contentView)
            }
        }
        return true
    }
}

/// AppKit 滚动桥：零尺寸 NSView 挂在 ScrollView **内容树内部**（必须在内——挂在 ScrollView
/// 外层时是兄弟节点，enclosingScrollView 解析不到）。解析到本会话底层 NSScrollView 后
/// 交 coordinator 安装通知；视图若被 SwiftUI 重建，updateNSView 以 !== 检测并重挂。
struct ChatScrollBridgeView: NSViewRepresentable {
    let sessionId: UUID
    let coordinator: ChatScrollCoordinator
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let sv = nsView.enclosingScrollView,
               coordinator.scrollView(for: sessionId) !== sv {
                coordinator.attach(sessionId: sessionId, scrollView: sv)
            }
        }
    }
}

// MARK: - 浏览导航刻度轨（Dock 放大手感）

/// 刻度轨布局数学（纯值模型，光标每帧移动即整轨 O(n) 重算）：
/// - 静止态：均匀紧凑 pitch（可用高 ÷ 条数自适应收缩、保底 pitchMin），容器高恒为
///   静止总高并垂直居中——**坐标系恒定是丝滑的关键**：放大只改槽内偏移与 scale，
///   容器几何不随放大变化，跟踪坐标无反馈漂移、无边界追逐振荡；
/// - 放大态：每枚 tick 按「光标 → 静止中心」距离的余弦钟形得权重 w（Dock 经典衰减：
///   峰在光标正下方、radius 处平滑归零、域外恒 0）；槽心 = 静止中心 + 上方累计生长
///   − 锚点前累计生长——**锚点（当前消息 tick）恒钉死在静止位、scale 恒 1**，不参与
///   放大布局，成为波中的稳定零位；其余 tick 相对它彼此推开；
/// - 明暗与大小共用同一条 w：不透明度 = rest + t×(lerp(dim, bright, w) − rest)，
///   光标正下方最亮、远端比静止更暗，两个维度同步流动；
/// - 命中槽由相邻槽心中点切分（Voronoi），无缝相接、随放大同步长大——hover 判定与
///   点击目标在任何放大态下都严丝合缝。
struct ChatTickRailLayout {
    struct Slot: Equatable {
        var center: CGFloat      // 槽心 y（容器静止坐标系；tick 视觉锚点）
        var frameTop: CGFloat    // 命中槽顶（相邻槽心中点切分，可溢出容器上下缘）
        var frameHeight: CGFloat // 命中槽高（槽间恒无缝）
        var scale: CGFloat       // 放大倍率（1 = 静止/锚点）
        var opacity: Double      // 明暗梯度输出（仅普通 tick 使用；accent 锚点忽略）
    }

    let pitch: CGFloat
    /// 静止总高（容器固定高 = n × pitch）
    let restHeight: CGFloat
    /// 容器顶缘在几何区（overlay 可用区）坐标系中的 y（垂直居中换算；跟踪层局部坐标
    /// 经 trackTop 偏移换算到本坐标系后使用）
    let containerTop: CGFloat
    /// 首/末命中槽的外缘（容器坐标系，可越出 [0, restHeight]）——hover 判定的上下界
    let railTop: CGFloat
    let railBottom: CGFloat
    let slots: [Slot]

    /// - pinnedIndex: 当前消息 tick 下标（accent 锚点）——恒 scale 1、位置钉死不动；
    ///   nil 时退化为绕几何中心对称生长
    init(count: Int, availableHeight: CGFloat, cursorY: CGFloat, amount: CGFloat, pinnedIndex: Int?) {
        let tokens = Theme.Layout.self
        let n = max(count, 0)
        let avail = max(availableHeight, 1)
        // 放大生长余量（worst-case 上界 Σ(scale−1)·pitch ≤ (maxScale−1)·(radius+pitch)）：
        // 静止总高预算先扣除它 → 光标扫到峰值时整轨视觉高也不超可用区
        let growthReserve = (tokens.chatTickMagnifyMaxScale - 1)
            * (tokens.chatTickMagnifyRadius + tokens.chatTickPitch)
        let p = n > 0
            ? min(tokens.chatTickPitch, max(tokens.chatTickPitchMin, (avail - growthReserve) / CGFloat(n)))
            : tokens.chatTickPitch
        pitch = p
        restHeight = p * CGFloat(n)
        containerTop = (avail - restHeight) / 2

        guard n > 0 else {
            slots = []
            railTop = 0
            railBottom = 0
            return
        }
        let t = min(max(amount, 0), 1)
        let maxGain = tokens.chatTickMagnifyMaxScale - 1
        let radius = tokens.chatTickMagnifyRadius
        let pinned = pinnedIndex.flatMap { $0 >= 0 && $0 < n ? $0 : nil }
        let colors = Theme.Colors.self

        // 第一遍：各 tick 的权重 w（余弦钟形）→ scale / 不透明度 / 生长量
        var scales: [CGFloat] = []
        scales.reserveCapacity(n)
        var opacities: [Double] = []
        opacities.reserveCapacity(n)
        var growths: [CGFloat] = []
        growths.reserveCapacity(n)
        for i in 0..<n {
            let center = containerTop + p * (CGFloat(i) + 0.5)
            let d = abs(cursorY - center)
            let w: CGFloat = d < radius ? 0.5 * (1 + cos(.pi * d / radius)) : 0
            // 锚点不参与放大布局：scale 恒 1（颜色恒 accent，不透明度输出不参与）
            let scale = i == pinned ? 1 : 1 + maxGain * w * t
            scales.append(scale)
            growths.append((scale - 1) * p)
            // 明暗双维度：与大小共用同一 w 与渐入量 t（rest → lerp(dim, bright, w)）
            let target = colors.chatTickDimOpacity + (colors.chatTickBrightOpacity - colors.chatTickDimOpacity) * Double(w)
            opacities.append(colors.chatTickRestOpacity + Double(t) * (target - colors.chatTickRestOpacity))
        }
        // 第二遍：槽心 = 静止中心 + 上方累计生长 − 锚点前累计生长（锚点钉死 = 零位）；
        // 无锚点时退化为全局生长一半（绕几何中心对称生长）
        var growthAbove: [CGFloat] = []
        growthAbove.reserveCapacity(n)
        var running: CGFloat = 0
        var totalGrowth: CGFloat = 0
        for i in 0..<n {
            growthAbove.append(running)
            running += growths[i]
            totalGrowth += growths[i]
        }
        let pivot = pinned.map { growthAbove[$0] } ?? totalGrowth / 2
        var centers: [CGFloat] = []
        centers.reserveCapacity(n)
        for i in 0..<n {
            centers.append(p * (CGFloat(i) + 0.5) + growthAbove[i] - pivot)
        }
        // 第三遍：命中槽 = 相邻槽心中点切分（端点槽向外延伸自身半步，可越容器缘）
        var result: [Slot] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            let top = i > 0
                ? (centers[i - 1] + centers[i]) / 2
                : centers[0] - (n > 1 ? (centers[1] - centers[0]) / 2 : p * scales[0] / 2)
            let bottom = i < n - 1
                ? (centers[i] + centers[i + 1]) / 2
                : centers[i] + (n > 1 ? (centers[i] - centers[i - 1]) / 2 : p * scales[i] / 2)
            result.append(Slot(center: centers[i], frameTop: top,
                               frameHeight: bottom - top, scale: scales[i], opacity: opacities[i]))
        }
        slots = result
        railTop = result[0].frameTop
        railBottom = result[n - 1].frameTop + result[n - 1].frameHeight
    }

    /// 几何区坐标 → 光标正下方的 tick 下标：横坐标须落在轨体内（左伸接近带只驱动放大、
    /// 不触发 hover），纵坐标须落在命中槽域内；槽无缝相接，命中即返。
    func hoveredIndex(at point: CGPoint, trackWidth: CGFloat, railWidth: CGFloat) -> Int? {
        guard !slots.isEmpty, point.x >= trackWidth - railWidth else { return nil }
        let y = point.y - containerTop
        guard y >= railTop, y <= railBottom else { return nil }
        for (i, slot) in slots.enumerated() where y >= slot.frameTop && y < slot.frameTop + slot.frameHeight {
            return i
        }
        return slots.indices.last  // y == railBottom 边界兜底
    }
}

/// 右缘消息刻度轨（Dock magnification 手感）：
/// 每条用户消息一枚 tick，静止紧凑密排（pitch 按可用高度自适应收缩）；光标进入磁吸
/// 跟踪带（轨体 + 上下各一个衰减半径 + 左伸接近带）后，光标附近的 tick 按余弦钟形
/// 衰减实时放大并彼此推开、明暗同步流动；离开平滑收拢。hover 预览胶囊、点击直达、
/// 当前条 accent 锚点（钉死不动）全部保留。
///
/// 丝滑的关键路径：
/// - **跟踪面必须挂在覆盖整个交互区的共同祖先上**（历史根因：跟踪层曾是 tick 层
///   下方兄弟节点，光标压上可命中的 tick 即触发 hover exit → 放大瞬间塌缩、胶囊
///   永不出现）——现在 contentShape + onContinuousHover 挂在包裹 tick 层的磁吸带
///   容器上，tick 是其后代，从左邻带到轨上 hover 连续不断流；
/// - 光标 y 直接赋值驱动每帧布局（无隐式动画、即时跟随）；只有 magnifyAmount 的
///   进入 0→1 / 离开 1→0 走显式 easeOut 动画（渐入点亮 / 收拢回弹）——进入动画
///   只在 hover 生命周期开始播一次（amount 目标值即时为 1，后续移动不重复触发）；
/// - hover 写入不走 withAnimation（防同事物染指槽位布局），胶囊过渡由 tick 内层
///   值域动画 `.animation(_:value:)` 承担（只在 hover 变化帧生效，光标移动帧零动画）；
/// - 光标状态私有于本视图——每帧重算只触及刻度轨子树，不冲刷消息列表。
struct ChatTickRail: View {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let preview: String
        let isCurrent: Bool
    }

    let items: [Item]
    let onSelect: (UUID) -> Void

    /// 光标 y（几何区坐标系；直接驱动 = 零动画即时跟随）
    @State private var cursorY: CGFloat = 0
    /// 放大渐入量 0…1：唯一走动画的分量（进入点亮 / 离开收拢）
    @State private var magnifyAmount: CGFloat = 0
    /// 被悬停 tick 的消息 id（预览胶囊锚点），由跟踪坐标派生
    @State private var hoveredTickId: UUID?

    /// 轨体宽 = 当前条峰值放大后宽度（tick 右缘对齐，放大向左生长，右基准线钉死不动）
    private var railWidth: CGFloat {
        Theme.Layout.chatTickActiveWidth * Theme.Layout.chatTickMagnifyMaxScale
    }

    /// 跟踪带宽 = 轨体宽 + 左伸接近带（光标逼近即开始响应，Dock 同款「迎光标」）
    private var trackWidth: CGFloat {
        railWidth + Theme.Layout.chatTickTrackSlop
    }

    var body: some View {
        GeometryReader { geo in
            let model = ChatTickRailLayout(
                count: items.count,
                availableHeight: geo.size.height,
                cursorY: cursorY,
                amount: magnifyAmount,
                pinnedIndex: items.firstIndex(where: { $0.isCurrent })
            )
            let radius = Theme.Layout.chatTickMagnifyRadius
            // 磁吸带 = 轨体 ± 一个衰减半径（几何区坐标）；不铺满全高——带外衰减恒零
            // （手感无差），右缘其余区域不占用命中（滚动条可拖拽）
            let trackTop = max(0, model.containerTop - radius)
            let trackHeight = min(geo.size.height, model.containerTop + model.restHeight + radius) - trackTop
            ZStack(alignment: .topTrailing) {
                // tick 层：容器恒为静止总高；放大形变全部收在槽内偏移与 scale
                ZStack(alignment: .top) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        tick(item, slot: model.slots[index])
                    }
                }
                .frame(width: railWidth, height: model.restHeight, alignment: .top)
                .offset(y: model.containerTop - trackTop)
            }
            .frame(width: trackWidth, height: trackHeight, alignment: .topTrailing)
            // 单一跟踪面：覆盖整个交互区（接近带 + 轨体），tick 是其后代 →
            // 光标在带内任意位置 hover 连续；点击仍由 tick 自身的 tap 手势命中
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let y = location.y + trackTop  // 带局部 → 几何区坐标系
                    cursorY = y
                    updateHover(at: CGPoint(x: location.x, y: y), model: model)
                    if magnifyAmount < 1 {
                        withAnimation(.easeOut(duration: Theme.Motion.chatTickMagnifyIn)) {
                            magnifyAmount = 1
                        }
                    }
                case .ended:
                    withAnimation(.easeOut(duration: Theme.Motion.chatTickMagnifyOut)) {
                        magnifyAmount = 0
                        hoveredTickId = nil
                    }
                }
            }
            .position(x: geo.size.width - trackWidth / 2, y: trackTop + trackHeight / 2)
        }
    }

    /// 跟踪坐标派生 hover：命中槽含光标即点亮该 tick；变化才写状态（去抖防每帧 setState）。
    /// 刻意裸写不走 withAnimation——胶囊过渡由 tick 内层 .animation(_:value:) 承担，
    /// 本路径若带动画事务会染指同一渲染帧里的槽位布局（放大跟手性受损）。
    private func updateHover(at location: CGPoint, model: ChatTickRailLayout) {
        let newId = model.hoveredIndex(at: location, trackWidth: trackWidth, railWidth: railWidth)
            .map { items[$0].id }
        guard newId != hoveredTickId else { return }
        hoveredTickId = newId
    }

    /// 单枚 tick：默认 10×2 圆头；当前查看条 16×3 accent 点亮（锚点，钉死不动）；
    /// 普通 tick 明暗随槽位梯度输出（光标正下方最亮、远端更暗）；点击直达该条消息。
    /// 命中区 = Voronoi 槽（随放大同步长大、槽间无缝），胶囊视觉锚定槽心、scaleEffect 放大。
    /// 动画作用域纪律：`.animation(_:value:)` 只罩颜色/胶囊/缩放内层（hover 变化帧才生效）；
    /// 槽位 offset/frame 外壳零动画修饰——光标移动帧的布局即时跟随，绝不橡胶延迟。
    @ViewBuilder
    private func tick(_ item: Item, slot: ChatTickRailLayout.Slot) -> some View {
        let hovered = hoveredTickId == item.id
        let baseWidth = item.isCurrent ? Theme.Layout.chatTickActiveWidth : Theme.Layout.chatTickWidth
        let baseHeight = item.isCurrent ? Theme.Layout.chatTickActiveHeight : Theme.Layout.chatTickHeight
        Capsule(style: .continuous)
            .fill(item.isCurrent ? Theme.Colors.accent : Color.primary.opacity(slot.opacity))
            .frame(width: baseWidth, height: baseHeight)
            .scaleEffect(slot.scale)
            .overlay(alignment: .trailing) {
                // 预览胶囊：hover 弹出，锚定放大后 tick 左侧（overlay trailing = 垂直中心
                // 即 tick 视觉中心）；空文本（纯图片等）消息不弹胶囊；纯展示不吞命中
                if hovered && !item.preview.isEmpty {
                    tickPreviewCapsule(item.preview)
                        .padding(.trailing, baseWidth * slot.scale + Theme.Layout.chatTickPreviewGap)
                        .transition(.opacity.combined(with: .offset(x: 5)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: Theme.Motion.chatTickHoverFade), value: hovered)
            .animation(.easeOut(duration: Theme.Motion.chatTickHoverFade), value: item.isCurrent)
            // —— 以下外壳定位属性无动画修饰覆盖：光标驱动即时跟随 ——
            // 视觉锚定槽心（命中槽与视觉中心在轨端略有错位，故不用槽 frame 的中心对齐）
            .offset(y: slot.center - slot.frameTop - baseHeight / 2)
            .frame(width: railWidth, height: slot.frameHeight, alignment: .topTrailing)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(item.id) }
            // 刻意不挂 .help()——系统 tooltip 与预览胶囊语义冗余，且贴右缘没有 tip 落点空间
            .offset(y: slot.frameTop)
    }

    /// 预览胶囊：深面板底 + 0.5pt 描边 + 8pt 圆角 + 轻投影，白字单行截断；
    /// 右端小三角指回 tick（方向性锚点）。
    ///
    /// 布局关键（空壳事故根因）：本视图挂在 tick 的 overlay 里，SwiftUI overlay 会把
    /// 宿主 tick 的窄尺寸（≈10~16pt）作为宽度 proposal 传进来，Text 会被压扁截断、
    /// 只剩描边空壳。修复 = 先 frame(maxWidth:) 再 fixedSize：fixedSize 让本视图忽略
    /// 宿主 proposal，frame(maxWidth:) 在自由 proposal 下把超长文本钳到上限截断。
    /// 顺序不可换（fixedSize 在前会让 frame 重新收到窄 proposal，前功尽弃）。
    private func tickPreviewCapsule(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.text(Theme.Typography.footnote))
            .foregroundColor(Theme.Colors.contentPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Theme.Layout.chatTickPreviewMaxWidth - Theme.Spacing.xl * 2)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.previewCapsule, style: .continuous)
                    .fill(Theme.Colors.chatNavFloatFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.previewCapsule, style: .continuous)
                    .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
            )
            .overlay(alignment: .trailing) {
                TickPreviewTail()
                    .fill(Theme.Colors.chatNavFloatFill)
                    .frame(width: 5, height: 8)
                    .offset(x: 4.5)
            }
            .shadow(color: .black.opacity(Theme.Shadow.navFloatOpacity),
                    radius: Theme.Shadow.navFloatRadius,
                    y: Theme.Shadow.navFloatY)
    }
}

// MARK: - 手动虚拟化行容器

/// 行级「实渲染 ↔ 等高占位」切换容器：窗口内（或首见无缓存）实渲染；窗口外用缓存
/// 高度的**等高占位**。占位高度 = 实测缓存高度 → 切换零位移 → document 高度恒稳。
/// 这是 LazyVStack 黑盒行估算的替代：macOS 13 上 LazyVStack 回收远行的估算归零/
/// 失准，实例化-回收的「估算↔真实」差一次性结算成万级 pt 的 doc 骤变（日志定证
/// -14306 → 视口瞬移 14053 = 「上滚跳过数条消息」的最终根因，塌缩瞬间零子视图
/// 回退事件、视频无占位闪现——纯行级估算结算）。窗口集合与高度缓存由
/// SessionMessageList.updateRowFrames 的行级几何信号维护。
@MainActor
struct ChatVirtualRow<Content: View>: View {
    let messageId: UUID
    @Binding var rowHeights: [UUID: CGFloat]
    let inWindow: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            // 首见（无缓存）恒实渲染：几何信号测得高度回写缓存后，离开窗口才切占位。
            if inWindow || rowHeights[messageId] == nil {
                content()
            } else if let height = rowHeights[messageId] {
                Color.clear.frame(height: height)
            }
        }
        // 实渲染 ↔ 占位是内容等效替换：禁动画防闪烁与 CA 事务竞态（历史白屏族防线）。
        // 行 id（message.id）恒定；消息入场 transition 保留在 content 内部。
        .transaction { $0.animation = nil }
    }
}

// MARK: - 浏览导航预览胶囊小三角

/// 预览胶囊右端指向 tick 的小三角（方向性锚点）。
struct TickPreviewTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
