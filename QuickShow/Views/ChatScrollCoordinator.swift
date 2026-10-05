// 从 AIChatScrollNavigation.swift 机械拆分：AI 会话滚动与浏览导航——滚动协调中枢 / AppKit 桥 / 虚拟化行。

import AppKit
import SwiftUI

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
