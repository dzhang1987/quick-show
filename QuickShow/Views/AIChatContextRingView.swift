import SwiftUI

// MARK: - 上下文水位圆环（水位 / 详情浮层 / 压缩入口 三合一）

/// 上下文水位圆环：输入坞低频工具组的「态势感知」控件（2026-10 重设计），
/// 取代旧版「水位小字 + ⟲ 压缩钮」双控件组合——一枚 14pt 描边空心环同时承担三职：
///   1. 环体即水位：12 点起步顺时针，亮弧 = 已用/窗口比例，暗弧 = 剩余轨道；
///   2. hover 弹详情卡：已用/窗口/百分比与已压缩摘要信息（自绘浮层，刻意不挂系统
///      .help——与 tick 预览胶囊同款理由：自绘浮层与系统 tooltip 语义冗余）；
///   3. 点击即压缩：整环是一枚按钮，触发 onCompact。
///
/// 视觉纪律（与图钉/发送同一克制语言）：
/// - 静止纯灰无底：亮弧 iconRest、轨道再降透明度，无渐变无发光无多余色彩；
/// - hover 才出圆底提亮（iconHoverBg + iconHover），不常驻 rim；
/// - 警戒破格：ratio > 0.8 亮弧转 statusWarning（阈值与调用侧 showDockSecondaryTools
///   的破格常显同源）——需要警示的时刻不沉默；
/// - 压缩中：水位弧让位于不定态转圈（固定 1/4 圈亮弧 iconHover、线性匀速 1s/圈），
///   禁用点击但全亮——「进行中」是活跃信号，不再做 0.5 降透明度弱化
///  （2026-10 用户决策：取代先前「纯禁用弱化、不换旋转/进度轮」的约定；
///   压缩中并由调用侧 showDockSecondaryTools 破格常显，进行中的操作不消失）；
/// - 动效只用 Theme.Motion.contentFade 的 ease-out；唯转圈是线性匀速（不定态语义本身）。
///
/// 结构纪律（详情卡的渲染层级）：
/// macOS 26+ 的 .glassEffect 会把内容裁剪进玻璃形状——详情卡若挂在坞内按钮的
/// overlay，向上弹出部分会被输入卡顶缘切断。故本组件只在 hover 时经
/// anchorPreference 上报「自身锚点 + 数据快照」，卡片由调用侧在玻璃裁剪域之外
/// 挂载（见 View.contextRingDetailHost()）。
struct AIChatContextRingView: View {
    /// 水位快照（usedTokens/windowTokens/ratio；真源在 AIChatState.contextWatermark）。
    let watermark: ContextWatermark
    /// 压缩进行中：环体切换为不定态转圈 + 禁用点击（见头注视觉纪律）。
    let isCompacting: Bool
    /// 已压缩消息条数（nil = 从未压缩；详情卡的摘要行据此显隐）。
    let summarizedCount: Int?
    /// 当前会话的最近一次压缩结果（state.currentSessionOutcome；失败行据此显隐）。
    let compactionOutcome: CompactionOutcome?
    /// 点击圆环触发压缩（调用侧接 AIChatState.compactNow()）。
    let onCompact: () -> Void

    /// hover 态：驱动圆底提亮、亮弧增色与详情卡上报。
    @State private var hovered = false
    /// 不定态转圈角（度）：仅 isCompacting 期间由无限动画驱动 0→360 循环；
    /// 停止时禁用动画归零——不残留中间角度、不继续微转，下次启动恒从 12 点干净起步。
    @State private var spinnerAngle: Double = 0

    /// 环体直径 14pt：比 13pt 图标略大一档——空心描边环无填充、视觉偏小，
    /// 与电池图标「视觉偏小需加大一档」同思路；点击区仍对齐 24pt 图标钮档位。
    private let ringDiameter: CGFloat = 14
    /// 线宽 1.5pt：1x 屏不发虚（1pt 底线之上），2x 屏不臃肿（2pt 之下）。
    private let ringLineWidth: CGFloat = 1.5
    /// 警戒阈值：与调用侧 watermarkBreaksThrough（showDockSecondaryTools 破格）同源。
    private let warningRatio: Double = 0.8
    /// 不定态弧长：固定 1/4 圈。
    private let spinnerArcFraction: Double = 0.25
    /// 不定态转速：线性匀速 1s/圈。
    private let spinnerPeriod: Double = 1.0

    private var isWarning: Bool { watermark.ratio > warningRatio }

    /// 亮弧色：警戒 > hover > 静止（警戒态 hover 不再提亮——statusWarning 已是强调色）。
    private var arcColor: Color {
        if isWarning { return Theme.Colors.statusWarning }
        return hovered ? Theme.Colors.iconHover : Theme.Colors.iconRest
    }

