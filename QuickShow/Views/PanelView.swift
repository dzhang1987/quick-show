import SwiftUI

struct PanelView: View {
    @ObservedObject var appState: AppState
    // 面板实时尺寸：由 PanelManager 在窗口动画期间逐帧推送（livePanelSize）。
    // 宽度驱动大字时钟字号连续缩放（Hero 缩放通道），高度驱动展开进度。
    // 注意：SwiftUI PreferenceKey/GeometryReader 测量链在本应用不可用——
    // NSGlassEffectView 承载的 NSHostingView 中只要内容含 Button，测量就会死锁在 0x0
    // （最小复现实验 V6 坐实：占位 Text 测量正常，加一个普通 Button 即死锁），
    // 因此布局进度的数据源是 AppKit 侧窗口 frame，绝对可靠
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
        }
        .onHover { isHovering in
            appState.setHovered(isHovering)
        }
        // 弹性填充：面板尺寸的唯一时钟是 AppKit 窗口 setFrame 动画，
        // hosting view 随窗口逐帧变大/变小，SwiftUI 内容跟随可用空间自然 reflow（live resize 质感），
        // 严禁恢复固定 .frame(width:height:) 尺寸插值，否则与窗口动画双时钟打架抖动
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if #available(macOS 26.0, *) {
                // 26+：材质由窗口层 NSGlassEffectView 统一提供，内容背景保持透明
                Color.clear
            } else {
                // 13~25 降级：原生超薄材质，跟随系统明暗翻转（内容语义色同步适配）
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                    .fill(.ultraThinMaterial)
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
                        .foregroundStyle(.tertiary)
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
                    ("⌘ Q", "退出应用")
                ])
                
                // 列 2：效率工具
                ShortcutGroupCard(title: "效率加速", shortcuts: [
                    ("A", "防休眠阻止息屏"),
                    ("C", "清理释放系统内存"),
                    ("X", "剪贴板纯文本化"),
                    ("O", "秒开系统下载目录"),
                    ("L", "全屏锁屏离座")
                ])
                
                // 列 3：系统控制
                ShortcutGroupCard(title: "系统控制", shortcuts: [
                    ("M", "一键静音 / 恢复"),
                    ("↑ / ↓", "微调主音量 (±5%)"),
                    ("P", "番茄钟播放 / 暂停"),
                    ("D", "专注模式设置"),
                    ("?", "速查卡片常驻开关")
                ])
            }
            .padding(.horizontal, Theme.Spacing.xxxl)
            .padding(.bottom, Theme.Spacing.xxxl)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // 原生超薄材质，跟随系统明暗翻转（与窗口玻璃同哲学）
            RoundedRectangle(cornerRadius: Theme.Radius.cheatSheet, style: .continuous)
                .fill(.ultraThinMaterial)
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
                .foregroundColor(.secondary)
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

// MARK: - 面板圆角裁剪（仅降级路径生效）
// macOS 26+ 的圆角由窗口层 NSGlassEffectView 统一处理，无需在此重复裁剪
private struct PanelRoundedClip: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        }
    }
}
