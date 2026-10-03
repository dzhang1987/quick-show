@preconcurrency import CoreLocation
import Foundation
import MapKit
import os

// MARK: - 日志

/// 高德接入诊断日志（key 探测、请求失败、兜底路径）
private let amapLogger = Logger(subsystem: "com.dzhang.quickshow.ai", category: "amap")

// MARK: - 地图数据模型

/// 地点解析 / 搜索结果（geocode 与 search_places 共用）
struct MapPlace {
    let name: String
    let formattedAddress: String
    let coordinate: CLLocationCoordinate2D
}

/// 单条路线导航步骤
struct MapRouteStep {
    let instruction: String
    let distanceMeters: Double
}

/// 路线规划结果（含完整折线坐标）
struct MapRoute {
    let distanceMeters: Double
    let durationSeconds: Double
    let steps: [MapRouteStep]
    let points: [CLLocationCoordinate2D]
    let mode: String
}

/// 出行方式（仅 Phase 1 支持的取值）
enum MapRouteMode: String {
    case walking
    case driving
    case transit
}

// MARK: - MapService（MapKit 异步封装）

/// MapKit 数据源封装：地理编码、POI 搜索、路线规划。
/// 全部方法以 async/throws 暴露，供 MapTools 直接调用；结果均为结构化 Swift 模型。
///
/// 扩展点（Phase 2）：高德（Amap）接入时，在本文件按同样的方法签名新增一套
/// `AmapService`，由工具层按配置选择数据源即可，无需改动工具协议与卡片契约。
enum MapService {

    // MARK: 地理编码

    /// 地址 → 坐标。空结果抛「未找到该地址对应的坐标」。
    /// 备注：CLGeocoder 自 macOS 26 起被软废弃，但当前 deployment target 为 13.0，
    /// Phase 1 直接沿用即可；后续可迁移至 MKGeocodingRequest。
    static func geocode(address: String, city: String?) async throws -> [MapPlace] {
        let query = [address, city]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard !query.isEmpty else {
            throw ToolExecutionError("地址不能为空")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let geocoder = CLGeocoder()
            geocoder.geocodeAddressString(query) { placemarks, error in
                // 闭包捕获 geocoder，确保请求期间不被释放
                _ = geocoder

                if let error {
                    continuation.resume(throwing: mapGeocodeError(error))
                    return
                }
                guard let placemarks, !placemarks.isEmpty else {
                    continuation.resume(throwing: ToolExecutionError("未找到该地址对应的坐标"))
                    return
                }
                let places = placemarks.map { placemark in
                    MapPlace(
                        name: placemark.name ?? placemark.locality ?? "未知地点",
                        formattedAddress: formattedAddress(from: placemark),
                        coordinate: placemark.location?.coordinate ?? kCLLocationCoordinate2DInvalid
                    )
                }
                continuation.resume(returning: places)
            }
        }
    }

    // MARK: POI 搜索

