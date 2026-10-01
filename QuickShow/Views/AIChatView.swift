import AppKit
import Combine
import SwiftUI

/// AI 对话视图（Lane C）：将嵌入 NSHostingView，由 AIWindowManager 管理外窗尺寸与焦点。
/// 视觉全部走 DesignTokens 既有令牌（本文件严禁新增令牌——Lane B 并行维护 DesignTokens）。
///
/// Wave 2 结构：
/// - 左侧会话窄栏（⌘B 显隐，展开时窗口整体加宽，见 AIWindowManager.setSidebarVisible）
/// - 消息列表：hover 渐显操作条（复制；最后一条落定助手消息附「重新生成」）
/// - 输入卡：⊕ 图片附件菜单 + 模型 chip + 剪贴板附加 + 发送/中止
/// - 快捷键 ⌘N/⌘B/⌘F 由 AIChatKeyMonitor（本地事件监听）接线；ESC/⌘K 仍走窗口层
///
/// 公开接口（接线用）：
/// - `state`：会话状态（AIChatState.shared）。
/// - `onOpenSettings`：未配置引导卡片「打开设置…」的出口（注入 AppState.openSettings）。
/// - `onClose`：输入框聚焦时 ESC 的兜底出口（注入 AIWindowManager 的关窗逻辑）。
/// 标注 @MainActor：AIChatState 全程 @MainActor，视图与状态同隔离域，消除 actor 隔离错误。
@MainActor
struct AIChatView: View {
    @ObservedObject var state: AIChatState
    var onOpenSettings: (() -> Void)?
    var onClose: (() -> Void)?

    init(state: AIChatState, onOpenSettings: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.state = state
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
        // 侧栏显隐偏好与 AIWindowManager 共用同一 UserDefaults 键（窗口首次取尺寸早于视图出现）
        _sidebarVisible = State(initialValue: UserDefaults.standard.bool(forKey: AIWindowManager.sidebarVisibleKey))
    }

    /// 输入框占位文案（⏎/⇧⏎/ESC 语义提示）。
    private let inputPlaceholder = "问点什么…（⏎ 发送 · ⇧⏎ 换行 · ESC 关闭）"
    /// 滚动到底部的锚点 id。
    private let bottomAnchorID = "aiChat.bottom"

    /// 端点配置可用性：hasConfiguredEndpoint 读 UserDefaults/Keychain，非 @Published，
    /// 故在视图出现与关键窗口激活时主动刷新（避免设置后回到对话窗仍显示引导）。
    @State private var configured = false
    /// 剪贴板是否有可用文本（控制剪贴板按钮弱化不可点）。
    @State private var hasClipboardText = false
    /// 剪贴板是否有可用图片（控制 ⊕ 菜单「剪贴板导入」可用态）。
    @State private var hasClipboardImage = false
    /// 流式滚动节流时间戳：token 高频到达时限制滚动频率，避免每 token 触发布局重排。
    @State private var lastAutoScrollAt: Date = .distantPast
    /// 会话窄栏显隐（持久化到 UserDefaults，窗口宽度联动见 AIWindowManager）。
    @State private var sidebarVisible = false
    /// ⌘F 聚焦令牌：递增即让侧栏搜索框聚焦。
    @State private var searchFocusRequest = 0
    /// 行内重命名进行中的会话 id（非 nil 时 ESC 优先取消重命名，由按键监听消费）。
    @State private var renamingSessionId: UUID?
    /// 点击放大预览的图片附件（非 nil 时显示覆盖层，ESC/点击关闭）。
    @State private var zoomedAttachment: ChatImageAttachment?
    /// 模型列表与当前选中（AIChatService 非 @Published，随环境刷新主动拉取）。
    @State private var modelList: [AIModel] = []
    @State private var selectedModelId: String = ""
    /// AI 窗快捷键监听（⌘N/⌘B/⌘F + 重命名/放大态下的 ESC 先行消费）。
    @State private var keyMonitor = AIChatKeyMonitor()

