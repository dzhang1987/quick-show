import SwiftUI
import AppKit

// MARK: - 权限确认抽屉通知

extension Notification.Name {
    static let quickShowExecuteToolConfirmation = Notification.Name("quickShowExecuteToolConfirmation")
}

// MARK: - 权限确认抽屉内容视图

/// 危险工具权限确认（纯粹 macOS 极客与原生质感）：
/// 1. 标题行：图标 + 明确问询标题（恒常规色，红色只保留给告警横幅一处）；右端轻量状态指示；
/// 2. 破坏性操作全宽高危告警横幅（若有）：状态标签与原因合一，杜绝徽章/胶囊散落重复；
/// 3. 终端代码卡片：自带专属顶栏工具条（微缩三圆点 + sh 标识 + 独立复制按钮），
///    代码主体 100% 独立展示，绝无遮挡；顶栏恒固定，复制按钮永远可达；
/// 4. 记忆规则胶囊条：微圆点风格 + 细描边轻量底板，单行展开不折行；
/// 5. 底部双按钮：严格遵循与 ask_user 一致的消极在左、积极在右规范，紧凑比例（24~26pt），材质平衡。
///
/// 高度纪律：标题/告警/记忆胶囊/按钮行是恒可见的固定区，只有代码卡正文受
/// DrawerBodyArea 预算约束（整抽屉 ≤ 窗口 80%）——长 heredoc 命令只在卡内滚动，
/// 绝不把抽屉顶穿窗口（历史事故：标题与终端顶栏被推到窗外裁掉）。
struct ToolConfirmationDrawerContent: View {
    let request: ToolConfirmationRequest
    /// 整抽屉高度预算（窗口内容高度的 80%），由 AIChatDrawerPanel 统一注入
    let heightBudget: CGFloat

    /// 是否勾选本会话记住规则
    @State private var rememberRule: Bool = false
    /// 参数/命令复制成功反馈状态
    @State private var hasCopied: Bool = false
    /// 复制按钮 hover 状态
    @State private var hoveredCopy: Bool = false
    /// 顶部固定区（标题行 + 高危告警 + 上留白）实测高度
    @State private var topChromeHeight: CGFloat = 0
    /// 底部固定区（记忆胶囊 + 操作按钮 + 下留白）实测高度
    @State private var bottomChromeHeight: CGFloat = 0
    /// 终端卡顶栏实测高度（复制按钮所在行，恒固定不滚动）
    @State private var terminalToolbarHeight: CGFloat = 0

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 固定区（顶部）：标题行 + 高危告警（恒可见，绝不随长命令滚出窗外）
            topChrome

            // 正文区：终端卡 / 参数卡（顶栏固定，代码主体按预算滚动）
            commandOrArgumentsBlock

