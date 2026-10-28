// 从 AIChatView.swift 机械拆分：AI 会话布局支撑（通知名 / 消息分组缓存 / 滚动快照 / 行几何与预热签名 / 阅读列约束 / 面板圆角裁剪）。

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// 抽屉关闭后请求主输入框恢复第一响应者（AIChatView 发布，ChatInputTextView 观察）。
    static let aiChatRefocusInput = Notification.Name("aiChat.refocusInput")
    /// AI 窗呼出完成后强制主输入框接管第一响应者（AIWindowManager.show 发布，ChatInputTextView 观察）。
    /// 区别于 refocusInput 的让位语义：NSWindow 隐藏不清 firstResponder，侧栏搜索/重命名
    /// 持焦后关窗会让复开时的 didBecomeKey 兜底永久让位；「呼出即打字」是硬预期，
    /// 此处无条件聚焦（抽屉展开期间例外，焦点留给抽屉交互）。
    static let aiChatForceFocusInput = Notification.Name("aiChat.forceFocusInput")
    /// Quick Switcher 键盘导航信号（上下高亮移动与回车选择）
    static let aiChatQuickSwitcherUp = Notification.Name("aiChat.quickSwitcherUp")
    static let aiChatQuickSwitcherDown = Notification.Name("aiChat.quickSwitcherDown")
    static let aiChatQuickSwitcherSelect = Notification.Name("aiChat.quickSwitcherSelect")
    /// Quick Switcher 快捷删除高亮会话（⌃D / ⌘⌫）
    static let aiChatQuickSwitcherDelete = Notification.Name("aiChat.quickSwitcherDelete")
    /// AI 运行模式变更通知（单 Agent / 多 Agent 协作模式切换时广播）
    static let aiExecutionModeDidChange = Notification.Name("aiChat.executionModeDidChange")
    /// 请求平滑滚动并短暂高亮某条消息（点击引用预览时发布，SessionMessageList 观察）
    static let aiChatScrollToMessage = Notification.Name("aiChat.scrollToMessage")
    /// 触发 @ 引用确认通知（点击面板候选行时广播，ChatInputNSTextView 消费清理 @ 词）
    static let aiChatConfirmAtMention = Notification.Name("aiChat.confirmAtMention")
}

// MARK: - 划词局部引用调度中心与微型药丸

/// 划词引用调度中心：通过窗口事件监听与悬浮子面板（Child Window），实现 100% 稳定的划词悬浮引用按钮
@MainActor
final class ChatSelectionQuoteCoordinator: NSObject, ObservableObject {
    static let shared = ChatSelectionQuoteCoordinator()

    private var pillPanel: NSPanel?
    private var eventMonitor: Any?
    private weak var activeTextView: NSTextView?
    @Published var selectedText: String = ""

    override private init() {
        super.init()
        setupEventMonitor()
    }

