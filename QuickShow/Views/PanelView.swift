import SwiftUI

struct PanelView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        let metrics = appState.currentMetrics()
        let isExpandedOrCheat = (appState.isExpanded || appState.showCheatSheet)
        let panelWidth = isExpandedOrCheat ? metrics.expandedSize.width : metrics.compactSize.width
        let panelHeight = isExpandedOrCheat ? metrics.expandedSize.height : metrics.compactSize.height
        
        VStack(spacing: 0) {
            // 上半部分：核心大字时钟与日期徽章
            TimeDisplayView(appState: appState, panelWidth: panelWidth)
                .padding(.top, isExpandedOrCheat ? 16 : 30)
                .padding(.horizontal, 24)
            
            // 严格受限的自然呼吸微间距，彻底杜绝拉裂虚空
            Spacer(minLength: 8).frame(maxHeight: isExpandedOrCheat ? 12 : 36)
            
            // 细若游丝的微光渐隐分割线（严格保持 0.5pt 高度）
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.15),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
                .padding(.horizontal, 24)
            
            // 底部微状态栏（P0 状态：电池、WiFi、音频、常驻图钉）
            StatusBarView(appState: appState)
                .padding(.horizontal, 24)
                .padding(.top, isExpandedOrCheat ? 10 : 16)
                .padding(.bottom, appState.isExpanded ? 8 : 24)
            
            // 展开后的监控面板 (P1 状态：CPU/内存负载、网速、日历日程、番茄钟)
            if appState.isExpanded {
                ExpandedMonitoringView(appState: appState)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.animation(.easeInOut(duration: 0.16).delay(0.04)),
                            removal: .opacity.animation(.easeInOut(duration: 0.10))
                        )
                    )
            }
            
            // 隐形 ESC 键盘快捷键监听兜底
            Button("") {
                appState.dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            
            // 隐形 ⌘ + , 快捷打开偏好设置兜底
            Button("") {
                appState.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            
            // 隐形 ⌘ + Q 快捷退出兜底
            Button("") {
                appState.quitApp()
            }
            .keyboardShortcut("q", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .onHover { isHovering in
            appState.setHovered(isHovering)
        }
        .frame(width: panelWidth, height: panelHeight)
        .background(
            ZStack {
                // 1. 原生高斯模糊材质（圆角内）
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                
                // 2. 深邃黑曜石微光渐变，提供绝对对比度与通透感
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.88),
                                Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.94)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            ZStack {
                // 1. 基础晶体边缘高光描边 (全周连续曲率)
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.38), location: 0.0),
                                .init(color: Color.white.opacity(0.12), location: 0.35),
                                .init(color: Color.white.opacity(0.03), location: 0.70),
                                .init(color: Color.white.opacity(0.20), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                
                // 2. 方案 1：黑曜石底边框「晶体折射光消散动效」（仅一瞥模式且未展开时呈现）
                if appState.mode == .glance && !appState.isExpanded {
                    GeometryReader { geo in
                        let activeWidth = geo.size.width * appState.glanceProgress
                        
                        // 沿 26pt 连续曲率圆角的纯白折射微光
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(appState.isHovered ? 0.95 : 0.75),
                                        Color.white.opacity(appState.isHovered ? 0.85 : 0.60)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                lineWidth: appState.isHovered ? 1.25 : 0.90
                            )
                            // 仅保留底部 32pt 区域（涵盖底部水平切边与圆角切弧）
                            .mask(
                                VStack(spacing: 0) {
                                    Spacer()
                                    Rectangle()
                                        .frame(height: 32)
                                }
                            )
                            // 水平居中对称收缩 mask（两端柔和羽化）
                            .mask(
                                HStack {
                                    Spacer()
                                    Rectangle()
                                        .fill(
                                            LinearGradient(
                                                stops: [
                                                    .init(color: .clear, location: 0.0),
                                                    .init(color: .white, location: 0.12),
                                                    .init(color: .white, location: 0.88),
                                                    .init(color: .clear, location: 1.0)
                                                ],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: max(0, activeWidth))
                                    Spacer()
                                }
                            )
                            .shadow(
                                color: Color.white.opacity(appState.isHovered ? 0.45 : 0.20),
                                radius: appState.isHovered ? 3.0 : 1.2,
                                x: 0,
                                y: 1
                            )
                            .animation(.linear(duration: 0.04), value: appState.glanceProgress)
                    }
                    .transition(.opacity)
                }
            }
        )
        .overlay {
            if appState.showCheatSheet {
                CheatSheetView(appState: appState)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
    }
}

// MARK: - 全键盘盲操速查微卡片 (CheatSheet)
struct CheatSheetView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 12) {
            // 顶部小标题栏
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "command")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.orange)
                    Text("全键盘盲操速查表")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.95))
                    Text("(按住 ⌘ 提示 · 松开自动收起)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.white.opacity(0.45))
                }
                
                Spacer()
                
                Button {
                    appState.setCheatSheetVisible(false)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.40))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            
            // 三列结构化快捷键分组 (满铺卡片网格)
            HStack(alignment: .top, spacing: 10) {
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
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.96),
                                Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.98)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
        )
        .padding(6)
    }
}

struct ShortcutGroupCard: View {
    let title: String
    let shortcuts: [(String, String)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(.white.opacity(0.70))
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            
            ForEach(shortcuts, id: \.0) { key, desc in
                HStack(spacing: 8) {
                    Text(key)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                    
                    Text(desc)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                    
                    Spacer(minLength: 0)
                }
            }
            
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
        )
    }
}
