import SwiftUI
import Combine
import Foundation

// MARK: - 番茄钟域
/// 番茄钟运行态 + 持久化统计（今日完成数 / 连续天数，跨天自动重置）+ tick 步进订阅。
/// 控制方法（toggle/reset/cycle）留在门面 Actions 扩展，引用 resetGlanceTimer/showToast。
final class PomodoroStore: ObservableObject {
    @Published var pomodoroRunning: Bool = false
    @Published var pomodoroRemainingSeconds: Int = 25 * 60

    // 番茄钟统计（持久化：今日完成数与连续天数，跨天自动重置）
    @AppStorage("pomodoroTodayCount") var pomodoroTodayCount: Int = 0
    @AppStorage("pomodoroTodayKey") private var pomodoroTodayKey: String = ""       // yyyy-MM-dd，今日计数锚点
    @AppStorage("pomodoroStreakDays") var pomodoroStreakDays: Int = 0
    @AppStorage("pomodoroStreakLastDay") private var pomodoroStreakLastDay: String = "" // yyyy-MM-dd，连续判定锚点

    // 本次计时是否为短休息（5m 短休息完成不计入番茄统计）
    var pomodoroIsRestSession: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private weak var facade: AppState?

    /// 订阅主时钟：每秒倒计时步进，归零记录完成并发 Toast。
    func attach(tick: AnyPublisher<AppTick, Never>, facade: AppState) {
        self.facade = facade
        tick.sink { [weak self, weak facade] _ in
            guard let self, let facade else { return }
            // 番茄钟倒计时步进
            if self.pomodoroRunning && self.pomodoroRemainingSeconds > 0 {
                self.pomodoroRemainingSeconds -= 1
                if self.pomodoroRemainingSeconds == 0 {
                    self.pomodoroRunning = false
                    self.recordCompletion()
                    facade.showToast(String(localized: "🎉 番茄专注时段已完成！"))
                }
            }
        }.store(in: &cancellables)
    }

    var formattedPomodoroTime: String {
        let m = pomodoroRemainingSeconds / 60
        let s = pomodoroRemainingSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// 番茄钟完成统计：专注时段归零时累计今日数并维护连续天数（短休息不计数）
    private static let pomodoroDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func recordCompletion() {
        guard !pomodoroIsRestSession else { return }
        let now = Date()
        let today = Self.pomodoroDayFormatter.string(from: now)
        // 跨天重置今日计数
        if pomodoroTodayKey != today {
            pomodoroTodayKey = today
            pomodoroTodayCount = 0
        }
        pomodoroTodayCount += 1
        // 连续天数：今日已记过保持不变；昨日有记录则累加；否则中断重计为 1
        if pomodoroStreakLastDay != today {
            let yesterday = Self.pomodoroDayFormatter.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now)
            pomodoroStreakDays = (pomodoroStreakLastDay == yesterday) ? pomodoroStreakDays + 1 : 1
            pomodoroStreakLastDay = today
        }
    }
}