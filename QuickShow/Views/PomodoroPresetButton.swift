import SwiftUI

// 职责来源：ExpandedMonitoringView 右卡片番茄钟预设时长选择按钮
// MARK: - 番茄钟预设选择按钮
struct PomodoroPresetButton: View {
    let title: String
    let minutes: Int
    @ObservedObject var appState: AppState
    /// 紧凑档（窄卡时由 FocusWorkCard 的 ViewThatFits 选中）：字号与内边距各降一档，
    /// 让「预设可点」在窄窗也保得住；`lineLimit(1)` 保证任何挤压都只截断不逐字折行
    var compact: Bool = false
    
    private var isSelected: Bool {
        let currentMinutes = appState.pomodoroRemainingSeconds / 60
        return currentMinutes == minutes
    }
    
    var body: some View {
        Button {
            appState.resetPomodoro(durationMinutes: minutes)
        } label: {
            Text(title)
                .font(.system(size: compact ? Theme.Typography.mini : Theme.Typography.caption, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? .orange : Theme.Colors.presetText)
                .lineLimit(1)
                .padding(.horizontal, compact ? Theme.Spacing.xs : Theme.Spacing.chip)
                .padding(.vertical, Theme.Spacing.xxs)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.orange.opacity(0.20) : Theme.Colors.surfaceBadge)
                )
        }
        .buttonStyle(.plain)
    }
}

