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

// MARK: - 地图卡片主视图

struct AIChatMapCardView: View {
    let payload: MapCardPayload

    /// 复制坐标钮的轻反馈（对勾短暂停留后复位，与工具卡复制钮同节奏）。
    @State private var copied = false

    /// 地图区高度（280~320 档取中：一屏可读全貌，又不至于压垮消息流）。
    private static let mapHeight: CGFloat = 300

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
                systemName: copied ? "checkmark" : "square.on.square",
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
        .qsHelp(help)
    }
}

// MARK: - 解码失败占位小卡

/// payload 解码失败时的可读错误占位（与工具卡失败摘要同一语言），卡片容器保持一致。
struct MapCardErrorView: View {
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