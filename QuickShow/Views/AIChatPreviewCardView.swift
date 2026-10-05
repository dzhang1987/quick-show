import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// MARK: - AI 对话文件预览卡片
//
// 工具结果携带 card 信封（type == "preview_file"）时，由 RichCardRegistry 分派到本卡片：
// 内嵌系统 QuickLook 的 QLPreviewView，原生渲染图片 / PDF / 文本 / 音视频等任意可预览文件，
// 无需为每种格式手写渲染器。
//
// 视觉原则（与 AIChatMapCardView 机械一致）：
// - 卡片容器 = 助手气泡同款（chatAssistantBubble 底 + cardStroke 0.5pt 描边 + Radius.groupCard），
//   宽度 maxWidth .infinity，与正文 / 工具卡共用同一可用宽度
// - 结构两段：头部信息条（文件名 + 类型 kind，Theme 设计令牌）→ 预览区（文档族
//   文本 / PDF 520pt / 媒体类 300pt，按 kind 自适应；insetCard 圆角裁剪 + chatStrokeStrong 0.5pt 描边，与地图卡同语言）
// - 本文件严禁新增设计令牌，全部走 DesignTokens 既有值

// MARK: - 数据契约

/// 文件预览卡片 payload：与工具层 JSON 契约精确对齐（camelCase 原文键，JSONDecoder 默认策略直解）。
struct PreviewCardPayload: Codable, Equatable {
    var path: String    // 本地文件绝对路径
    var kind: String    // 展示用类型名（typeIdentifier 或扩展名小写）

    /// 文件名：路径最后一段。
    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - 卡片提供者（RichCardProvider 契约）

enum PreviewCardProvider: RichCardProvider {
    static let cardType = "preview_file"

    /// payload Data → 卡片视图；解码失败返回可读的中文错误占位小卡，绝不抛出。
    static func makeView(payload: Data) -> AnyView {
        do {
            let model = try JSONDecoder().decode(PreviewCardPayload.self, from: payload)
            return AnyView(AIChatPreviewCardView(payload: model))
        } catch {
            return AnyView(PreviewCardErrorView(detail: error.localizedDescription))
        }
    }
}

// MARK: - 文件预览卡片主视图

struct AIChatPreviewCardView: View {
    let payload: PreviewCardPayload

    /// 文档族（文本 / 表格 / PDF）预览区高度：300pt 下长文档看不到完整语义单元
    /// （.md 表格约 5.5 行且末行截断、PDF 页底被裁），520pt 约一屏可读。
    private static let documentPreviewHeight: CGFloat = 520
    /// 媒体类（图片 / 音视频 / 未知类型）预览区高度：内容按比例自适应，300pt 已足够。
    private static let mediaPreviewHeight: CGFloat = 300

    /// UTI 判不出文本族时的扩展名兜底集合（不含点、小写比较）。
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "json", "log", "xml", "yaml", "yml",
        "html", "css", "js", "ts", "swift", "py", "sh", "c", "h", "cpp",
        "java", "rs", "go", "rb", "sql"
    ]

    /// 预览区高度：按类型自适应。
    /// 优先走系统 UTI 体系（kind 多为 typeIdentifier，如 net.daringfireball.markdown）：
    /// `conforms(to: .text)` 覆盖 plain-text / source-code / markdown / json / csv 等文本族，
    /// `conforms(to: .pdf)` 覆盖 PDF（同为竖版文档，矮了页底被裁）；
    /// UTI 构造失败或 kind 为扩展名回退值时，用扩展名集合兜底。
    private var previewHeight: CGFloat {
        if let type = UTType(payload.kind),
           type.conforms(to: .text) || type.conforms(to: .pdf) {
            return Self.documentPreviewHeight
        }
        let ext = payload.kind.lowercased()
        if !ext.isEmpty, Self.textExtensions.contains(ext) || ext == "pdf" {
            return Self.documentPreviewHeight
        }
        return Self.mediaPreviewHeight
    }

    /// 渲染期文件是否仍存在：历史回放时文件可能已被清理，此处仅做只读探测。
    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: payload.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
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

    // MARK: 头部信息条（文件名 + 类型 kind）

