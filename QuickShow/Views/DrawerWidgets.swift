import SwiftUI

// MARK: - 选项胶囊

/// 选项胶囊：视觉沿用坞内微胶囊语言（surfaceTrack 底 + chatCapsuleRim 0.5pt 描边），
/// 选中态换 accent 档（0.12 底 + 0.45 描边 + ✓，与状态徽标同一克制语言）；
/// 选中态依然保留 prefixNumber（如 ✓ 4 一直问下去），确保 1-9 盲操按键记忆永远清晰。
struct DrawerOptionCapsule: View {
    let option: UserQuestionOption
    var prefixNumber: Int? = nil
    let selected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(Theme.Typography.text(Theme.Typography.micro, .bold))
                }
                if let prefixNumber {
                    Text("\(prefixNumber)")
                        .font(Theme.Typography.mono(Theme.Typography.micro, selected ? .bold : .medium))
                        .foregroundColor(selected ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                }
                Text(option.label)
                    .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                    .lineLimit(1)
            }
            .foregroundColor(
                selected
                    ? Theme.Colors.accent
                    : (hovered ? Theme.Colors.iconHover : Theme.Colors.contentSecondaryStrong)
            )
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        selected
                            ? Theme.Colors.accent.opacity(0.12)
                            : (hovered ? Theme.Colors.iconHoverBg : Theme.Colors.surfaceTrack)
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        selected ? Theme.Colors.accent.opacity(0.45) : Theme.Colors.chatCapsuleRim,
                        lineWidth: 0.5
                    )
            )
            .contentShape(Capsule(style: .continuous))
            .animation(.easeOut(duration: Theme.Motion.contentFade), value: selected)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
        .help(option.description.map { "\(option.label)\n\($0)" } ?? option.label)
    }
}

// MARK: - 自定义答案行内胶囊

/// 自定义答案行内胶囊：完全融入选项流（高度与常规胶囊一致），消除外凸大长框。
/// 编辑态（isEditing）：原地自适应展开为输入胶囊，直接打字；
/// 已输入态（hasContent）：呈高亮选中态（✓ 5 ✏️ 预览文本 ✕）；
/// 未输入态：虚线微弱胶囊（5 ✏️ 自定义…）。
struct DrawerCustomOptionCapsule: View {
    var prefixNumber: Int? = nil
    @Binding var customText: String
    let isEditing: Bool
    @FocusState.Binding var isFocused: Bool
    let onStartEditing: () -> Void
    let onClear: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @State private var hovered = false

    private var hasContent: Bool {
        !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if isEditing {
                editingCapsule
            } else {
                normalButtonCapsule
            }
        }
        .animation(.easeOut(duration: Theme.Motion.contentFade), value: isEditing)
        .animation(.easeOut(duration: Theme.Motion.contentFade), value: hasContent)
    }

    // MARK: - 编辑中行内胶囊

    private var editingCapsule: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let prefixNumber {
                Text("\(prefixNumber)")
                    .font(Theme.Typography.mono(Theme.Typography.micro, .bold))
                    .foregroundColor(Theme.Colors.accent)
            }

            Image(systemName: "pencil")
                .font(Theme.Typography.text(Theme.Typography.micro, .bold))
                .foregroundColor(Theme.Colors.accent)

            TextField(String(localized: "输入自定义答案…"), text: $customText)
                .textFieldStyle(.plain)
                .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                .foregroundColor(Theme.Colors.contentPrimary)
                .focused($isFocused)
                .frame(minWidth: 120, maxWidth: 200)
                .onSubmit {
                    onSubmit()
                }
                .onExitCommand {
                    onCancel()
                }

            if hasContent {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Typography.text(Theme.Typography.micro))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "清空"))
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.Colors.surfaceCard)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Theme.Colors.accent.opacity(0.6), lineWidth: 1.0)
        )
    }

    // MARK: - 常规/有内容胶囊

    private var normalButtonCapsule: some View {
        Button(action: onStartEditing) {
            HStack(spacing: Theme.Spacing.xs) {
                if hasContent {
                    Image(systemName: "checkmark")
                        .font(Theme.Typography.text(Theme.Typography.micro, .bold))
                }
                if let prefixNumber {
                    Text("\(prefixNumber)")
                        .font(Theme.Typography.mono(Theme.Typography.micro, hasContent ? .bold : .medium))
                        .foregroundColor(hasContent ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                }

                Image(systemName: "pencil")
                    .font(Theme.Typography.text(Theme.Typography.micro, .medium))

                Text(hasContent ? customPreviewText : String(localized: "自定义…"))
                    .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                    .lineLimit(1)

                if hasContent {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(Theme.Typography.text(Theme.Typography.micro))
                            .foregroundColor(Theme.Colors.contentTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "清空自定义回答"))
                }
            }
            .foregroundColor(
                hasContent
                    ? Theme.Colors.accent
                    : (hovered ? Theme.Colors.iconHover : Theme.Colors.contentSecondaryStrong)
            )
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        hasContent
                            ? Theme.Colors.accent.opacity(0.12)
                            : (hovered ? Theme.Colors.iconHoverBg : Theme.Colors.surfaceTrack)
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        hasContent
                            ? Theme.Colors.accent.opacity(0.45)
                            : (hovered ? Theme.Colors.accent.opacity(0.25) : Theme.Colors.chatCapsuleRim),
                        style: StrokeStyle(lineWidth: 0.5, dash: hasContent ? [] : [3, 3])
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
        .help(hasContent ? customText : String(localized: "输入自定义答案"))
    }

    private var customPreviewText: String {
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 10 {
            return "\(trimmed.prefix(10))…"
        }
        return trimmed
    }
}