    var body: some View {
        HStack(spacing: 0) {
            // 左侧会话窄栏（⌘B 显隐；窗口宽度由 AIWindowManager 同步加宽/收窄）
            if sidebarVisible {
                AIChatSidebarView(
                    store: state.store,
                    searchFocusRequest: searchFocusRequest,
                    renamingSessionId: $renamingSessionId,
                    onSelect: { id in state.selectSession(id: id) },
                    onNewSession: { newSession() }
                )
                .transition(.opacity)

                // 竖向细分割线（与横分割线同款两端羽化语言）
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
            }

            mainColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // 复刻主面板做法：26+ 材质由窗口层 NSGlassEffectView 统一提供，内容背景透明；
            // 13~25 降级用原生超薄材质（随系统明暗翻转）
            if #available(macOS 26.0, *) {
                Color.clear
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        // 图片点击放大覆盖层（轻量自实现；ESC 由 keyMonitor 先行消费关闭）
        // 注意顺序：overlay 必须写在圆角裁剪之前，否则 13~25 降级路径下覆盖层会是直角
        .overlay {
            if let zoomed = zoomedAttachment {
                ImageZoomOverlay(attachment: zoomed) {
                    withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                        zoomedAttachment = nil
                    }
                }
            }
        }
        .modifier(AIChatRoundedClip())
        .onAppear {
            refreshEnvironment()
            installKeyMonitor()
        }
        .onDisappear { keyMonitor.remove() }
        // 回到/激活 AI 窗口时刷新配置与剪贴板可用态（设置窗口改动后可即时生效）
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshEnvironment()
        }
    }

    // MARK: - 主列（对话区 + 输入区）

    private var mainColumn: some View {
        VStack(spacing: 0) {
            // 三态：未配置引导 / 空态欢迎页 / 消息列表
            if !configured && state.messages.isEmpty {
                UnconfiguredGuideView(onOpenSettings: onOpenSettings)
            } else if state.messages.isEmpty {
                WelcomeView(
                    hasClipboardText: hasClipboardText,
                    onAttachClipboard: { attachClipboard() }
                )
            } else {
                messageList
            }

            // 细若游丝的分割线（复刻主面板语言）：分隔对话区与输入区
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.0),
                            Color.primary.opacity(Theme.Colors.dividerOpacity),
                            Color.primary.opacity(0.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: Theme.Layout.dividerHeight)
                .padding(.horizontal, Theme.Spacing.panel)

            inputArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 高不透明底板（≥90%）：稳定阅读区，压住玻璃穿透导致的文字对比度波动；
        // 半透明只留给窗体外缘（玻璃/材质边缘），层级靠深浅差而非透明度叠加
        .background(Theme.Colors.chatBase)
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // 连续同角色消息成组：组间距 26 明显大于组内间距 8，形成分组呼吸感
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(groupMessages(state.messages)) { group in
                        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                            ForEach(group.messages) { message in
                                ChatMessageRow(
                                    message: message,
                                    // 仅最后一条已落定/已中止的助手消息附「重新生成」
                                    canRegenerate: message.id == lastRegeneratableAssistantId,
                                    onRetry: { state.retryLast() },
                                    onRegenerate: { state.retryLast() },
                                    onTapImage: { attachment in
                                        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                                            zoomedAttachment = attachment
                                        }
                                    }
                                )
                                // .equatable()：message 未变的历史行直接跳过重建，
                                // 流式期间仅最后一行 diff（配合 State 单条 mutate，避免全列表重排/重渲染）
                                .equatable()
                                // 以稳定 id 渲染；State 只 mutate content，不改 id
                                .id(message.id)
                            }
                        }
                    }
                    // 底部不可见锚点：滚动目标
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.section)
                .padding(.vertical, Theme.Spacing.section)
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
            // 新消息落定：动画滚到底
            .onChange(of: state.messages.count) { _ in
                scrollToBottom(proxy, animated: true)
            }
            // 流式增量：内容变化触发，节流 0.12s + 非动画滚动（避免每 token 抖动）
            .onChange(of: state.messages.last?.content) { _ in
                guard state.isStreaming else { return }
                let now = Date()
                guard now.timeIntervalSince(lastAutoScrollAt) > 0.12 else { return }
                lastAutoScrollAt = now
                scrollToBottom(proxy, animated: false)
            }
            // 流式结束：补一次动画滚动，确保末尾完整可见
            .onChange(of: state.isStreaming) { streaming in
                if !streaming { scrollToBottom(proxy, animated: true) }
            }
        }
    }

    /// 连续同角色消息分组（组 id 取首条消息 id，保证 SwiftUI 身份稳定不闪动）。
    private func groupMessages(_ messages: [ChatMessage]) -> [MessageGroup] {
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

    /// 最后一条可重新生成的助手消息 id（落定或中止态；失败态气泡内已有重试按钮，不重复提供）。
    private var lastRegeneratableAssistantId: UUID? {
        guard !state.isStreaming else { return nil }
        return state.messages.last { message in
            guard message.role == .assistant else { return false }
            switch message.state {
            case .done, .aborted: return true
            default: return false
            }
        }?.id
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    // MARK: - 输入区

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // 待发送图片附件条：缩略图胶囊横排，可单个移除
            if !state.imageAttachments.isEmpty {
                ImageAttachmentStrip(attachments: state.imageAttachments) { id in
                    state.removeImageAttachment(id: id)
                }
            }

            // 剪贴板附加胶囊：非 nil 时显示，可一键移除
            if let clip = state.clipboardAttachment {
                ClipboardAttachmentCapsule(charCount: clip.count) {
                    state.removeClipboardAttachment()
                }
            }

            // 输入卡：文本区 + 底部工具行（⊕ 附件 / 模型 chip / 剪贴板 / 发送）
            VStack(spacing: 0) {
                // 输入框：NSViewRepresentable 包装 NSTextView（自定义 ⏎/⇧⏎ 与中文 IME 组字语义）
                ZStack(alignment: .topLeading) {
                    ChatInputTextView(
                        text: $state.inputText,
                        onSubmit: { state.send() },
                        onEscape: { handleEscape() },
                        onInsertImages: { images in insertImages(images) }
                    )
                    if state.inputText.isEmpty {
                        Text(inputPlaceholder)
                            .font(Theme.Typography.text(13))
                            .foregroundColor(Theme.Colors.idleText)
                            .padding(.horizontal, Theme.Spacing.xxl)
                            .padding(.vertical, Theme.Spacing.xl)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 56)

                HStack(spacing: Theme.Spacing.lg) {
                    attachMenuButton
                    modelChip
                    Spacer(minLength: 0)
                    clipboardButton
                    sendButton
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.lg)
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    // 输入卡比主区底板亮一档半：操作焦点明确可辨（原 surfaceInset 与主背景几乎无差）
                    .fill(Theme.Colors.chatInputCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
            )
            // 拖到输入卡边缘 padding 区也能接住（主路径在 NSTextView 子类）
            .onDrop(of: ["public.image", "public.file-url"], isTargeted: nil) { providers in
                handleDropProviders(providers)
            }

            // 快捷键提示行：与输入卡之间以羽化 hairline 分隔，整体再弱一档，不与输入卡混为一体
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.0),
                            Color.primary.opacity(Theme.Colors.dividerOpacity * 0.6),
                            Color.primary.opacity(0.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: Theme.Layout.dividerHeight)
                .padding(.horizontal, Theme.Spacing.xxl)

            HStack(spacing: Theme.Spacing.lg) {
                // ⌘K 清空：弱化图标钮（快捷键由窗口层处理，此处提供鼠标入口）
                Button {
                    state.clearSession()
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "trash")
                            .font(Theme.Typography.text(11, .medium))
                        Text("清空")
                            .font(Theme.Typography.text(11, .medium))
                    }
                    .foregroundColor(state.messages.isEmpty ? Theme.Colors.idleText.opacity(0.6) : Theme.Colors.contentTertiary)
                }
                .buttonStyle(.plain)
                .disabled(state.messages.isEmpty)
                .help("清空当前会话（⌘K 重新开始）")

                Spacer(minLength: 0)

                Text("⌘B 会话 · ⌘K 清空 · ESC 关闭")
                    .font(Theme.Typography.text(10.5))
                    .foregroundColor(Theme.Colors.idleText.opacity(0.85))
            }
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.top, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.xxl)
        // 鼠标进入输入区时刷新剪贴板可用态（覆盖"先复制、后移动鼠标到窗口"的常见路径）
        .onHover { _ in refreshClipboardAvailability() }
    }

    /// ⊕ 附件菜单：剪贴板导入 / 从文件选择…
    private var attachMenuButton: some View {
        Menu {
            Button {
                attachImageFromPasteboard()
            } label: {
                Label("剪贴板导入", systemImage: "photo.on.rectangle")
            }
            .disabled(!hasClipboardImage)

            Button {
                chooseImageFiles()
            } label: {
                Label("从文件选择…", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(Theme.Typography.text(13, .medium))
                .foregroundColor(Theme.Colors.iconRest)
                .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
                .background(Circle().fill(Theme.Colors.surfaceButton))
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("添加图片附件（也可直接粘贴或拖入）")
    }

    /// 模型 chip：胶囊显示当前模型，点击弹下拉切换（仅多模型时显示，单模型弱化隐藏）。
    @ViewBuilder
    private var modelChip: some View {
        if modelList.count > 1 {
            Menu {
                ForEach(modelList) { model in
                    Button {
                        selectModel(model)
                    } label: {
                        if model.modelId == selectedModelId {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(currentModelName)
                        .font(Theme.Typography.text(11, .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Theme.Typography.text(8, .medium))
                        .foregroundColor(Theme.Colors.idleText)
                }
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.xxxs)
                .frame(height: Theme.Layout.iconButtonSize)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.Colors.surfaceTrack)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("切换模型（下一轮对话生效）")
        }
    }

    private var currentModelName: String {
        if let matched = modelList.first(where: { $0.modelId == selectedModelId }) {
            return matched.name
        }
        return selectedModelId.isEmpty ? "模型" : selectedModelId
    }

    private var clipboardButton: some View {
        Button {
            attachClipboard()
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(Theme.Typography.text(13, .medium))
                .foregroundColor(hasClipboardText ? Theme.Colors.iconRest : Theme.Colors.idleText.opacity(0.5))
                .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
                .background(Circle().fill(Theme.Colors.surfaceButton))
        }
        .buttonStyle(.plain)
        .disabled(!hasClipboardText)
        .help("附加剪贴板内容作为上下文")
    }

    private var sendButton: some View {
        Button {
            if state.isStreaming {
                state.abortStreaming()
            } else {
                state.send()
            }
        } label: {
            Image(systemName: state.isStreaming ? "stop.fill" : "arrow.up")
                .font(Theme.Typography.text(13, .bold))
                .foregroundColor(sendButtonForeground)
                .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
                .background(Circle().fill(sendButtonFill))
        }
        .buttonStyle(.plain)
        .disabled(!state.isStreaming && !canSend)
        .help(state.isStreaming ? "中止生成" : "发送（⏎）")
    }

    // MARK: - 状态与动作

    private var canSend: Bool {
        !state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || state.clipboardAttachment != nil
            || !state.imageAttachments.isEmpty   // 纯图片也可发送
    }

    /// 发送键底：可用 = 主题强调色实心（琥珀/青），流式 = 警告红，禁用 = 灰底。
    private var sendButtonFill: Color {
        if state.isStreaming { return Theme.Colors.statusWarning.opacity(0.9) }
        return canSend ? Theme.Colors.accent : Theme.Colors.surfaceButton
    }

    /// 发送键图标：实心强调色底上取深色（琥珀/青均属亮色底，深图标对比最稳），
    /// 流式红底用白色；禁用态弱化灰。
    private var sendButtonForeground: Color {
        if state.isStreaming { return .white }
        if canSend { return Color.black.opacity(0.72) }
        return Theme.Colors.idleText
    }

    /// 刷新非 @Published 的外部环境：端点配置、剪贴板可用性、模型列表。
    private func refreshEnvironment() {
        configured = state.hasConfiguredEndpoint
        refreshClipboardAvailability()
        modelList = AIChatService.shared.modelList
        selectedModelId = AIChatService.shared.selectedModel
    }

    /// 单独刷新剪贴板可用态（轻量，供 hover/窗口激活调用）。
    private func refreshClipboardAvailability() {
        let clipboard = NSPasteboard.general
        let text = clipboard.string(forType: .string)
        hasClipboardText = !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        hasClipboardImage = PasteboardImageExtractor.containsImage(clipboard)
    }

    /// 附加剪贴板文本；失败（空剪贴板）时同步弱化按钮，做轻反馈。
    private func attachClipboard() {
        if !state.attachClipboard() {
            hasClipboardText = false
        }
    }

    /// 从剪贴板导入图片附件。
    private func attachImageFromPasteboard() {
        insertImages(PasteboardImageExtractor.images(from: NSPasteboard.general))
    }

    /// 从文件选择器导入图片附件。
    private func chooseImageFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "选择图片"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let attachment = ImageAttachmentProcessor.makeAttachment(fromFileURL: url) {
                state.addImageAttachment(attachment)
            }
        }
    }

    /// 粘贴/拖入图片的统一落点（编码失败静默跳过）。
    private func insertImages(_ images: [NSImage]) {
        for image in images {
            _ = state.addImage(image)
        }
    }

    /// SwiftUI 层拖放（输入卡边缘区域）：按 NSImage / 文件 URL 两类加载。
    private func handleDropProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { item, _ in
                    guard let image = item as? NSImage else { return }
                    DispatchQueue.main.async { [state] in
                        _ = state.addImage(image)
                    }
                }
            } else if provider.canLoadObject(ofClass: NSURL.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSURL.self) { item, _ in
                    guard let url = item as? URL else { return }
                    DispatchQueue.main.async { [state] in
                        if let attachment = ImageAttachmentProcessor.makeAttachment(fromFileURL: url) {
                            state.addImageAttachment(attachment)
                        }
                    }
                }
            }
        }
        return handled
    }

    private func selectModel(_ model: AIModel) {
        AIChatService.shared.selectedModel = model.modelId
        selectedModelId = model.modelId
    }

    /// 新建会话（⌘N 与侧栏按钮共用）：若正处于行内重命名则先退出。
    private func newSession() {
        renamingSessionId = nil
        _ = state.newSession()
    }

    /// 侧栏显隐切换（⌘B）：视图状态 + 窗口宽度联动（AIWindowManager 内写偏好并动画调宽）。
    private func toggleSidebar() {
        setSidebarVisible(!sidebarVisible)
    }

    private func setSidebarVisible(_ visible: Bool) {
        guard visible != sidebarVisible else { return }
        withAnimation(.easeOut(duration: Theme.Motion.windowResize)) {
            sidebarVisible = visible
        }
        AIWindowManager.shared.setSidebarVisible(visible)
    }

    // MARK: - 快捷键监听（⌘N/⌘B/⌘F + 重命名/放大态 ESC 先行消费）

    private func installKeyMonitor() {
        keyMonitor.isRenaming = { renamingSessionId != nil }
        keyMonitor.onCancelRename = { renamingSessionId = nil }
        keyMonitor.isZooming = { zoomedAttachment != nil }
        keyMonitor.onDismissZoom = {
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                zoomedAttachment = nil
            }
        }
        keyMonitor.onNewSession = { newSession() }
        keyMonitor.onToggleSidebar = { toggleSidebar() }
        // ⌘F：侧栏收起时先展开，再聚焦搜索框
        keyMonitor.onFocusSearch = {
            if !sidebarVisible { setSidebarVisible(true) }
            searchFocusRequest += 1
        }
        keyMonitor.install()
    }

    /// ESC 两阶段语义（输入框聚焦时的兜底路径）：① 流式中先中止生成；② 否则关窗还焦点。
    private func handleEscape() {
        if state.isStreaming {
            state.abortStreaming()
        } else {
            onClose?()
        }
    }
}

