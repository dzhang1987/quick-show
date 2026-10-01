import AppKit
import Combine
import SwiftUI

/// AI 对话视图（Lane C）：将嵌入 NSHostingView，由 AIWindowManager 管理外窗尺寸与焦点。
/// 视觉全部走 DesignTokens 既有令牌（本文件严禁新增令牌——Lane B 并行维护 DesignTokens）。
///
/// 公开接口（接线用）：
/// - `state`：会话状态（AIChatState.shared）。
/// - `onOpenSettings`：未配置引导卡片「打开设置…」的出口（注入 AppState.openSettings）。
/// - `onClose`：输入框聚焦时 ESC 的兜底出口（注入 AIWindowManager 的关窗逻辑）。
///   说明：FloatingPanel 系面板对 firstResponder is NSTextView 会全键放行，
///   故 ESC 可能直达输入框 cancelOperation——此时由本视图两阶段处理（先中止、后关窗）。
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
    /// 流式滚动节流时间戳：token 高频到达时限制滚动频率，避免每 token 触发布局重排。
    @State private var lastAutoScrollAt: Date = .distantPast

    var body: some View {
        VStack(spacing: 0) {
            // 未配置且无任何消息时才显示引导；已有历史/失败消息时仍展示列表，
            // 避免未配置下点发送后的失败反馈被引导卡遮住
            if configured || !state.messages.isEmpty {
                messageList
            } else {
                UnconfiguredGuideView(onOpenSettings: onOpenSettings)
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
        .modifier(AIChatRoundedClip())
        .onAppear { refreshEnvironment() }
        // 回到/激活 AI 窗口时刷新配置与剪贴板可用态（设置窗口改动后可即时生效）
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshEnvironment()
        }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                    ForEach(state.messages) { message in
                        ChatMessageRow(message: message, onRetry: { state.retryLast() })
                            // .equatable()：message 未变的历史行直接跳过重建，
                            // 流式期间仅最后一行 diff（配合 State 单条 mutate，避免全列表重排/重渲染）
                            .equatable()
                            // 以稳定 id 渲染；State 只 mutate content，不改 id
                            .id(message.id)
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
            // 剪贴板附加胶囊：非 nil 时显示，可一键移除
            if let clip = state.clipboardAttachment {
                ClipboardAttachmentCapsule(charCount: clip.count) {
                    state.removeClipboardAttachment()
                }
            }

            HStack(alignment: .bottom, spacing: Theme.Spacing.lg) {
                // 输入框：NSViewRepresentable 包装 NSTextView（自定义 ⏎/⇧⏎ 与中文 IME 组字语义）
                ZStack(alignment: .topLeading) {
                    ChatInputTextView(
                        text: $state.inputText,
                        onSubmit: { state.send() },
                        onEscape: { handleEscape() }
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
                .frame(height: 76)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                        .fill(Theme.Colors.surfaceInset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                        .stroke(Theme.Colors.groupCardStroke, lineWidth: 0.5)
                )

                VStack(spacing: Theme.Spacing.lg) {
                    // 剪贴板：空剪贴板弱化不可点
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

                    // 发送 / 中止：流式时切换为停止按钮（ESC 同样可中止）
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
            }

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

                Text("⌘K 清空 · ESC 关闭")
                    .font(Theme.Typography.text(10.5))
                    .foregroundColor(Theme.Colors.idleText)
            }
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.top, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.section)
        // 鼠标进入输入区时刷新剪贴板可用态（覆盖“先复制、后移动鼠标到窗口”的常见路径）
        .onHover { _ in refreshClipboardAvailability() }
    }

    // MARK: - 状态与动作

    private var canSend: Bool {
        !state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || state.clipboardAttachment != nil
    }

    private var sendButtonFill: Color {
        if state.isStreaming { return Theme.Colors.statusWarning.opacity(0.9) }
        return canSend ? Theme.Colors.accent : Theme.Colors.surfaceButton
    }

    private var sendButtonForeground: Color {
        if state.isStreaming || canSend { return Color(.windowBackgroundColor) }
        return Theme.Colors.idleText
    }

    /// 刷新非 @Published 的外部环境：端点配置与剪贴板可用性。
    private func refreshEnvironment() {
        configured = state.hasConfiguredEndpoint
        refreshClipboardAvailability()
    }

    /// 单独刷新剪贴板可用态（轻量，供 hover/窗口激活调用）。
    private func refreshClipboardAvailability() {
        let clipboard = NSPasteboard.general.string(forType: .string)
        hasClipboardText = !(clipboard?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// 附加剪贴板；失败（空剪贴板）时同步弱化按钮，做轻反馈。
    private func attachClipboard() {
        if !state.attachClipboard() {
            hasClipboardText = false
        }
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

// MARK: - 单条消息

private struct ChatMessageRow: View, Equatable {
    let message: AIChatState.ChatMessage
    let onRetry: () -> Void

    /// 仅按消息内容判定相等：闭包语义跨渲染一致，忽略其对 diff 的干扰，
    /// 使 .equatable() 能在流式期间跳过未变更行。
    static func == (lhs: ChatMessageRow, rhs: ChatMessageRow) -> Bool {
        lhs.message == rhs.message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: Theme.Spacing.panel) }
            content
            if message.role == .assistant { Spacer(minLength: Theme.Spacing.panel) }
        }
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

    /// 用户消息：右对齐气泡，主色系弱背景。
    private var userBubble: some View {
        Text(message.content)
            .font(Theme.Typography.text(13))
            .foregroundColor(Theme.Colors.contentPrimary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.vertical, Theme.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .fill(Theme.Colors.accent.opacity(0.16))
            )
    }

    @ViewBuilder
    private var assistantContent: some View {
        switch message.state {
        case .sending, .streaming:
            // 流式/首 token 等待：纯文本增量 + 呼吸态
            StreamingMessageView(content: message.content)
        case .failed(let errorText):
            FailedMessageView(errorText: errorText, onRetry: onRetry)
        case .done:
            // 落定态：完整 Markdown 渲染
            AssistantMarkdownView(content: message.content)
        case .aborted:
            // 中止：保留半截内容的富渲染 + 弱标记
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                AssistantMarkdownView(content: message.content)
                AbortedTag()
            }
        }
    }
}

/// assistant 落定消息：行级预切分围栏代码块，其余段做行内 Markdown 富渲染。
private struct AssistantMarkdownView: View {
    let content: String

    var body: some View {
        let segments = MarkdownSegments.split(content)
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let text):
                    Text(MarkdownSegments.inlineAttributed(text))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(Theme.Colors.surfaceCard)
        )
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
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(Theme.Colors.surfaceCard)
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
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(Theme.Colors.statusWarning.opacity(0.10))
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

// MARK: - 代码块

private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(Theme.Typography.mono(10, .semibold))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }
            // 代码块内不转 Markdown，纯等宽显示（长行自然换行，避免嵌套横向滚动）
            Text(code)
                .font(Theme.Typography.mono(12.5))
                .foregroundColor(Theme.Colors.contentPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(Theme.Colors.surfaceTrack)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .stroke(Theme.Colors.groupCardStroke, lineWidth: 0.5)
        )
    }
}

