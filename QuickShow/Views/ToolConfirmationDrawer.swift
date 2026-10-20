import SwiftUI

// MARK: - 权限确认抽屉

/// 危险工具权限确认：工具名徽章 + 参数完整代码块（默认完整呈现、自适应换行、超长限高内部滚动）+ 三按钮。
/// 三按钮语义：拒绝（次要）/ 执行（主要实心）/ 本会话总是允许（描边第三样式）；
/// ESC = 拒绝（窗口层/视图层链路统一走 resolveConfirmation(.denied)）。
struct ToolConfirmationDrawerContent: View {
    let request: ToolConfirmationRequest

    /// 完整参数区自然高度测量（用于自适应，消除多余空白）
    @State private var argumentsContentHeight: CGFloat = 0

    /// 美化后的完整参数（JSON 格式化换行与缩进）。
    private var prettyArguments: String { ToolJSONText.pretty(request.argumentsJSON) }

    /// 显示参数文本：优先完整格式化参数，兜底摘要。
    private var displayArguments: String {
        let trimmed = prettyArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? request.summary : trimmed
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
                DrawerActionButton(title: String(localized: "拒绝"), style: .secondary) {
                    ChatInteractionCenter.shared.resolveConfirmation(.denied)
                }
                Spacer(minLength: 0)
                DrawerActionButton(title: String(localized: "本会话总是允许"), style: .outlined) {
                    ChatInteractionCenter.shared.resolveConfirmation(.alwaysAllowThisSession)
                }
                DrawerActionButton(title: String(localized: "执行"), style: .primary) {
                    ChatInteractionCenter.shared.resolveConfirmation(.executeOnce)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.top, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.xl)
        .onPreferenceChange(DrawerArgumentsHeightPreferenceKey.self) { height in
            argumentsContentHeight = height
        }
    }

    // MARK: - 参数代码块（默认完整呈现、自适应换行、超长限高内部滚动）

    private var argumentsBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("参数")
                .font(Theme.Typography.text(Theme.Typography.mini, .semibold))
                .foregroundColor(Theme.Colors.contentTertiary)

            argumentsSection
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                        .fill(Theme.Colors.surfaceBadge)
                )
        }
    }

    private var argumentsContent: some View {
        Text(displayArguments)
            .font(Theme.Typography.mono(Theme.Typography.footnote))
            .foregroundColor(Theme.Colors.contentSecondaryStrong)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DrawerArgumentsHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            )
    }

    @ViewBuilder
    private var argumentsSection: some View {
        if argumentsContentHeight > AIChatDrawerMetrics.argumentsMaxHeight {
            ScrollView(.vertical, showsIndicators: false) {
                argumentsContent
            }
            .frame(height: AIChatDrawerMetrics.argumentsMaxHeight, alignment: .top)
        } else {
            argumentsContent
        }
    }
}

// MARK: - 内部高度测量键

private struct DrawerArgumentsHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
