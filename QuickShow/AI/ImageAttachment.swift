import AppKit
import Foundation

// MARK: - 图片附件处理（NSImage → JPEG base64）

/// 图片附件压缩工具：统一把任意 NSImage 转成 JPEG base64，供 vision 请求体使用。
/// 服务层只依赖 AppKit，不含 SwiftUI。
enum ImageAttachmentProcessor {
    /// 原图最长边上限（像素）。超出则等比缩放，控制 base64 体积与请求延迟。
    static let maxDimension: CGFloat = 1600
    /// 原图 JPEG 压缩质量。
    static let jpegQuality: CGFloat = 0.8
    /// 缩略图最长边上限。
    static let thumbnailMaxDimension: CGFloat = 160
    /// 缩略图 JPEG 压缩质量。
    static let thumbnailQuality: CGFloat = 0.6

    /// 把 NSImage 压缩为 JPEG base64 附件。
    /// - Returns: 附件模型；编码失败返回 nil（调用方静默忽略该图）。
    static func makeAttachment(from image: NSImage, fileName: String? = nil) -> ChatImageAttachment? {
        guard let jpeg = jpegData(from: image, maxDimension: maxDimension, quality: jpegQuality) else {
            return nil
        }
        let thumb = jpegData(from: image, maxDimension: thumbnailMaxDimension, quality: thumbnailQuality)
        let pixelSize = pixelSize(of: image)

        return ChatImageAttachment(
            base64JPEG: jpeg.base64EncodedString(),
            thumbnailBase64JPEG: thumb?.base64EncodedString(),
            pixelWidth: Int(pixelSize.width.rounded()),
            pixelHeight: Int(pixelSize.height.rounded()),
            byteCount: jpeg.count,
            fileName: fileName
        )
    }

    /// 从文件 URL 读取并转成附件（失败返回 nil）。
    static func makeAttachment(fromFileURL url: URL) -> ChatImageAttachment? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return makeAttachment(from: image, fileName: url.lastPathComponent)
    }

    /// 读取剪贴板中的图片并转成附件（无图片返回 nil）。
    static func makeAttachmentFromPasteboard() -> ChatImageAttachment? {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        return makeAttachment(from: image)
    }

    // MARK: - 内部

    /// 等比缩放到最长边限制内并编码为 JPEG。
    private static func jpegData(from image: NSImage, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let target = fittedSize(of: image, maxDimension: maxDimension)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width.rounded()),
            pixelsHigh: Int(target.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap = rep else { return nil }

        // 用统一尺寸重绘（保持宽高比），避免直接操作 NSImage 造成的分辨率歧义。
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            image.draw(
                in: NSRect(origin: .zero, size: target),
                from: NSRect(origin: .zero, size: image.size),
                operation: .copy,
                fraction: 1.0
            )
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// 读取 NSImage 的像素尺寸（回退到逻辑尺寸）。
    private static func pixelSize(of image: NSImage) -> NSSize {
        if let rep = image.representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    /// 计算等比缩放后的目标尺寸。
    private static func fittedSize(of image: NSImage, maxDimension: CGFloat) -> NSSize {
        let size = pixelSize(of: image)
        guard size.width > 0, size.height > 0 else {
            return NSSize(width: maxDimension, height: maxDimension)
        }
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return size }
        let scale = maxDimension / longest
        return NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
    }
}