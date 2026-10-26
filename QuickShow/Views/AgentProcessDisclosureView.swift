import AppKit
import SwiftUI

// MARK: - 智能体回合执行过程折叠栏 (Agent Turn Process Disclosure)
//
// 终局设计哲学（基于第一性原理）：
// 1. 回合级聚合（Turn-level Trace Aggregation）：
//    一次提问对应的全部多轮推导与工具动作，统摄为唯一的过程栏。彻底消除多轮调用产生的“千层饼/手风琴”堆叠。
// 2. 去卡片化极简流（Borderless / Ambient Stream）：
//    告别生硬的圆角边框大盒子与厚重底色。收起态通透自然，犹如正文上方的灵动元数据；
// 3. 结构化时间线（Execution Timeline）：
//    展开后按步骤与轮次条理清晰地呈现推导心路与工具调研成果，因果链条一目了然。

/// 记忆用户主动切换折叠态（按回合 turnId 键控）：
/// LazyVStack 反实例化重建（滚动回收）时恢复上次用户指定的状态。
enum TurnProcessDisclosureMemory {
    private static var userToggledById: [UUID: Bool] = [:]

    static func userToggledState(for turnId: UUID) -> Bool? {
        userToggledById[turnId]
    }

    static func note(for turnId: UUID, expanded: Bool) {
        userToggledById[turnId] = expanded
    }
}

/// 智能体回合执行过程折叠视图
struct AgentProcessDisclosureView: View {
    let turnId: UUID
    let trace: AgentTurnTrace
    let hasContent: Bool

    @State private var expanded: Bool
    @State private var hovered = false

    init(
        turnId: UUID,
        trace: AgentTurnTrace,
        hasContent: Bool
    ) {
        self.turnId = turnId
        self.trace = trace
        self.hasContent = hasContent

        if let remembered = TurnProcessDisclosureMemory.userToggledState(for: turnId) {
            _expanded = State(initialValue: remembered)
        } else {
            // 默认策略：正在流式且正文未产出时展开展示过程；一旦已落定或正文已有内容，默认收起
            _expanded = State(initialValue: trace.isLive && !hasContent)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                expandedBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 去卡片化：收起态完全通透；展开态采用极淡的内嵌底与左侧微光线，无硬外边框
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(expanded ? Theme.Colors.surfaceInset : (hovered ? Theme.Colors.surfaceCard : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .stroke(expanded ? Theme.Colors.cardStroke.opacity(0.4) : Color.clear, lineWidth: 0.5)
        )
        .onHover { isHovering in
            hovered = isHovering
        }
        // 收尾对账：生成结束时平滑收起至单行摘要（除非用户手动固定展开）
        .onChange(of: trace.isLive) { live in
            if !live {
                if TurnProcessDisclosureMemory.userToggledState(for: turnId) == nil {
                    withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                        expanded = false
                    }
                }
            }
        }
        // 正文开流时：若用户未主动操作，自动收缩折叠，视觉舞台让位给打字机正文
        .onChange(of: hasContent) { hasText in
            if hasText && trace.isLive && TurnProcessDisclosureMemory.userToggledState(for: turnId) == nil && expanded {
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
                    expanded = false
                }
            }
        }
    }

    private func toggleExpanded() {
        let next = !expanded
        TurnProcessDisclosureMemory.note(for: turnId, expanded: next)
        withAnimation(.easeOut(duration: Theme.Motion.contentFade)) {
            expanded = next
        }
    }

    // MARK: - Header 状态行（去卡片化极简通透栏）

    private var headerIconName: String {
        if trace.isLive {
            if trace.hasTools { return "gearshape.arrow.triangle.2.circlepath" }
            return "brain"
        }
        if trace.hasReasoning && trace.hasTools { return "sparkles" }
        if trace.hasTools { return "wrench.and.screwdriver" }
        return "brain"
    }