    /// 关键词搜索附近地点；center 为 nil 时按纯文本查询（可含城市名），
    /// 提供 center 时按 radiusMeters（默认 5000 米）限定搜索区域。
    static func searchPlaces(
        keyword: String,
        center: CLLocationCoordinate2D?,
        radiusMeters: Double?
    ) async throws -> [MapPlace] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolExecutionError("搜索关键词不能为空")
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let center {
            let radius = max(radiusMeters ?? 5000, 100)
            request.region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: radius,
                longitudinalMeters: radius
            )
        }

        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch {
            throw ToolExecutionError("地点搜索失败：\(error.localizedDescription)")
        }

        return response.mapItems.map { item in
            MapPlace(
                name: item.name ?? "未知地点",
                formattedAddress: formattedAddress(from: item.placemark),
                coordinate: item.placemark.coordinate
            )
        }
    }

    // MARK: 路线规划

    /// 路线规划：步行 / 驾车走 MKDirections；transit 在 macOS 不支持，直接抛错。
    static func planRoute(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        mode: MapRouteMode
    ) async throws -> MapRoute {
        if mode == .transit {
            // MapKit 在 macOS 不支持公交路线；transit 由 AmapService 提供，此分支仅防御性保留。
            throw ToolExecutionError("transit 公交路线需高德数据源（MapKit 无公交）")
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = (mode == .walking) ? .walking : .automobile

        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch {
            throw mapDirectionsError(error)
        }

        guard let route = response.routes.first else {
            throw ToolExecutionError("未找到可用路线")
        }

        let steps = route.steps.map { step in
            MapRouteStep(
                instruction: step.instructions.isEmpty ? "继续前行" : step.instructions,
                distanceMeters: step.distance
            )
        }
        return MapRoute(
            distanceMeters: route.distance,
            durationSeconds: route.expectedTravelTime,
            steps: steps,
            points: coordinates(of: route.polyline),
            mode: mode.rawValue
        )
    }

    // MARK: - 内部辅助

    /// MKPolyline → 完整坐标数组
    private static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        var points = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: count))
        return points
    }

    /// 由 placemark 各字段尽量拼出完整地址（按包含关系去重，避免 name 与街道重复）
    private static func formattedAddress(from placemark: CLPlacemark) -> String {
        var parts: [String] = []
        func append(_ value: String?) {
            guard let value, !value.isEmpty else { return }
            if parts.contains(where: { $0.contains(value) || value.contains($0) }) { return }
            parts.append(value)
        }

        append(placemark.name)
        if let thoroughfare = placemark.thoroughfare {
            var street = thoroughfare
            if let sub = placemark.subThoroughfare, !thoroughfare.contains(sub) {
                street += sub
            }
            append(street)
        }
        append(placemark.subLocality)
        append(placemark.locality)
        append(placemark.administrativeArea)
        append(placemark.postalCode)
        append(placemark.country)

        return parts.isEmpty ? "未知地址" : parts.joined(separator: ", ")
    }

    /// CLGeocoder 错误 → 用户可读中文
    private static func mapGeocodeError(_ error: Error) -> ToolExecutionError {
        if let clError = error as? CLError, clError.code == .geocodeFoundNoResult {
            return ToolExecutionError("未找到该地址对应的坐标")
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return ToolExecutionError("地理编码请求失败，请检查网络连接")
        }
        return ToolExecutionError("地理编码失败：\(error.localizedDescription)")
    }

    /// MKDirections 错误 → 用户可读中文（含限流与网络失败）
    private static func mapDirectionsError(_ error: Error) -> ToolExecutionError {
        if let mkError = error as? MKError {
            switch mkError.code {
            case .loadingThrottled:
                return ToolExecutionError("路线请求过于频繁，请稍后重试")
            case .placemarkNotFound:
                return ToolExecutionError("无法解析起点或终点坐标")
            case .directionsNotFound:
                return ToolExecutionError("未找到可用路线")
            case .serverFailure:
                return ToolExecutionError("路线服务暂时不可用，请稍后重试")
            default:
                return ToolExecutionError("路线规划失败：\(mkError.localizedDescription)")
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return ToolExecutionError("路线请求失败，请检查网络连接")
        }
        return ToolExecutionError("路线规划失败：\(error.localizedDescription)")
    }
}

// MARK: - 高德 Key 读取（运行时探测）

/// 高德 API Key 配置：文件存储（纯文本单行），每次调用时重读，便于运行期替换 key 而无需重启。
/// 参考 WebToolsConfig 的 tavily_apikey 读取方式。
enum AmapConfig {
    /// 读取 `~/Library/Application Support/QuickShow/amap_apikey` 并 trim；
    /// 文件不存在或内容为空 → nil（视为未配置，全部走 MapKit）。
    static func apiKey() -> String? {
        guard let url = apiKeyFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static var apiKeyFileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("QuickShow", isDirectory: true)
            .appendingPathComponent("amap_apikey")
    }
}

// MARK: - AmapService（高德 Web 服务 v3）

/// 高德开放平台 Web 服务（v3，GET，参数 key）异步封装。
///
/// - 坐标系：高德返回 **GCJ-02**；Apple 地图在中国区同样为 GCJ-02，故坐标可不做转换直接
///   透传给卡片渲染。海外使用会有数百米偏移，Phase 2 不做坐标系转换。
/// - 配额提示：POI 搜索（place/text）月度配额约 5000 次，显著低于 LBS 类服务的约 15 万次/月，
///   使用需留意；geocode / direction 配额更高。
/// - polyline 格式为 `"lng,lat;lng,lat;..."`（**经度在前**、分号分隔），解析时切勿调换。
enum AmapService {

