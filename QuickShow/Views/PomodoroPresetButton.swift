import SwiftUI

// 职责来源：ExpandedMonitoringView 右卡片番茄钟预设时长选择按钮
// MARK: - 番茄钟预设选择按钮
struct PomodoroPresetButton: View {
    let title: String
    let minutes: Int
    @ObservedObject var appState: AppState
    
    private var isSelected: Bool {
        let currentMinutes = appState.pomodoroRemainingSeconds / 60
        return currentMinutes == minutes
    }
    
    var body: some View {
        Button {
            appState.resetPomodoro(durationMinutes: minutes)
        } label: {
            Text(title)
                .font(.system(size: Theme.Typography.caption, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? .orange : Theme.Colors.presetText)
                .padding(.horizontal, Theme.Spacing.chip)
                .padding(.vertical, Theme.Spacing.xxs)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.orange.opacity(0.20) : Theme.Colors.surfaceBadge)
                )
        }
        .buttonStyle(.plain)
    }
}

