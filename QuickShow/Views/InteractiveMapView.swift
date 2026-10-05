import AppKit
import MapKit
import SwiftUI

// MARK: - 交互式地图（NSViewRepresentable 包装 MKMapView）

/// 原生 MKMapView 包装：可拖动 / 滚轮缩放；标注走系统 callout；路线走强调色折线。
/// 刷新策略：内容指纹（payload 整体 Equatable）未变时 updateNSView 完全不动地图——
/// 用户手动拖过的视角必须保留，父视图刷新 / 历史回放不得重置平移缩放。
struct InteractiveMapView: NSViewRepresentable {
    let payload: MapCardPayload

    /// 包围盒自适应时四周留白（pt）。
    private static let fitPadding: CGFloat = 40
    /// 仅有中心点 / 单点时的默认视野跨度（米）：街区级。
    private static let defaultSpanMeters: Double = 1500

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        // 平面阅读：小卡片禁倾斜 / 旋转（禁旋转后罗盘无意义，一并关闭）
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.showsCompass = false
        // 交互：拖动 + 滚轮缩放（AppKit 手势链原生顺滑）
        mapView.isScrollEnabled = true
        mapView.isZoomEnabled = true
        // 注册标注视图类：macOS 上 dequeueReusableAnnotationView(withIdentifier:for:)
        // 必须先注册对应类，否则首次显示标注（区域变化触发 viewFor 回调）即抛
        // NSInvalidArgumentException 直接崩溃（已由隔离 harness 复现定位）
        mapView.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: Coordinator.markerIdentifier
        )
        // 底图：默认 MKStandardMapConfiguration，明暗跟随窗口 effectiveAppearance
        // （NSApp.appearance 全局切换自动传导，无需手动干预 appearance）
        applyContent(to: mapView, coordinator: context.coordinator)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        guard context.coordinator.appliedPayload != payload else { return }
        applyContent(to: mapView, coordinator: context.coordinator)
    }

    /// 释放期摘掉 delegate，杜绝悬垂回调。
    static func dismantleNSView(_ nsView: MKMapView, coordinator: Coordinator) {
        nsView.delegate = nil
    }

    // MARK: 内容应用（标注 + 路线 + 视野）

    private func applyContent(to mapView: MKMapView, coordinator: Coordinator) {
        mapView.removeAnnotations(mapView.annotations)
        mapView.removeOverlays(mapView.overlays)

        let markers = payload.resolvedMarkers
        let annotations = markers.map { marker -> MKPointAnnotation in
            let annotation = MKPointAnnotation()
            annotation.coordinate = marker.coordinate
            annotation.title = marker.title
            annotation.subtitle = marker.subtitle
            return annotation
        }
        mapView.addAnnotations(annotations)

        let routePoints = payload.resolvedRoutePoints
        if routePoints.count >= 2 {
            mapView.addOverlay(MKPolyline(coordinates: routePoints, count: routePoints.count))
        }

        Self.applyViewport(
            to: mapView,
            center: payload.center?.location,
            spanMeters: payload.spanMeters,
            contentPoints: markers.map(\.coordinate) + routePoints
        )
        coordinator.appliedPayload = payload
    }

    /// 视野决策：center + spanMeters 优先；缺 center 时按标注 + 路线包围盒自适应（四周留白）；
    /// 单点退化为默认跨度 region（包围盒零尺寸会放到最大缩放级别，不可读）。
    private static func applyViewport(
        to mapView: MKMapView,
        center: CLLocationCoordinate2D?,
        spanMeters: Double?,
        contentPoints: [CLLocationCoordinate2D]
    ) {
        if let center {
            let span = (spanMeters ?? 0) > 0 ? spanMeters! : Self.defaultSpanMeters
            mapView.setRegion(
                MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span),
                animated: false
            )
            return
        }
        guard let first = contentPoints.first else { return }
        guard contentPoints.count > 1 else {
            mapView.setRegion(
                MKCoordinateRegion(
                    center: first,
                    latitudinalMeters: Self.defaultSpanMeters,
                    longitudinalMeters: Self.defaultSpanMeters
                ),
                animated: false
            )
            return
        }
        let boundingRect = contentPoints.reduce(MKMapRect.null) { rect, coordinate in
            rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        let padding = Self.fitPadding
        mapView.setVisibleMapRect(
            boundingRect,
            edgePadding: NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding),
            animated: false
        )
    }

    // MARK: Coordinator（MKMapViewDelegate）

    final class Coordinator: NSObject, MKMapViewDelegate {
        /// 已应用的内容指纹：updateNSView 据此做 diff。
        var appliedPayload: MapCardPayload?

        /// 标注视图复用标识：makeNSView 的注册与 viewFor 的 dequeue 共用。
        static let markerIdentifier = "map-card-marker"

        /// 标注视图：系统 MKMarkerAnnotationView + callout（title / subtitle 直接可读），
        /// 颜色对齐主题强调色。
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is MKPointAnnotation else { return nil }
            let identifier = Self.markerIdentifier
            let markerView: MKMarkerAnnotationView
            if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: identifier, for: annotation)
                as? MKMarkerAnnotationView {
                markerView = reused
            } else {
                markerView = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            }
            markerView.canShowCallout = true
            // FIXME(待编译验证)：NSColor(Color) 对 dynamicProvider 色（amber accent）是否保留
            // 明暗动态性；若快照为固定值，明暗翻转时标注/路线色不跟随（视觉影响小，可接受）。
            markerView.markerTintColor = NSColor(Theme.Colors.accent)
            return markerView
        }

        /// 路线渲染：主题强调色描边，圆头圆接（折线转角不生硬）。
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = NSColor(Theme.Colors.accent)
            renderer.lineWidth = 3.5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
    }
}