    // MARK: 地理编码

    /// 地址 → 坐标（geocode/geo）。无结果返回空数组（由分派层回退 MapKit）。
    static func geocode(address: String, city: String?, key: String) async throws -> [MapPlace] {
        var params = ["address": address]
        if let city, !city.isEmpty { params["city"] = city }

        let json = try await request(path: "/v3/geocode/geo", params: params, key: key)
        guard let geocodes = json["geocodes"] as? [[String: Any]] else { return [] }
        return geocodes.compactMap { item -> MapPlace? in
            guard let coordinate = parseLocation(item["location"]) else { return nil }
            let formatted = amapString(item["formatted_address"]) ?? ""
            let name = amapString(item["name"]) ?? (formatted.isEmpty ? "未知地点" : formatted)
            return MapPlace(
                name: name,
                formattedAddress: formatted.isEmpty ? name : formatted,
                coordinate: coordinate
            )
        }
    }

    // MARK: 逆地理（城市反查，供公交路线用）

    /// 坐标 → 城市名（regeo）。直辖市 city 字段可能为空数组，此时回退 province。
    static func reverseGeocodeCity(_ coordinate: CLLocationCoordinate2D, key: String) async throws -> String {
        let params = ["location": coordString(coordinate)]
        let json = try await request(path: "/v3/geocode/regeo", params: params, key: key)
        guard let regeocode = json["regeocode"] as? [String: Any],
              let component = regeocode["addressComponent"] as? [String: Any] else {
            throw ToolExecutionError("无法解析起点所在城市")
        }
        if let city = amapString(component["city"]), !city.isEmpty { return city }
        if let province = amapString(component["province"]), !province.isEmpty { return province }
        throw ToolExecutionError("无法解析起点所在城市")
    }

    // MARK: POI 搜索

    /// 关键词搜索（place/text，offset=10）。提供中心坐标时以 location+radius 做周边检索。
    static func searchPlaces(
        keyword: String,
        city: String?,
        center: CLLocationCoordinate2D?,
        radiusMeters: Double?,
        key: String
    ) async throws -> [MapPlace] {
        var params = ["keywords": keyword, "offset": "10"]
        if let city, !city.isEmpty { params["city"] = city }
        if let center {
            params["location"] = coordString(center)
            params["radius"] = String(Int(max(radiusMeters ?? 5000, 100)))
        }

        let json = try await request(path: "/v3/place/text", params: params, key: key)
        guard let pois = json["pois"] as? [[String: Any]] else { return [] }
        return pois.compactMap { poi -> MapPlace? in
            guard let coordinate = parseLocation(poi["location"]) else { return nil }
            let name = amapString(poi["name"]) ?? "未知地点"
            return MapPlace(
                name: name,
                formattedAddress: poiFormattedAddress(poi, fallbackName: name),
                coordinate: coordinate
            )
        }
    }

    // MARK: 路线规划

    /// 路线规划分派：步行 / 驾车 / 公交。
    static func planRoute(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        mode: MapRouteMode,
        key: String
    ) async throws -> MapRoute {
        switch mode {
        case .walking:
            return try await directionRoute(
                apiPath: "/v3/direction/walking",
                origin: origin,
                destination: destination,
                mode: mode,
                key: key
            )
        case .driving:
            return try await directionRoute(
                apiPath: "/v3/direction/driving",
                origin: origin,
                destination: destination,
                mode: mode,
                key: key
            )
        case .transit:
            return try await transitRoute(origin: origin, destination: destination, key: key)
        }
    }

    /// 步行 / 驾车：route.paths[0]（distance / duration / steps）
    private static func directionRoute(
        apiPath: String,
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        mode: MapRouteMode,
        key: String
    ) async throws -> MapRoute {
        let params = [
            "origin": coordString(origin),
            "destination": coordString(destination)
        ]
        let json = try await request(path: apiPath, params: params, key: key)
        guard let route = json["route"] as? [String: Any],
              let paths = route["paths"] as? [[String: Any]],
              let path = paths.first else {
            throw ToolExecutionError("高德未找到可用路线")
        }

        let steps = (path["steps"] as? [[String: Any]] ?? []).map { step in
            MapRouteStep(
                instruction: truncated(amapString(step["instruction"]) ?? "继续前行"),
                distanceMeters: amapNumber(step["distance"]) ?? 0
            )
        }
        let points = routePoints(path: path)
        guard !points.isEmpty else {
            throw ToolExecutionError("高德路线坐标为空")
        }
        return MapRoute(
            distanceMeters: amapNumber(path["distance"]) ?? 0,
            durationSeconds: amapNumber(path["duration"]) ?? 0,
            steps: steps,
            points: points,
            mode: mode.rawValue
        )
    }

