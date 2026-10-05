import Foundation
import Combine

// MARK: - tick 载荷
/// 单一主时钟的一次 tick。count 从 1 开始，对齐原 AppState.tickCounter += 1 语义。
struct AppTick {
    let date: Date
    let count: Int
}

// MARK: - 后台队列单一来源（原 AppState.statusRefreshQueue 迁出，供多个 store 共用）
/// 系统状态刷新专用串行后台队列：把 WiFi/蓝牙/音频/日历等阻塞式系统查询移出主线程，
/// 保证面板先上屏、状态随后异步补齐；串行执行也避免查询任务相互堆叠。
enum BackgroundQueues {
    static let statusRefresh = DispatchQueue(label: "com.quickshow.statusRefresh", qos: .userInitiated)
}

// MARK: - 单一主时钟 + tick 总线
/// 面板显示期间每秒发一次 AppTick，隐藏时 stop 并归零（隐藏即零消耗）。
/// 各域 store 通过 attach(tick:facade:) 订阅，订阅顺序即原分发顺序。
final class TickEngine {
    let publisher: AnyPublisher<AppTick, Never>
    private let subject = PassthroughSubject<AppTick, Never>()
    private var timer: AnyCancellable?
    private var count = 0

    init() {
        publisher = subject.eraseToAnyPublisher()
    }

    func start() {
        stop()
        count = 0
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                guard let self else { return }
                self.count += 1
                self.subject.send(AppTick(date: date, count: self.count))
            }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}