            // 固定区（底部）：记忆放行规则 + 操作按钮（恒可见）
            bottomChrome
        }
        .padding(.horizontal, Theme.Spacing.section)
        .onReceive(NotificationCenter.default.publisher(for: .quickShowExecuteToolConfirmation)) { _ in
            execute()
        }
    }

    // MARK: - 高度预算

    /// 代码主体可用高度 = 整抽屉预算 − 头尾固定区 − 终端卡顶栏；
    /// 保底 bodyMinHeight：窗口被压到极小（固定区已吃掉大半预算）时仍留几行可读空间。
    private var bodyAvailableHeight: CGFloat {
        let chrome = topChromeHeight + bottomChromeHeight + terminalToolbarHeight
        return max(AIChatDrawerMetrics.bodyMinHeight, heightBudget - chrome)
    }

    // MARK: - 固定区

    /// 顶部固定区：标题行 + 高危告警 + 上留白（实测高供预算扣减）
    private var topChrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
                .padding(.bottom, Theme.Spacing.lg)

            if case .destructive(let reason) = request.riskLevel {
                destructiveAlertView(reason: reason)
                    .padding(.bottom, Theme.Spacing.lg)
            }
        }
        .padding(.top, Theme.Spacing.xxl)
        .measureDrawerHeight(into: $topChromeHeight)
    }

    /// 底部固定区：记忆胶囊 + 操作按钮 + 下留白（实测高供预算扣减）。
    /// 与卡片的呼吸缝沿用原节奏：破坏性操作（无胶囊行）= xxl，常规 = lg。
    private var bottomChrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !request.riskLevel.isDestructive {
                rememberRuleToggle
                    .padding(.bottom, Theme.Spacing.xxl)
            }
            actionButtonsRow
        }
        .padding(.top, request.riskLevel.isDestructive ? Theme.Spacing.xxl : Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xl)
        .measureDrawerHeight(into: $bottomChromeHeight)
    }

    // MARK: - 标题行

    private var headerView: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: headerIconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(headerIconColor)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                // 方案 B：主标题直接呈现核心动作意图，大幅降低决策成本
                Text(request.actionIntent)
                    .font(Theme.Typography.text(Theme.Typography.callout, .semibold))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // 辅助标识栏：标明具体的底层工具（如「终端 Shell (run_shell)」）
                HStack(spacing: 4) {
                    Text(displayName ?? request.toolName)
                        .font(Theme.Typography.text(Theme.Typography.micro, .medium))
                        .foregroundColor(Theme.Colors.contentTertiary)

                    if let toolName = displayName, toolName != request.toolName {
                        Text("(\(request.toolName))")
                            .font(Theme.Typography.mono(Theme.Typography.micro))
                            .foregroundColor(Theme.Colors.contentTertiary.opacity(0.7))
                    }
                }
            }

            Spacer(minLength: 0)

            // 高危状态标签已并入告警横幅；此处仅保留常规确认的轻量指示
            if !request.riskLevel.isDestructive {
                Text("待确认")
                    .font(Theme.Typography.text(Theme.Typography.caption))
                    .foregroundColor(Theme.Colors.contentTertiary)
                    .padding(.top, 2)
            }
        }
    }

    private var headerIconName: String {
        if request.riskLevel.isDestructive {
            // 危险三角符号唯一保留给下方告警横幅，标题行改用盾牌语义避免图标重复
            return "exclamationmark.shield.fill"
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

    /// 全宽高危告警横幅：整抽屉唯一红色警示源（与终端卡同宽同圆角体系）。
    /// 「高危操作」状态标签 + 竖线分隔 + 破坏性原因一行收敛，替代旧徽章与小胶囊的散落重复。
    private func destructiveAlertView(reason: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Color.red.opacity(0.9))
                .font(.system(size: 11, weight: .semibold))

            Text("高危操作")
                .font(Theme.Typography.text(Theme.Typography.caption, .bold))
                .foregroundColor(Color.red.opacity(0.95))

            Rectangle()
                .fill(Color.red.opacity(0.28))
                .frame(width: 1, height: 10)

            Text(reason)
                .font(Theme.Typography.text(Theme.Typography.caption, .medium))
                .foregroundColor(Color.red.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color.red.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.red.opacity(0.22), lineWidth: 0.5)
        )
    }

    // MARK: - 终端代码卡片（集成顶栏，彻底解决遮挡问题）

    /// 上方顶栏恒固定（复制按钮永远可达），下方代码主体按预算滚动。
    private var commandOrArgumentsBlock: some View {
        VStack(spacing: 0) {
            // 终端顶栏（Toolbar）
            terminalHeaderToolbar
                .measureDrawerHeight(into: $terminalToolbarHeight)

            // 0.5pt 细微内分割线
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)

            // 代码主体：自然高度未超预算紧凑包裹，超出锁在预算内滚动（绝无悬浮物遮挡代码）
            DrawerBodyArea(availableHeight: bodyAvailableHeight) { _ in
                if let cmd = shellCommand {
                    terminalCommandSection(cmd)
                } else {
                    normalArgumentsSection
                }
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

    /// 参数主体（JSON 格式化原文）：高度统一交给 DrawerBodyArea 预算，
    /// 不再各自内嵌滚动（双层滚动会让滚轮命中区互相打架）。
    private var normalArgumentsSection: some View {
        argumentsContent
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
