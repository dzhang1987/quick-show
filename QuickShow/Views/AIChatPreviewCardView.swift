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
// 视觉原则（与 MarkdownCodeBlock / AIChatMapCardView 质感同源）：
// - 卡片容器 = 通透微质感底（surfaceTrack 底 + chatStrokeStrong 0.5pt 描边 + Radius.groupCard），
//   宽度 maxWidth .infinity，与正文 / 工具卡共用同一可用宽度，彻底消灭不透明死白底，融入毛玻璃窗体
// - 结构两段：头部信息条（文件名 + 类型规格，Theme 设计令牌）→ 预览区（文档族
//   文本 / PDF 460pt / 媒体类按比例自适应；chatStrokeStrong 0.5pt 分割线）
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
    @State private var copied = false
    @State private var isHovered = false
    @State private var isZoomed = false
    @State private var isContentHovered = false
    @State private var loadedImage: NSImage?

    /// 文档族（文本 / 表格 / PDF）预览区高度
    private static let documentPreviewHeight: CGFloat = 460

    /// UTI 判不出文本族时的扩展名兜底集合（不含点、小写比较）。
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "json", "log", "xml", "yaml", "yml",
        "html", "css", "js", "ts", "swift", "py", "sh", "c", "h", "cpp",
        "java", "rs", "go", "rb", "sql"
    ]

    /// 是否为本地图片（支持常见位图与矢量图扩展名，或 UTI conforms to public.image）。
    private var isImageFile: Bool {
        let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "avif", "webp", "heic", "gif", "tiff", "bmp", "ico", "svg"
        ]
        let ext = URL(fileURLWithPath: payload.path).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return true }
        if let type = UTType(payload.kind), type.conforms(to: .image) { return true }
        return false
    }

    /// 人性化文件类型描述（告别裸露的 public.png / public.avif 底层代号）。
    private var humanReadableKind: String {
        let ext = URL(fileURLWithPath: payload.path).pathExtension.uppercased()
        if !ext.isEmpty {
            return ext
        }
        if let type = UTType(payload.kind) {
            return type.localizedDescription ?? type.preferredFilenameExtension?.uppercased() ?? "文件"
        }
        return "文件"
    }

    /// 规格元数据，如 "PNG · 1920 × 1080 · 2.4 MB" 或 "PDF · 3.2 MB"
    private var fileMetaText: String {
        var parts: [String] = [humanReadableKind]

        // 若为图片，尝试提取分辨率
        if isImageFile, let imgRep = NSImageRep(contentsOfFile: payload.path) {
            let pxWidth = imgRep.pixelsWide > 0 ? imgRep.pixelsWide : Int(imgRep.size.width)
            let pxHeight = imgRep.pixelsHigh > 0 ? imgRep.pixelsHigh : Int(imgRep.size.height)
            if pxWidth > 0 && pxHeight > 0 {
                parts.append("\(pxWidth) × \(pxHeight)")
            }
        }

        // 文件大小
        if let attributes = try? FileManager.default.attributesOfItem(atPath: payload.path),
           let fileSize = attributes[.size] as? Int64, fileSize > 0 {
            let formattedSize = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            parts.append(formattedSize)
        }

        return parts.joined(separator: " · ")
    }

    /// Header 左侧小图标
    private var fileIconName: String {
        if isImageFile { return "photo" }
        if let type = UTType(payload.kind), type.conforms(to: .pdf) || payload.path.lowercased().hasSuffix(".pdf") {
            return "doc.text.fill"
        }
        return "doc.text"
    }

    /// 预览区高度：按类型自适应。
    private var previewHeight: CGFloat {
        if let type = UTType(payload.kind),
           type.conforms(to: .text) || type.conforms(to: .pdf) {
            return Self.documentPreviewHeight
        }
        let ext = payload.kind.lowercased()
        if !ext.isEmpty, Self.textExtensions.contains(ext) || ext == "pdf" {
            return Self.documentPreviewHeight
        }
        return Self.documentPreviewHeight
    }

    /// 渲染期文件是否仍存在：历史回放时文件可能已被清理，此处仅做只读探测。
    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: payload.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if fileExists {
                Rectangle()
                    .fill(Theme.Colors.chatStrokeStrong)
                    .frame(height: 0.5)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .fill(Theme.Colors.surfaceTrack)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .sheet(isPresented: $isZoomed) {
            UniversalFileZoomSheet(
                payload: payload,
                image: loadedImage,
                isImage: isImageFile,
                onDismiss: { isZoomed = false }
            )
        }
    }

    // MARK: 头部信息条（文件名 + 类型规格 + 动作胶囊）

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: fileIconName)
                .font(Theme.Typography.text(13.5, .medium))
                .foregroundColor(Theme.Colors.accent)
                .padding(.top, 1.5)

            VStack(alignment: .leading, spacing: 2) {
                Text(payload.fileName)
                    .font(Theme.Typography.text(12.5, .medium))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(fileMetaText)
                    .font(Theme.Typography.text(10.5, .regular))
                    .foregroundColor(Theme.Colors.contentTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.md)

            HStack(spacing: Theme.Spacing.xs) {
                revealButton
                copyButton
            }
            .opacity((isHovered || copied) ? 1 : 0)
            .allowsHitTesting(isHovered || copied)
            .accessibilityHidden(!isHovered && !copied)
        }
        .padding(.horizontal, Theme.Layout.chatCodeBlockPaddingH)
        .padding(.vertical, 9)
    }

    private var revealButton: some View {
        Button(action: revealInFinder) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "folder")
                    .font(Theme.Typography.text(9.5, .medium))
                Text(String(localized: "在访达中显示"))
                    .font(Theme.Typography.text(9.5, .medium))
            }
            .foregroundColor(Theme.Colors.contentTertiary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.surfaceButton)
            )
        }
        .buttonStyle(.plain)
        .help(String(localized: "在访达中定位此文件"))
    }

    private var copyButton: some View {
        Button(action: copyPath) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .font(Theme.Typography.text(9.5, .medium))
                Text(copied ? String(localized: "已复制") : String(localized: "复制路径"))
                    .font(Theme.Typography.text(9.5, .medium))
            }
            .foregroundColor(copied ? Theme.Colors.accent : Theme.Colors.contentTertiary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.surfaceButton)
            )
        }
        .buttonStyle(.plain)
        .help(payload.path)
    }

    private func revealInFinder() {
        let fileURL = URL(fileURLWithPath: payload.path)
        if FileManager.default.fileExists(atPath: payload.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            let dirURL = fileURL.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dirURL.path) {
                NSWorkspace.shared.open(dirURL)
            }
        }
    }

    private func copyPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload.path, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.transientFeedbackDuration) {
            copied = false
        }
    }

    // MARK: 预览区

    @ViewBuilder
    private var content: some View {
        if fileExists {
            ZStack(alignment: .bottomTrailing) {
                if isImageFile {
                    imageContent
                } else {
                    documentContent
                }

                if isContentHovered {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(Theme.Typography.text(9.5, .medium))
                        Text(String(localized: "点击放大"))
                            .font(Theme.Typography.text(9.5, .medium))
                    }
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color.black.opacity(0.65))
                    )
                    .padding(Theme.Spacing.md)
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isContentHovered = hovering
                }
            }
            .onTapGesture {
                isZoomed = true
            }
        } else {
            missingState
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let img = loadedImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 520)
        } else {
            RoundedRectangle(cornerRadius: 0)
                .fill(Theme.Colors.surfaceTrack)
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .overlay(ProgressView().controlSize(.small))
                .task {
                    await loadImageAsync()
                }
        }
    }

    @ViewBuilder
    private var documentContent: some View {
        QuickLookPreviewContainer(
            url: URL(fileURLWithPath: payload.path),
            title: payload.fileName
        )
        .frame(height: previewHeight)
    }

    @MainActor
    private func loadImageAsync() async {
        guard loadedImage == nil else { return }
        let path = payload.path
        let img = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOfFile: path)
        }.value
        if let img {
            self.loadedImage = img
        }
    }

    // MARK: 文件缺失态（渲染期文件已被清理 / 移走）

    private var missingState: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "doc.questionmark")
                .font(Theme.Typography.text(16))
                .foregroundColor(Theme.Colors.idleText)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(String(localized: "文件不存在或已被移动"))
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
        .padding(.horizontal, Theme.Layout.chatCodeBlockPaddingH)
        .padding(.vertical, Theme.Spacing.xl)
    }
}