// MARK: - AI 窗快捷键监听

/// AI 窗级快捷键本地监听：⌘N 新会话 / ⌘B 侧栏显隐 / ⌘F 聚焦搜索。
/// 为什么不用 AIPanel.sendEvent 拦截：窗口层按键纪律（ESC/⌘K/文本聚焦放行）不允许改动；
/// 本地监听在 NSApplication 派发到窗口之前触发，既不动窗口层逻辑，又能覆盖
/// 「第一响应者非输入框」（如焦点在侧栏会话行）的路径。
/// 另承担两个 UI 态下的 ESC 先行消费：行内重命名中 → 取消重命名；图片放大中 → 关闭放大层。
/// 非隔离类：本地监听恒在主线程事件派发路径触发，回调直接执行，避免 NSEvent 跨隔离域。
final class AIChatKeyMonitor {
    private var monitor: Any?

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

        // ESC：仅在重命名/放大态下先行消费；其余放行给窗口层两阶段语义
        if event.keyCode == 53, flags.isEmpty {
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

// MARK: - 单条消息

/// 连续同角色消息组（消息列表分组渲染用；id 取首条消息 id 保证身份稳定）。
private struct MessageGroup: Identifiable {
    let id: UUID
    let role: ChatMessage.Role
    var messages: [ChatMessage]
}

private struct ChatMessageRow: View, Equatable {
    let message: ChatMessage
    /// 是否为最后一条可重新生成的助手消息（父视图计算，含流式中禁用语义）。
    let canRegenerate: Bool
    let onRetry: () -> Void
    let onRegenerate: () -> Void
    let onTapImage: (ChatImageAttachment) -> Void

    /// 仅按内容与可重生成标记判定相等：闭包语义跨渲染一致，忽略其对 diff 的干扰，
    /// 使 .equatable() 能在流式期间跳过未变更行。
    static func == (lhs: ChatMessageRow, rhs: ChatMessageRow) -> Bool {
        lhs.message == rhs.message && lhs.canRegenerate == rhs.canRegenerate
    }

    @State private var rowHovered = false
    @State private var pillHovered = false
    @State private var copied = false

    /// 操作条可见性：行 hover、操作条自身 hover（探出行外部分）、复制反馈期三任一。
    private var actionsVisible: Bool { rowHovered || pillHovered || copied }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: Theme.Spacing.panel) }
            content
            if message.role == .assistant { Spacer(minLength: Theme.Spacing.panel) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { rowHovered = hovering }
        }
        // hover 渐显操作条：浮起 pill 跨骑气泡下缘（一半在气泡 padding 区、一半探入下方间距），
        // 不占布局位——恒占位的做法会让同角色消息组的组内紧凑节奏失效
        .overlay(alignment: message.role == .user ? .bottomTrailing : .bottomLeading) {
            if actionsVisible, message.role != .system {
                actionPill
                    .offset(y: 10)
                    .transition(.opacity)
            }
        }
    }

    /// 浮动操作条：复制（成功变对勾轻反馈）；最后一条落定助手消息附「重新生成」。
    /// 实心底板 + 提亮描边 + 微阴影：跨骑气泡与行间空隙，需自身可辨（不靠背景衬托）。
    private var actionPill: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Button(action: copyContent) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(Theme.Typography.text(10, .medium))
                    .foregroundColor(copied ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                    .frame(width: 20, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("复制")

            if canRegenerate {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.Typography.text(10, .medium))
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .frame(width: 20, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("重新生成")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.Colors.chatInputCard)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { pillHovered = hovering }
        }
    }

    private func copyContent() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)
        copied = true
        // 轻反馈：对勾短暂停留后复位
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantContent
        case .system:
            EmptyView()
        }
    }

    /// 用户消息：右对齐气泡，琥珀强调色底 + 同系描边（容器感）；图片缩略图排在文本上方（点击放大）。
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.lg) {
            if !message.images.isEmpty {
                MessageImageThumbs(images: message.images, onTap: onTapImage)
            }
            if !message.content.isEmpty {
                Text(message.content)
                    .font(Theme.Typography.text(13))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .fill(Theme.Colors.accent.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .stroke(Theme.Colors.accent.opacity(0.32), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var assistantContent: some View {
        // 文本气泡与工具调用卡片纵向排列：一轮助手消息可能兼有文本与工具调用，
        // 纯工具调用轮（无文本）只渲染卡片、不留空文本气泡；卡片与气泡同宽
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            assistantTextPart
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                AIToolCallCardView(toolCalls: toolCalls)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 助手消息的文本部分（按状态分派）；纯工具调用消息（无文本）不渲染空气泡。
    @ViewBuilder
    private var assistantTextPart: some View {
        // 有工具调用且文本为空时跳过文本气泡（工具卡片单独成段）
        let skipsTextBubble = message.content.isEmpty && !(message.toolCalls?.isEmpty ?? true)
        switch message.state {
        case .sending, .streaming:
            // 流式/首 token 等待：纯文本增量 + 呼吸态（流结束后切完整 AST 渲染）
            StreamingMessageView(content: message.content)
        case .failed(let errorText):
            FailedMessageView(errorText: errorText, onRetry: onRetry)
        case .done:
            // 落定态：完整块级 Markdown 渲染（AIChatMarkdownView）
            if !skipsTextBubble {
                AssistantMarkdownView(content: message.content)
            }
        case .aborted:
            // 中止：保留半截内容的富渲染 + 弱标记
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if !skipsTextBubble {
                    AssistantMarkdownView(content: message.content)
                }
                AbortedTag()
            }
        }
    }
}

/// 流式消息：纯文本增量（不解析 Markdown，避免半截语法抖动），末尾附呼吸态提示。
private struct StreamingMessageView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if !content.isEmpty {
                Text(content)
                    .font(Theme.Typography.text(13))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            StreamingIndicator()
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .fill(Theme.Colors.chatAssistantBubble)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .stroke(Theme.Colors.cardStroke, lineWidth: 0.5)
        )
    }
}

/// 「生成中…」呼吸态：opacity 呼吸动画（repeatForever + autoreverses）。
private struct StreamingIndicator: View {
    @State private var breathing = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("▌").font(Theme.Typography.text(12))
            Text("生成中…").font(Theme.Typography.text(11, .medium))
        }
        .foregroundColor(Theme.Colors.contentTertiary)
        .opacity(breathing ? 1.0 : 0.3)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

/// 失败消息：错误色提示 + 重试按钮（重发最后一条 user 消息）。
private struct FailedMessageView: View {
    let errorText: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.text(12))
                    .foregroundColor(Theme.Colors.statusWarning)
                Text(errorText)
                    .font(Theme.Typography.text(12))
                    .foregroundColor(Theme.Colors.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: onRetry) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.Typography.text(11, .semibold))
                    Text("重试")
                        .font(Theme.Typography.text(11, .semibold))
                }
                .foregroundColor(Theme.Colors.contentPrimary)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.vertical, Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                        .fill(Theme.Colors.surfaceButton)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .fill(Theme.Colors.statusWarning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .stroke(Theme.Colors.statusWarning.opacity(0.28), lineWidth: 0.5)
        )
    }
}