    private var header: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(Theme.Typography.text(Theme.Typography.iconLarge))
                .foregroundColor(Theme.Colors.accent)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(payload.fileName)
                    .font(Theme.Typography.text(Theme.Typography.callout, .semibold))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(payload.kind)
                    .font(Theme.Typography.text(Theme.Typography.footnote))
                    .foregroundColor(Theme.Colors.contentTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.lg)
    }

    // MARK: 预览区

    @ViewBuilder
    private var content: some View {
        if fileExists {
            QuickLookPreviewContainer(
                url: URL(fileURLWithPath: payload.path),
                title: payload.fileName
            )
            .frame(height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
            )
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.lg)
        } else {
            missingState
        }
    }

    // MARK: 文件缺失态（渲染期文件已被清理 / 移走）

    private var missingState: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "doc.questionmark")
                .font(Theme.Typography.text(16))
                .foregroundColor(Theme.Colors.idleText)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("文件不存在或已被移动")
                    .font(Theme.Typography.text(Theme.Typography.footnote))
                    .foregroundColor(Theme.Colors.contentTertiary)
                Text(payload.path)
                    .font(Theme.Typography.mono(Theme.Typography.tiny))
                    .foregroundColor(Theme.Colors.idleText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.xl)
    }
}

// MARK: - 解码失败占位小卡

/// payload 解码失败时的可读错误占位（与地图卡错误态同一语言），卡片容器保持一致。
private struct PreviewCardErrorView: View {
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "xmark.octagon")
                .font(Theme.Typography.text(10, .semibold))
                .foregroundColor(Theme.Colors.statusWarning)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("文件预览数据无法解析")
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

// MARK: - 预览项（QLPreviewItem：为 QLPreviewView 提供 URL 与自定义标题）

/// QLPreviewItem 最小实现：NSURL 本身已实现该协议，但标题固定取末段路径；
/// 本 wrapper 让卡片头部标题与 QuickLook 内部标题显式一致。
private final class PreviewFileItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String?) {
        self.previewItemURL = url
        self.previewItemTitle = title
    }
}

// MARK: - QuickLook 预览容器（NSViewRepresentable 包装 QLPreviewView）

/// 原生 QLPreviewView 包装：由系统 QuickLook 生成器渲染任意可预览文件内容。
/// 刷新策略：URL / 标题指纹未变时 updateNSView 完全不动预览项——
/// 父视图刷新 / 历史回放不得重置用户已有的缩放与滚动位置。
private struct QuickLookPreviewContainer: NSViewRepresentable {
    let url: URL
    let title: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    // QLPreviewView(frame:style:) 为可失败构造（ObjC 未标注 nonnull 的 id 返回值），
    // 故 NSViewRepresentable 以 NSView 为承载类型；构造失败时退回空白 NSView，绝不崩。
    func makeNSView(context: Context) -> NSView {
        // .normal 为默认大尺寸样式（无边框内嵌用法，视觉交给外层卡片容器）
        guard let previewView = QLPreviewView(frame: .zero, style: .normal) else {
            return NSView()
        }
        previewView.autostarts = true
        // 清除 QuickLook 自带背景，令预览内容融入卡片容器（描边与圆角由 SwiftUI 外层负责）
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.clear.cgColor
        apply(to: previewView, coordinator: context.coordinator)
        return previewView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let previewView = nsView as? QLPreviewView else { return }
        apply(to: previewView, coordinator: context.coordinator)
    }

    /// 释放期清空预览项，杜绝 QuickLook 后台生成器持有已销毁视图。
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        (nsView as? QLPreviewView)?.previewItem = nil
    }

    /// 仅在指纹变化时重建预览项并刷新，避免流式刷新反复重载。
    private func apply(to previewView: QLPreviewView, coordinator: Coordinator) {
        guard coordinator.appliedURL != url || coordinator.appliedTitle != title else { return }
        previewView.previewItem = PreviewFileItem(url: url, title: title)
        previewView.refreshPreviewItem()
        coordinator.appliedURL = url
        coordinator.appliedTitle = title
    }

    final class Coordinator {
        /// 已应用的预览项指纹：updateNSView 据此做 diff。
        var appliedURL: URL?
        var appliedTitle: String?
    }
}