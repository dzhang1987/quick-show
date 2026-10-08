@preconcurrency import CoreLocation
import Foundation

// MARK: - my_location
//
// 坐标系说明（与 MapService 策略一致）：
// CoreLocation 在中国区域返回的坐标与 Apple 中国区地图（GCJ-02）对齐，可直接配合
// 高德 API 与本应用地图卡片，无需转换；海外返回 WGS-84，与高德存在数百米偏移，
// 本 Phase 不做坐标系转换。
//
// 说明：本工具除协议层 snake_case name 外，另提供中文 displayName 与 category，
// 仅供设置页/卡片展示；发给模型的 name/schema 与执行链路完全不变。

/// 读取设备当前 GPS 定位（经纬度 + 大致地址）
final class MyLocationTool: AITool {
    let name = "my_location"
    let displayName = String(localized: "我的位置")
    let category: ToolCategory = .map
    /// 纯读定位，使用独立 CLLocationManager 实例、无共享可变状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
    let description = "读取设备当前 GPS 定位（经纬度坐标与大致地址）。可与 search_places 的 center 参数、plan_route 的 origin 参数直接配合，回答「附近」「从我这里」类问题。"

    var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any](), "required": [String]()]
    }

    private static let iso8601Formatter = ISO8601DateFormatter()

    func execute(arguments: [String: Any]) async throws -> String {
        // CLLocationManager 必须在主线程创建；独立实例，不复用 SystemStatusProvider。
        let bridge = await MainActor.run { LocationBridge() }

        let location: CLLocation
        do {
            location = try await bridge.fetchLocation()
        } catch {
            await MainActor.run { bridge.teardown() }
            throw error
        }
        await MainActor.run { bridge.teardown() }

        let coordinate = location.coordinate
        // 反向地理编码为加分项：失败不致命，坐标为 nil 地址照常返回。
        let address = await reverseGeocodedAddress(for: coordinate)
        let accuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : 0

        var payload: [String: Any] = [
            "ok": true,
            "lat": coordinate.latitude,
            "lng": coordinate.longitude,
            "accuracyMeters": accuracy,
            "timestamp": Self.iso8601Formatter.string(from: location.timestamp)
        ]
        // 反查失败时 formattedAddress 为 null（坐标照常返回）
        payload["formattedAddress"] = address ?? NSNull()
        return AIToolExecutor.encodeJSON(payload)
    }

    // MARK: 反向地理编码（best-effort）

    /// 坐标 → 大致地址（主线程回调桥接）。任何失败返回 nil，不影响坐标结果。
    private func reverseGeocodedAddress(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return await withCheckedContinuation { continuation in
            let geocoder = CLGeocoder()
            let resumeOnce = ResumeOnce(continuation)
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                // 闭包捕获 geocoder，确保请求期间不被释放
                _ = geocoder
                resumeOnce.resume(placemarks?.first.flatMap { Self.formattedAddress(from: $0) })
            }
            // 超时保护：反查超时不阻塞坐标返回（整体需控制在执行器 30 秒超时内）
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                resumeOnce.resume(nil)
            }
        }
    }

    /// placemark → 国/省/市/区/街道级地址（按包含关系去重）
    private static func formattedAddress(from placemark: CLPlacemark) -> String? {
        var parts: [String] = []
        func append(_ value: String?) {
            guard let value, !value.isEmpty else { return }
            if parts.contains(where: { $0.contains(value) || value.contains($0) }) { return }
            parts.append(value)
        }
        append(placemark.country)
        append(placemark.administrativeArea)
        append(placemark.locality)
        append(placemark.subLocality)
        if let thoroughfare = placemark.thoroughfare {
            var street = thoroughfare
            if let sub = placemark.subThoroughfare, !thoroughfare.contains(sub) {
                street += sub
            }
            append(street)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - 定位桥接

/// 一次性定位请求桥接器：把 CLLocationManager 的 delegate 回调转为 async/await。
///
/// - 必须在主线程创建（调用方经 `MainActor.run`），manager 的调用经 `MainActor.run` 发起；
/// - delegate 回调由 CLLocationManager 投递到创建线程（主线程）；
/// - 内部可变状态（continuation）用 NSLock 保护，配合超时 Task 保证只 resume 一次。
private final class LocationBridge: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var authContinuation: CheckedContinuation<Void, Error>?
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

    /// 授权超时（秒）：覆盖用户阅读系统弹窗的时间，且整体不超过执行器 30 秒上限。
    private static let authorizationTimeout: UInt64 = 12_000_000_000
    /// 单次定位超时（秒）
    private static let locationTimeout: UInt64 = 8_000_000_000

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// 释放：一次请求完成后由调用方在主线程置空 delegate。
    func teardown() {
        manager.delegate = nil
    }

    // MARK: 主流程

    func fetchLocation() async throws -> CLLocation {
        let status: CLAuthorizationStatus = await MainActor.run { manager.authorizationStatus }
        switch status {
        case .authorizedAlways, .authorized:
            break
        case .notDetermined:
            try await requestAuthorization()
        case .denied, .restricted:
            throw ToolExecutionError("定位权限被拒绝，请在 系统设置 › 隐私与安全性 › 定位服务 中开启 QuickShow")
        @unknown default:
            throw ToolExecutionError("定位权限状态未知，暂时无法获取定位")
        }

        // 新鲜度：优先使用 60 秒内的缓存值，否则现取一次
        let cached: CLLocation? = await MainActor.run { manager.location }
        if let cached, abs(cached.timestamp.timeIntervalSinceNow) <= 60 {
            return cached
        }
        return try await requestOneShotLocation()
    }

    /// notDetermined → 请求 WhenInUse 授权，等待授权回调（拒绝 / 超时抛错）
    private func requestAuthorization() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setAuthContinuation(continuation)
            Task { @MainActor in
                manager.requestWhenInUseAuthorization()
            }
            Task {
                try? await Task.sleep(nanoseconds: Self.authorizationTimeout)
                self.finishAuth(.failure(ToolExecutionError("等待定位授权超时，请稍后重试")))
            }
        }
    }

    /// 现取一次定位
    private func requestOneShotLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
            setLocationContinuation(continuation)
            Task { @MainActor in
                manager.requestLocation()
            }
            Task {
                try? await Task.sleep(nanoseconds: Self.locationTimeout)
                self.finishLocation(.failure(ToolExecutionError("暂时无法获取定位，请稍后再试")))
            }
        }
    }

    // MARK: CLLocationManagerDelegate（回调在主线程）

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            finishAuth(.success(()))
        case .denied, .restricted:
            finishAuth(.failure(ToolExecutionError("定位权限被拒绝，请在 系统设置 › 隐私与安全性 › 定位服务 中开启 QuickShow")))
        default:
            break // notDetermined：继续等待用户选择
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        finishLocation(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishLocation(.failure(mapLocationError(error)))
    }

    private func mapLocationError(_ error: Error) -> ToolExecutionError {
        if let clError = error as? CLError {
            switch clError.code {
            case .denied:
                return ToolExecutionError("定位权限被拒绝，请在 系统设置 › 隐私与安全性 › 定位服务 中开启 QuickShow")
            case .locationUnknown:
                return ToolExecutionError("暂时无法获取定位，请稍后再试")
            case .network:
                return ToolExecutionError("定位服务网络异常，请稍后再试")
            default:
                return ToolExecutionError("获取定位失败：\(clError.localizedDescription)")
            }
        }
        return ToolExecutionError("暂时无法获取定位，请稍后再试")
    }

    // MARK: Continuation 管理（单次 resume 保证）

    private func setAuthContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        authContinuation = continuation
        lock.unlock()
    }

    private func finishAuth(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = authContinuation
        authContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func setLocationContinuation(_ continuation: CheckedContinuation<CLLocation, Error>) {
        lock.lock()
        locationContinuation = continuation
        lock.unlock()
    }

    private func finishLocation(_ result: Result<CLLocation, Error>) {
        lock.lock()
        let continuation = locationContinuation
        locationContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

// MARK: - 一次性 continuation 闸门

/// 保证 continuation 只 resume 一次（CLGeocoder 回调与超时 Task 竞态安全）
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<T, Never>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(returning: value)
    }
}