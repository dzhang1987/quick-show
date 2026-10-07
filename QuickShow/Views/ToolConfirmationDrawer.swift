import SwiftUI

// MARK: - 权限确认抽屉

/// 危险工具权限确认：工具名徽章 + 参数代码块（长命令默认单行摘要、点击展开）+ 三按钮。
/// 三按钮语义：拒绝（次要）/ 执行（主要实心）/ 本会话总是允许（描边第三样式）；
/// ESC = 拒绝（窗口层/视图层链路统一走 resolveConfirmation(.denied)）。
struct ToolConfirmationDrawerContent: View {
    let request: ToolConfirmationRequest

    /// 完整参数是否已展开（默认单行摘要）。
    @State private var argumentsExpanded = false
    /// 「完整参数」入口 hover 态。
    @State private var toggleHovered = false

    /// 美化后的完整参数（展开态展示）。
    private var prettyArguments: String { ToolJSONText.pretty(request.argumentsJSON) }

    /// 是否「长命令」：多行或超长 → 默认折叠为单行摘要 + 提供展开入口；
    /// 短参数直接完整展示，不制造无意义的折叠/展开切换。
    private var hasMoreArguments: Bool {
        let trimmed = request.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("\n") || trimmed.count > AIChatDrawerMetrics.argumentsShortLimit
    }

    /// 工具中文展示名（注册表查不到时省略，徽章已承担蛇形名展示）。
    private var displayName: String? {
        AIToolRegistry.shared.tool(named: request.toolName)?.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            // 标题行：工具名徽章（等宽小字）+ 请求执行权限；右端附中文展示名
            HStack(spacing: Theme.Spacing.lg) {
                Text(request.toolName)
                    .font(Theme.Typography.mono(Theme.Typography.mini, .medium))
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                            .fill(Theme.Colors.surfaceBadge)
                    )
                Text("请求执行权限")
                    .font(Theme.Typography.text(Theme.Typography.callout, .semibold))
                    .foregroundColor(Theme.Colors.contentPrimary)
                Spacer(minLength: 0)
                if let displayName, displayName != request.toolName {
                    Text(displayName)
                        .font(Theme.Typography.text(Theme.Typography.caption))
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .lineLimit(1)
                }
            }

            argumentsBlock

            // 按钮行：消极在左、积极在右（拒绝远离主操作区）
            HStack(spacing: Theme.Spacing.lg) {
                DrawerActionButton(title: "拒绝", style: .secondary) {
                    ChatInteractionCenter.shared.resolveConfirmation(.denied)
                }
                Spacer(minLength: 0)
                DrawerActionButton(title: "本会话总是允许", style: .outlined) {
                    ChatInteractionCenter.shared.resolveConfirmation(.alwaysAllowThisSession)
                }
                DrawerActionButton(title: "执行", style: .primary) {
                    ChatInteractionCenter.shared.resolveConfirmation(.executeOnce)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.top, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.xl)
    }

    // MARK: 参数代码块

    /// 参数区：等宽小号 + 内嵌深色底（与工具卡参数区同一语言）。
    /// 长命令折叠态单行摘要（点击整块或右上「完整参数」展开）；展开态多行可滚动、限高。
    private var argumentsBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.lg) {
                Text("参数")
                    .font(Theme.Typography.text(Theme.Typography.mini, .semibold))
                    .foregroundColor(Theme.Colors.contentTertiary)
                Spacer(minLength: 0)
                if hasMoreArguments {
                    Button {
                        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                            argumentsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(argumentsExpanded ? "收起" : "完整参数")
                                .font(Theme.Typography.text(Theme.Typography.mini, .medium))
                            Image(systemName: "chevron.right")
                                .font(Theme.Typography.text(8, .semibold))
                                .rotationEffect(.degrees(argumentsExpanded ? 90 : 0))
                        }
                        .foregroundColor(toggleHovered ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { toggleHovered = hovering }
                    }
                    .qsHelp(argumentsExpanded ? "收起参数" : "展开查看完整参数")
                }
            }

            Group {
                if argumentsExpanded {
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(prettyArguments)
                            .font(Theme.Typography.mono(Theme.Typography.footnote))
                            .foregroundColor(Theme.Colors.contentSecondaryStrong)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: AIChatDrawerMetrics.argumentsMaxHeight, alignment: .top)
                } else {
                    Text(request.summary)
                        .font(Theme.Typography.mono(Theme.Typography.footnote))
                        .foregroundColor(Theme.Colors.contentSecondaryStrong)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.surfaceBadge)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous))
            .onTapGesture {
                // 点击代码块本身同样切换展开（仅长命令可展开时）
                guard hasMoreArguments else { return }
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                    argumentsExpanded.toggle()
                }
            }
        }
    }
}
