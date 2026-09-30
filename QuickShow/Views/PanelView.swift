import SwiftUI

struct PanelView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // 上半部分：核心大字时钟与日期徽章
            TimeDisplayView(appState: appState)
                .padding(.top, 18)
                .padding(.horizontal, 24)
            
            Spacer(minLength: 10)
            
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
            
            // 底部微状态栏（电池、WiFi、微图钉）
            StatusBarView(appState: appState)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 16)
            
            // 隐形 ESC 键盘快捷键监听兜底
            Button("") {
                appState.dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .frame(width: 360, height: 172)
        // 核心：严格限定在 26pt 连续曲率圆角内，四周零 padding，零多余像素
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
            // 晶体边缘双重微光高光描边
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
        )
    }
}