    private var headerTitle: String {
        if trace.isLive {
            if let running = trace.runningToolDisplayName {
                if trace.roundCount > 1 {
                    return String(localized: "正在调用 \(running)… · 第 \(trace.roundCount) 轮")
                }
                return String(localized: "正在调用 \(running)…")
            }
            if trace.hasReasoning {
                return String(localized: "深度思考中…")
            }
            return String(localized: "智能体执行中…")
        }
        if trace.roundCount > 1 {
            return String(localized: "思考与调研过程")
        }
        if trace.hasReasoning && trace.hasTools {
            return String(localized: "思考与工具调用")
        }
        if trace.hasTools {
            return String(localized: "工具调用")
        }
        return String(localized: "思考过程")
    }

    private var headerSubtitle: String? {
        guard !expanded else { return nil }
        if trace.isLive { return nil }

        if trace.roundCount > 1 {
            let toolsTotal = trace.totalToolsCount
            let failed = trace.failedToolsCount
            if failed > 0 {
                return "\(trace.roundCount) 轮调用 · \(toolsTotal) 个工具（\(failed) 个未成功）"
            } else {
                return "\(trace.roundCount) 轮调用 · 共 \(toolsTotal) 个工具全部完成"
            }
        } else if trace.hasTools {
            let toolsTotal = trace.totalToolsCount
            let failed = trace.failedToolsCount
            if failed > 0 {
                return "\(toolsTotal) 个工具（\(failed) 个未成功）"
            } else {
                return "\(toolsTotal) 个工具已完成"
            }
        } else if trace.hasReasoning {
            return trace.latestReasoningSummary
        }
        return nil
    }

    private var header: some View {
        Button(action: toggleExpanded) {
            HStack(spacing: Theme.Spacing.sm) {
                if trace.isLive && trace.hasTools {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: headerIconName)
                        .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                        .foregroundColor(trace.isLive ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                }

                Text(headerTitle)
                    .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                    .foregroundColor(trace.isLive ? Theme.Colors.accent : Theme.Colors.contentSecondaryStrong)

                if let subtitle = headerSubtitle {
                    Text("·")
                        .foregroundColor(Theme.Colors.contentTertiary)
                    Text(subtitle)
                        .font(Theme.Typography.text(Theme.Typography.footnote))
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: Theme.Spacing.sm)

                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(Theme.Typography.text(Theme.Typography.micro, .medium))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? String(localized: "收起执行过程") : String(localized: "展开思考与调研过程"))
    }

    // MARK: - 展开区（执行时间线）

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Rectangle()
                .fill(Theme.Colors.cardStroke.opacity(0.5))
                .frame(height: Theme.Layout.dividerHeight)
                .padding(.horizontal, Theme.Spacing.sm)

            if trace.roundCount <= 1, let firstStep = trace.steps.first {
                // 单轮轻量直出
                singleStepContent(step: firstStep)
            } else {
                // 多轮时间线聚合
                multiStepTimeline
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.md)
        .transition(.opacity)
    }

    // MARK: 单轮展示