    /// 公交：origin 先 regeo 反查城市，再调 integrated；拼接各段 polyline。
    private static func transitRoute(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        key: String
    ) async throws -> MapRoute {
        let city = try await reverseGeocodeCity(origin, key: key)
        let params = [
            "origin": coordString(origin),
            "destination": coordString(destination),
            "city": city
        ]
        let json = try await request(path: "/v3/direction/transit/integrated", params: params, key: key)
        guard let route = json["route"] as? [String: Any],
              let transits = route["transits"] as? [[String: Any]],
              let transit = transits.first else {
            throw ToolExecutionError("高德未找到可用公交路线")
        }

        var steps: [MapRouteStep] = []
        var points: [CLLocationCoordinate2D] = []
        var totalDistance: Double = 0

        for segment in (transit["segments"] as? [[String: Any]] ?? []) {
            // 步行段：逐条步行指令 + polyline
            if let walking = segment["walking"] as? [String: Any] {
                for step in (walking["steps"] as? [[String: Any]] ?? []) {
                    steps.append(MapRouteStep(
                        instruction: truncated(amapString(step["instruction"]) ?? "步行"),
                        distanceMeters: amapNumber(step["distance"]) ?? 0
                    ))
                    points.append(contentsOf: parsePolyline(step["polyline"]))
                }
                totalDistance += amapNumber(walking["distance"]) ?? 0
            }
            // 公交段：取首条线路的上下车站与 polyline
            if let bus = segment["bus"] as? [String: Any],
               let lines = bus["buslines"] as? [[String: Any]],
               let line = lines.first {
                let lineName = amapString(line["name"]) ?? "公交"
                let departure = (line["departure_stop"] as? [String: Any]).flatMap { amapString($0["name"]) }
                let arrival = (line["arrival_stop"] as? [String: Any]).flatMap { amapString($0["name"]) }
                var instruction = "乘坐\(lineName)"
                if let departure, let arrival {
                    instruction += "：\(departure) → \(arrival)"
                }
                steps.append(MapRouteStep(
                    instruction: truncated(instruction),
                    distanceMeters: amapNumber(line["distance"]) ?? 0
                ))
                points.append(contentsOf: parsePolyline(line["polyline"]))
                totalDistance += amapNumber(line["distance"]) ?? 0
            }
        }

        guard !points.isEmpty else {
            throw ToolExecutionError("高德公交路线坐标为空")
        }
        // 分段未给出距离时，用折线几何长度兜底（近似值）
        if totalDistance <= 0 {
            totalDistance = polylineLength(points)
        }
        return MapRoute(
            distanceMeters: totalDistance,
            durationSeconds: amapNumber(transit["duration"]) ?? 0,
            steps: steps,
            points: points,
            mode: MapRouteMode.transit.rawValue
        )
    }

    // MARK: HTTP