// MARK: - Markdown 行级预切分

private enum MarkdownSegment {
    case prose(String)
    case code(language: String?, code: String)
}

private enum MarkdownSegments {
    /// 行级预切分：把围栏代码块（```）与普通文本分离。
    /// - 以「行首 trim 后以 ``` 开头」为围栏边界，围栏行本身不渲染；
    /// - 紧跟围栏的语言标识（如 swift）单独保留用于代码块头部；
    /// - 未闭合围栏：剩余内容整体按代码块处理（流式中止后的半截代码块友好）；
    /// - 仅落定态（done/aborted）调用；流式态走纯文本增量，不做此切分。
    static func split(_ text: String) -> [MarkdownSegment] {
        guard !text.isEmpty else { return [] }

        var segments: [MarkdownSegment] = []
        var proseBuffer: [String] = []
        var codeBuffer: [String] = []
        var inCode = false
        var language: String?

        func flushProse() {
            guard !proseBuffer.isEmpty else { return }
            segments.append(.prose(proseBuffer.joined(separator: "\n")))
            proseBuffer.removeAll()
        }
        func flushCode() {
            segments.append(.code(language: language, code: codeBuffer.joined(separator: "\n")))
            codeBuffer.removeAll()
            language = nil
        }

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    inCode = true
                    let tag = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                }
                continue
            }
            if inCode {
                codeBuffer.append(rawLine)
            } else {
                proseBuffer.append(rawLine)
            }
        }
        if inCode { flushCode() } // 未闭合围栏：兜底按代码块落定
        flushProse()
        return segments
    }

    /// 行内 Markdown 富渲染（粗体/斜体/行内代码/链接）。
    /// 只用 inlineOnlyPreservingWhitespace：不解析块级结构，换行原样保留（块级已由 split 处理）。
    /// 链接色走 Theme 主色；行内代码用 mono + 代码底色（既有令牌，不新增）。
    static func inlineAttributed(_ text: String) -> AttributedString {
        var attributed: AttributedString
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            attributed = parsed
        } else {
            attributed = AttributedString(text)
        }

        // 先统一基础字体与正文色（正文可读性不弱于 contentTertiary 0.55，这里用 contentPrimary）
        attributed.font = Theme.Typography.text(13)
        attributed.foregroundColor = Theme.Colors.contentPrimary

        // 先快照 run 属性再回写，规避「边遍历 runs 边 mutate」的独占访问风险
        let runInfo = attributed.runs.map { ($0.range, $0.link, $0.inlinePresentationIntent) }
        for (range, link, intent) in runInfo {
            if link != nil {
                attributed[range].foregroundColor = Theme.Colors.accent
            }
            if let intent, intent.contains(.code) {
                attributed[range].font = Theme.Typography.mono(12.5)
                attributed[range].backgroundColor = Theme.Colors.surfaceTrack
            }
        }
        return attributed
    }
}

// MARK: - 输入框（NSTextView 包装）

/// NSTextView 包装：实现 ⏎ 发送 / ⇧⏎ 换行 / 中文输入法组字放行。
/// 为什么不用 SwiftUI TextField/TextEditor：⏎ 语义必须自定义，且必须在 doCommandBy 层
/// 通过 markedRange 判定中文输入法组字，避免组字回车被误判为发送。
private struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onEscape: () -> Void

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

/// 自定义 NSTextView：ESC 触发注入回调（先中止/后关窗由调用方决定）。
/// FloatingPanel 系面板对 firstResponder is NSTextView 全键放行，ESC 可能直达此处；
/// 由 AIChatView.handleEscape 承载两阶段语义；无回调时走默认 cancelOperation。
private final class ChatInputNSTextView: NSTextView {
    var onEscape: (() -> Void)?

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