// MARK: - 抽屉按钮

/// 抽屉操作按钮三样式：primary（accent 实心，主操作）/ secondary（surfaceButton 底，消极操作）
/// / outlined（描边，第三样式）。紧凑轻盈的原生按钮，快捷键作为轻量微文字随行展示。
struct DrawerActionButton: View {
    enum Style {
        case primary
        case secondary
        case outlined
    }

    let title: String
    var shortcut: String? = nil
    let style: Style
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Typography.text(Theme.Typography.callout, .medium))
                    .foregroundColor(foregroundColor)
                    .lineLimit(1)

                if let shortcut {
                    Text(shortcut)
                        .font(Theme.Typography.mono(Theme.Typography.micro, .medium))
                        .foregroundColor(shortcutForegroundColor)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.vertical, Theme.Spacing.smd)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
    }

    private var fillColor: Color {
        switch style {
        case .primary:
            if !enabled { return Theme.Colors.chatSendDisabledFill }
            return hovered ? Theme.Colors.accent.opacity(0.85) : Theme.Colors.accent
        case .secondary:
            return hovered ? Theme.Colors.iconHoverBg : Theme.Colors.surfaceButton
        case .outlined:
            return hovered ? Theme.Colors.iconHoverBg : Color.clear
        }
    }

    private var strokeColor: Color {
        switch style {
        case .outlined:
            return Theme.Colors.badgeStroke
        case .secondary:
            return Theme.Colors.chatStrokeStrong
        case .primary:
            return Color.clear
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            // 实心强调色钮：严格使用系统设计令牌 actionButtonForeground，标准主题纯白，杜绝蓝底黑字！
            return enabled ? Theme.Colors.actionButtonForeground : Theme.Colors.contentTertiary
        case .secondary:
            return Theme.Colors.contentPrimary
        case .outlined:
            return hovered ? Theme.Colors.contentPrimary : Theme.Colors.contentSecondaryStrong
        }
    }

    private var shortcutForegroundColor: Color {
        switch style {
        case .primary:
            return enabled ? Theme.Colors.actionButtonForeground.opacity(0.75) : Theme.Colors.contentTertiary
        case .secondary, .outlined:
            return Theme.Colors.contentTertiary
        }
    }
}

// MARK: - 选项流式布局

/// 选项胶囊流式行：子视图放不下时换行（与附件 FlowRow 同款极简实现，
/// 因 FlowRow 为附件模块私有，此处按抽屉语义独立一份，不跨模块借私有类型）。
struct DrawerOptionFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
