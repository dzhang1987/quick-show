// 从 AIChatView.swift 机械拆分：输入坞状态与空态视图（排队消息面板 / 欢迎页 / 未配置引导）。

import AppKit
import Combine
import SwiftUI

// MARK: - 排队消息一体化面板（QueuedMessagesPanel）

/// 排队消息一体化面板（参考 Antigravity 交互与 macOS 原生质感）：
/// - 单条时：直接呈现卡片，右侧集成 [立即插入 ->]、[就地编辑 ✏️]、[移除 🗑️]；
/// - 多条时：顶部显示「排队消息 (N)」折叠控制栏，默认折叠，可展开逐条管理；
/// - 独立编辑态：点击 ✏️ 原地展开行内编辑框，保存/取消不污染主输入框草稿；
/// - 防透字底衬：使用 chatNavFloatFill(0.95 实底) + chatStrokeStrong 描边，彻底阻断背后文字透视。
struct QueuedMessagesPanel: View {
    @ObservedObject var state: AIChatState

    @State private var isExpanded: Bool = false
    @State private var editingItemId: UUID? = nil
    @State private var editingDraft: String = ""

    private var queue: [QueuedChatInput] {
        state.pendingQueue
    }

    var body: some View {
        guard !queue.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(spacing: Theme.Spacing.xs) {
                if queue.count > 1 {
                    headerBar
                }

                if queue.count == 1 || isExpanded {
                    ForEach(queue) { item in
                        QueuedMessageCardRow(
                            item: item,
                            isEditing: editingItemId == item.id,
                            editingDraft: $editingDraft,
                            onPromote: {
                                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                                    state.promoteQueuedInput(id: item.id)
                                }
                            },
                            onStartEdit: {
                                editingItemId = item.id
                                editingDraft = item.text
                            },
                            onSaveEdit: {
                                state.updateQueuedInput(id: item.id, newText: editingDraft)
                                editingItemId = nil
                                editingDraft = ""
                            },
                            onCancelEdit: {
                                editingItemId = nil
                                editingDraft = ""
                            },
                            onRemove: {
                                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                                    state.removeQueuedInput(id: item.id)
                                }
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: Theme.Motion.toastScale)))
                    }
                } else if let first = queue.first {
                    // 多条折叠态：展示第一条摘要，引导点击展开全部
                    QueuedMessageCardRow(
                        item: first,
                        isEditing: false,
                        editingDraft: .constant(""),
                        onPromote: {
                            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                                state.promoteQueuedInput(id: first.id)
                            }
                        },
                        onStartEdit: {
                            isExpanded = true
                            editingItemId = first.id
                            editingDraft = first.text
                        },
                        onSaveEdit: {},
                        onCancelEdit: {},
                        onRemove: {
                            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                                state.removeQueuedInput(id: first.id)
                            }
                        }
                    )
                }
            }
            .animation(.easeOut(duration: Theme.Motion.contentFade), value: queue)
            .animation(.easeOut(duration: Theme.Motion.contentFade), value: isExpanded)
            .animation(.easeOut(duration: Theme.Motion.contentFade), value: editingItemId)
        )
    }

    private var headerBar: some View {
        Button {
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "tray.full.fill")
                    .font(Theme.Typography.text(10, .semibold))
                    .foregroundColor(Theme.Colors.accent)

                Text(String(localized: "排队消息 (\(queue.count))"))
                    .font(Theme.Typography.text(11, .semibold))
                    .foregroundColor(Theme.Colors.contentPrimary)

                Text(String(localized: "· 将按顺序自动处理"))
                    .font(Theme.Typography.text(10))
                    .foregroundColor(Theme.Colors.contentTertiary)

                Spacer(minLength: 0)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(Theme.Typography.text(10, .bold))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                    RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                        .fill(Theme.Colors.chatNavFloatFill)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .strokeBorder(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 单条排队消息卡片行

struct QueuedMessageCardRow: View {
    let item: QueuedChatInput
    let isEditing: Bool
    @Binding var editingDraft: String
    let onPromote: () -> Void
    let onStartEdit: () -> Void
    let onSaveEdit: () -> Void
    let onCancelEdit: () -> Void
    let onRemove: () -> Void

    @State private var hovered = false

    private var isSteering: Bool { item.kind == .steering }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if isEditing {
                // 原地就地编辑模式
                HStack(spacing: Theme.Spacing.sm) {
                    TextField(String(localized: "修改排队消息…"), text: $editingDraft, onCommit: onSaveEdit)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.text(11, .medium))
                        .foregroundColor(Theme.Colors.contentPrimary)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                                .fill(Theme.Colors.surfaceInset)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                                .strokeBorder(Theme.Colors.accent.opacity(0.4), lineWidth: 0.5)
                        )

                    Button(action: onSaveEdit) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(Theme.Typography.text(13))
                            .foregroundColor(Theme.Colors.statusPositive)
                    }
                    .buttonStyle(.plain)
                    .help("保存修改 (⏎)")

                    Button(action: onCancelEdit) {
                        Image(systemName: "xmark.circle")
                            .font(Theme.Typography.text(13))
                            .foregroundColor(Theme.Colors.contentTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("取消 (ESC)")
                }
            } else {
                // 普通卡片展示模式
                HStack(spacing: Theme.Spacing.md) {
                    // 状态徽标 Tag（插入 ⇄ 追加）
                    HStack(spacing: 3) {
                        Image(systemName: isSteering
                              ? "arrowshape.turn.up.right.fill"
                              : "arrowshape.turn.up.left.fill")
                            .font(Theme.Typography.text(9, .semibold))
                        Text(isSteering ? String(localized: "插入") : String(localized: "追加"))
                            .font(Theme.Typography.text(10, .semibold))
                    }
                    .foregroundColor(isSteering ? Theme.Colors.accent : Theme.Colors.contentSecondaryStrong)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isSteering ? Theme.Colors.accent.opacity(0.12) : Theme.Colors.surfaceTrack)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(isSteering ? Theme.Colors.accent.opacity(0.25) : Theme.Colors.cardStroke, lineWidth: 0.5)
                    )

                    // 消息正文摘要
                    Text(displayText)
                        .font(Theme.Typography.text(11, .medium))
                        .foregroundColor(Theme.Colors.contentPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    // 操作按钮组
                    HStack(spacing: Theme.Spacing.sm) {
                        // 若当前是追加，提供显式 [-> 立即插入] 提权按钮
                        if !isSteering {
                            Button(action: onPromote) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(Theme.Typography.text(12, .semibold))
                                    .foregroundColor(Theme.Colors.accent)
                            }
                            .buttonStyle(.plain)
                            .help("立即插入当前任务（中途插队，在下一思考/工具轮次前注入）")
                        }

                        // ✏️ 就地编辑
                        Button(action: onStartEdit) {
                            Image(systemName: "pencil")
                                .font(Theme.Typography.text(11))
                                .foregroundColor(Theme.Colors.contentSecondaryStrong)
                        }
                        .buttonStyle(.plain)
                        .help("就地编辑内容")

                        // 🗑️ 删除
                        Button(action: onRemove) {
                            Image(systemName: "trash")
                                .font(Theme.Typography.text(11))
                                .foregroundColor(Theme.Colors.contentTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("删除该条排队消息")
                    }
                    .opacity(hovered ? 1.0 : 0.75)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            ZStack {
                // 100% 纯实底垫底，彻底消除任何透明度造成的下层 Markdown 透视
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .fill(Theme.Colors.chatNavFloatFill)
                if hovered {
                    RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                        .fill(Theme.Colors.iconHoverBg)
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .strokeBorder(isSteering ? Theme.Colors.accent.opacity(0.35) : (hovered ? Theme.Colors.accent.opacity(0.3) : Theme.Colors.chatStrokeStrong), lineWidth: 0.5)
        )
        .onHover { isHovered in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                hovered = isHovered
            }
        }
        .help(isSteering
              ? String(localized: "插入：将在当前任务的下一次思考或工具调用前中途注入\n") + displayText
              : String(localized: "追加：将在当前任务全部完成后作为下一轮自动发送\n") + displayText)
    }

    private var displayText: String {
        if !item.text.isEmpty { return item.text }
        if !item.images.isEmpty { return String(localized: "图片 ×\(item.images.count)") }
        return ""
    }
}

// MARK: - 兼容微胶囊（保留类型以防老代码外部引用）

struct QueuedInputCapsule: View {
    let item: QueuedChatInput
    let onRecall: () -> Void

    var body: some View {
        Button(action: onRecall) {
            Text(item.text)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 空态欢迎页（已配置、无消息）

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Image(systemName: "sparkles")
                .font(.system(size: Theme.Typography.settingsIcon, weight: .regular))
                .foregroundColor(Theme.Colors.accent)
            Text("有什么想问的？")
                .font(Theme.Typography.text(Theme.Typography.toast, .medium))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
        }
        .padding(Theme.Spacing.panel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 未配置引导

struct UnconfiguredGuideView: View {
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
