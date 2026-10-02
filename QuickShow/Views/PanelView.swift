import SwiftUI

struct PanelView: View {
    @ObservedObject var appState: AppState
    // 面板实时尺寸：由 PanelManager 在窗口动画期间逐帧推送（livePanelSize）。
    // 宽度驱动大字时钟字号连续缩放（Hero 缩放通道），高度驱动展开进度。
    // 注意：SwiftUI PreferenceKey/GeometryReader 测量链在本应用不可用——
    // NSGlassEffectView 承载的 NSHostingView 中只要内容含 Button，测量就会死锁在 0x0
    // （最小复现实验 V6 坐实：占位 Text 测量正常，加一个普通 Button 即死锁），
    // 因此布局进度的数据源是 AppKit 侧窗口 frame，绝对可靠
    // 整窗 glass 已移除，该 workaround 待观察后清理。
    private var renderedSize: CGSize {
        appState.livePanelSize
    }
    
    var body: some View {
        let metrics = appState.currentMetrics()
        let isExpandedOrCheat = (appState.isExpanded || appState.showCheatSheet)
        // 兜底目标宽度：仅供首帧布局（尚未测得实际宽度时）推算字号
        let panelWidth = isExpandedOrCheat ? metrics.expandedSize.width : metrics.compactSize.width
        
        // 展开进度 0→1：由面板实际渲染高度逐帧推导（窗口动画是唯一时钟），
        // 下方所有布局量都是它的线性函数，内容总需求恒小于窗口实际高度，时钟永不被裁
        let compactH = metrics.compactSize.height
        let expandedH = metrics.expandedSize.height
        let expandProgress: CGFloat = expandedH > compactH
            ? min(max((renderedSize.height - compactH) / (expandedH - compactH), 0), 1)
            : 0
        
        VStack(spacing: 0) {
            // 按面板上下文整体切换渲染（独立功能 = 独立全面板视图，上下文间完全互斥零残留）
            switch appState.currentContext {
            case .calendar:
                // 日历态：整面板 100% 归日历——无时钟、无底栏微标、无倒计时微光条
                CalendarPanelView(appState: appState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            case .glance, .dashboard:
                // 常规态：大字时钟 + 底栏微状态 + 中部监控区
                // 上半部分：核心大字时钟与日期徽章
                // 字号随实际渲染宽度逐帧连续缩放；锚点 padding 随展开进度逐帧连续滑动
                // （端点 30↔8：展开态时钟贴近顶部，释放的空间让给状态栏与监控区呼吸）
                TimeDisplayView(appState: appState, panelWidth: renderedSize.width > 0 ? renderedSize.width : panelWidth)
                    .padding(.top, Theme.Layout.heroTopCompact - (Theme.Layout.heroTopCompact - Theme.Layout.heroTopExpanded) * expandProgress)
                    .padding(.horizontal, Theme.Spacing.panel)
                
                // 严格受限的自然呼吸微间距，彻底杜绝拉裂虚空（端点 36↔12 不变，随进度连续收缩）
                Spacer(minLength: 8)
                    .frame(maxHeight: Theme.Layout.breathCompact - (Theme.Layout.breathCompact - Theme.Layout.breathExpanded) * expandProgress)
                
                // 细若游丝的微光渐隐分割线（严格保持 0.5pt 高度）
                // 0.25 是对比度下限：黑色低 alpha 在亮玻璃上是"阴影"型弱对比，
                // 需显著高于暗色白线的等效发光感，双模式均清晰但不抢戏
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.0),
                                Color.primary.opacity(Theme.Colors.dividerOpacity),
                                Color.primary.opacity(0.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: Theme.Layout.dividerHeight)
                    .padding(.horizontal, Theme.Spacing.panel)
                
                // 底部微状态栏（P0 状态：电池、WiFi、音频、常驻图钉）
                // padding 端点 16↔10 / 24↔12，随进度连续滑动（展开态底部呼吸加大）
                StatusBarView(appState: appState)
                    .padding(.horizontal, Theme.Spacing.panel)
                    .padding(.top, Theme.Layout.statusTopCompact - (Theme.Layout.statusTopCompact - Theme.Layout.statusTopExpanded) * expandProgress)
                    .padding(.bottom, Theme.Layout.statusBottomCompact - (Theme.Layout.statusBottomCompact - Theme.Layout.statusBottomExpanded) * expandProgress)
                
                // 展开后的监控面板 (P1 状态：CPU/内存负载、网速、日历日程、番茄钟)
                // 占位高度 = 完整高度 × 展开进度：窗口长多少它吃多少，逐帧由实际高度挤出，
                // 全程内容需求恒 ≤ 窗口实际高度（数学保证零溢出）；顶对齐 + clipped：
                // 即便极端账目误差也只裁监控区底部，时钟绝不被裁；
                // 占位与 isExpanded 解耦（收起时随窗口收缩自然归零，无瞬跳），isExpanded 只管淡入淡出；
                // p=1 端点 = 内容 241.5 + 底部呼吸 14（时钟上移释放的空间转移至此）
                ExpandedMonitoringView(appState: appState)
                    .padding(.horizontal, Theme.Spacing.xxxl)
                    .frame(height: (Theme.Layout.monitorContentHeight + Theme.Layout.monitorBreath) * expandProgress, alignment: .top)
                    .clipped()
                    .opacity(appState.isExpanded ? 1 : 0)
                    .animation(.easeInOut(duration: Theme.Motion.windowResize), value: appState.isExpanded)
                
                // 注意：此处曾有 ESC/⌘,/⌘Q 三个隐形 keyboardShortcut Button 兜底，已删除。
                // 根因（最小复现实验铁证）：keyboardShortcut 在 NSGlassEffectView 承载的
                // NSHostingView 中会卡死 SwiftUI 布局链——首帧布局停在 0x0 后，窗口 resize
                // 不再触发测量上报（renderedSize 恒 0 → expandProgress 恒 0 → 监控卡片零高消失）。
                // 快捷键由 FloatingPanel.sendEvent/keyDown/cancelOperation 完整拦截，无功能损失。
                // 整窗 glass 已移除，该 workaround 待观察后清理。
            }
        }
        // 日历态 ↔ 常规态整体切换：交叉淡化与窗口尺寸动画同节奏（0.16s ≈ 0.18s），无跳变闪烁
        .animation(.easeInOut(duration: Theme.Motion.contentFade), value: appState.currentContext)
        .onHover { isHovering in
            appState.setHovered(isHovering)
        }
        // 弹性填充：面板尺寸的唯一时钟是 AppKit 窗口 setFrame 动画，
        // hosting view 随窗口逐帧变大/变小，SwiftUI 内容跟随可用空间自然 reflow（live resize 质感），
        // 严禁恢复固定 .frame(width:height:) 尺寸插值，否则与窗口动画双时钟打架抖动
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 全局禁用系统键盘焦点环：本应用键盘交互全由 FloatingPanel.sendEvent 自行拦截分发，
        // SwiftUI Button 无需接收键盘焦点；按钮被点击/键盘导航后成为 first responder 时
        // 系统会围绕按钮 bounds 画蓝色 focus ring（圆角与胶囊形状不贴合，视觉脏点）。
        // focusEffectDisabled 从 macOS 14 起可用且对整个视图树传播；
        // macOS 13 降级路径下 plain 按钮默认不绘制焦点环，无需等效处理
        .modifier(FocusRingDisabledModifier())
        .background {
            // 内容层标准材质（HIG：内容层必须用标准材质，Liquid Glass 只属于功能层）。
            // 整窗 NSGlassEffectView 已移除后，26+ 与 13~25 统一铺 ultraThinMaterial，
            // 明暗翻转由材质自身随 effectiveAppearance 驱动，语义色同源无错位。
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        // 一瞥倒计时微光进度条：bottom overlay 贴面板底边，与 VStack 内容排布完全解耦——
        // 展开/收起窗口动画期间 hosting view 逐帧变形，overlay 底边自动跟随，绝无悬空错位；
        // 置于 PanelRoundedClip 之前：随内容被圆角统一裁剪（底角弧形贴边正确）
        .overlay(alignment: .bottom) {
            // 显示条件与旧黑曜石晶体消散动效一致：仅一瞥模式、未展开看板、无速查表时呈现；
            // hover/Toast 期间 glanceProgress 在状态侧自然冻结，进度条随之停住，视图层零额外逻辑
            if appState.mode == .glance && !appState.isExpanded && !appState.showCheatSheet {
                GlanceProgressBar(
                    progress: appState.glanceProgress,
                    panelWidth: renderedSize.width > 0 ? renderedSize.width : panelWidth
                )
            }
        }
        .modifier(PanelRoundedClip())
        .overlay {
            if appState.showCheatSheet {
                CheatSheetView(appState: appState)
                    .transition(.opacity.combined(with: .scale(scale: Theme.Motion.overlayScale)))
            }
        }
    }
}

// MARK: - 全键盘盲操速查微卡片 (CheatSheet)
struct CheatSheetView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: Theme.Spacing.xxl) {
            // 顶部小标题栏
            HStack {
                HStack(spacing: Theme.Spacing.lg) {
                    Image(systemName: "command")
                        .font(.system(size: Theme.Typography.badge, weight: .bold))
                        .foregroundColor(.orange)
                    Text("全键盘盲操速查表")
                        .font(.system(size: Theme.Typography.badge, weight: .bold))
                        .foregroundColor(.primary)
                    Text("(按住 ⌘ 提示 · 松开自动收起)")
                        .font(.system(size: Theme.Typography.body, weight: .regular))
                        .foregroundStyle(Theme.Colors.contentTertiary)
                }
                
                Spacer()
                
                Button {
                    appState.setCheatSheetVisible(false)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Theme.Typography.closeButton))
                        .foregroundColor(Theme.Colors.closeIcon)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.section)
            .padding(.top, Theme.Spacing.xxxl)
            
            // 三列结构化快捷键分组 (满铺卡片网格)
            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                // 列 1：基础交互
                ShortcutGroupCard(title: "基础控制", shortcuts: [
                    ("Tab", "展开 / 收起看板"),
                    ("Space", "常驻图钉切换"),
                    ("ESC", "退出 / 关闭面板"),
                    ("⌘ ,", "偏好设置"),
                    ("⌘ Q", "退出应用"),
                    ("G", "切换日历视图"),
                    ("1 / 2 / 3", "日历 月/周/日"),
                    ("← / →", "日历翻页 / 媒体切歌")
                ])
                
                // 列 2：效率工具
                ShortcutGroupCard(title: "效率加速", shortcuts: [
                    ("I", "AI 对话"),
                    ("A", "防休眠阻止息屏"),
                    ("C", "清理释放系统内存"),
                    ("X", "剪贴板纯文本化"),
                    ("O", "秒开系统下载目录"),
                    ("L", "全屏锁屏离座")
                ])
                
                // 列 3：系统控制（含媒体盲操，存在媒体会话时生效）
                ShortcutGroupCard(title: "系统控制", shortcuts: [
                    ("M", "一键静音 / 恢复"),
                    ("↑ / ↓", "微调主音量 (±5%)"),
                    ("P", "番茄钟播放 / 暂停"),
                    ("D", "专注模式设置"),
                    ("?", "速查卡片常驻开关"),
                    ("⏎", "媒体播放 / 暂停"),
                    ("← / →", "上一首 / 下一首"),
                    (", / .", "快退 / 快进 15 秒")
                ])
            }
            .padding(.horizontal, Theme.Spacing.xxxl)
            .padding(.bottom, Theme.Spacing.xxxl)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // 加厚至 thinMaterial：压住下方 124pt 大时钟的透出叠压（ultraThin 太薄会残影），
            // 保持玻璃通透哲学、不叠额外底色、不做实心卡片；跟随系统明暗翻转
            RoundedRectangle(cornerRadius: Theme.Radius.cheatSheet, style: .continuous)
                .fill(.thinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cheatSheet, style: .continuous))
        .padding(Theme.Spacing.md)
    }
}

