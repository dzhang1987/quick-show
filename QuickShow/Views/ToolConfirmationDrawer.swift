import SwiftUI
import AppKit

// MARK: - 权限确认抽屉通知

extension Notification.Name {
    static let quickShowExecuteToolConfirmation = Notification.Name("quickShowExecuteToolConfirmation")
}

// MARK: - 权限确认抽屉内容视图

/// 危险工具权限确认（纯粹 macOS 极客与原生质感）：
/// 1. 标题行：图标 + 明确问询标题（剔除冗余蛇形名与重复说明）；右端轻量状态指示；
/// 2. 破坏性操作高危告警提示条（若有）；
/// 3. 终端代码卡片：自带专属顶栏工具条（微缩三圆点 + sh 标识 + 独立复制按钮），代码主体 100% 独立展示，绝无遮挡；
/// 4. 记忆规则胶囊条：微圆点风格 + 细描边轻量底板，单行展开不折行；
/// 5. 底部双按钮：严格遵循与 ask_user 一致的消极在左、积极在右规范，紧凑比例（24~26pt），材质平衡。
struct ToolConfirmationDrawerContent: View {
    let request: ToolConfirmationRequest

    /// 是否勾选本会话记住规则
    @State private var rememberRule: Bool = false
    /// 参数/命令复制成功反馈状态
    @State private var hasCopied: Bool = false
    /// 复制按钮 hover 状态
    @State private var hoveredCopy: Bool = false
    /// 完整参数区自然高度测量（用于自适应，消除多余空白）
    @State private var argumentsContentHeight: CGFloat = 0

    /// 针对终端 Shell 工具提取真实执行命令（直达人类可读意图）
    private var shellCommand: String? {
        guard request.toolName == "run_shell" || request.toolName == "shell" else { return nil }
        guard let data = request.argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = dict["command"] as? String else {
            return nil
        }
        return cmd
    }

    /// 美化后的完整参数（JSON 格式化换行与缩进）。
    private var prettyArguments: String { ToolJSONText.pretty(request.argumentsJSON) }

    /// 显示参数文本：优先完整格式化参数，兜底摘要。
    private var displayArguments: String {
        let trimmed = prettyArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? request.summary : trimmed
    }

    /// 工具中文展示名。
    private var displayName: String? {
        AIToolRegistry.shared.tool(named: request.toolName)?.displayName
    }

