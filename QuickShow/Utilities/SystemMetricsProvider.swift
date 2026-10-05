import Foundation
import Darwin
import Network

// MARK: - 系统性能负载 / 网络速率 / 延迟 / 磁盘 / 高负载进程
// 差分状态（prevCpuInfo / prevBytesIn / prevBytesOut / prevNetTime）随本类方法一并迁移
final class SystemMetricsProvider {
    // CPU 状态缓存
    private var prevCpuInfo: processor_info_array_t?
    private var prevNumCpuInfo: mach_msg_type_number_t = 0
    private var lastCpuUsage: Double = 0.0

    // 网速状态缓存
    private var prevBytesIn: UInt64 = 0
    private var prevBytesOut: UInt64 = 0
    private var prevNetTime: TimeInterval = 0
    private var lastTrafficInfo = NetworkTrafficInfo(downloadSpeed: "0 KB/s", uploadSpeed: "0 KB/s")

    // MARK: - 系统性能负载 (CPU / 内存)
    func getSystemPerformanceInfo() -> SystemPerformanceInfo {
        // 1. CPU 使用率 (Mach Kernel API)
        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        
        let err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfo)
        var cpuUsage: Double = lastCpuUsage
        
        if err == KERN_SUCCESS, let cpuInfo = cpuInfo {
            if let prevCpu = prevCpuInfo {
                var inUse: Int64 = 0
                var total: Int64 = 0
                
                for i in 0..<Int32(numCPUsU) {
                    let offset = Int(CPU_STATE_MAX * i)
                    let user = Int64(cpuInfo[offset + Int(CPU_STATE_USER)] - prevCpu[offset + Int(CPU_STATE_USER)])
                    let system = Int64(cpuInfo[offset + Int(CPU_STATE_SYSTEM)] - prevCpu[offset + Int(CPU_STATE_SYSTEM)])
                    let nice = Int64(cpuInfo[offset + Int(CPU_STATE_NICE)] - prevCpu[offset + Int(CPU_STATE_NICE)])
                    let idle = Int64(cpuInfo[offset + Int(CPU_STATE_IDLE)] - prevCpu[offset + Int(CPU_STATE_IDLE)])
                    
                    let cpuInUse = user + system + nice
                    let cpuTotal = cpuInUse + idle
                    
                    inUse += cpuInUse
                    total += cpuTotal
                }
                
                if total > 0 {
                    cpuUsage = (Double(inUse) / Double(total)) * 100.0
                    lastCpuUsage = cpuUsage
                }
                
                let prevSize = vm_size_t(prevNumCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
                vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: prevCpu)), prevSize)
            }
            prevCpuInfo = cpuInfo
            prevNumCpuInfo = numCpuInfo
        }
        
        // 2. 内存使用率 (Mach Kernel VM Statistics)
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let memResult = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        var memPercent: Double = 0.0
        var usedGB: Double = 0.0
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(totalBytes) / 1024.0 / 1024.0 / 1024.0
        
        if memResult == KERN_SUCCESS {
            let pageSize = UInt64(vm_page_size)
            let usedPages = UInt64(vmStats.active_count) + UInt64(vmStats.wire_count) + UInt64(vmStats.speculative_count) + UInt64(vmStats.compressor_page_count)
            let usedBytes = usedPages * pageSize
            memPercent = min(max((Double(usedBytes) / Double(totalBytes)) * 100.0, 0.0), 100.0)
            usedGB = Double(usedBytes) / 1024.0 / 1024.0 / 1024.0
        }
        
        return SystemPerformanceInfo(
            cpuUsage: min(max(cpuUsage, 0.0), 100.0),
            memoryUsagePercent: memPercent,
            memoryUsedGB: usedGB,
            memoryTotalGB: totalGB
        )
    }
    
    // MARK: - 实时网络速率 (getifaddrs)
    func getNetworkTrafficInfo() -> NetworkTrafficInfo {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return lastTrafficInfo
        }
        defer { freeifaddrs(ifaddr) }
        
        var currentIn: UInt64 = 0
        var currentOut: UInt64 = 0
        
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            
            if isUp && !isLoopback, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                if let data = current.pointee.ifa_data {
                    let networkData = data.assumingMemoryBound(to: if_data.self)
                    currentIn += UInt64(networkData.pointee.ifi_ibytes)
                    currentOut += UInt64(networkData.pointee.ifi_obytes)
                }
            }
            ptr = current.pointee.ifa_next
        }
        
        let now = Date().timeIntervalSince1970
        guard prevNetTime > 0 else {
            prevBytesIn = currentIn
            prevBytesOut = currentOut
            prevNetTime = now
            return lastTrafficInfo
        }
        
        let deltaT = max(now - prevNetTime, 0.1)
        let deltaIn = currentIn >= prevBytesIn ? currentIn - prevBytesIn : 0
        let deltaOut = currentOut >= prevBytesOut ? currentOut - prevBytesOut : 0
        
        prevBytesIn = currentIn
        prevBytesOut = currentOut
        prevNetTime = now
        
        let inSpeed = Double(deltaIn) / deltaT
        let outSpeed = Double(deltaOut) / deltaT
        
        lastTrafficInfo = NetworkTrafficInfo(
            downloadSpeed: formatNetworkSpeed(inSpeed),
            uploadSpeed: formatNetworkSpeed(outSpeed)
        )
        return lastTrafficInfo
    }
    
    private func formatNetworkSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1024.0 * 1024.0 {
            return String(format: "%.1f MB/s", bytesPerSec / 1024.0 / 1024.0)
        } else if bytesPerSec >= 1024.0 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024.0)
        } else {
            return String(format: "%.0f B/s", bytesPerSec)
        }
    }
    
    // MARK: - 网络延迟测量 (多目标 TCP connect 握手计时)
    // ICMP ping 需要特权套接字，改用 NWConnection 对多个公共 DNS 的 443 端口并行发起 TCP 连接计时，
    // 以最先完成握手的目标耗时近似网络往返延迟。单一目标不可靠：如 1.1.1.1 在国内网络常被墙，
    // 导致延迟恒显「—」；多目标并行取最快者可跨网络环境稳定工作，全部失败或超时回调 nil，界面优雅降级。
    func measureNetworkLatency(completion: @escaping (Int?) -> Void) {
        // 探测目标：国内公共 DNS 优先（阿里 / 腾讯），国际（Cloudflare / Google）兜底
        let targets = ["223.5.5.5", "119.29.29.29", "1.1.1.1", "8.8.8.8"]
        // 专用串行队列：所有连接的状态回调与超时兜底在同一队列串行执行，标志位天然无线程竞争
        let queue = DispatchQueue(label: "com.quickshow.latency", qos: .utility)
        let start = Date()
        var reported = false        // 是否已回调最终结果（只回调一次）
        var remaining = targets.count // 尚未终止的探测目标数：归零仍未成功则回调 nil
        var connections: [NWConnection] = []
        
        // 统一收口：成功传延迟毫秒数，失败传 nil；回收全部连接避免悬挂
        func finish(_ ms: Int?) {
            guard !reported else { return }
            reported = true
            for conn in connections {
                conn.stateUpdateHandler = nil
                conn.cancel()
            }
            connections.removeAll()
            DispatchQueue.main.async { completion(ms) }
        }
        
        for target in targets {
            let connection = NWConnection(host: NWEndpoint.Host(target), port: 443, using: .tcp)
            connections.append(connection)
            var connectionDone = false // 单连接终止标志：确保 remaining 只递减一次
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // 同刻并行起跑，最先握手成功者即最快目标
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    finish(ms)
                case .failed, .cancelled:
                    guard !connectionDone else { return }
                    connectionDone = true
                    connection.stateUpdateHandler = nil
                    remaining -= 1
                    if remaining == 0 { finish(nil) }
                default:
                    break // .preparing / .waiting 交给超时兜底
                }
            }
            connection.start(queue: queue)
        }
        
        // 3 秒超时兜底：断网或高丢包时保证回调必然触发
        queue.asyncAfter(deadline: .now() + 3) {
            finish(nil)
        }
    }
    
    // MARK: - 磁盘存储空间感知 (Disk Info)
    func getDiskInfo() -> DiskInfo {
        let url = URL(fileURLWithPath: "/")
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = values.volumeAvailableCapacityForImportantUsage,
           let total = values.volumeTotalCapacity {
            return DiskInfo(
                freeGB: Double(free) / 1024.0 / 1024.0 / 1024.0,
                totalGB: Double(total) / 1024.0 / 1024.0 / 1024.0
            )
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let free = attrs[.systemFreeSize] as? Int64,
           let total = attrs[.systemSize] as? Int64 {
            return DiskInfo(
                freeGB: Double(free) / 1024.0 / 1024.0 / 1024.0,
                totalGB: Double(total) / 1024.0 / 1024.0 / 1024.0
            )
        }
        return DiskInfo(freeGB: 0, totalGB: 0)
    }
    
    // MARK: - 高负载进程探测 (Top CPU Process)
    func getTopCPUProcess() -> String? {
        let pipe = Pipe()
        let process = Process()
        process.launchPath = "/bin/ps"
        process.arguments = ["-arcx", "-o", "%cpu,comm"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: "\n")
                for line in lines.dropFirst() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    if parts.count >= 2, let cpu = Double(parts[0]) {
                        let name = String(parts[1])
                        if name != "QuickShow" && name != "ps" && cpu >= 18.0 {
                            return "\(name) \(Int(cpu))%"
                        }
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }
    
    /// 异步探测高负载进程：ps 子进程在后台队列执行，避免 fork + waitUntilExit 阻塞主线程
    /// 复用 getTopCPUProcess() 的解析逻辑，结果统一回主线程后通过 completion 返回
    func getTopCPUProcessAsync(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = self.getTopCPUProcess()
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}