struct ShortcutGroupCard: View {
    let title: String
    let shortcuts: [(String, String)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            Text(title)
                .font(.system(size: Theme.Typography.callout, weight: .bold))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.xxs)
            
            ForEach(shortcuts, id: \.0) { key, desc in
                HStack(spacing: Theme.Spacing.lg) {
                    Text(key)
                        .font(.system(size: Theme.Typography.keyCap, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange.opacity(0.95))
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                                .fill(Theme.Colors.surfaceKeyCap)
                        )
                    
                    Text(desc)
                        .font(.system(size: Theme.Typography.body, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer(minLength: 0)
                }
            }
            
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .fill(Theme.Colors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .stroke(Theme.Colors.groupCardStroke, lineWidth: 0.5)
        )
    }
}

// MARK: - 一瞥倒计时微光进度条
// 贴面板底边、水平居中的细光带：宽度 = 面板宽 × glanceProgress，
// 随倒计时从满宽由左右两侧向中间对称收拢（消散终点收敛于面板中心）。
// 宽度数据源与 Hero 时钟缩放同源（AppKit 窗口 frame 逐帧推送的 livePanelSize + 首帧 metrics 兜底），
// 规避 NSGlassEffectView 内 GeometryReader/PreferenceKey 测量死锁（整窗 glass 已移除，该 workaround 待观察后清理）；
// tick 0.04s 足够密（每步约 1/75 宽度）天然连续，无需视图侧 .animation；
// 重置回满由状态侧 withAnimation(Theme.Motion.progressReset) 事务动画天然驱动
private struct GlanceProgressBar: View {
    let progress: CGFloat   // 1.0 → 0.0（满 → 空）
    let panelWidth: CGFloat
    
