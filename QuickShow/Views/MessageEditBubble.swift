// 从 AIChatMessageRow.swift 机械拆分：就地编辑气泡及其编辑会话状态。
// 生命周期 = 编辑会话：父级 ChatMessageRow 以 `if editing` 条件渲染本视图，
// 进入即创建（草稿以原消息文本/图片初始化）、退出即销毁（状态天然重置），
// 无需父级手工复位草稿。父级仅保留 editing 协调态（showsActionRow 分支与
// content 分派依赖它）；确认提交经 onCommit 回到原 onEditResend 调用点，行为不变。

import SwiftUI

/// 就地编辑态：气泡原地「展开」为编辑器——同底色/圆角/内边距，无跳变感。
/// 顶部为可单张移除的图片附件条（粘贴可追加）；中间为 IME 安全编辑框
/// （⏎ 确认 / ⇧⏎ 换行 / ESC 取消，高度随内容自适应、封顶滚动）；
/// 底部为操作钮（快捷键语义由 .help() tooltip 承担，对齐全窗提示纪律）。
struct MessageEditBubble: View {
    /// 编辑对象：原消息文本/图片作为草稿初值（进入编辑态时锁定，编辑期间不变）。
    let message: ChatMessage
    /// 确认重发：把清理后的文本与图片附件交回父级（父级退出编辑态并转交 onEditResend）。
    let onCommit: (String, [ChatImageAttachment]) -> Void
    /// 取消编辑：父级退出编辑态（带淡出动画）。
    let onCancel: () -> Void

    /// 编辑草稿：随本视图创建时以原消息文本/图片初始化，销毁即重置。
    @State private var editText: String
    @State private var editImages: [ChatImageAttachment]
    /// 编辑器内容高度（由 ChatInlineEditTextView 实测回写，驱动编辑气泡自适应生长）。
    @State private var editHeight: CGFloat = 18

    init(
        message: ChatMessage,
        onCommit: @escaping (String, [ChatImageAttachment]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.message = message
        self.onCommit = onCommit
        self.onCancel = onCancel
        _editText = State(initialValue: message.content)
        _editImages = State(initialValue: message.images)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.lg) {
            if !editImages.isEmpty {
                ImageAttachmentStrip(attachments: editImages) { id in
                    editImages.removeAll { $0.id == id }
                }
            }

            ChatInlineEditTextView(
                text: $editText,
                contentHeight: $editHeight,
                onSubmit: confirmEdit,
                onEscape: cancelEdit,
                onInsertImages: { images in
                    for image in images {
                        if let attachment = ImageAttachmentProcessor.makeAttachment(from: image) {
                            editImages.append(attachment)
                        }
                    }
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: editHeight)

            HStack(spacing: Theme.Spacing.md) {
                editBubbleButton(title: String(localized: "取消"), tint: Theme.Colors.contentSecondaryStrong, action: cancelEdit)
                    .help("取消编辑（ESC）")
                editBubbleButton(
                    title: String(localized: "重发"),
                    tint: canConfirmEdit ? Theme.Colors.accent : Theme.Colors.contentTertiary,
                    action: confirmEdit
                )
                .disabled(!canConfirmEdit)
                .help("确认并重发（⏎）")
            }
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.userBubble, style: .continuous)
                .fill(Theme.Colors.chatUserBubble)
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// 编辑气泡内的小胶囊钮：与失败卡「重试」同一语言（surfaceButton 实底 + keyCap 圆角）。
    private func editBubbleButton(title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.text(11, .semibold))
                .foregroundColor(tint)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.vertical, Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                        .fill(Theme.Colors.surfaceButton)
                )
        }
        .buttonStyle(.plain)
    }

    /// 可确认重发：文本非空或仍有图片附件（与主输入框 canSend 同规则）。
    private var canConfirmEdit: Bool {
        !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !editImages.isEmpty
    }

    /// 确认编辑：先清理空文本，再把新文本/图片交给父级（父级退出编辑态并重发，不阻塞）。
    private func confirmEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !editImages.isEmpty else { return }
        onCommit(text, editImages)
    }

    /// 取消编辑：丢弃草稿（本视图销毁），父级恢复原气泡。
    private func cancelEdit() {
        onCancel()
    }
}