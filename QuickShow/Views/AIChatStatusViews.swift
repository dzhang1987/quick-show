// 从 AIChatView.swift 机械拆分：输入坞状态与空态视图（队列胶囊 / 剪贴板胶囊 / 欢迎页 / 未配置引导）。

import AppKit
import Combine
import SwiftUI

// MARK: - 待注入队列胶囊（steering / follow-up）

/// 待注入队列胶囊：类型标签（转向=↪ / 追问=↩ + 中文小字）+ 文本单行截断 + hover 露出 ✕。
/// 点击整枚胶囊取回编辑（数据层回填输入框，胶囊随队列移除消失）；hover 提亮。
/// ✕ 与整枚同语义（撤回该条回填输入框），始终占位、hover 才显形——opacity 渐变、
/// 布局零跳动（同 showDockSecondaryTools 纪律）。
/// 视觉沿用坞内微胶囊语言：实底 surfaceTrack + 0.5pt 白 rim，不新增设计令牌。
struct QueuedInputCapsule: View {
    let item: QueuedChatInput
    let onRecall: () -> Void

    @State private var hovered = false

    private var isSteering: Bool { item.kind == .steering }

    var body: some View {
        Button(action: onRecall) {
            HStack(spacing: Theme.Spacing.md) {
                // 类型标签：转向=即时修正方向（accent 强调）；追问=轮末追加（次级色）
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: isSteering
                          ? "arrowshape.turn.up.right.fill"
                          : "arrowshape.turn.up.left.fill")
                        .font(Theme.Typography.text(10, .semibold))
                    Text(isSteering ? "转向" : "追问")
                        .font(Theme.Typography.text(10, .semibold))
                }
                .foregroundColor(isSteering ? Theme.Colors.accent : Theme.Colors.contentSecondaryStrong)

                Text(displayText)
                    .font(Theme.Typography.text(11, .medium))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                // ✕ 撤回钮：与点击整枚同动作（撤回回填），嵌套命中无歧义；
                // 非 hover 时禁命中，点击穿透到整枚胶囊。
                Button(action: onRecall) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Typography.text(12))
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
                .accessibilityHidden(!hovered)
                .help("撤回该条到输入框")
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                Capsule(style: .continuous)
                    .fill(hovered ? Theme.Colors.iconHoverBg : Theme.Colors.surfaceTrack)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Theme.Colors.chatCapsuleRim, lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
        // 固定文案后附队列项完整文本（单行截断的补偿：多行长文经 tooltip 全量可读）
        .help((isSteering
              ? "转向：本轮生成中即时注入、修正方向 · 点击取回编辑"
              : "追问：本轮回复完成后自动追加一轮 · 点击取回编辑")
              + "\n" + displayText)
    }

    /// 展示文本：纯图片队列项给占位文案（对齐 send 的「请查看图片。」兜底语义）。
    private var displayText: String {
        if !item.text.isEmpty { return item.text }
        if !item.images.isEmpty { return "图片 ×\(item.images.count)" }
        return ""
    }
}

// MARK: - 剪贴板胶囊

struct ClipboardAttachmentCapsule: View {
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

struct WelcomeView: View {
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
