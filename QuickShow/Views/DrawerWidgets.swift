import SwiftUI

// MARK: - 选项胶囊

/// 选项胶囊：视觉沿用坞内微胶囊语言（surfaceTrack 底 + chatCapsuleRim 0.5pt 描边），
/// 选中态换 accent 档（0.12 底 + 0.45 描边 + ✓，与状态徽标同一克制语言）；
/// hover 提亮。选项说明文字经 tooltip 展示（胶囊保持单行紧凑）。
struct DrawerOptionCapsule: View {
    let option: UserQuestionOption
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

// MARK: - 抽屉按钮

/// 抽屉操作按钮三样式：primary（accent 实心，主操作）/ secondary（surfaceButton 底，消极操作）
/// / outlined（描边，第三样式）。禁用态 = chatSendDisabledFill 底 + 弱化字（发送钮同款语言）。
struct DrawerActionButton: View {
    enum Style {
        case primary
        case secondary
        case outlined
    }

    let title: String
    let style: Style
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.text(Theme.Typography.body, .medium))
                .foregroundColor(foregroundColor)
                .padding(.horizontal, Theme.Spacing.card)
                .padding(.vertical, Theme.Spacing.md)
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
        default:
            return Color.clear
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            // 与发送钮同款：强调色底上取深色对比最稳；禁用态降弱化字
            return enabled ? Color.black.opacity(0.72) : Theme.Colors.contentTertiary
        case .secondary:
            return Theme.Colors.contentPrimary
        case .outlined:
            return hovered ? Theme.Colors.contentPrimary : Theme.Colors.contentSecondaryStrong
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
