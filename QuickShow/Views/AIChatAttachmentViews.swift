import AppKit
import SwiftUI

// MARK: - 图片附件解码与缓存

/// base64 JPEG → NSImage 的解码缓存（按附件 id 记忆，避免列表滚动/重渲染反复解码）。
/// 缩略图与原图共用一个缓存（key 带前缀区分）。
enum ChatImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    /// 缩略图（无缩略图时回退原图）。
    static func thumbnail(for attachment: ChatImageAttachment) -> NSImage? {
        if let thumb = attachment.thumbnailBase64JPEG {
            return image(key: "thumb-\(attachment.id.uuidString)", base64: thumb)
        }
        return fullImage(for: attachment)
    }

    /// 原图（点击放大用）。
    static func fullImage(for attachment: ChatImageAttachment) -> NSImage? {
        image(key: "full-\(attachment.id.uuidString)", base64: attachment.base64JPEG)
    }

    private static func image(key: String, base64: String) -> NSImage? {
        let nsKey = key as NSString
        if let cached = cache.object(forKey: nsKey) { return cached }
        guard let data = Data(base64Encoded: base64), let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: nsKey)
        return image
    }
}

// MARK: - 粘贴板图片提取（粘贴 / 拖入共用）

/// 从粘贴板提取图片（截图等位图数据 + Finder 拷贝的图片文件 URL），供 ⌘V 与拖放共用。
enum PasteboardImageExtractor {
    /// 粘贴板中是否含可用图片（用于 ⊕ 菜单项的可用态）。
    static func containsImage(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        return imageFileURLs(from: pasteboard).isEmpty == false
    }

    /// 提取全部图片（位图数据优先，其次图片文件 URL）。
    static func images(from pasteboard: NSPasteboard) -> [NSImage] {
        var result: [NSImage] = []
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            result.append(contentsOf: images.filter { $0.isValid })
        }
        for url in imageFileURLs(from: pasteboard) {
            if let image = NSImage(contentsOf: url) {
                result.append(image)
            }
        }
        return result
    }

    /// 粘贴板中的图片文件 URL（按 UTI  conformsTo public.image 过滤）。
    private static func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] ?? []
        return urls.filter { url in
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
                // 沙盒外读取失败时按扩展名兜底
                return ["png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp", "heic"]
                    .contains(url.pathExtension.lowercased())
            }
            return type.conforms(to: .image)
        }
    }
}

// MARK: - 输入区附件条（待发送）

/// 已选图片附件的缩略图胶囊横排：输入区上方，hover 显示移除钮。
struct ImageAttachmentStrip: View {
    let attachments: [ChatImageAttachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.lg) {
                ForEach(attachments) { attachment in
                    PendingAttachmentThumb(attachment: attachment, onRemove: { onRemove(attachment.id) })
                }
            }
            .padding(.vertical, Theme.Spacing.xxs) // 给 hover 移除钮留出血
        }
    }
}

/// 单个待发送附件：44pt 圆角缩略图 + hover 右上角移除钮。
private struct PendingAttachmentThumb: View {
    let attachment: ChatImageAttachment
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbImage
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                        .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
                )

            if hovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Typography.text(13))
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .background(Circle().fill(Color(.windowBackgroundColor)).padding(2))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .transition(.opacity)
                .help("移除该图片")
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
        .help(attachment.fileName ?? String(localized: "图片附件"))
    }

    @ViewBuilder
    private var thumbImage: some View {
        if let image = ChatImageCache.thumbnail(for: attachment) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(Theme.Colors.surfaceTrack)
                .overlay(
                    Image(systemName: "photo")
                        .font(Theme.Typography.text(14))
                        .foregroundColor(Theme.Colors.idleText)
                )
        }
    }
}

// MARK: - 消息气泡内缩略图

/// 用户消息气泡内的图片附件横排：点击回调交给外层（放大预览）。
struct MessageImageThumbs: View {
    let images: [ChatImageAttachment]
    let onTap: (ChatImageAttachment) -> Void

    var body: some View {
        // 单图放大展示，多图横排；超过气泡宽度自然换行
        FlowRow(spacing: Theme.Spacing.lg) {
            ForEach(images) { attachment in
                Button { onTap(attachment) } label: {
                    if let image = ChatImageCache.thumbnail(for: attachment) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(
                                width: thumbSize(for: attachment).width,
                                height: thumbSize(for: attachment).height
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                                    .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                            .fill(Theme.Colors.surfaceTrack)
                            .frame(width: 96, height: 72)
                    }
                }
                .buttonStyle(.plain)
                .help("点击放大查看")
            }
        }
    }

    /// 气泡内缩略图尺寸：按原图宽高比等比收缩到上限框内（最长边 160，最短边保底 56）。
    private func thumbSize(for attachment: ChatImageAttachment) -> CGSize {
        let maxSide: CGFloat = 160
        let minSide: CGFloat = 56
        let w = CGFloat(max(attachment.pixelWidth, 1))
        let h = CGFloat(max(attachment.pixelHeight, 1))
        let scale = min(maxSide / w, maxSide / h, 1.0)
        var size = CGSize(width: w * scale, height: h * scale)
        if size.width < minSide { size.width = minSide }
        if size.height < minSide { size.height = minSide }
        return size
    }
}

/// 极简流式行：子视图放不下时换行（仅用于附件横排，非通用组件）。
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 点击放大覆盖层（轻量自实现，替代 Quick Look）

/// 图片放大预览：铺满窗口的暗化遮罩 + 原图等比缩放，点击任意处或 ESC 关闭。
/// 说明：Quick Look 需要落盘临时文件 + QLPreviewPanel 数据源，对悬浮窗形态过重；
/// 本覆盖层零 IO、与大圆角玻璃气质一致，ESC 由 AIChatView 的按键监听先行消费。
struct ImageZoomOverlay: View {
    let attachment: ChatImageAttachment
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // 暗化遮罩（点击关闭）
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            if let image = ChatImageCache.fullImage(for: attachment) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(Theme.Spacing.panel)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                    .onTapGesture(perform: onDismiss)
            }
        }
        .transition(.opacity)
    }
}
