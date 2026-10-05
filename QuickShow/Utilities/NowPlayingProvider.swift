import Foundation
import AppKit

// MARK: - Now Playing 媒体信息桥（mediaremote-adapter）
// macOS 15.4+ 起 mediaremoted 对第三方进程做 entitlement 校验，直读 MediaRemote 恒返回空。
// 改用已 vendor 的 mediaremote-adapter：借系统自带 /usr/bin/perl（com.apple.perl 身份）
// 加载 helper framework 读取系统 Now Playing 数据。调用契约：
//   /usr/bin/perl <script> <framework> <子命令> [选项]   （所有路径必须绝对路径）
//   test   → 退出码 0 表示可用；非 0 表示被系统封锁，判定后不重试
//   stream → diff 模式持续按行输出 NDJSON（payload 只含变更字段，Swift 侧合并）直到 SIGTERM
//   send <ID> → 发送媒体控制命令（2=播放/暂停 4=下一首 5=上一首 12=快退15s 13=快进15s）
// 无媒体会话时合并状态为空，映射层置 nil；流属于事件推送，待机零轮询。
//
// 本类不持有 @Published：info 更新经构造注入的 onInfoUpdate 回调推给门面，
// 由门面在 main 队列写入 @Published nowPlayingInfo，维持原有线程/发布语义。
final class NowPlayingProvider {
    /// info 更新回调（门面注入）；调用点与原来赋值 nowPlayingInfo 的线程语义一致（均在 main 队列）
    private let onInfoUpdate: (NowPlayingInfo?) -> Void

    // adapter 可用标记：test 未通过时永久为 false，nowPlayingInfo 恒 nil（不重试）
    private var adapterAvailable = false
    private var adapterStreamProcess: Process?
    private var adapterStreamOutputHandle: FileHandle?
    private var adapterBufferLock = NSLock()
    private var adapterBuffer = Data()

    // diff 模式合并状态（仅 adapterParseQueue 串行访问，无需加锁）：
    // payload 只含变更字段，新值覆盖对应 key，值为 null 的 key 移除
    private var nowPlayingMergedState: [String: Any] = [:]
    // 封面解码缓存：以 base64 串为内容指纹，同一封面不重复解码（大封面解码可达数十毫秒）
    private var artworkCacheKey: String? = nil
    private var artworkCache: NSImage? = nil
    // payload 合并/模型构建专用串行队列：封面 base64 解码移出主线程，且保证 diff 按序合并
    private static let adapterParseQueue = DispatchQueue(label: "com.quickshow.nowplaying.parse", qos: .utility)
    // ISO8601 时间戳解析（timestamp 为 elapsedTime 的采样时刻，是进度插值基准）
    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(onInfoUpdate: @escaping (NowPlayingInfo?) -> Void) {
        self.onInfoUpdate = onInfoUpdate
    }

    /// 门面在 init 中调用：拉起桥接（内部后台清理孤儿 + test 自检 + stream）
    func start() {
        startNowPlayingAdapter()
    }

    /// 门面 willTerminate / deinit 调用：终止 stream 进程，避免孤儿
    func shutdown() {
        stopNowPlayingAdapter()
    }

    /// bundle 内 adapter 资源绝对路径；资源缺失时整体降级禁用
    private var adapterResourcePaths: (script: String, framework: String, testClient: String)? {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("MediaRemote") else { return nil }
        let script = base.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = base.appendingPathComponent("MediaRemoteAdapter.framework").path
        let testClient = base.appendingPathComponent("MediaRemoteAdapterTestClient").path
        guard FileManager.default.fileExists(atPath: script),
              FileManager.default.fileExists(atPath: framework),
              FileManager.default.fileExists(atPath: testClient) else { return nil }
        return (script, framework, testClient)
    }

