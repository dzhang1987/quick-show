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

/// 已选图片附件的缩略图胶囊横排：输入区上方，点击预览，hover 显示移除钮。
struct ImageAttachmentStrip: View {
    let attachments: [ChatImageAttachment]
    var onTap: ((ChatImageAttachment) -> Void)? = nil
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.lg) {
                ForEach(attachments) { attachment in
                    PendingAttachmentThumb(
                        attachment: attachment,
                        onTap: { onTap?(attachment) },
                        onRemove: { onRemove(attachment.id) }
                    )
                }
            }
            .padding(.vertical, Theme.Spacing.xxs) // 给 hover 移除钮留出血
        }
    }
}

/// 单个待发送附件：44pt 圆角缩略图 + 点击大图预览 + hover 右上角移除钮。
private struct PendingAttachmentThumb: View {
    let attachment: ChatImageAttachment
    var onTap: (() -> Void)? = nil
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                onTap?()
            } label: {
                thumbImage
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                            .stroke(
                                hovered ? Theme.Colors.accent.opacity(0.65) : Theme.Colors.chatStrokeStrong,
                                lineWidth: hovered ? 1 : 0.5
                            )
                    )
            }
            .buttonStyle(.plain)
            .help(attachment.fileName.map { "\($0) (点击预览)" } ?? String(localized: "点击预览图片"))

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
                .help(String(localized: "移除该图片"))
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
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

/// 用户消息气泡内的图片附件排版：
/// - 单图：大画幅自适应卡片（保持原图比例，最大 340×260pt，呼吸感自然）；
/// - 多图：规整紧凑网格流横排（每张 72~110pt，自适应折行且紧凑收敛）。
struct MessageImageThumbs: View {
    let images: [ChatImageAttachment]
    let onTap: (ChatImageAttachment) -> Void

    var body: some View {
        if images.count == 1, let single = images.first {
            singleImageView(single)
        } else {
            multiImagesView
        }
    }

    /// 单图大画幅视图
    @ViewBuilder
    private func singleImageView(_ attachment: ChatImageAttachment) -> some View {
        let size = singleImageSize(for: attachment)
        Button {
            onTap(attachment)
        } label: {
            if let image = ChatImageCache.thumbnail(for: attachment) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                            .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
                    .fill(Theme.Colors.surfaceTrack)
                    .frame(width: size.width, height: size.height)
            }
        }
        .buttonStyle(.plain)
        .help(String(localized: "点击放大查看"))
    }

    /// 多图网格流视图
    private var multiImagesView: some View {
        FlowRow(spacing: Theme.Spacing.md) {
            ForEach(images) { attachment in
                let size = multiThumbSize(for: attachment)
                Button {
                    onTap(attachment)
                } label: {
                    if let image = ChatImageCache.thumbnail(for: attachment) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                                    .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                            .fill(Theme.Colors.surfaceTrack)
                            .frame(width: size.width, height: size.height)
                    }
                }
                .buttonStyle(.plain)
                .help(String(localized: "点击放大查看"))
            }
        }
    }

    /// 单图精简预览尺寸：按原图宽高比收敛至 [minSide, 180×140] 内，克制优雅不霸屏
    private func singleImageSize(for attachment: ChatImageAttachment) -> CGSize {
        let maxWidth: CGFloat = 180
        let maxHeight: CGFloat = 140
        let minSide: CGFloat = 64

        let w = CGFloat(max(attachment.pixelWidth, 1))
        let h = CGFloat(max(attachment.pixelHeight, 1))

        let widthScale = maxWidth / w
        let heightScale = maxHeight / h
        let scale = min(widthScale, heightScale, 1.0)

        var finalW = w * scale
        var finalH = h * scale

        if finalW < minSide && finalH < minSide {
            let boost = minSide / max(finalW, finalH)
            finalW *= boost
            finalH *= boost
        }

        return CGSize(width: finalW.rounded(), height: finalH.rounded())
    }

    /// 多图网格内单张缩略图尺寸：规整紧凑（最长边 88，保底 60）
    private func multiThumbSize(for attachment: ChatImageAttachment) -> CGSize {
        let maxSide: CGFloat = 88
        let minSide: CGFloat = 60
        let w = CGFloat(max(attachment.pixelWidth, 1))
        let h = CGFloat(max(attachment.pixelHeight, 1))
        let scale = min(maxSide / w, maxSide / h, 1.0)
        var size = CGSize(width: w * scale, height: h * scale)
        if size.width < minSide { size.width = minSide }
        if size.height < minSide { size.height = minSide }
        return size
    }
}

/// 极简流式行：子视图放不下时换行，精准上报真实占据宽度（彻底消除盲目撑满容器的空白 bug）。
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                maxRowWidth = max(maxRowWidth, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        if x > 0 {
            maxRowWidth = max(maxRowWidth, x - spacing)
        }
        let totalHeight = y + rowHeight
        return CGSize(width: min(maxRowWidth, maxWidth), height: totalHeight)
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

// MARK: - 输入坞待发送引用条（结构化生长胶囊）

/// 输入坞生长区内的引用胶囊：展示当前挂载的引用片段、来源角色与一键关闭按钮
struct ActiveQuoteStrip: View {
    @ObservedObject var state: AIChatState
    @State private var closeButtonHovered = false

    var body: some View {
        if let quote = state.activeQuote {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "quote.opening")
                    .font(Theme.Typography.text(10, .semibold))
                    .foregroundColor(Theme.Colors.accent)

                if let role = quote.role {
                    Text(role == .assistant ? String(localized: "AI 回复") : String(localized: "你的提问"))
                        .font(Theme.Typography.text(10, .semibold))
                        .foregroundColor(role == .assistant ? Theme.Colors.accent : Theme.Colors.contentSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(Color.white.opacity(0.08))
                        )
                }

                Text(quote.text)
                    .font(Theme.Typography.text(11))
                    .foregroundColor(Theme.Colors.contentPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: Theme.Spacing.sm)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        state.clearQuote()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(Theme.Typography.text(9, .bold))
                        .foregroundColor(closeButtonHovered ? Theme.Colors.contentPrimary : Theme.Colors.contentTertiary)
                        .padding(4)
                        .background(
                            Circle().fill(Color.white.opacity(closeButtonHovered ? 0.15 : 0.06))
                        )
                }
                .buttonStyle(.plain)
                .onHover { closeButtonHovered = $0 }
                .help(String(localized: "取消引用"))
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 5)
            .background(
                ZStack {
                    // 实色遮挡层：彻底消除暗黑模式下底层消息流的字迹穿透
                    RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))

                    // 磨砂模糊层
                    RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                        .fill(.regularMaterial)

                    // 暗色流光衬底
                    RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                        .fill(Theme.Colors.chatBase.opacity(0.85))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .strokeBorder(Theme.Colors.accent.opacity(0.35), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.95)),
                removal: .opacity
            ))
        }
    }
}