    /// 统一 GET 请求：拼接 key，校验 status=="1"，返回原始 JSON。
    private static func request(path: String, params: [String: String], key: String) async throws -> [String: Any] {
        var components = URLComponents(string: "https://restapi.amap.com\(path)")
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "key", value: key))
        components?.queryItems = items
        guard let url = components?.url else {
            throw ToolExecutionError("高德请求地址构造失败")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ToolExecutionError("高德请求失败：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ToolExecutionError("高德服务响应异常")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ToolExecutionError("高德服务返回异常（HTTP \(http.statusCode)）")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolExecutionError("高德响应解析失败")
        }
        guard (amapString(json["status"]) ?? "0") == "1" else {
            throw ToolExecutionError(amapErrorMessage(json))
        }
        return json
    }

    /// 高德错误码 → 用户可读中文（10001 提示检查 amap_apikey 文件）
    private static func amapErrorMessage(_ json: [String: Any]) -> String {
        let info = amapString(json["info"]) ?? "未知错误"
        let infocode = amapString(json["infocode"]) ?? ""
        switch infocode {
        case "10001":
            return "高德 API Key 无效（infocode 10001），请检查 amap_apikey 文件"
        case "10003", "10044":
            return "高德服务调用额度超限（infocode \(infocode)）：\(info)"
        case "10004":
            return "高德服务访问过于频繁（infocode \(infocode)）：\(info)"
        default:
            return infocode.isEmpty ? "高德服务错误：\(info)" : "高德服务错误（infocode \(infocode)）：\(info)"
        }
    }

    // MARK: 解析辅助

    /// "lng,lat" → 坐标（经度在前）
    private static func parseLocation(_ raw: Any?) -> CLLocationCoordinate2D? {
        guard let string = amapString(raw) else { return nil }
        let parts = string.split(separator: ",")
        guard parts.count == 2,
              let lng = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let lat = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// "lng,lat;lng,lat;..." → 坐标数组（经度在前、分号分隔）
    private static func parsePolyline(_ raw: Any?) -> [CLLocationCoordinate2D] {
        guard let string = amapString(raw), !string.isEmpty else { return [] }
        return string.split(separator: ";").compactMap { pair -> CLLocationCoordinate2D? in
            let parts = pair.split(separator: ",")
            guard parts.count == 2,
                  let lng = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let lat = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
    }

    /// 路线坐标：优先 path.polyline，缺失时按 steps[].polyline 顺序拼接
    private static func routePoints(path: [String: Any]) -> [CLLocationCoordinate2D] {
        if let direct = amapString(path["polyline"]), !direct.isEmpty {
            return parsePolyline(direct)
        }
        var points: [CLLocationCoordinate2D] = []
        for step in (path["steps"] as? [[String: Any]] ?? []) {
            points.append(contentsOf: parsePolyline(step["polyline"]))
        }
        return points
    }

    /// POI 地址拼接：cityname + adname + address（中文无分隔符），缺省回退名称
    private static func poiFormattedAddress(_ poi: [String: Any], fallbackName: String) -> String {
        var parts: [String] = []
        func append(_ value: String?) {
            guard let value, !value.isEmpty else { return }
            if parts.contains(where: { $0.contains(value) || value.contains($0) }) { return }
            parts.append(value)
        }
        append(amapString(poi["cityname"]))
        append(amapString(poi["adname"]))
        append(amapString(poi["address"]))
        return parts.isEmpty ? fallbackName : parts.joined()
    }

    /// "lng,lat" 字符串
    private static func coordString(_ coordinate: CLLocationCoordinate2D) -> String {
        "\(coordinate.longitude),\(coordinate.latitude)"
    }

    /// 折线几何长度（米），用于公交分段缺失距离时的近似兜底
    private static func polylineLength(_ points: [CLLocationCoordinate2D]) -> Double {
        guard points.count > 1 else { return 0 }
        var total: Double = 0
        for index in 1..<points.count {
            let previous = CLLocation(latitude: points[index - 1].latitude, longitude: points[index - 1].longitude)
            let current = CLLocation(latitude: points[index].latitude, longitude: points[index].longitude)
            total += current.distance(from: previous)
        }
        return total
    }

    private static func amapString(_ raw: Any?) -> String? {
        if let string = raw as? String { return string }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    private static func amapNumber(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String { return Double(string) }
        return nil
    }

    /// 单条指令截断到 ~120 字符，避免超长导航文本撑爆卡片
    private static func truncated(_ text: String, limit: Int = 120) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

// MARK: - 数据源标注与分派（高德优先 + MapKit 兜底）

/// 结果数据源标注（写入结果 JSON 的 source 字段）
enum MapDataSource: String {
    case amap
    case mapkit
}

/// geocode / search_places 分派结果
struct MapPlaceResult {
    let places: [MapPlace]
    let source: MapDataSource
}

/// plan_route 分派结果
struct MapRouteResult {
    let route: MapRoute
    let source: MapDataSource
}

/// 分派层：有高德 key 时优先走高德，失败 / status!="1" / 空结果自动回退 MapKit 并打日志。
/// transit 为例外：MapKit 无公交数据，无 key 或高德失败时维持明确报错。
enum MapDispatch {

    // MARK: 地理编码

    static func geocode(address: String, city: String?) async throws -> MapPlaceResult {
        var amapFailure: Error?
        if let key = AmapConfig.apiKey() {
            do {
                let places = try await AmapService.geocode(address: address, city: city, key: key)
                if !places.isEmpty {
                    return MapPlaceResult(places: places, source: .amap)
                }
                amapLogger.notice("高德地理编码无结果，回退 MapKit")
            } catch {
                amapLogger.warning("高德地理编码失败，回退 MapKit：\(error.localizedDescription, privacy: .public)")
                amapFailure = error
            }
        }

        do {
            let places = try await MapService.geocode(address: address, city: city)
            return MapPlaceResult(places: places, source: .mapkit)
        } catch {
            throw combinedFallbackError(amapFailure: amapFailure, mapkitError: error)
        }
    }

    // MARK: POI 搜索

    static func searchPlaces(
        keyword: String,
        city: String?,
        center: CLLocationCoordinate2D?,
        radiusMeters: Double?
    ) async throws -> MapPlaceResult {
        var amapFailure: Error?
        if let key = AmapConfig.apiKey() {
            do {
                let places = try await AmapService.searchPlaces(
                    keyword: keyword,
                    city: city,
                    center: center,
                    radiusMeters: radiusMeters,
                    key: key
                )
                if !places.isEmpty {
                    return MapPlaceResult(places: places, source: .amap)
                }
                amapLogger.notice("高德 POI 搜索无结果，回退 MapKit")
            } catch {
                amapLogger.warning("高德 POI 搜索失败，回退 MapKit：\(error.localizedDescription, privacy: .public)")
                amapFailure = error
            }
        }

        // MapKit 兜底：未提供 center 时把城市名并入自然语言查询
        var query = keyword
        if center == nil, let city, !city.isEmpty {
            query = "\(keyword) \(city)"
        }
        do {
            let places = try await MapService.searchPlaces(keyword: query, center: center, radiusMeters: radiusMeters)
            return MapPlaceResult(places: places, source: .mapkit)
        } catch {
            throw combinedFallbackError(amapFailure: amapFailure, mapkitError: error)
        }
    }

    // MARK: 路线规划

    static func planRoute(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        mode: MapRouteMode
    ) async throws -> MapRouteResult {
        // transit：仅高德提供，无 MapKit 兜底
        if mode == .transit {
            guard let key = AmapConfig.apiKey() else {
                throw ToolExecutionError("transit 公交路线需要高德 API Key，请在 ~/Library/Application Support/QuickShow/amap_apikey 配置后重试")
            }
            do {
                let route = try await AmapService.planRoute(
                    origin: origin,
                    destination: destination,
                    mode: .transit,
                    key: key
                )
                return MapRouteResult(route: route, source: .amap)
            } catch {
                amapLogger.warning("高德公交路线规划失败：\(error.localizedDescription, privacy: .public)")
                throw ToolExecutionError("公交路线规划失败：\(error.localizedDescription)")
            }
        }

        var amapFailure: Error?
        if let key = AmapConfig.apiKey() {
            do {
                let route = try await AmapService.planRoute(
                    origin: origin,
                    destination: destination,
                    mode: mode,
                    key: key
                )
                return MapRouteResult(route: route, source: .amap)
            } catch {
                amapLogger.warning("高德路线规划失败，回退 MapKit：\(error.localizedDescription, privacy: .public)")
                amapFailure = error
            }
        }

        do {
            let route = try await MapService.planRoute(origin: origin, destination: destination, mode: mode)
            return MapRouteResult(route: route, source: .mapkit)
        } catch {
            throw combinedFallbackError(amapFailure: amapFailure, mapkitError: error)
        }
    }

    // MARK: 兜底错误合并

    /// 高德与 MapKit 均失败时合并两者的用户可读原因（保留 key 失效等关键提示）。
    private static func combinedFallbackError(amapFailure: Error?, mapkitError: Error) -> ToolExecutionError {
        guard let amapFailure else {
            return (mapkitError as? ToolExecutionError) ?? ToolExecutionError(mapkitError.localizedDescription)
        }
        return ToolExecutionError("高德：\(amapFailure.localizedDescription)；MapKit：\(mapkitError.localizedDescription)")
    }
}