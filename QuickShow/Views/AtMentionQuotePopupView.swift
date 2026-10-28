import SwiftUI
import AppKit

// MARK: - 输入坞 @ 快捷引用历史消息面板

/// 在输入坞键入 @ 唤出的历史消息引用面板（轻量毛玻璃下拉浮层）
/// - 支持按 @ 后的关键字实时全文过滤
/// - 支持 ↑/↓ 键盘方向键切换高亮，⏎ 确认引用，ESC 取消
/// - 确认后自动移除输入框中的 @query 词并挂载引用胶囊
struct AtMentionQuotePopupView: View {
    @ObservedObject var state: AIChatState
    var onConfirm: (Int) -> Void
    var onDismiss: () -> Void

    private var candidates: [ChatMessage] {
        state.candidateQuoteMessages()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶栏：标题与操作提示
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "quote.opening")
                    .font(Theme.Typography.text(10, .semibold))
                    .foregroundColor(Theme.Colors.accent)
                Text(String(localized: "引用会话消息"))
                    .font(Theme.Typography.text(11, .semibold))
                    .foregroundColor(Theme.Colors.contentPrimary)
                Spacer()
                Text(String(localized: "↑↓ 切换 · ⏎ 确认 · ESC 取消"))
                    .font(Theme.Typography.text(10))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }
            .padding(.horizontal, Theme.Spacing.card)
            .padding(.vertical, Theme.Spacing.sm)

            Divider()
                .overlay(Theme.Colors.cardStroke)

            // 候选消息列表
            if candidates.isEmpty {
                HStack {
                    Spacer()
                    Text(state.atMentionQuery.isEmpty ? String(localized: "当前会话暂无历史消息可引用") : String(localized: "未找到包含「\(state.atMentionQuery)」的消息"))
                        .font(Theme.Typography.text(11))
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .padding(.vertical, Theme.Spacing.lg)
                    Spacer()
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, msg in
                        candidateRow(msg: msg, index: index)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
                .padding(.horizontal, Theme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                // 1. 实色遮挡层：彻底阻断下方会话文字与背景穿透
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))

                // 2. 毛玻璃磨砂层：提供柔和高阶磨砂质感
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(.regularMaterial)

                // 3. 微调暗色流光衬底
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.Colors.chatBase.opacity(0.85))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Colors.chatStrokeStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    @ViewBuilder
    private func candidateRow(msg: ChatMessage, index: Int) -> some View {
        let isSelected = (index == state.atMentionSelectedIndex)
        Button {
            onConfirm(index)
        } label: {
            HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                // 角色图标徽章
                roleBadge(role: msg.role)

                // 消息摘录
                Text(msg.content.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(Theme.Typography.text(11))
                    .foregroundColor(isSelected ? Theme.Colors.contentPrimary : Theme.Colors.contentSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: Theme.Spacing.sm)

                // 时间戳
                Text(msg.formattedShortTime)
                    .font(Theme.Typography.text(10))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .fill(isSelected ? Theme.Colors.accent.opacity(0.15) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                            .strokeBorder(isSelected ? Theme.Colors.accent.opacity(0.4) : Color.clear, lineWidth: 0.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func roleBadge(role: ChatMessage.Role) -> some View {
        HStack(spacing: 3) {
            Image(systemName: role == .assistant ? "sparkles" : "person.fill")
                .font(Theme.Typography.text(9, .semibold))
            Text(role == .assistant ? String(localized: "AI") : String(localized: "我"))
                .font(Theme.Typography.text(10, .semibold))
        }
        .foregroundColor(role == .assistant ? Theme.Colors.accent : Theme.Colors.contentSecondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(role == .assistant ? Theme.Colors.accent.opacity(0.12) : Color.white.opacity(0.06))
        )
    }
}
