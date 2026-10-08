import Combine
import SwiftUI

// 由 AIChatMarkdownView.swift 拆出：图片内存缓存与三态图片视图。

// MARK: - 图片

/// 图片内存缓存（按地址键，避免滚动/重渲染反复下载与解码）。
/// `NSCache` 自身线程安全，可跨后台解码任务读写。
private enum MarkdownImageCache {
    static let cache = NSCache<NSURL, NSImage>()

    /// 渲染高度记忆（url 字符串 → 上次渲染高度）：**反实例化高度回退防线**——
    /// 图片本体被 NSCache 逐出后，滚动回收重建的 loading 态用记忆高度作
    /// minHeight，不再回落 120 固定占位（连环塌缩雪崩的主力源：每图塌
    /// 80~600pt × 行内多图同步重建 → doc 骤塌 → LazyVStack 底部锚定逐批拖视口）。
    /// 主线程读写（视图 init / 渲染回写），图片数量级小、无上限必要。
    private static var renderedHeights: [String: CGFloat] = [:]

    static func rememberedHeight(for url: String) -> CGFloat? {
        renderedHeights[url]
    }

    static func noteRenderedHeight(url: String, height: CGFloat) {
        renderedHeights[url] = height
    }

    static func key(for url: String) -> NSURL? {
        if let parsed = URL(string: url), parsed.scheme != nil {
            return parsed as NSURL
        }
        let expanded = (url as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return URL(fileURLWithPath: expanded) as NSURL
    }
}

/// 远程 / 本地 / data URI 图片视图：异步加载 + 内存缓存，绝不阻塞流式渲染。
/// 三态：加载中（等高占位 + ProgressView）/ 失败（弱化块 + alt + url）/ 成功（等比缩放 + 圆角 + 描边）。
/// 对外契约：`MarkdownImageView(alt:url:title:linkURL:)`（`linkURL` 默认 nil，被 MarkdownInlineText 拆段路径引用）。
/// 当图片来自 `[![alt](img)](link)` 这类链接内嵌图片时，`linkURL` 非 nil：成功态图片可点击打开链接。
struct MarkdownImageView: View {
    let alt: String
    let url: String
    let title: String?
    /// 外层链接地址（链接内嵌图片）；nil = 普通图片，不可点击。
    let linkURL: String?

    /// 显式 init：保证 `alt:url:title:` 旧调用与 `alt:url:title:linkURL:` 新调用都可用。
    /// **图片缓存命中直接以 success 态种子化**：反实例化重建（滚动回收）不再回落
    /// 120 占位——连环塌缩雪崩的主力源（每图塌 80~600pt × 行内多图同步重建 →
    /// doc 骤塌 → LazyVStack 底部锚定逐批拖视口 = 「上滚跳过数条消息」）。
    init(alt: String, url: String, title: String?, linkURL: String? = nil) {
        self.alt = alt
        self.url = url
        self.title = title
        self.linkURL = linkURL
        if let key = MarkdownImageCache.key(for: url),
           let cached = MarkdownImageCache.cache.object(forKey: key) {
            _state = State(initialValue: .success(cached))
        }
    }

    private enum LoadState {
        case loading
        case success(NSImage)
        case failure
    }

    @State private var state: LoadState = .loading
    /// 成功态是否处于 hover（可点击时用于手型光标与轻微提亮）。
    @State private var hovering = false
    /// 手型光标是否已 push（保证与 pop 严格配对，避免光标栈失衡）。
    @State private var cursorPushed = false

