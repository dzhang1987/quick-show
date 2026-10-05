import CoreLocation
import Foundation
import SwiftUI

// MARK: - 数据契约

/// 地图卡片 payload：与工具层 JSON 契约精确对齐（camelCase 原文键，JSONDecoder 默认策略直解）。
/// 全部字段可缺省：center 缺省时按 markers + route 包围盒自适应；三者全缺 → 空态卡。
struct MapCardPayload: Codable, Equatable {
    var title: String?          // 卡片标题
    var subtitle: String?       // 副标题
    var center: MapCoordinate?  // 可选；缺省时按内容自适应
    var spanMeters: Double?     // 可选 region 跨度（米）
    var markers: [MapCardMarker]?   // 标注点
    var route: MapCardRoute?        // 可选路线折线
}

/// 经纬度（WGS84）。
struct MapCoordinate: Codable, Equatable {
    var lat: Double
    var lng: Double

    /// 转 CoreLocation 坐标；越界值返回 nil（非法坐标会让 MKMapView 断言，宁丢不崩）。
    var location: CLLocationCoordinate2D? {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }
}

/// 标注点（MKPointAnnotation，title / subtitle 进系统 callout）。
struct MapCardMarker: Codable, Equatable {
    var title: String?
    var subtitle: String?
    var lat: Double
    var lng: Double
}

/// 路线折线（mode 为工具层预留语义——walk / drive 等，当前渲染不区分样式）。
struct MapCardRoute: Codable, Equatable {
    var points: [MapCoordinate]
    var mode: String?
}

// MARK: payload 派生（坐标过滤与空态判定）

extension MapCardPayload {
    /// 过滤越界坐标后的有效标注。
    var resolvedMarkers: [(coordinate: CLLocationCoordinate2D, title: String?, subtitle: String?)] {
        (markers ?? []).compactMap { marker in
            guard let coordinate = MapCoordinate(lat: marker.lat, lng: marker.lng).location else { return nil }
            return (coordinate, marker.title, marker.subtitle)
        }
    }

    /// 过滤越界坐标后的有效路线点（保持原有顺序）。
    var resolvedRoutePoints: [CLLocationCoordinate2D] {
        (route?.points ?? []).compactMap { $0.location }
    }

    /// 空态判定：中心、标注、路线三者皆无可用内容。
    var isContentEmpty: Bool {
        center?.location == nil && resolvedMarkers.isEmpty && resolvedRoutePoints.isEmpty
    }

    /// 动作行目标点：中心 > 首个标注 > 路线首点。
    var actionCoordinate: CLLocationCoordinate2D? {
        center?.location ?? resolvedMarkers.first?.coordinate ?? resolvedRoutePoints.first
    }
}

// MARK: - 卡片提供者（RichCardProvider 契约）

enum MapCardProvider: RichCardProvider {
    static let cardType = "map"

    /// payload Data → 卡片视图；解码失败返回可读的中文错误占位小卡，绝不抛出。
    static func makeView(payload: Data) -> AnyView {
        do {
            let model = try JSONDecoder().decode(MapCardPayload.self, from: payload)
            return AnyView(AIChatMapCardView(payload: model))
        } catch {
            return AnyView(MapCardErrorView(detail: error.localizedDescription))
        }
    }
}