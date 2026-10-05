import SwiftUI

// 展开监控看板外层布局壳：顶部微光分割线 + 左右双卡片 Bento Grid。
// 卡片内容已拆分至 PerformanceCard / FocusWorkCard。
struct ExpandedMonitoringView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // 细若游丝的微光渐隐分割线
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
                .padding(.horizontal, Theme.Spacing.divider)
            
            // 核心双列卡片 Bento Grid (左右对称卡片网格，卡片高度 225pt)
            HStack(spacing: Theme.Spacing.xxl) {
                // MARK: - 左卡片：⚡️ 系统性能与网络吞吐
                PerformanceCard(appState: appState)
                
                // MARK: - 右卡片：🎯 专注工坊与效率日程
                FocusWorkCard(appState: appState)
            }
            .frame(height: Theme.Layout.monitorCardHeight)
            .padding(.horizontal, Theme.Spacing.section)
            .padding(.top, Theme.Spacing.xxs)
            .padding(.bottom, Theme.Spacing.md)
        }
    }
}