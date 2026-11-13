import SwiftUI

// MARK: - 会话授权盾牌徽标

/// 顶栏会话授权徽标：当前会话存在授权/拒绝记忆时点亮；
/// 点击展开授权列表（查看 + 撤销）。记忆可见可控是会话级授权的安全阀——
/// 授权不做黑箱，用户随时可以收回或恢复询问。
struct PermissionGrantBadge: View {
    @ObservedObject private var grantStore = ToolPermissionGrantStore.shared
    @State private var showList = false
    @State private var hovered = false

    private var memoryCount: Int {
        grantStore.activeGrants.count + grantStore.activeDenials.count
    }

    var body: some View {
        if memoryCount > 0 {
            Button {
                showList.toggle()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(Theme.Typography.text(Theme.Typography.callout, .medium))
                    Text("\(memoryCount)")
                        .font(Theme.Typography.mono(Theme.Typography.micro, .semibold))
                }
                .foregroundColor(hovered ? Theme.Colors.iconHover : Theme.Colors.accent)
                .frame(height: Theme.Layout.iconButtonSize)
                .padding(.horizontal, Theme.Spacing.xs)
                .background(
                    Capsule().fill(hovered ? Theme.Colors.iconHoverBg : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
            }
            .help(String(localized: "查看本会话的授权与拒绝"))
            .popover(isPresented: $showList, arrowEdge: .bottom) {
                PermissionGrantListView()
            }
        }
    }
}

// MARK: - 授权列表

/// 会话授权/拒绝列表：逐条撤销授权（回到下次再问）或撤销拒绝（恢复询问资格）。
struct PermissionGrantListView: View {
    @ObservedObject private var grantStore = ToolPermissionGrantStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(String(localized: "本会话授权"))
                .font(Theme.Typography.text(Theme.Typography.caption, .semibold))
                .foregroundColor(Theme.Colors.contentPrimary)

            if grantStore.activeGrants.isEmpty && grantStore.activeDenials.isEmpty {
                Text(String(localized: "暂无授权或拒绝"))
                    .font(Theme.Typography.text(Theme.Typography.caption))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }

            ForEach(grantStore.activeGrants) { grant in
                memoryRow(
                    icon: "checkmark.shield",
                    iconColor: Theme.Colors.accent,
                    title: grant.scope.displayTitle,
                    subtitle: String(localized: "已允许 · ") + grant.grantedAt.formatted(date: .omitted, time: .shortened),
                    actionTitle: String(localized: "撤销")
                ) {
                    grantStore.revokeGrant(id: grant.id)
                }
            }

            ForEach(grantStore.activeDenials) { denial in
                memoryRow(
                    icon: "xmark.shield",
                    iconColor: Theme.Colors.contentTertiary,
                    title: denial.scope.displayTitle,
                    subtitle: String(localized: "已拒绝 · ") + denial.deniedAt.formatted(date: .omitted, time: .shortened),
                    actionTitle: String(localized: "恢复询问")
                ) {
                    grantStore.revokeDenial(id: denial.id)
                }
            }

            Text(String(localized: "授权与拒绝仅对本会话生效"))
                .font(Theme.Typography.text(Theme.Typography.micro))
                .foregroundColor(Theme.Colors.contentTertiary)
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 300)
    }

    private func memoryRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.text(Theme.Typography.caption, .medium))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.Typography.text(Theme.Typography.micro))
                    .foregroundColor(Theme.Colors.contentTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: action) {
                Text(actionTitle)
                    .font(Theme.Typography.text(Theme.Typography.micro, .medium))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(
                        Capsule().fill(Theme.Colors.surfaceButton)
                    )
            }
            .buttonStyle(.plain)
        }
    }
}