    /// 启动全局鼠标与滚动监控（单例常驻）
    private func setupEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseUp {
                DispatchQueue.main.async {
                    self.evaluateCurrentSelection()
                }
            } else if event.type == .scrollWheel {
                // 滚动时不消失：实时更新药丸位置，跟随选区移动（取消划词才消失）
                if self.pillPanel?.isVisible == true {
                    DispatchQueue.main.async {
                        self.evaluateCurrentSelection()
                    }
                }
            }
            return event
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollViewDidScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: nil
        )
    }

    @objc private func handleScrollViewDidScroll(_ note: Notification) {
        if pillPanel?.isVisible == true {
            evaluateCurrentSelection()
        }
    }

    /// 针对特定文本视图精确评估划词选区
    func evaluateSelection(in textView: NSTextView) {
        if textView is ChatInputNSTextView {
            hidePill()
            return
        }
        let range = textView.selectedRange()
        // 核心准则：只有选区为空（取消划词）才消失
        guard range.length > 0 else {
            hidePill()
            return
        }
        guard let fullString = textView.string as NSString?,
              range.location + range.length <= fullString.length else {
            hidePill()
            return
        }
        let text = fullString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            hidePill()
            return
        }
        guard let window = textView.window ?? NSApp.keyWindow,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            hidePill()
            return
        }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height

        // 视口可见性约束：若所在滚动容器视口中选区已被滚出视野，则隐藏
        if let clipView = textView.enclosingScrollView?.contentView {
            let rectInClip = textView.convert(rect, to: clipView)
            let visibleRect = clipView.bounds
            if rectInClip.maxY < visibleRect.minY || rectInClip.minY > visibleRect.maxY {
                hidePill()
                return
            }
        }

        self.activeTextView = textView
        let rectInWindow = textView.convert(rect, to: nil)
        let rectInScreen = window.convertToScreen(rectInWindow)

        showPill(text: text, anchorScreenRect: rectInScreen, parentWindow: window)
    }

    /// 检查当前聚焦窗口与活动文本视图中的选区
    func evaluateCurrentSelection() {
        if let active = activeTextView, active.window != nil {
            evaluateSelection(in: active)
            return
        }
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
            evaluateSelection(in: tv)
            return
        }
        hidePill()
    }

    private func ensurePanel() -> NSPanel {
        if let pillPanel { return pillPanel }
        // 预留充足透明留白（116 x 52），彻底消除阴影被窗口边界截断产生的直角黑边
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 116, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // 关键防线：严禁开启 borderless 窗口的 hasShadow，否则 WindowServer 会绘制矩形死黑投影外框
        panel.hasShadow = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: FloatingQuotePillContentView())
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        self.pillPanel = panel
        return panel
    }

    func showPill(text: String, anchorScreenRect: NSRect, parentWindow: NSWindow) {
        selectedText = text
        let panel = ensurePanel()
        let panelW: CGFloat = 116
        let panelH: CGFloat = 52

        // 窗口尺寸内含充足透明呼吸间距，使药丸视觉中心恰好悬停在选区上方 8pt 处
        var pillX = anchorScreenRect.midX - panelW / 2
        var pillY = anchorScreenRect.maxY - 4

        // 窗口边缘防溢出约束
        if let screen = parentWindow.screen ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            pillX = max(visibleFrame.minX + 8, min(pillX, visibleFrame.maxX - panelW - 8))
            // 若上方空间不足以容纳药丸，则智能沉降到选区下方
            if pillY + panelH > visibleFrame.maxY - 8 {
                pillY = anchorScreenRect.minY - panelH + 4
            }
        }

        panel.setFrame(NSRect(x: pillX, y: pillY, width: panelW, height: panelH), display: true)
        if panel.parent !== parentWindow {
            if let oldParent = panel.parent {
                oldParent.removeChildWindow(panel)
            }
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        EscapePolicyCenter.shared.push(scope: .chat, id: "selection_quote_pill") { [weak self] in
            guard let self, self.pillPanel?.isVisible == true else { return false }
            if let tv = self.activeTextView {
                let loc = tv.selectedRange().location
                tv.setSelectedRange(NSRange(location: loc != NSNotFound ? loc : 0, length: 0))
            }
            self.hidePill()
            return true
        }
    }

    func hidePill() {
        EscapePolicyCenter.shared.pop(scope: .chat, id: "selection_quote_pill")
        guard let panel = pillPanel, panel.isVisible else {
            selectedText = ""
            activeTextView = nil
            return
        }
        panel.orderOut(nil)
        selectedText = ""
        activeTextView = nil
    }

    func commitQuote() {
        guard !selectedText.isEmpty else { return }
        let quoteText = selectedText
        let tv = activeTextView
        AIChatState.shared.setQuote(text: quoteText, role: .assistant)
        // 核心诉求：点击引用后，取消文本划词选区
        if let tv {
            let loc = tv.selectedRange().location
            tv.setSelectedRange(NSRange(location: loc != NSNotFound ? loc : 0, length: 0))
        }
        // 引用药丸消失
        hidePill()
        // 输入坞获取光标并聚焦
        NotificationCenter.default.post(name: .aiChatForceFocusInput, object: nil)
    }
}

/// 划词悬浮微型小药丸内容视图
struct FloatingQuotePillContentView: View {
    @ObservedObject private var coordinator = ChatSelectionQuoteCoordinator.shared
    @State private var isHovered = false