    var body: some View {
        Group {
            switch state {
            case .loading:
                loadingView
            case let .success(image):
                successView(image)
            case .failure:
                failureView
            }
        }
        .task(id: url) { await load() }
        .onDisappear {
            // 视图消失时兜底弹出手型光标，避免离开后光标残留。
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
    }

    /// 可点击链接 URL；`linkURL` 为 nil 或无法构造 URL 时为 nil（图片退化为不可点击）。
    private var clickableURL: URL? {
        guard let linkURL, let url = URL(string: linkURL) else { return nil }
        return url
    }

    // MARK: 三态视图

    /// 加载中：等高占位块 + 居中 ProgressView。**高度下限 = 渲染高度记忆**——
    /// 图片本体被 NSCache 逐出、反实例化重建走 loading 态时，占位不再回落固定
    /// 120（真实图常见 200~700pt，回落即 doc 塌缩）；无记忆（首见）才用 120。
    private var loadingView: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
            .fill(Theme.Colors.surfaceTrack)
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(120, MarkdownImageCache.rememberedHeight(for: url) ?? 120))
            .overlay(ProgressView().controlSize(.small))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
            )
    }

    /// 成功：按原始宽高比、容器宽自适应（限制向上采样）、圆角 insetCard、轻描边。
    /// 链接内嵌图片（linkURL 有效）时可点击打开，hover 手型光标 + 轻微提亮。
    private func successView(_ image: NSImage) -> some View {
        let clickable = clickableURL != nil
        return Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            // 先钉住不超过原始像素宽（向上采样限制）；圆角/描边跟随图片本身。
            .frame(maxWidth: max(image.size.width, 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                    .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
            )
            // 命中区 = 图片本身（避免外层满宽 frame 把透明区也纳入点击/hover）。
            .contentShape(Rectangle())
            .brightness(clickable && hovering ? 0.05 : 0)
            .onTapGesture {
                guard let target = clickableURL else { return }
                NSWorkspace.shared.open(target)
            }
            .onHover { isHovering in
                handleHover(isHovering, clickable: clickable)
            }
            // 再在容器内左对齐铺排（图片窄时不拉伸容器视觉）。
            .frame(maxWidth: .infinity, alignment: .leading)
            // 渲染高度回写记忆：供 loading 态 minHeight 种子（反实例化重建不塌缩）。
            // task(id: height) 高度变化（窗口宽度联动）时刷新记录。
            .background(
                GeometryReader { geo in
                    Color.clear
                        .task(id: geo.size.height) {
                            MarkdownImageCache.noteRenderedHeight(url: url, height: geo.size.height)
                        }
                }
            )
    }

    /// hover 状态与手型光标维护：仅在可点击时 push/pop，且 push 与 pop 严格配对。
    private func handleHover(_ isHovering: Bool, clickable: Bool) {
        hovering = isHovering
        guard clickable else {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
            return
        }
        if isHovering, !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        } else if !isHovering, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    /// 失败：弱化色圆角块内显示 alt 文本 + url 小字链接。
    private var failureView: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(alt.isEmpty ? String(localized: "图片无法加载") : alt)
                .font(Theme.Typography.text(12))
                .foregroundColor(Theme.Colors.contentSecondaryStrong)
                .fixedSize(horizontal: false, vertical: true)
            if let linkURL = URL(string: url),
               let scheme = linkURL.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                Link(destination: linkURL) {
                    Text(url)
                        .font(Theme.Typography.text(10))
                        .foregroundColor(Theme.Colors.accent)
                }
            } else {
                Text(url)
                    .font(Theme.Typography.text(10))
                    .foregroundColor(Theme.Colors.contentTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(Theme.Colors.surfaceTrack)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
    }

    // MARK: 加载

    /// 仅做状态编排（网络/解码均已异步外移），故固定在主 actor 上执行，@State 写入安全。
    /// 顺序契约：**缓存命中路径不置 loading**——init 已种子的 success（反实例化重建
    /// 恢复）不被拉回占位态闪变；只有确认要走异步加载才置 loading。
    @MainActor
    private func load() async {
        guard let key = MarkdownImageCache.key(for: url) else {
            state = .failure
            return
        }
        if let cached = MarkdownImageCache.cache.object(forKey: key) {
            state = .success(cached)
            return
        }
        state = .loading

        let decoded: NSImage?
        if let parsed = URL(string: url),
           let scheme = parsed.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            decoded = await Self.loadRemote(parsed)
        } else {
            let raw = url
            decoded = await Task.detached(priority: .utility) {
                Self.decodeLocalOrData(raw)
            }.value
        }

        guard !Task.isCancelled else { return }
        if let decoded {
            MarkdownImageCache.cache.setObject(decoded, forKey: key)
            state = .success(decoded)
        } else {
            state = .failure
        }
    }

    /// 远程图片：URLSession 异步取数据，解码放到后台线程。
    private static func loadRemote(_ url: URL) async -> NSImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                return nil
            }
            return await Task.detached(priority: .utility) { NSImage(data: data) }.value
        } catch {
            return nil
        }
    }

    /// 本地绝对路径（支持 ~ 展开 / file://）与 `data:` URI 解码；已在后台线程调用。
    private static func decodeLocalOrData(_ raw: String) -> NSImage? {
        if raw.hasPrefix("data:") {
            return decodeDataURI(raw)
        }
        if raw.hasPrefix("file://"), let fileURL = URL(string: raw) {
            return NSImage(contentsOf: fileURL)
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        return NSImage(contentsOfFile: expanded)
    }

    /// `data:image/...;base64,<payload>` 解码。
    private static func decodeDataURI(_ uri: String) -> NSImage? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.startIndex..<comma].lowercased()
        guard header.contains(";base64") else { return nil }
        let payload = String(uri[uri.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
        return NSImage(data: data)
    }
}