    var body: some View {
        Button(action: onCompact) {
            ZStack {
                // 暗弧轨道：iconRest 再降透明度——存在感低于亮弧，只界定「满环在哪」；
                // 转圈期间轨道保留（不定态弧绕轨道运行的参照系）
                Circle()
                    .stroke(Theme.Colors.iconRest.opacity(0.35), lineWidth: ringLineWidth)
                if isCompacting {
                    // 不定态 spinner：隐藏水位弧，固定 1/4 圈亮弧线性匀速循环。
                    // 与水位弧互斥渲染（if/else 分支 + opacity 交叉淡化）——两个
                    // .animation(value:) 修饰器各管各的，互不干扰；色用 iconHover 档
                    // 全亮（「进行中」是活跃信号，不做禁用降透明度）
                    Circle()
                        .trim(from: 0, to: spinnerArcFraction)
                        .stroke(Theme.Colors.iconHover,
                                style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90 + spinnerAngle))
                        .transition(.opacity)
                } else {
                    // 水位弧：12 点起步（rotationEffect -90°）顺时针；round 端点在极小尺寸
                    // 下更精致；ratio 钳制 [0,1]，水位估算越界（如 usage 超窗）不脱轨
                    Circle()
                        .trim(from: 0, to: min(max(watermark.ratio, 0), 1))
                        .stroke(arcColor, style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .transition(.opacity)
                }
            }
            .frame(width: ringDiameter, height: ringDiameter)
            // 点击/hover 区对齐全组统一的 24pt 图标钮档位；hover 圆底是家族语言
            //（压缩中禁用点击，圆底不出——但 onHover 仍驱动详情卡上报）
            .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
            .background(
                Circle().fill(hovered && !isCompacting ? Theme.Colors.iconHoverBg : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCompacting)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
        // 转圈启停：isCompacting 翻转即启动/停止，启停边界干净（见函数注释）；
        // onAppear 兜底「进窗时已在压缩」（onChange 不对初始值触发）
        .onChange(of: isCompacting) { compacting in
            if compacting { startSpinner() } else { stopSpinner() }
        }
        .onAppear {
            if isCompacting { startSpinner() }
        }
        // hover 中上报「按钮锚点 + 数据快照」，详情卡由宿主层渲染（见头注结构纪律）；
        // hover 结束上报 nil，卡片随之收起
        .anchorPreference(key: ContextRingDetailAnchorKey.self, value: .bounds) { anchor in
            hovered
                ? ContextRingDetailPayload(
                    anchor: anchor,
                    watermark: watermark,
                    isCompacting: isCompacting,
                    summarizedCount: summarizedCount,
                    compactionOutcome: compactionOutcome
                )
                : nil
        }
        // 弧长/警戒色随水位渐变；isCompacting 翻转驱动两弧 opacity 交叉淡化
        .animation(.easeOut(duration: Theme.Motion.contentFade), value: watermark.ratio)
        .animation(.easeOut(duration: Theme.Motion.contentFade), value: isCompacting)
    }

    /// 启动不定态转圈：先无动画归零（双保险防快速启停残留中间角度），
    /// 再以线性匀速无限循环 0→360（autoreverses: false，每圈 360→0 瞬回，视觉无缝）。
    private func startSpinner() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { spinnerAngle = 0 }
        withAnimation(.linear(duration: spinnerPeriod).repeatForever(autoreverses: false)) {
            spinnerAngle = 360
        }
    }

    /// 停止转圈：禁用动画归零——repeatForever 的进行中动画随状态重写被替换，
    /// 角度直接回 0，不残留中间角度、不继续微转；此刻 spinner 弧已随分支切换
    /// 移除，归零只是状态卫生（下次启动恒从 12 点起步）。
    private func stopSpinner() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { spinnerAngle = 0 }
    }
}

// MARK: - 详情浮层挂载通道（锚点上报 → 宿主渲染）

/// 详情卡渲染载荷：hover 中的圆环把「自身 bounds 锚点 + 数据快照」一并上报，
/// 宿主层（contextRingDetailHost）据此在玻璃裁剪域之外定位渲染详情卡。
private struct ContextRingDetailPayload {
    var anchor: Anchor<CGRect>
    var watermark: ContextWatermark
    var isCompacting: Bool
    var summarizedCount: Int?
    var compactionOutcome: CompactionOutcome?
}