    var body: some View {
        Button {
            coordinator.commitQuote()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "quote.opening")
                    .font(Theme.Typography.text(10, .bold))
                Text(String(localized: "引用"))
                    .font(Theme.Typography.text(11, .semibold))
            }
            .foregroundColor(isHovered ? Theme.Colors.accent : Theme.Colors.contentPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                ZStack {
                    Capsule().fill(Color(nsColor: .windowBackgroundColor))
                    Capsule().fill(.regularMaterial)
                    Capsule().fill(Theme.Colors.chatBase.opacity(0.92))
                }
            )
            .overlay(
                Capsule().strokeBorder(Theme.Colors.accent.opacity(isHovered ? 0.75 : 0.35), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

// MARK: - 单条消息

/// 连续同角色消息组（消息列表分组渲染用；id 取首条消息 id 保证身份稳定）。
struct MessageGroup: Identifiable {
    let id: UUID
    let role: ChatMessage.Role
    var messages: [ChatMessage]
}

/// 消息分组缓存：messages 底层存储未变时复用上次分组结果，避免隐藏会话随 store 扇出
/// 重求值时每次 body 都做 O(n) 全量分组。
/// 判定用「持有同一份 messages 值 + 同 buffer 地址 + 同长度」：缓存持有值会保持该 buffer
/// 的引用，store 后续修改必触发 COW 换 buffer，故地址+长度相同即内容相同。O(1)，
/// 比逐字段 Equatable（含图片 base64/长文本）便宜且同样可靠。
final class MessageGroupingCache {
    private var cachedMessages: [ChatMessage] = []
    private var cachedGroups: [MessageGroup] = []

    func groups(for messages: [ChatMessage]) -> [MessageGroup] {
        if !messages.isEmpty,
           messages.count == cachedMessages.count,
           sameStorage(messages, cachedMessages) {
            return cachedGroups
        }
        cachedMessages = messages
        cachedGroups = Self.group(messages)
        return cachedGroups
    }

    /// 两数组是否共享同一底层存储 buffer（值语义下即同内容）。
    private func sameStorage(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> Bool {
        lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                left.baseAddress == right.baseAddress
            }
        }
    }

    private static func group(_ messages: [ChatMessage]) -> [MessageGroup] {
        var groups: [MessageGroup] = []
        for message in messages {
            if let last = groups.last, last.role == message.role, message.role != .system {
                groups[groups.count - 1].messages.append(message)
            } else {
                groups.append(MessageGroup(id: message.id, role: message.role, messages: [message]))
            }
        }
        return groups
    }
}

/// 单会话滚动快照：切走时记录，切回时据此恢复阅读位置。
struct ScrollSnapshot {
    /// 离开时数组序最靠前的可见消息 id（nil 表示当时无可见消息）。
    var topVisibleMessageID: UUID?
    /// 离开时是否处于贴底跟随态（pinned）；true 则切回贴底，false 则回到锚点。
    var isPinned: Bool
}

// MARK: - 消息行几何信号（诚实视口锚点）

/// 每个已实现化消息行上报其在本实例滚动视口坐标系中的 frame（`[messageID: CGRect]`）。
/// 关键：preference 每次布局**全量重算**，reduce 合并出的字典 = 当前帧真实已实现行集合
/// （不像行级 onAppear/onDisappear 那样只增不减），据此可算出真实「视口首个可见消息」。
struct MessageRowFramePreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - 公式预热去重签名

/// 会话 latex 预热签名：消息条数 + 内容总字符 + 末条 id。未变则复用上次收集结果、跳过重复收集。
struct LatexPrefetchSignature: Equatable {
    var messageCount: Int
    var totalChars: Int
    var lastMessageID: UUID?
}

// MARK: - 面板圆角裁剪（统一路径）
// 整窗 glass 已移除后，窗口层圆角由 PanelHostingConfigurator 在 AppKit 根图层统一施加；
// 这里再对 SwiftUI 内容做一次同半径裁剪，保证自绘内容不越界。
struct AIChatRoundedClip: ViewModifier {
    func body(content: Content) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }
}

// MARK: - 阅读列约束（消息列 / 输入坞 / 浮动导航簇共用）

/// 内容区宽度上报键（阅读列水平边距分级的输入信号）。
struct ChatReadingColumnWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 阅读列统一约束：限宽 `Theme.Layout.chatContentMaxWidth` 居中 + 水平边距分级
/// （内容区 <720pt 用 `Spacing.section`=18 即默认窗现状；≥720pt 升为 28，宽窗保留玻璃呼吸边）。
/// 刻度轨（宽 10~19pt，贴右缘 4pt）静止时完全容纳于右侧 18pt 边距内，消除双侧额外 28pt 内缩，
/// 内容与输入坞自然舒展。各应用点（消息列/输入坞/回底钮/顶栏图钉）共用本修饰器，列左缘/右缘对齐逻辑单一来源、永不漂移。
///
/// 宽度读取走 background GeometryReader + preference：部署目标 macOS 13 不可用
/// onGeometryChange（14+）；GeometryReader 挂 background 内尺寸被前景约束（最外层撑满帧），
/// 无 ScrollView 内直接嵌 GeometryReader 的高度提议风险。padding 跳变不回读最外层宽度
/// （maxWidth: .infinity 层宽度只取决于父级提议），无反馈环。
/// 已知行为：冷启动首帧 preference 尚未上报时按窄档 18 上屏，次帧修正为宽档（仅窗口
/// ≥720pt 首建时发生一次 ~1 帧的列定锚；面板复用/LRU 常驻路径 @State 已持正确值，不跳变）。
struct ChatReadingColumn: ViewModifier {
    /// 列内内容对齐：消息列/输入坞 leading，浮动导航簇 trailing（贴列右缘）。
    let alignment: Alignment
    /// 内容区实测宽度（最外层撑满帧的几何读数），驱动水平边距分级。
    @State private var containerWidth: CGFloat = 0

