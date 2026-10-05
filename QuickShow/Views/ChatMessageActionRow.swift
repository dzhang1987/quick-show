// 从 AIChatMessageRow.swift 机械拆分：消息行下方常驻操作行及其图标钮。
// 本视图无自有状态：hover/copy 反馈态仍由父级 ChatMessageRow 持有（仅按值/回调传入），
// 保证拆分前后渲染与交互逐字一致；父级 private 方法以闭包值传出。

import SwiftUI

/// 常驻操作行：复制（成功变对勾轻反馈）；最后一条落定助手消息附「重新生成」；
/// 会话内最后一条 user 消息附「撤回 / 编辑」（与复制一致常驻，生成中不显示）。
/// 弱化常驻：图标静止 38% 灰、整行 hover 提亮 85%；按钮自身 hover 叠 0.08 圆角底，不抢正文层级。
struct ChatMessageActionRow: View {
    let message: ChatMessage
    /// 是否为最后一条可重新生成的助手消息（父视图计算，含流式中禁用语义）。
    let canRegenerate: Bool
    /// 是否为会话内最后一条 user 消息且可撤回/编辑（父视图计算，含生成中禁用语义）。
    let canEditLastRound: Bool
    /// 复制轻反馈对勾态（父级持有，本视图只读）。
    let copied: Bool
    /// 父行 hover 态：驱动图标色提亮（行级弱化/增强的统一信号）。
    let rowHovered: Bool
    /// 复制整条消息文本（父级写剪贴板并置对勾）。
    let onCopy: () -> Void
    /// 重新生成最后一条助手消息。
    let onRegenerate: () -> Void
    /// 进入就地编辑态（父级持有 editing 协调态）。
    let onBeginEdit: () -> Void
    /// 撤回最后一轮（内容回填输入框）。
    let onWithdraw: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if !message.content.isEmpty {
                ChatActionIconButton(
                    systemName: copied ? "checkmark" : "square.on.square",
                    tint: copied ? Theme.Colors.accent : nil,
                    help: "复制",
                    rowHovered: rowHovered,
                    action: onCopy
                )
            }

            if message.role == .assistant, canRegenerate {
                ChatActionIconButton(
                    systemName: "arrow.clockwise",
                    tint: nil,
                    help: "重新生成",
                    rowHovered: rowHovered,
                    action: onRegenerate
                )
            }

            // 撤回/编辑：与复制行为一致——常驻可见（静止 38% 灰、行 hover 提亮），不做 hover 浮现
            if message.role == .user, canEditLastRound {
                ChatActionIconButton(
                    systemName: "pencil",
                    tint: nil,
                    help: "编辑并重发",
                    rowHovered: rowHovered,
                    action: onBeginEdit
                )
                ChatActionIconButton(
                    systemName: "arrow.uturn.backward",
                    tint: nil,
                    help: "撤回该轮（内容回填输入框）",
                    rowHovered: rowHovered,
                    action: onWithdraw
                )
            }
        }
    }
}

/// 操作行图标钮：10pt hierarchical 符号、18×18 命中区；
/// 图标色随行 hover 提亮（0.38 → 0.85），自身 hover 叠 primary 0.08 圆角底（macOS 工具图标惯例）。
struct ChatActionIconButton: View {
    let systemName: String
    /// 反馈色（如复制成功的 accent 对勾）；nil = 常规灰度档。
    var tint: Color? = nil
    let help: String
    /// 父行 hover 态：驱动图标色提亮（行级弱化/增强的统一信号）。
    let rowHovered: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(Theme.Typography.text(10, .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(tint ?? Color.primary.opacity(rowHovered ? 0.85 : 0.38))
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
    }
}