    /// 标题主文案（剔除重复冗余）
    private var headerTitle: String {
        if request.riskLevel.isDestructive {
            return String(localized: "高危指令待确认")
        }
        if request.toolName == "run_shell" || request.toolName == "shell" {
            return String(localized: "执行 Shell 命令")
        }
        return displayName ?? request.toolName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题行：精致图标 + 标题；右端轻量提示
            headerView
                .padding(.bottom, Theme.Spacing.lg)

            // 破坏性操作高危告警提示条
            if case .destructive(let reason) = request.riskLevel {
                destructiveAlertView(reason: reason)
                    .padding(.bottom, Theme.Spacing.lg)
            }

            // 终端风格代码卡片（自带独立顶栏，绝无按钮遮挡代码）
            commandOrArgumentsBlock
                .padding(.bottom, !request.riskLevel.isDestructive ? Theme.Spacing.lg : Theme.Spacing.xl)

            // 记忆放行规则微胶囊条
            if !request.riskLevel.isDestructive {
                rememberRuleToggle
                    .padding(.bottom, Theme.Spacing.xl)
            }

            // 底部操作按钮行：严格与 ask_user 保持一致（左退右进，紧凑轻盈）
            actionButtonsRow
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.top, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.xl)
        .onPreferenceChange(DrawerArgumentsHeightPreferenceKey.self) { height in
            argumentsContentHeight = height
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickShowExecuteToolConfirmation)) { _ in
            execute()
        }
    }

    // MARK: - 标题行

    private var headerView: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: headerIconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(headerIconColor)

            Text(headerTitle)
                .font(Theme.Typography.text(Theme.Typography.callout, .semibold))
                .foregroundColor(request.riskLevel.isDestructive ? Color.red.opacity(0.9) : Theme.Colors.contentPrimary)

            Spacer(minLength: 0)

            if request.riskLevel.isDestructive {
                Text("高危操作")
                    .font(Theme.Typography.mono(Theme.Typography.micro, .bold))
                    .foregroundColor(Color.red.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.red.opacity(0.12))
                    )
            } else {
                Text("待确认")
                    .font(Theme.Typography.text(Theme.Typography.caption))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }
        }
    }

    private var headerIconName: String {
        if request.riskLevel.isDestructive {
            return "exclamationmark.triangle.fill"
        }
        if shellCommand != nil {
            return "terminal.fill"
        }
        return "shield.lefthalf.filled"
    }

    private var headerIconColor: Color {
        if request.riskLevel.isDestructive {
            return Color.red.opacity(0.9)
        }
        return Theme.Colors.accent
    }

    private func destructiveAlertView(reason: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Color.red.opacity(0.9))
                .font(.system(size: 11, weight: .semibold))
            Text(reason)
                .font(Theme.Typography.text(Theme.Typography.caption, .medium))
                .foregroundColor(Color.red.opacity(0.9))
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .fill(Color.red.opacity(0.12))
        )
    }

    // MARK: - 终端代码卡片（集成顶栏，彻底解决遮挡问题）

    private var commandOrArgumentsBlock: some View {
        VStack(spacing: 0) {
            // 终端顶栏（Toolbar）
            terminalHeaderToolbar

            // 0.5pt 细微内分割线
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)

            // 代码主体内容（绝对无悬浮物遮挡）
            if let cmd = shellCommand {
                terminalCommandSection(cmd)
            } else {
                normalArgumentsSection
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color(red: 0.08, green: 0.085, blue: 0.095))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
        )
    }

    private var terminalHeaderToolbar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // macOS 极简三色微圆点装饰
            HStack(spacing: 5) {
                Circle().fill(Color.red.opacity(0.70)).frame(width: 6.5, height: 6.5)
                Circle().fill(Color.yellow.opacity(0.70)).frame(width: 6.5, height: 6.5)
                Circle().fill(Color.green.opacity(0.70)).frame(width: 6.5, height: 6.5)
            }

            Text(shellCommand != nil ? "sh" : "json")
                .font(Theme.Typography.mono(Theme.Typography.micro, .medium))
                .foregroundColor(Color.white.opacity(0.40))
                .padding(.leading, 2)

            Spacer(minLength: 0)

            // 专属顶栏复制操作（优雅融入，带 hover 与点击反馈，绝不遮挡代码）
            Button(action: {
                let textToCopy = shellCommand ?? displayArguments
                copyText(textToCopy)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                    Text(hasCopied ? "已复制" : "复制")
                        .font(Theme.Typography.text(Theme.Typography.micro, .medium))
                }
                .foregroundColor(hasCopied ? Theme.Colors.statusPositive : Color.white.opacity(hoveredCopy ? 0.90 : 0.55))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(hoveredCopy ? 0.12 : (hasCopied ? 0.15 : 0.05)))
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                    hoveredCopy = hovering
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, 6)
    }

    private func terminalCommandSection(_ cmd: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Text("$")
                .font(Theme.Typography.mono(Theme.Typography.footnote, .bold))
                .foregroundColor(Theme.Colors.accent)
                .padding(.top, 1)

            Text(cmd)
                .font(Theme.Typography.mono(Theme.Typography.footnote))
                .foregroundColor(Color(white: 0.92))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, Theme.Spacing.lg)
    }

    private var normalArgumentsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if argumentsContentHeight > AIChatDrawerMetrics.argumentsMaxHeight {
                ScrollView(.vertical, showsIndicators: false) {
                    argumentsContent
                }
                .frame(height: AIChatDrawerMetrics.argumentsMaxHeight, alignment: .top)
            } else {
                argumentsContent
            }
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, Theme.Spacing.lg)
    }

    private var argumentsContent: some View {
        Text(displayArguments)
            .font(Theme.Typography.mono(Theme.Typography.footnote))
            .foregroundColor(Color(white: 0.92))
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

    // MARK: - 记忆规则微胶囊条

    private var rememberRuleToggle: some View {
        let scopeTitle = request.suggestedScope?.displayTitle ?? String(localized: "记住此工具，本会话不再询问")
        return Button(action: {
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                rememberRule.toggle()
            }
        }) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: rememberRule ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(rememberRule ? Theme.Colors.accent : Theme.Colors.contentTertiary)

                Text(scopeTitle)
                    .font(Theme.Typography.text(Theme.Typography.caption))
                    .foregroundColor(rememberRule ? Theme.Colors.contentPrimary : Theme.Colors.contentSecondaryStrong)
                    .lineLimit(1)

                Spacer(minLength: 0)

                HStack(spacing: 3) {
                    Text("按")
                        .font(Theme.Typography.text(Theme.Typography.micro))
                        .foregroundColor(Theme.Colors.contentTertiary)
                    HStack(spacing: 2) {
                        Text("⌘")
                            .font(Theme.Typography.mono(Theme.Typography.micro, .medium))
                        Text("⏎")
                            .font(Theme.Typography.mono(Theme.Typography.micro, .medium))
                    }
                    .foregroundColor(Theme.Colors.contentSecondaryStrong)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Theme.Colors.surfaceKeyCap)
                    )
                    Text("直接放行")
                        .font(Theme.Typography.text(Theme.Typography.micro))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
            }
            .padding(.horizontal, Theme.Spacing.card)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(rememberRule ? Theme.Colors.accent.opacity(0.08) : Theme.Colors.surfaceButton)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .strokeBorder(rememberRule ? Theme.Colors.accent.opacity(0.35) : Theme.Colors.cardStroke, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 按钮行（左退右进，紧凑轻盈）

    private var actionButtonsRow: some View {
        HStack(spacing: Theme.Spacing.lg) {
            DrawerActionButton(title: String(localized: "拒绝"), shortcut: "esc", style: .secondary) {
                ChatInteractionCenter.shared.resolveConfirmation(.denied)
            }
            Spacer(minLength: 0)
            DrawerActionButton(title: String(localized: "执行"), shortcut: "⏎", style: .primary) {
                execute()
            }
        }
    }

    // MARK: - 操作执行

    private func execute() {
        if rememberRule && !request.riskLevel.isDestructive {
            if let scope = request.suggestedScope {
                ChatInteractionCenter.shared.resolveConfirmation(.allowSuggestedScope(scope))
            } else {
                ChatInteractionCenter.shared.resolveConfirmation(.alwaysAllowThisSession)
            }
        } else {
            ChatInteractionCenter.shared.resolveConfirmation(.executeOnce)
        }
    }

    private func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        hasCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            hasCopied = false
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