    /// 启动桥接：后台先清理上次残留的孤儿 stream 进程，再跑 test 自检，通过才拉起 stream；失败/超时则永久禁用、nowPlayingInfo 恒 nil
    private func startNowPlayingAdapter() {
        guard let paths = adapterResourcePaths else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.killOrphanAdapterProcesses(scriptPath: paths.script)
            guard self.runAdapterTest(paths: paths) else { return }
            DispatchQueue.main.async {
                self.adapterAvailable = true
                self.startAdapterStream(paths: paths)
            }
        }
    }

    /// 清理孤儿 stream 进程：上次实例若经 SIGTERM（如 killall）/强退等路径退出，不会触发
    /// willTerminate 回收，其 stream 子进程会被重新挂到 launchd 下永久残留
    /// （持续占用 mediaremoted XPC 连接与内存，且随每次重启累积）。
    /// 以本 bundle 内脚本绝对路径做 pkill 精确匹配清理；调用时机在自身 stream 拉起之前，不会误杀自己。
    private func killOrphanAdapterProcesses(scriptPath: String) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", scriptPath]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        // 无孤儿时 pkill 返回非 0，属正常情况，忽略结果
        try? pkill.run()
        pkill.waitUntilExit()
    }

    /// 自检 adapter 是否被系统授权；5 秒超时兜底，超时强制终止并判定不可用
    private func runAdapterTest(paths: (script: String, framework: String, testClient: String)) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script, paths.framework, paths.testClient, "test"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    /// 拉起 stream 子进程，逐行读取 NDJSON；进程生命周期由持有引用管理，退出即降级。
    /// diff 模式（默认）：payload 只含变更字段，Swift 侧维护合并状态字典；
    /// 保留封面输出（artworkData），供展开态媒体卡片渲染。
    private func startAdapterStream(paths: (script: String, framework: String, testClient: String)) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script, paths.framework, "stream", "--debounce=100"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let outputHandle = pipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeAdapterStream(data)
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.adapterStreamOutputHandle?.readabilityHandler = nil
                self.adapterStreamOutputHandle = nil
                self.adapterStreamProcess = nil
                // 非零退出码 = 致命错误，不得重新拉起；置 nil 优雅降级
                self.adapterAvailable = false
                self.onInfoUpdate(nil)
            }
        }
        do {
            try process.run()
            adapterStreamProcess = process
            adapterStreamOutputHandle = outputHandle
        } catch {
            adapterAvailable = false
        }
    }

    /// 按行切分流式输出（readabilityHandler 回调可能含半行，需缓冲拼接后再解析）
    private func consumeAdapterStream(_ data: Data) {
        adapterBufferLock.lock()
        adapterBuffer.append(data)
        var lines: [String] = []
        while let newline = adapterBuffer.firstIndex(of: 0x0A) {
            let lineData = adapterBuffer.subdata(in: adapterBuffer.startIndex..<newline)
            adapterBuffer.removeSubrange(adapterBuffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        adapterBufferLock.unlock()
        for line in lines {
            parseAdapterLine(line)
        }
    }

    /// 解析单行 NDJSON：stream 行形如 {"type":"data","payload":{...}}；
    /// diff 合并与封面解码放专用串行队列（避免阻塞主线程），结果回主线程赋值
    private func parseAdapterLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null", let data = trimmed.data(using: .utf8) else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let payload = object["payload"] as? [String: Any] ?? object
        Self.adapterParseQueue.async { [weak self] in
            guard let self = self else { return }
            let info = self.buildNowPlayingInfo(from: payload)
            DispatchQueue.main.async {
                self.onInfoUpdate(info)
            }
        }
    }

    /// diff 合并 + 模型映射（仅 adapterParseQueue 串行执行）：
    /// 新 payload 覆盖对应 key，值为 null 的 key 移除；
    /// 「有媒体会话即显示」：title 非空即保留（暂停也显示，供 ⏎ 盲操恢复播放），空会话置 nil
    private func buildNowPlayingInfo(from payload: [String: Any]) -> NowPlayingInfo? {
        for (key, value) in payload {
            if value is NSNull {
                nowPlayingMergedState.removeValue(forKey: key)
            } else {
                nowPlayingMergedState[key] = value
            }
        }
        let merged = nowPlayingMergedState
        guard let title = merged["title"] as? String, !title.isEmpty else {
            // 会话消失：清空合并状态与封面缓存，下次会话从零开始
            nowPlayingMergedState = [:]
            artworkCacheKey = nil
            artworkCache = nil
            return nil
        }
        let playing = merged["playing"] as? Bool ?? false
        let bundleID = merged["bundleIdentifier"] as? String
        let parentBundleID = merged["parentApplicationBundleIdentifier"] as? String
        return NowPlayingInfo(
            title: title,
            artist: merged["artist"] as? String ?? "",
            album: merged["album"] as? String ?? "",
            appName: adapterAppName(parentBundleID: parentBundleID, bundleID: bundleID),
            // WebKit.GPU 等辅助进程不可激活，存「可激活的应用」：优先父应用（如 Safari）
            bundleIdentifier: parentBundleID ?? bundleID,
            isPlaying: playing,
            duration: merged["duration"] as? Double ?? 0,
            elapsedTime: merged["elapsedTime"] as? Double ?? 0,
            playbackRate: merged["playbackRate"] as? Double ?? (playing ? 1.0 : 0.0),
            timestamp: (merged["timestamp"] as? String).flatMap(Self.parseISO8601),
            artwork: decodeArtwork(base64: merged["artworkData"] as? String)
        )
    }
    
    /// ISO8601 时间戳解析：兼容带毫秒（.123Z）与标准（Z）两种格式
    private static func parseISO8601(_ string: String) -> Date? {
        if let date = iso8601FractionalFormatter.date(from: string) { return date }
        return iso8601Formatter.date(from: string)
    }
    
    /// 封面解码缓存：以 base64 串为内容指纹，同一封面不重复解码
    private func decodeArtwork(base64: String?) -> NSImage? {
        guard let base64 = base64, !base64.isEmpty else { return nil }
        if artworkCacheKey == base64 { return artworkCache }
        let image = Data(base64Encoded: base64).flatMap { NSImage(data: $0) }
        artworkCacheKey = base64
        artworkCache = image
        return image
    }
    
    /// 发送媒体控制命令：每次按键 spawn 一次性 perl 进程，
    /// 忽略 stdout/stderr、短生命周期自然退出（即发即弃，不阻塞主线程）
    func sendMediaCommand(_ command: MediaCommand) {
        guard adapterAvailable, let paths = adapterResourcePaths else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script, paths.framework, "send", "\(command.rawValue)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// 反查来源应用展示名：优先父应用（用户心智中的 App），查不到退化为 bundle id 末段
    private func adapterAppName(parentBundleID: String?, bundleID: String?) -> String {
        guard let lookupID = parentBundleID ?? bundleID else { return "" }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: lookupID).first,
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        return lookupID.split(separator: ".").last.map(String.init) ?? ""
    }

    /// 停止 stream 进程：App 退出/deinit 时发 SIGTERM，避免遗留孤儿进程
    private func stopNowPlayingAdapter() {
        adapterStreamOutputHandle?.readabilityHandler = nil
        adapterStreamOutputHandle = nil
        if let process = adapterStreamProcess, process.isRunning {
            process.terminate()
        }
        adapterStreamProcess = nil
    }
}