import AppKit
import MapKit
import SwiftUI

// MARK: - AI 对话地图卡片
//
// 工具结果携带 card 信封（type == "map"）时，由 RichCardRegistry 分派到本卡片：
// 内嵌原生 MKMapView，可拖动 / 滚轮缩放，标注点走系统 callout，路线折线描边用主题强调色。
//
// 视觉原则（与 AIToolCallCardView 同族）：
// - 卡片容器 = 助手气泡同款（chatAssistantBubble 底 + cardStroke 0.5pt 描边 + Radius.groupCard），
//   宽度 maxWidth .infinity，与正文 / 工具卡共用同一可用宽度
// - 结构三段：头部（标题 + 副标题，无标题整体隐藏）→ 地图区（300pt，insetCard 圆角裁剪
//   + chatStrokeStrong 0.5pt 描边，与消息内图片缩略图同一语言）→ 0.5pt 分隔线 → 底部动作行
// - 底图明暗不做手动干预：跟随窗口 effectiveAppearance——App 的 NSApp.appearance 全局联动
//   机制会自动传导，macOS 13 默认 MKStandardMapConfiguration 底图即随外观翻转
// - 本文件严禁新增设计令牌，全部走 DesignTokens 既有值

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

// MARK: - 地图卡片主视图

struct AIChatMapCardView: View {
    let payload: MapCardPayload

    /// 复制坐标钮的轻反馈（对勾短暂停留后复位，与工具卡复制钮同节奏）。
    @State private var copied = false

    /// 地图区高度（280~320 档取中：一屏可读全貌，又不至于压垮消息流）。
    /// （fileprivate：同文件的 InteractiveMapView 视野逻辑需引用）
    fileprivate static let mapHeight: CGFloat = 300
    /// 包围盒自适应时四周留白（pt）。
    fileprivate static let fitPadding: CGFloat = 40
    /// 仅有中心点 / 单点时的默认视野跨度（米）：街区级。
    fileprivate static let defaultSpanMeters: Double = 1500

    private var hasHeader: Bool {
        guard let title = payload.title else { return false }
        return !title.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasHeader {
                header
            }
            if payload.isContentEmpty {
                emptyState
            } else {
                mapSection
                // 地图与动作行之间：与工具卡条目同款 0.5pt 细线
                Rectangle()
                    .fill(Theme.Colors.cardStroke)
                    .frame(height: Theme.Layout.dividerHeight)
                    .padding(.horizontal, Theme.Spacing.xxl)
                actionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .fill(Theme.Colors.chatAssistantBubble)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .stroke(Theme.Colors.cardStroke, lineWidth: 0.5)
        )
    }

    // MARK: 头部（无 title 整体隐藏）

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(payload.title ?? "")
                .font(Theme.Typography.text(Theme.Typography.callout, .semibold))
                .foregroundColor(Theme.Colors.contentPrimary)
            if let subtitle = payload.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Theme.Typography.text(Theme.Typography.footnote))
                    .foregroundColor(Theme.Colors.contentTertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.lg)
    }

    // MARK: 地图区

    private var mapSection: some View {
        InteractiveMapView(payload: payload)
            .frame(height: Self.mapHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
            )
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.top, hasHeader ? 0 : Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.lg)
    }

    // MARK: 底部动作行

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.lg) {
            MapCardActionButton(
                systemName: "map",
                title: "在地图中打开",
                tint: Theme.Colors.accent,
                help: "在系统地图 App 中查看"
            ) {
                openInMaps()
            }
            MapCardActionButton(
                systemName: copied ? "checkmark" : "doc.on.doc",
                title: copied ? "已复制" : "复制坐标",
                tint: copied ? Theme.Colors.accent : Theme.Colors.contentTertiary,
                help: "复制中心点经纬度"
            ) {
                copyCoordinate()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.xl)
    }

    // MARK: 空态（无中心 / 标注 / 路线）

    private var emptyState: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "map")
                .font(Theme.Typography.text(16))
                .foregroundColor(Theme.Colors.idleText)
            Text("没有可展示的地图内容")
                .font(Theme.Typography.text(Theme.Typography.footnote))
                .foregroundColor(Theme.Colors.contentTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.top, hasHeader ? 0 : Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.xl)
    }

    // MARK: 动作

    /// 组装 MKMapItem 跳系统地图：有标注时全部带上（名称回填），否则只带中心点。
    private func openInMaps() {
        let items: [MKMapItem]
        let markers = payload.resolvedMarkers
        if !markers.isEmpty {
            items = markers.map { marker in
                let item = MKMapItem(placemark: MKPlacemark(coordinate: marker.coordinate))
                item.name = marker.title ?? marker.subtitle ?? payload.title
                return item
            }
        } else if let coordinate = payload.actionCoordinate {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            item.name = payload.title ?? payload.subtitle
            items = [item]
        } else {
            return
        }
        _ = MKMapItem.openMaps(with: items, launchOptions: nil)
    }

    /// 复制中心坐标（lat, lng 六位小数，与系统地图粘贴格式兼容）。
    private func copyCoordinate() {
        guard let coordinate = payload.actionCoordinate else { return }
        let text = String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - 动作行按钮（与工具卡复制钮同一语言：surfaceButton 底 + keyCap 圆角 + 9.5pt）

private struct MapCardActionButton: View {
    let systemName: String
    let title: String
    var tint: Color = Theme.Colors.contentTertiary
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: systemName)
                    .font(Theme.Typography.text(Theme.Typography.tiny, .medium))
                Text(title)
                    .font(Theme.Typography.text(Theme.Typography.tiny, .medium))
            }
            .foregroundColor(tint)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.surfaceButton)
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 解码失败占位小卡

/// payload 解码失败时的可读错误占位（与工具卡失败摘要同一语言），卡片容器保持一致。
private struct MapCardErrorView: View {
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "xmark.octagon")
                .font(Theme.Typography.text(10, .semibold))
                .foregroundColor(Theme.Colors.statusWarning)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("地图数据无法解析")
                    .font(Theme.Typography.text(Theme.Typography.footnote, .medium))
                    .foregroundColor(Theme.Colors.contentPrimary)
                Text(detail)
                    .font(Theme.Typography.mono(Theme.Typography.tiny))
                    .foregroundColor(Theme.Colors.contentTertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .fill(Theme.Colors.chatAssistantBubble)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .stroke(Theme.Colors.cardStroke, lineWidth: 0.5)
        )
    }
}

// MARK: - 交互式地图（NSViewRepresentable 包装 MKMapView）

/// 原生 MKMapView 包装：可拖动 / 滚轮缩放；标注走系统 callout；路线走强调色折线。
/// 刷新策略：内容指纹（payload 整体 Equatable）未变时 updateNSView 完全不动地图——
/// 用户手动拖过的视角必须保留，父视图刷新 / 历史回放不得重置平移缩放。
private struct InteractiveMapView: NSViewRepresentable {
    let payload: MapCardPayload

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
            let span = (spanMeters ?? 0) > 0 ? spanMeters! : AIChatMapCardView.defaultSpanMeters
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
                    latitudinalMeters: AIChatMapCardView.defaultSpanMeters,
                    longitudinalMeters: AIChatMapCardView.defaultSpanMeters
                ),
                animated: false
            )
            return
        }
        let boundingRect = contentPoints.reduce(MKMapRect.null) { rect, coordinate in
            rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        let padding = AIChatMapCardView.fitPadding
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
