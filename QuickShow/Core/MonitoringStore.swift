import SwiftUI
import Combine
import Foundation

// MARK: - 扩展监控域
/// 性能负载 / 实时网速 / 网络延迟 / 高负载进程 + tick 订阅。
/// 相位常量逐字搬运：traffic 每 tick、latency count%5==2、perf+topCPU count%2==0。
final class MonitoringStore: ObservableObject {
    @Published var performanceInfo: SystemPerformanceInfo = SystemPerformanceInfo(cpuUsage: 0, memoryUsagePercent: 0, memoryUsedGB: 0, memoryTotalGB: 16)
    @Published var trafficInfo: NetworkTrafficInfo = NetworkTrafficInfo(downloadSpeed: "0 KB/s", uploadSpeed: "0 KB/s")
    @Published var topCPUProcess: String? = nil
    // 网络延迟（毫秒，nil = 未知/失败/断网；仅面板展开时低频测量）
    @Published var networkLatency: Int? = nil

    // 高负载进程探测进行中标记：ps 未返回前跳过新一轮，防止任务堆积
    private var isFetchingTopCPU = false
    private var cancellables = Set<AnyCancellable>()
    private weak var facade: AppState?

    func attach(tick: AnyPublisher<AppTick, Never>, facade: AppState) {
        self.facade = facade
        tick.sink { [weak self, weak facade] tick in
            guard let self, let facade else { return }

            // 实时网速：每秒更新
            if facade.isExpanded && facade.showNetworkSpeed {
                self.trafficInfo = SystemStatusProvider.shared.getNetworkTrafficInfo()
            }

            // 网络延迟：展开且开启网速展示时每 5 秒异步低频测量一次
            //（面板隐藏时主时钟停摆，天然满足"仅面板可见时测量"，待机零消耗）
            if facade.isExpanded && facade.showNetworkSpeed && (tick.count % 5 == 2) {
                SystemStatusProvider.shared.measureNetworkLatency { [weak self] ms in
                    self?.networkLatency = ms
                }
            }

            // 性能负载 (CPU & RAM)：展开时每 2 秒刷新一次，降低开销
            if facade.isExpanded && facade.showPerformance && (tick.count % 2 == 0) {
                self.performanceInfo = SystemStatusProvider.shared.getSystemPerformanceInfo()
                self.fetchTopCPUProcess()
            }
        }.store(in: &cancellables)
    }

    /// 异步刷新高负载进程：带防重叠闸门，ps 未返回前不再发起新一轮
    func fetchTopCPUProcess() {
        guard !isFetchingTopCPU else { return }
        isFetchingTopCPU = true
        SystemStatusProvider.shared.getTopCPUProcessAsync { [weak self, weak facade] result in
            guard let self else { return }
            self.isFetchingTopCPU = false
            // 面板已收起则丢弃过期结果，避免无谓刷新
            guard facade?.isExpanded == true else { return }
            self.topCPUProcess = result
        }
    }
}