import SwiftUI

// MARK: - Agent 渐变身份徽标（光与纸质感重塑 · 2026-11）
//
// 设计目标：给 agent 一个可复用的「品牌身份」视觉锚点，替代此前裸着的单色 SF Symbol。
// 构成 = accent 实底 + 顶部白光光泽（受光渐变）+ 0.5pt 受光 rim + 高对比图标，
// 大尺寸（欢迎页）再叠一圈品牌色氛围柔光。尺寸参数化：圆角 / 图标按比例缩放，
// 顶栏 / 助手回合锚点 / 欢迎页三处共用同一组件，视觉语言单一来源。
//
// 色彩纪律：底色 / 前景 / 光泽 / rim 全部走 DesignTokens（Theme.Colors.agentMark*），
// 随主题变体（黑曜极光蓝 / 琥珀香槟金）与明暗外观自动适配，本视图不硬编码任何色值。

/// Agent 渐变身份徽标。
struct AgentIdentityMark: View {
    /// SF Symbol 图标名（来自 AIAgent.iconName）。
    let iconName: String
    /// 徽标边长（默认顶栏档）。
    var size: CGFloat = Theme.Layout.chatTopBarMarkSize
    /// 是否叠加品牌色氛围柔光（欢迎页大徽标用；小尺寸默认关闭避免噪声）。
    var showsGlow: Bool = false

    /// 连续曲率圆角（随尺寸等比，保持同一圆润语言）。
    private var cornerRadius: CGFloat { size * 0.30 }
    /// 图标字号（随尺寸等比）。
    private var iconSize: CGFloat { size * 0.52 }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.Colors.accent)
            // 顶部白光光泽：在 accent 实底上形成「顶部受光」渐变，徽标立刻有体积感
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.Colors.agentMarkSheenTop, Theme.Colors.agentMarkSheenBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            // 0.5pt 受光 rim：精细高光勾边，与输入坞微胶囊同一克制语言
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Colors.agentMarkRim, lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: iconName)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundColor(Theme.Colors.agentMarkForeground)
            )
            .frame(width: size, height: size)
            // 氛围柔光：仅大尺寸开启，品牌色向外晕染一圈柔光（欢迎页品牌时刻）
            .shadow(
                color: Theme.Colors.accent.opacity(showsGlow ? Theme.Colors.agentMarkGlowOpacity : 0),
                radius: showsGlow ? size * 0.35 : 0,
                y: 0
            )
            .accessibilityHidden(true)
    }
}

// MARK: - 助手回合身份锚点

/// 助手回合起始的身份锚点：小徽标 + agent 名。
/// 给「无气泡裸排」的助手文字一个「谁在说话」的结构锚点——不加气泡、不铺底，
/// 名字走三级弱文本，存在感克制，仅作回合节奏与身份辨识。
struct AssistantTurnAnchor: View {
    let agent: AIAgent

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            AgentIdentityMark(iconName: agent.iconName, size: Theme.Layout.chatTurnAnchorMarkSize)
            Text(agent.name)
                .font(Theme.Typography.text(Theme.Typography.chatTurnAnchorName, .medium))
                .foregroundColor(Theme.Colors.contentTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agent.name)
    }
}