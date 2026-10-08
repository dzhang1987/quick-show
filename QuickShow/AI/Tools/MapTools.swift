import CoreLocation
import Foundation

// 说明：各工具除协议层 snake_case name 外，另提供中文 displayName 与 category，
// 仅供设置页/卡片展示；发给模型的 name/schema 与执行链路完全不变。

// MARK: - 文件级辅助
//
// 坐标参数统一为 {lat: Double, lng: Double} 对象；工具结果顶层携带 "ok" 键，
// 由 AIToolExecutor.normalizeResult 原样透传。

/// 取可选的非空字符串参数（trim 后空串视为未提供）
private func optionalStringArg(_ arguments: [String: Any], _ key: String) -> String? {
    let value = stringValue(arguments[key])?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (value?.isEmpty == false) ? value : nil
}

/// Any → String（含 NSNumber 兼容）
private func stringValue(_ raw: Any?) -> String? {
    if let string = raw as? String { return string }
    if let number = raw as? NSNumber { return number.stringValue }
    return nil
}

/// 取可选数字参数；非法类型返回 nil
private func optionalNumber(_ raw: Any?) -> Double? {
    guard let raw, !(raw is NSNull) else { return nil }
    if let number = raw as? NSNumber { return number.doubleValue }
    if let string = raw as? String { return Double(string) }
    return nil
}

/// 取必填数字
private func requiredNumber(_ raw: Any?, key: String) throws -> Double {
    guard let value = optionalNumber(raw) else {
        if raw == nil || raw is NSNull {
            throw ToolExecutionError("缺少必填参数：\(key)")
        }
        throw ToolExecutionError("参数 \(key) 类型错误，应为数字")
    }
    return value
}

/// 从 {lat,lng} 对象解析坐标
private func coordinate(from dict: [String: Any], key: String) throws -> CLLocationCoordinate2D {
    let lat = try requiredNumber(dict["lat"], key: "\(key).lat")
    let lng = try requiredNumber(dict["lng"], key: "\(key).lng")
    return CLLocationCoordinate2D(latitude: lat, longitude: lng)
}

/// 取必填坐标参数 {lat,lng}
private func requiredCoordinate(_ arguments: [String: Any], _ key: String) throws -> CLLocationCoordinate2D {
    guard let raw = arguments[key], !(raw is NSNull) else {
        throw ToolExecutionError("缺少必填参数：\(key)")
    }
    guard let dict = raw as? [String: Any] else {
        throw ToolExecutionError("参数 \(key) 类型错误，应为 {lat,lng} 对象")
    }
    return try coordinate(from: dict, key: key)
}

/// 取可选坐标参数 {lat,lng}
private func optionalCoordinate(_ arguments: [String: Any], _ key: String) throws -> CLLocationCoordinate2D? {
    guard let raw = arguments[key], !(raw is NSNull) else { return nil }
    guard let dict = raw as? [String: Any] else {
        throw ToolExecutionError("参数 \(key) 类型错误，应为 {lat,lng} 对象")
    }
    return try coordinate(from: dict, key: key)
}

/// 坐标 → JSON 对象
private func coordinateJSON(_ coordinate: CLLocationCoordinate2D) -> [String: Any] {
    ["lat": coordinate.latitude, "lng": coordinate.longitude]
}

/// 地点 → 工具结果条目
private func placeJSON(_ place: MapPlace) -> [String: Any] {
    [
        "name": place.name,
        "formattedAddress": place.formattedAddress,
        "lat": place.coordinate.latitude,
        "lng": place.coordinate.longitude
    ]
}

/// 距离格式化：>= 1km 保留一位小数
private func formatDistance(_ meters: Double) -> String {
    if meters >= 1000 {
        return String(format: "%.1f km", meters / 1000)
    }
    return String(format: "%.0f m", meters)
}

/// 时长格式化：分钟起算，>= 60 分钟拆成小时
private func formatDuration(_ seconds: Double) -> String {
    let minutes = max(1, Int((seconds / 60).rounded()))
    if minutes >= 60 {
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? String(localized: "\(hours) 小时") : String(localized: "\(hours) 小时 \(remainder) 分钟")
    }
    return String(localized: "\(minutes) 分钟")
}

/// 出行方式中文名
private func modeDisplayName(_ mode: MapRouteMode) -> String {
    switch mode {
    case .walking: return String(localized: "步行")
    case .driving: return String(localized: "驾车")
    case .transit: return String(localized: "公交")
    }
}

// MARK: - 1. geocode