private struct ContextRingDetailAnchorKey: PreferenceKey {
    static var defaultValue: ContextRingDetailPayload? { nil }
    static func reduce(value: inout ContextRingDetailPayload?, nextValue: () -> ContextRingDetailPayload?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// 上下文水位详情卡宿主：必须挂在玻璃功能面（GlassSurface）**之后**——
    /// macOS 26+ 的 .glassEffect 会把内容裁剪进玻璃形状，挂早了浮层会被输入卡
    /// 顶缘切断。实现：读取圆环上报的锚点，把 1×1 隐形锚点钉在圆环顶缘上方，
    /// 卡片经 overlay(.bottom) 自锚点向上生长（免测卡片高度；输入坞在窗口底部、
    /// 上方是消息区，向上展开不会被窗口边缘裁切）。
    func contextRingDetailHost() -> some View {
        modifier(ContextRingDetailHost())
    }
}

private struct ContextRingDetailHost: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(ContextRingDetailAnchorKey.self) { payload in
            GeometryReader { proxy in
                if let payload {
                    let rect = proxy[payload.anchor]
                    // 顺序纪律：overlay 必须先挂在 1×1 锚点视图上、再整体 position。
                    // 若先 position 后 overlay，position 会把视图撑满整个 GeometryReader
                    // （= 宿主全尺寸），.bottom 对齐域随之变成宿主底缘——卡片被钉到输入卡
                    // 底部并把圆环整个盖住（2026-10 实拍回归）。先 overlay 再 position，
                    // 卡片底缘才真正锚在「圆环顶缘上方」、自锚点向上生长。
                    Color.clear
                        .frame(width: 1, height: 1)
                        .overlay(alignment: .bottom) {
                            ContextRingDetailCard(
                                watermark: payload.watermark,
                                isCompacting: payload.isCompacting,
                                summarizedCount: payload.summarizedCount,
                                compactionOutcome: payload.compactionOutcome
                            )
                            // fixedSize 不可省：锚点只有 1×1，overlay 会把宿主的窄尺寸
                            // 作为 proposal 传入，卡片会被压扁成空壳（tick 预览胶囊同款坑）
                            .fixedSize()
                            // 纯展示不吞点击：卡片悬于消息区上方，点击必须穿透到底层
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .offset(y: 4)))
                        }
                        .position(x: rect.midX, y: rect.minY - Theme.Spacing.md)
                }
            }
        }
    }
}

// MARK: - 详情卡

/// 详情浮层卡：深面板底 + 0.5pt 描边 + 8pt 圆角 + 轻投影（与浏览导航浮层同族 token，
/// 不新增设计令牌），底缘小三角指回圆环（方向性锚点）。
/// 内容克制五行封顶：标题 + 百分比 / tokens 明细 / 已压缩摘要（可选）/ 失败原因
/// （可选，警示色）/ 操作提示；摘要行只报条数不展开全文——展开详情归消息流里的
/// 压缩边界卡，职责不重叠。
private struct ContextRingDetailCard: View {
    let watermark: ContextWatermark
    let isCompacting: Bool
    let summarizedCount: Int?
    let compactionOutcome: CompactionOutcome?

    /// 与圆环警戒阈值同源。
    private var isWarning: Bool { watermark.ratio > 0.8 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.lg) {
                Text("上下文水位")
                    .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                    .foregroundColor(Theme.Colors.contentPrimary)
                Text("\(Int((watermark.ratio * 100).rounded()))%")
                    .font(Theme.Typography.mono(Theme.Typography.footnote))
                    .foregroundColor(isWarning ? Theme.Colors.statusWarning : Theme.Colors.contentTertiary)
            }
            Text("\(formatTokenCount(watermark.usedTokens)) / \(formatTokenCount(watermark.windowTokens)) tokens")
                .font(Theme.Typography.mono(Theme.Typography.caption))
                .foregroundColor(Theme.Colors.contentTertiary)
            if let summarizedCount, summarizedCount > 0 {
                Text("已压缩 \(summarizedCount) 条早期对话")
                    .font(Theme.Typography.text(Theme.Typography.caption))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }
            // 失败持久行：压缩失败在消息流里没有落点（成功才有边界卡/区域降档），
            // 详情卡是唯一能「事后查证」的位置；成功后 outcome 翻转，此行自消
            if let compactionOutcome, case .failed(_, let reason) = compactionOutcome {
                Text("上次压缩失败：\(reason)")
                    .font(Theme.Typography.text(Theme.Typography.caption))
                    .foregroundColor(Theme.Colors.statusWarning)
            }
            Text(isCompacting ? "正在压缩早期对话…" : "点击压缩早期对话（释放上下文）")
                .font(Theme.Typography.text(Theme.Typography.caption))
                .foregroundColor(Theme.Colors.idleText)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.previewCapsule, style: .continuous)
                .fill(Theme.Colors.chatNavFloatFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.previewCapsule, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
        .overlay(alignment: .bottom) {
            ContextRingCardTail()
                .fill(Theme.Colors.chatNavFloatFill)
                .frame(width: 8, height: 5)
                .offset(y: 4.5)
        }
        .shadow(color: .black.opacity(Theme.Shadow.navFloatOpacity),
                radius: Theme.Shadow.navFloatRadius,
                y: Theme.Shadow.navFloatY)
    }
}

/// 详情卡底缘指向圆环的小三角（方向性锚点，与 TickPreviewTail 同族、方向向下）。
private struct ContextRingCardTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// token 数紧凑格式化：<1k 原样；≥1k 用 k、≥1M 用 M，整倍去小数（512k），否则一位小数（12.3k）。
///（自 AIChatView 迁入：唯一消费点随水位控件一同独立。）
private func formatTokenCount(_ count: Int) -> String {
    if count < 1_000 { return "\(count)" }
    if count < 1_000_000 {
        let k = Double(count) / 1_000
        return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))k" : String(format: "%.1fk", k)
    }
    let m = Double(count) / 1_000_000
    return m.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(m))M" : String(format: "%.1fM", m)
}
