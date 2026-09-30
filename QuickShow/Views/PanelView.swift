import SwiftUI

struct PanelView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // 上半部分：核心大字时钟与日期徽章
            TimeDisplayView(appState: appState)
                .padding(.top, 16)
                .padding(.horizontal, 24)
            
            Spacer(minLength: 8)
            
            // 细若游丝的微光渐隐分割线
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
                .padding(.horizontal, 22)
            
            // 底部微状态栏（P0 状态：电池、WiFi、蓝牙、音频、勿扰、图钉、Tab展开键）
            StatusBarView(appState: appState)
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, appState.isExpanded ? 6 : 14)
            
            // 展开后的监控面板 (P1 状态：CPU/内存负载、网速、日历日程、番茄钟)
            if appState.isExpanded {
                ExpandedMonitoringView(appState: appState)
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
        .frame(
            width: appState.isExpanded ? 430 : 380,
            height: appState.isExpanded ? 286 : 168
        )
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
    }
}