/// 地址 → 坐标（高德优先，MapKit / CLGeocoder 兜底）
final class GeocodeTool: AITool {
    let name = "geocode"
    let displayName = String(localized: "地址解析")
    let category: ToolCategory = .map
    /// 纯读 + 网络查询，无共享可变状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
    let description = "将地址文本解析为经纬度坐标。可附加 city 收窄范围，返回最多 5 条匹配结果。"

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "address": ["type": "string", "description": "要解析的地址文本，如「北京市朝阳区三里屯」"],
                "city": ["type": "string", "description": "可选，城市名，用于收窄解析范围"]
            ],
            "required": ["address"]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let address = try requiredString(arguments, "address").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            throw ToolExecutionError("address 不能为空")
        }
        let city = optionalStringArg(arguments, "city")

        let result = try await MapDispatch.geocode(address: address, city: city)
        let results = result.places.prefix(5).map(placeJSON)
        return AIToolExecutor.encodeJSON(["ok": true, "source": result.source.rawValue, "results": results])
    }
}

// MARK: - 2. search_places

/// 关键词搜索地点（高德 POI 优先，MKLocalSearch 兜底）
final class SearchPlacesTool: AITool {
    let name = "search_places"
    let displayName = String(localized: "地点搜索")
    let category: ToolCategory = .map
    /// 纯读 + 网络查询，无共享可变状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
    let description = "按关键词搜索地点（如咖啡馆、加油站）。可提供城市名或中心坐标限定范围，返回最多 10 条结果。"

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "keyword": ["type": "string", "description": "搜索关键词，如「咖啡馆」「加油站」"],
                "city": ["type": "string", "description": "可选，城市名，仅在未提供 center 时生效"],
                "center": [
                    "type": "object",
                    "description": "可选，搜索中心坐标",
                    "properties": [
                        "lat": ["type": "number"],
                        "lng": ["type": "number"]
                    ],
                    "required": ["lat", "lng"]
                ],
                "radiusMeters": ["type": "number", "description": "可选，搜索半径（米），默认 5000，仅在提供 center 时生效"]
            ],
            "required": ["keyword"]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let keyword = try requiredString(arguments, "keyword").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            throw ToolExecutionError("keyword 不能为空")
        }
        let center = try optionalCoordinate(arguments, "center")
        let radius = optionalNumber(arguments["radiusMeters"])
        let city = optionalStringArg(arguments, "city")

        let result = try await MapDispatch.searchPlaces(
            keyword: keyword,
            city: city,
            center: center,
            radiusMeters: radius
        )
        let results = result.places.prefix(10).map(placeJSON)
        return AIToolExecutor.encodeJSON(["ok": true, "source": result.source.rawValue, "results": results])
    }
}

// MARK: - 3. plan_route

/// 路线规划：步行 / 驾车走「高德优先 + MKDirections 兜底」，公交仅高德提供
final class PlanRouteTool: AITool {
    let name = "plan_route"
    let displayName = String(localized: "路线规划")
    let category: ToolCategory = .map
    /// 纯读 + 网络查询，无共享可变状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
    let description = "规划两点之间的路线，支持步行（walking）、驾车（driving）与公交（transit）。返回距离、时长、导航步骤，并附带地图卡片。公交路线需配置高德 API Key。"

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "origin": [
                    "type": "object",
                    "description": "起点坐标",
                    "properties": [
                        "lat": ["type": "number"],
                        "lng": ["type": "number"]
                    ],
                    "required": ["lat", "lng"]
                ],
                "destination": [
                    "type": "object",
                    "description": "终点坐标",
                    "properties": [
                        "lat": ["type": "number"],
                        "lng": ["type": "number"]
                    ],
                    "required": ["lat", "lng"]
                ],
                "mode": [
                    "type": "string",
                    "enum": ["walking", "driving", "transit"],
                    "description": "出行方式，默认 driving；transit 公交需配置高德 API Key"
                ]
            ],
            "required": ["origin", "destination"]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let origin = try requiredCoordinate(arguments, "origin")
        let destination = try requiredCoordinate(arguments, "destination")

        let modeRaw = (optionalStringArg(arguments, "mode") ?? MapRouteMode.driving.rawValue).lowercased()
        guard let mode = MapRouteMode(rawValue: modeRaw) else {
            throw ToolExecutionError("mode 参数无效：\(modeRaw)，可选 walking/driving/transit")
        }

        let result = try await MapDispatch.planRoute(origin: origin, destination: destination, mode: mode)
        let route = result.route

        let steps: [[String: Any]] = route.steps.map { step in
            ["instruction": step.instruction, "distanceMeters": step.distanceMeters]
        }
        var originMarker = coordinateJSON(origin)
        originMarker["title"] = String(localized: "起点")
        var destinationMarker = coordinateJSON(destination)
        destinationMarker["title"] = String(localized: "终点")
        let markers: [[String: Any]] = [originMarker, destinationMarker]
        let card: [String: Any] = [
            "type": "map",
            "data": [
                "title": String(localized: "\(modeDisplayName(mode))路线 · \(formatDistance(route.distanceMeters)) · 约 \(formatDuration(route.durationSeconds))"),
                "markers": markers,
                "route": [
                    "points": route.points.map(coordinateJSON),
                    "mode": mode.rawValue
                ]
            ]
        ]

        return AIToolExecutor.encodeJSON([
            "ok": true,
            "source": result.source.rawValue,
            "distanceMeters": route.distanceMeters,
            "durationSeconds": route.durationSeconds,
            "steps": steps,
            "card": card
        ])
    }
}