    var body: some View {
        // 微光质感：中段实色，两端各 featherEdge 宽度羽化渐隐至透明（对称发光晶体），
        // 与底部分割线的对称渐隐语言一致；Color.primary 语义色随玻璃明暗自动翻转，
        // 双模式清晰克制；overlay .bottom 对齐保证光带恒水平居中，收拢全程零偏移
        LinearGradient(
            stops: [
                .init(color: Color.primary.opacity(0), location: 0),
                .init(color: Color.primary.opacity(Theme.Colors.glanceProgressOpacity), location: Theme.Colors.glanceProgressFeatherEdge),
                .init(color: Color.primary.opacity(Theme.Colors.glanceProgressOpacity), location: 1 - Theme.Colors.glanceProgressFeatherEdge),
                .init(color: Color.primary.opacity(0), location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: panelWidth * progress, height: Theme.Layout.glanceProgressHeight)
    }
}

// MARK: - 面板圆角裁剪（统一路径）
// 整窗 glass 已移除后，两个窗口的窗口层圆角由 PanelHostingConfigurator 在 AppKit 根图层
// 统一施加；这里再对 SwiftUI 内容做一次同半径裁剪，保证 content 自绘内容不越界。
private struct PanelRoundedClip: ViewModifier {
    func body(content: Content) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }
}

// MARK: - 全局禁用系统键盘焦点环
// macOS 14+：focusEffectDisabled 对整个视图树传播，面板内所有 Button/可聚焦视图
// 成为 first responder 时均不再绘制蓝色 focus ring；
// macOS 13：无此 API，且 plain 按钮默认不绘制焦点环，直接透传
private struct FocusRingDisabledModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled(true)
        } else {
            content
        }
    }
}