    @ViewBuilder
    private func singleStepContent(step: AgentTurnTrace.Step) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if step.hasReasoning, let reasoning = step.reasoning {
                TurnReasoningSectionView(
                    content: reasoning,
                    isLive: step.isLive,
                    isExpanded: expanded
                )
            }
            if step.hasTools {
                EmbeddedToolCallListView(toolCalls: step.toolCalls)
            }
        }
    }

    // MARK: 多轮时间线展示

    @ViewBuilder
    private var multiStepTimeline: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            ForEach(Array(trace.steps.enumerated()), id: \.element.id) { index, step in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    // 轮次节点标头
                    HStack(spacing: Theme.Spacing.xs) {
                        Circle()
                            .fill(step.isLive ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                            .frame(width: 4.5, height: 4.5)
                        Text("第 \(step.roundIndex) 轮")
                            .font(Theme.Typography.text(10.5, .semibold))
                            .foregroundColor(Theme.Colors.contentSecondaryStrong)
                        if step.hasTools {
                            Text("· \(step.toolCalls.count) 个工具")
                                .font(Theme.Typography.text(10))
                                .foregroundColor(Theme.Colors.contentTertiary)
                        }
                        Spacer()
                    }

                    // 节点内部内容
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        if step.hasReasoning, let reasoning = step.reasoning {
                            TurnReasoningSectionView(
                                content: reasoning,
                                isLive: step.isLive,
                                isExpanded: expanded
                            )
                        }
                        if step.hasTools {
                            EmbeddedToolCallListView(toolCalls: step.toolCalls)
                        }
                    }
                    .padding(.leading, Theme.Spacing.md)
                }

                if index < trace.steps.count - 1 {
                    Rectangle()
                        .fill(Theme.Colors.cardStroke.opacity(0.3))
                        .frame(height: Theme.Layout.dividerHeight)
                        .padding(.leading, Theme.Spacing.md)
                }
            }
        }
    }
}

// MARK: - 单轮独立思考过程排版区 (Turn Reasoning Section View)

/// 独立管理单轮思考过程的渲染、流式节流与高度自适应：
/// 1. 物理高度自适应包裹（shrink-to-fit）：单轮内容较短时紧贴文字，杜绝多余空白；
/// 2. 超过上限时限高滚动（max-height clamping）：内容超长时锁定在 reasoningMaxHeight 并平滑滚动；
/// 3. 轮次间状态完全隔离：彻底杜绝多轮聚合时不同轮次的高度状态互相污染。
private struct TurnReasoningSectionView: View {
    let content: String
    let isLive: Bool
    let isExpanded: Bool

    @State private var measuredHeight: CGFloat = 0
    @State private var renderedReasoning: String = ""
    @State private var lastRenderAt: Date = .distantPast

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    let text = renderedReasoning.isEmpty ? content : renderedReasoning
                    if text.isEmpty && isLive {
                        HStack(spacing: Theme.Spacing.sm) {
                            BlinkingCaret()
                            Text("思考中…")
                                .font(Theme.Typography.text(Theme.Typography.footnote))
                                .foregroundColor(Theme.Colors.contentTertiary)
                        }
                        .padding(.vertical, 2)
                    } else {
                        ReasoningMarkdownView(content: text, useCache: !isLive)
                        if isLive {
                            BlinkingCaret()
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("turnReasoningBottomAnchor")
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: TurnReasoningContentHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .frame(height: measuredHeight > 0 ? min(measuredHeight, Theme.Layout.reasoningMaxHeight) : nil)
            .frame(maxHeight: Theme.Layout.reasoningMaxHeight)
            .onPreferenceChange(TurnReasoningContentHeightKey.self) { h in
                if h > 0, abs(measuredHeight - h) >= 1.0 {
                    measuredHeight = h
                }
            }
            .onAppear {
                renderedReasoning = content
                lastRenderAt = Date()
            }
            .onChange(of: content) { newValue in
                if isLive {
                    let now = Date()
                    if now.timeIntervalSince(lastRenderAt) >= 0.08 {
                        lastRenderAt = now
                        renderedReasoning = newValue
                    }
                    if isExpanded {
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo("turnReasoningBottomAnchor", anchor: .bottom)
                            }
                        }
                    }
                } else {
                    renderedReasoning = newValue
                }
            }
            .onChange(of: isLive) { live in
                if !live {
                    renderedReasoning = content
                }
            }
        }
        .padding(.leading, 2.5 + Theme.Spacing.sm)
        .padding(.trailing, Theme.Spacing.sm)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                .fill(isLive ? Theme.Colors.accent.opacity(0.45) : Theme.Colors.contentTertiary.opacity(0.35))
                .frame(width: 2)
                .padding(.vertical, 2)
                .padding(.leading, Theme.Spacing.xs)
        }
    }
}

private struct TurnReasoningContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