// MARK: - 4. show_map

/// 直接渲染地图卡片（标记点 / 折线 / 中心点任选）
final class ShowMapTool: AITool {
    let name = "show_map"
    let displayName = String(localized: "展示地图")
    let category: ToolCategory = .map
    /// 纯读展示，无网络与共享状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
    let description = "在对话中展示一张地图卡片，可标注标记点或绘制路线折线。center、markers、route 至少提供一项。"

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "可选，卡片标题"],
                "subtitle": ["type": "string", "description": "可选，卡片副标题"],
                "center": [
                    "type": "object",
                    "description": "可选，地图中心坐标",
                    "properties": [
                        "lat": ["type": "number"],
                        "lng": ["type": "number"]
                    ],
                    "required": ["lat", "lng"]
                ],
                "spanMeters": ["type": "number", "description": "可选，显示范围（米）"],
                "markers": [
                    "type": "array",
                    "description": "可选，标记点列表",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "subtitle": ["type": "string"],
                            "lat": ["type": "number"],
                            "lng": ["type": "number"]
                        ],
                        "required": ["lat", "lng"]
                    ]
                ],
                "route": [
                    "type": "object",
                    "description": "可选，路线折线",
                    "properties": [
                        "points": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "lat": ["type": "number"],
                                    "lng": ["type": "number"]
                                ],
                                "required": ["lat", "lng"]
                            ]
                        ],
                        "mode": ["type": "string", "description": "可选，出行方式标识"]
                    ],
                    "required": ["points"]
                ]
            ],
            "required": [String]()
        ]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let title = optionalStringArg(arguments, "title")
        let subtitle = optionalStringArg(arguments, "subtitle")
        let center = try optionalCoordinate(arguments, "center")
        let span = optionalNumber(arguments["spanMeters"])
        let markers = try parseMarkers(arguments["markers"])
        let route = try parseRoute(arguments["route"])

        guard center != nil || !markers.isEmpty || !(route?.points.isEmpty ?? true) else {
            throw ToolExecutionError("必须至少提供 center、markers 或 route 之一")
        }

        var data: [String: Any] = [:]
        if let title { data["title"] = title }
        if let subtitle { data["subtitle"] = subtitle }
        if let center { data["center"] = coordinateJSON(center) }
        if let span { data["spanMeters"] = span }
        if !markers.isEmpty {
            data["markers"] = markers
        }
        if let route {
            var routeJSON: [String: Any] = ["points": route.points.map(coordinateJSON)]
            if let mode = route.mode, !mode.isEmpty { routeJSON["mode"] = mode }
            data["route"] = routeJSON
        }

        return AIToolExecutor.encodeJSON([
            "ok": true,
            "card": ["type": "map", "data": data]
        ])
    }

    // MARK: 参数解析

    /// 解析 markers 数组为卡片可用的 JSON 对象
    private func parseMarkers(_ raw: Any?) throws -> [[String: Any]] {
        guard let raw, !(raw is NSNull) else { return [] }
        guard let list = raw as? [[String: Any]] else {
            throw ToolExecutionError("参数 markers 类型错误，应为对象数组")
        }
        return try list.map { item in
            let coordinate = try coordinate(from: item, key: "markers[]")
            var marker: [String: Any] = coordinateJSON(coordinate)
            if let title = stringValue(item["title"]), !title.isEmpty { marker["title"] = title }
            if let subtitle = stringValue(item["subtitle"]), !subtitle.isEmpty { marker["subtitle"] = subtitle }
            return marker
        }
    }

    /// 解析 route 对象
    private func parseRoute(_ raw: Any?) throws -> MapRouteInput? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let dict = raw as? [String: Any] else {
            throw ToolExecutionError("参数 route 类型错误，应为对象")
        }
        guard let pointsRaw = dict["points"], !(pointsRaw is NSNull) else {
            throw ToolExecutionError("route.points 不能为空")
        }
        guard let list = pointsRaw as? [[String: Any]] else {
            throw ToolExecutionError("route.points 类型错误，应为坐标对象数组")
        }
        let points = try list.map { try coordinate(from: $0, key: "route.points[]") }
        return MapRouteInput(points: points, mode: stringValue(dict["mode"]))
    }

    /// show_map 的 route 参数模型
    private struct MapRouteInput {
        let points: [CLLocationCoordinate2D]
        let mode: String?
    }
}