// MARK: - 全文件通用沉浸式放大预览 Sheet

struct UniversalFileZoomSheet: View {
    let payload: PreviewCardPayload
    let image: NSImage?
    let isImage: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏控制条
            topBar
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.md)
                .background(Theme.Colors.chatNavFloatFill)

            Rectangle()
                .fill(Theme.Colors.chatStrokeStrong)
                .frame(height: 0.5)

            // 主展示区
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isImage ? Color.black.opacity(0.92) : Color(.windowBackgroundColor))
        }
        .frame(minWidth: 720, idealWidth: 860, maxWidth: 1280, minHeight: 520, idealHeight: 640, maxHeight: 960)
    }

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: isImage ? "photo" : "doc.text")
                .font(Theme.Typography.text(14, .medium))
                .foregroundColor(Theme.Colors.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(payload.fileName)
                    .font(Theme.Typography.text(13, .semibold))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: Theme.Spacing.md) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: payload.path))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(Theme.Typography.text(10, .medium))
                        Text(String(localized: "系统应用打开"))
                            .font(Theme.Typography.text(11, .medium))
                    }
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous).fill(Theme.Colors.surfaceButton))
                }
                .buttonStyle(.plain)
                .help(String(localized: "用系统默认应用打开该文件"))

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Typography.text(16))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(String(localized: "关闭 (ESC)"))
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if isImage, let img = image ?? NSImage(contentsOfFile: payload.path) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(Theme.Spacing.xl)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        } else {
            QuickLookPreviewContainer(
                url: URL(fileURLWithPath: payload.path),
                title: payload.fileName
            )
        }
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
                .fill(Theme.Colors.surfaceTrack)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
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