/// 「已中止」弱标记。
private struct AbortedTag: View {
    var body: some View {
        Text("已中止")
            .font(Theme.Typography.text(10.5, .medium))
            .foregroundColor(Theme.Colors.contentTertiary)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.surfaceBadge)
            )
    }
}

// MARK: - 剪贴板胶囊

private struct ClipboardAttachmentCapsule: View {
    let charCount: Int
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(Theme.Typography.text(11, .medium))
                .foregroundColor(Theme.Colors.accent)
            Text("已附加剪贴板 \(charCount) 字")
                .font(Theme.Typography.text(11, .medium))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(Theme.Typography.text(12))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }
            .buttonStyle(.plain)
            .help("移除剪贴板附加")
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .fill(Theme.Colors.surfaceButton)
        )
    }
}

// MARK: - 空态欢迎页（已配置、无消息）

private struct WelcomeView: View {
    let hasClipboardText: Bool
    let onAttachClipboard: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Image(systemName: "sparkles")
                .font(.system(size: Theme.Typography.settingsIcon, weight: .regular))
                .foregroundColor(Theme.Colors.accent)
            Text("有什么想问的？")
                .font(Theme.Typography.text(Theme.Typography.toast, .medium))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)

            // 剪贴板快捷引用：有可用文本时给一个轻入口
            if hasClipboardText {
                Button(action: onAttachClipboard) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "doc.on.clipboard")
                            .font(Theme.Typography.text(11, .medium))
                        Text("附加剪贴板内容")
                            .font(Theme.Typography.text(11, .medium))
                    }
                    .foregroundColor(Theme.Colors.contentTertiary)
                    .padding(.horizontal, Theme.Spacing.xxl)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                            .fill(Theme.Colors.surfaceButton)
                    )
                }
                .buttonStyle(.plain)
                .help("把剪贴板文本附加为对话上下文")
            }
        }
        .padding(Theme.Spacing.panel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 未配置引导

private struct UnconfiguredGuideView: View {
    let onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.xxl) {
            Image(systemName: "sparkles")
                .font(.system(size: Theme.Typography.settingsIcon, weight: .regular))
                .foregroundColor(Theme.Colors.accent)
            Text("未配置 AI 服务")
                .font(Theme.Typography.text(Theme.Typography.toast, .semibold))
                .foregroundColor(Theme.Colors.contentPrimary)
            Text("在设置中填写 Base URL、API Key 与 Model 后即可开始对话。")
                .font(Theme.Typography.text(12))
                .foregroundColor(Theme.Colors.contentTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onOpenSettings?()
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "gearshape.fill")
                        .font(Theme.Typography.text(12, .semibold))
                    Text("打开设置…")
                        .font(Theme.Typography.text(12, .semibold))
                }
                .foregroundColor(Color(.windowBackgroundColor))
                .padding(.horizontal, Theme.Spacing.card)
                .padding(.vertical, Theme.Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                        .fill(Theme.Colors.accent)
                )
            }
            .buttonStyle(.plain)
            .disabled(onOpenSettings == nil)
        }
        .padding(Theme.Spacing.panel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 输入框（NSTextView 包装）

/// NSTextView 包装：实现 ⏎ 发送 / ⇧⏎ 换行 / 中文输入法组字放行 / 图片粘贴与拖入。
/// 为什么不用 SwiftUI TextField/TextEditor：⏎ 语义必须自定义，且必须在 doCommandBy 层
/// 通过 markedRange 判定中文输入法组字，避免组字回车被误判为发送。
private struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onEscape: () -> Void
    /// 粘贴/拖入图片（NSImage 数组，由调用方转附件）。
    let onInsertImages: ([NSImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 手工搭建文本系统：scrollableTextView() 返回基类 NSTextView，无法插入自定义子类
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = ChatInputNSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.onEscape = onEscape
        textView.onInsertImages = onInsertImages
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        // 关闭各类自动替换/检查，避免对话输入被系统“纠正”并出现下划线噪音
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        // 内边距与 SwiftUI 占位文案 padding 对齐（复用既有间距令牌）
        textView.textContainerInset = NSSize(
            width: Theme.Spacing.xxl,
            height: Theme.Spacing.xl
        )
        textView.textContainer?.lineFragmentPadding = 0
        // 追加注册图片拖放类型（不影响默认文本拖入；jpeg 无内置常量，用 UTI 字符串）
        textView.registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")])

        let scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        context.coordinator.textView = textView
        context.coordinator.startObservingWindow()
        // 首帧若窗口已就绪则聚焦；窗口后续成为 key 时由观察者兜底聚焦
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.onEscape = onEscape
        textView.onInsertImages = onInsertImages
        // 外部（发送清空 / ⌘K / 重试）修改文本时回写；仅在内容不一致时写，避免打断输入与 IME 组字
        if textView.string != text {
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObservingWindow()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        weak var textView: ChatInputNSTextView?

        init(_ parent: ChatInputTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // 同步到绑定：仅在不等时写，避免与 updateNSView 形成回写回路
            if parent.text != tv.string {
                parent.text = tv.string
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // ⏎：中文 IME 组字期间 markedRange 非空 → 放行给输入法先提交候选字，绝不触发发送
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if textView.hasMarkedText() { return false }
                if NSEvent.modifierFlags.contains(.shift) {
                    // ⇧⏎ 换行：忽略 field editor 语义，强制插入软换行
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            // ⇧⏎ 在部分系统路径下映射为该命令：交给默认实现插入换行
            if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                return false
            }
            return false
        }

        /// 监听窗口成为 key：保证 AI 窗每次唤出时输入框拿到第一响应者。
        func startObservingWindow() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
        }

        func stopObservingWindow() {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        }

        @objc private func windowDidBecomeKey(_ note: Notification) {
            guard let window = note.object as? NSWindow,
                  window === textView?.window else { return }
            window.makeFirstResponder(textView)
        }
    }
}

/// 自定义 NSTextView：ESC 触发注入回调（先中止/后关窗由调用方决定）；
/// 粘贴/拖入图片优先转附件（剪贴板或拖拽源含图片时消费，不落入文本）。
/// FloatingPanel 系面板对 firstResponder is NSTextView 全键放行，ESC 可能直达此处；
/// 由 AIChatView.handleEscape 承载两阶段语义；无回调时走默认 cancelOperation。
private final class ChatInputNSTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onInsertImages: (([NSImage]) -> Void)?

    // 无 Edit 菜单的轻量应用里，文本系统的标准编辑键等效可能不被派发——
    // 显式接住，保证 ⌘V 粘贴 / ⌘C 拷贝 / ⌘X 剪切 / ⌘A 全选任何环境下可用
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 9: paste(nil); return true       // V
            case 8: copy(nil); return true        // C
            case 7: cut(nil); return true         // X
            case 0: selectAll(nil); return true   // A
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// 粘贴：剪贴板含图片（截图位图 / Finder 图片文件）时优先转为图片附件，否则走默认文本粘贴。
    override func paste(_ sender: Any?) {
        let images = PasteboardImageExtractor.images(from: NSPasteboard.general)
        if !images.isEmpty {
            onInsertImages?(images)
            return
        }
        super.paste(sender)
    }

    /// 拖入：拖拽源含图片时高亮接收并转附件，否则交给默认文本拖放。
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if PasteboardImageExtractor.containsImage(sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = PasteboardImageExtractor.images(from: sender.draggingPasteboard)
        if !images.isEmpty {
            onInsertImages?(images)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape {
            onEscape()
        } else {
            super.cancelOperation(sender)
        }
    }
}

// MARK: - 面板圆角裁剪（仅 13~25 降级路径生效）

private struct AIChatRoundedClip: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        }
    }
}