    private var horizontalPadding: CGFloat {
        // 断点比较留 1pt 容差（死区）：⌘B 侧栏展开时窗口 +216 且主列宽度补偿后为 W−0.5，
        // 窗口恰停在 720 附近时精确 `>= 720` 会让每次侧栏切换在 18↔28 档位间翻转 →
        // 整列重排。容差仅 1pt，视觉影响为零，只吸收这 0.5pt 的宽度补偿抖动。
        containerWidth >= Theme.Layout.chatReadingWideBreakpoint - 1
            ? Theme.Layout.chatReadingWidePadding
            : Theme.Spacing.section
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: Theme.Layout.chatContentMaxWidth, alignment: alignment)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ChatReadingColumnWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(ChatReadingColumnWidthKey.self) { containerWidth = $0 }
    }
}

extension View {
    /// 阅读列统一约束（限宽居中 + 水平边距分级），详见 `ChatReadingColumn`。
    func chatReadingColumn(alignment: Alignment = .leading) -> some View {
        modifier(ChatReadingColumn(alignment: alignment))
    }
}

// MARK: - 会话侧栏可拖拽微光分割线

/// 侧栏分割线底层的 AppKit 事件与光标处理视图。
/// 采用原生 resetCursorRects 保证光标实时响应且绝对零泄漏；
/// 捕获 mouseDown / mouseDragged / mouseUp 驱动增量宽度变化，双击触发复位。
final class SidebarDividerHandleNSView: NSView {
    var onWidthDelta: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private var initialMouseX: CGFloat = 0
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        isDragging = true
        initialMouseX = event.locationInWindow.x
        NSCursor.resizeLeftRight.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let currentX = event.locationInWindow.x
        let delta = currentX - initialMouseX
        initialMouseX = currentX
        onWidthDelta?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            NSCursor.pop()
            onDragEnded?()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil && isDragging {
            isDragging = false
            NSCursor.pop()
        }
    }
}

/// AppKit 分割线拖拽热区桥接。
struct SidebarDividerHandleRepresentable: NSViewRepresentable {
    var onWidthDelta: (CGFloat) -> Void
    var onDragEnded: () -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> SidebarDividerHandleNSView {
        let view = SidebarDividerHandleNSView(frame: .zero)
        view.onWidthDelta = onWidthDelta
        view.onDragEnded = onDragEnded
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: SidebarDividerHandleNSView, context: Context) {
        nsView.onWidthDelta = onWidthDelta
        nsView.onDragEnded = onDragEnded
        nsView.onDoubleClick = onDoubleClick
    }
}

/// 侧栏微光分割线：0.5pt 两端羽化细线 + 居中 8pt 交互热区（支持悬停光标、拖拽调宽与双击复位）。
struct SidebarDivider: View {
    @Binding var sidebarWidth: CGFloat
    let onDragEnded: () -> Void
    let onDoubleClick: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.0),
                            Color.primary.opacity(Theme.Colors.dividerOpacity),
                            Color.primary.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: Theme.Layout.dividerHeight)

            SidebarDividerHandleRepresentable(
                onWidthDelta: { delta in
                    let newWidth = sidebarWidth + delta
                    let clamped = min(max(newWidth, AIChatLayout.minSidebarWidth), AIChatLayout.maxSidebarWidth)
                    sidebarWidth = clamped
                },
                onDragEnded: onDragEnded,
                onDoubleClick: onDoubleClick
            )
            .frame(width: AIChatLayout.dividerInteractiveWidth)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - 自适应限高滚动通用容器（替代传统 OOP 继承基类）

private struct AdaptiveScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 统一的自适应限高滚动容器（替代传统 OOP 父类）：
/// - 内部自动测量内容实际物理高度；
/// - 内容高度 ≤ maxHeight 时：高度完全由内容撑开（shrink-to-fit），绝无多余留白，且不触发内部滚动；
/// - 内容高度 > maxHeight 时：高度锁定在 maxHeight，内部优雅滚动（原生 macOS 细滚动条）；
/// - 支持 .horizontal、.vertical 或双向 [.horizontal, .vertical] 滚动。
struct AdaptiveScrollBox<Content: View>: View {
    let axes: Axis.Set
    let maxHeight: CGFloat
    let showsIndicators: Bool
    @ViewBuilder let content: () -> Content

    @State private var measuredHeight: CGFloat = 0

    init(
        axes: Axis.Set = .vertical,
        maxHeight: CGFloat,
        showsIndicators: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.axes = axes
        self.maxHeight = maxHeight
        self.showsIndicators = showsIndicators
        self.content = content
    }

    var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: AdaptiveScrollContentHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .frame(height: measuredHeight > 0 ? min(measuredHeight, maxHeight) : nil)
        .frame(maxHeight: maxHeight)
        .onPreferenceChange(AdaptiveScrollContentHeightKey.self) { h in
            if h > 0 { measuredHeight = h }
        }
    }
}
