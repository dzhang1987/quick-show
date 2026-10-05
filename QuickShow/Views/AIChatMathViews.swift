import SwiftUI
import AppKit
import SwiftMath

// MARK: - 段落/公式高度持久缓存（跨重建查表，首帧免测量）

/// 全局测量缓存（独立枚举、非 MainActor、NSLock 保护，锁内只做字典操作）：
/// 1. 段落高度：跨 LRU 逐出重建复用，消除 `NSTextField.layoutSubtreeIfNeeded` 的重复测量
///    （这是历史「重挂载首帧最大成本」）。
/// 2. 块级公式高度：供 `AsyncMathBlockView` 占位直接锁定真实高度，消除占位→位图回填的高度跳变。
/// 键含内容 hash / 宽度桶 / 外观 / 字号 / 字重，内容变则键变，天然自洽。
enum MathLayoutCache {
    struct ParagraphKey: Hashable {
        var contentHash: Int
        /// 宽度取整（1pt 精度）。
        var widthBucket: Int
        var isDark: Bool
        var pointSizeMilli: Int
        var weightRaw: Int
    }

    struct BlockKey: Hashable {
        var latexHash: Int
        var pointSizeMilli: Int
        // 不含颜色：公式位图尺寸与颜色无关（只由数学原子布局决定）。
    }

    private static var paragraphCache: [ParagraphKey: CGFloat] = [:]
    private static var paragraphOrder: [ParagraphKey] = []
    private static var blockCache: [BlockKey: CGFloat] = [:]
    private static var blockOrder: [BlockKey] = []
    /// 各自 LRU 上限（高度是小数值，内存可忽略；条数上限防哈希表无限增长）。
    private static let limit = 4096
    private static let lock = NSLock()

    // MARK: 段落高度

    static func paragraphHeight(for key: ParagraphKey) -> CGFloat? {
        lock.lock(); defer { lock.unlock() }
        guard let height = paragraphCache[key] else { return nil }
        if let index = paragraphOrder.firstIndex(of: key) {
            paragraphOrder.remove(at: index)
            paragraphOrder.append(key)
        }
        return height
    }

    static func storeParagraphHeight(_ height: CGFloat, for key: ParagraphKey) {
        lock.lock(); defer { lock.unlock() }
        if paragraphCache[key] == nil { paragraphOrder.append(key) }
        paragraphCache[key] = height
        while paragraphOrder.count > limit {
            let oldest = paragraphOrder.removeFirst()
            paragraphCache.removeValue(forKey: oldest)
        }
    }

    // MARK: 块级公式高度

    static func blockHeight(latex: String, pointSize: CGFloat) -> CGFloat? {
        lock.lock(); defer { lock.unlock() }
        let key = blockKey(latex: latex, pointSize: pointSize)
        guard let height = blockCache[key] else { return nil }
        if let index = blockOrder.firstIndex(of: key) {
            blockOrder.remove(at: index)
            blockOrder.append(key)
        }
        return height
    }

    static func storeBlockHeight(_ height: CGFloat, latex: String, pointSize: CGFloat) {
        lock.lock(); defer { lock.unlock() }
        let key = blockKey(latex: latex, pointSize: pointSize)
        if blockCache[key] == nil { blockOrder.append(key) }
        blockCache[key] = height
        while blockOrder.count > limit {
            let oldest = blockOrder.removeFirst()
            blockCache.removeValue(forKey: oldest)
        }
    }

    private static func blockKey(latex: String, pointSize: CGFloat) -> BlockKey {
        BlockKey(
            latexHash: hashString(latex),
            pointSizeMilli: Int((pointSize * 1000).rounded())
        )
    }

    // MARK: 内容 hash（段落 token 序列）

    /// 段落 token 序列的稳定 hash（进程内稳定即可：缓存为进程内缓存）。
    static func contentHash(_ tokens: [InlineToken]) -> Int {
        var hasher = Hasher()
        hashTokens(tokens, into: &hasher)
        return hasher.finalize()
    }

    private static func hashTokens(_ tokens: [InlineToken], into hasher: inout Hasher) {
        for token in tokens {
            switch token {
            case let .text(value): hasher.combine(1); hasher.combine(value)
            case let .code(value): hasher.combine(2); hasher.combine(value)
            case let .bold(inner): hasher.combine(3); hashTokens(inner, into: &hasher)
            case let .italic(inner): hasher.combine(4); hashTokens(inner, into: &hasher)
            case let .link(text, url, title):
                hasher.combine(5); hashTokens(text, into: &hasher)
                hasher.combine(url); hasher.combine(title)
            case let .math(value): hasher.combine(6); hasher.combine(value)
            case let .strikethrough(inner): hasher.combine(7); hashTokens(inner, into: &hasher)
            case let .underline(inner): hasher.combine(8); hashTokens(inner, into: &hasher)
            case let .highlight(inner): hasher.combine(9); hashTokens(inner, into: &hasher)
            case let .`subscript`(inner): hasher.combine(10); hashTokens(inner, into: &hasher)
            case let .superscript(inner): hasher.combine(11); hashTokens(inner, into: &hasher)
            case let .image(alt, url, title):
                hasher.combine(12); hasher.combine(alt); hasher.combine(url); hasher.combine(title)
            case .lineBreak: hasher.combine(13)
            case let .footnoteRef(id): hasher.combine(14); hasher.combine(id)
            }
        }
    }

    private static func hashString(_ value: String) -> Int {
        var hasher = Hasher()
        hasher.combine(value)
        return hasher.finalize()
    }
}

// MARK: - 数学公式光栅化（LaTeX → NSImage）
//
// 设计要点：
// - macOS 1.7.3 上 MTMathUILabel.intrinsicContentSize 返回哨兵值 (-1,-1) 不可用，
//   故本方案统一走「离屏光栅化成 NSImage + NSTextAttachment / NSImageView」路径，
//   绝不把 MTMathUILabel 直接放进视图树。
// - 光栅化会把颜色烤进位图：动态 NSColor 直接传入会在暗色下黑底黑字。
//   因此所有颜色必须先在 effectiveAppearance 下解析成固定 sRGB 分量，再参与缓存 key。
enum MathRasterizer {

    /// 缓存 key：latex + 字号 + 已解析为 sRGB 的颜色四分量 + 显示/行内模式。
    /// 颜色进 key 保证亮暗两套位图各自独立，切换模式不会串味。
    private struct CacheKey: Hashable {
        let latex: String
        let pointSize: CGFloat
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        let isDisplay: Bool
    }

    /// 光栅化结果：位图 + 逻辑尺寸 + 基线信息（ascent/descent 供行内基线对齐）。
    struct Rasterized {
        let image: NSImage
        let size: NSSize
        let ascent: CGFloat
        let descent: CGFloat
    }

    private static var cache: [CacheKey: Rasterized] = [:]
    /// 插入序（LRU）：命中/写入移到尾部，超上限从头部淘汰，防位图缓存无界增长。
    private static var cacheOrder: [CacheKey] = []
    /// 缓存条数上限。
    private static let cacheLimit = 512
    /// 保护 cache / cacheOrder / inFlight 的互斥锁（主线程与后台队列并发访问）。
    private static let lock = NSLock()
    /// 串行化 SwiftMath 排版/光栅化：主线程同步路径与后台预热可能并发，内核非线程安全。
    private static let renderLock = NSLock()
    /// 按需异步光栅化串行队列（userInitiated：视图首帧占位后需尽快出图）。
    private static let rasterQueue = DispatchQueue(label: "quickshow.math.raster", qos: .userInitiated)
    /// 批量预热串行队列（utility：可让路给按需请求；与 rasterQueue 经 renderLock 串行化）。
    private static let prefetchQueue = DispatchQueue(label: "quickshow.math.prefetch", qos: .utility)
    /// 在飞行中的异步请求：同一 key 只派发一次，后续回调挂靠等待（去重）。
    private static var inFlight: [CacheKey: [(Rasterized?) -> Void]] = [:]
    /// 负缓存：render 明确失败（parse/光栅化失败）的 key。行内两段式回填会在失败后重建整段，
    /// 若不记录失败，重建时又会把该公式判为「未命中」并再次发起异步请求，形成请求风暴；
    /// 记录后主线程快速查询直接归入 `.failed` 降级为等宽源码，不再重复 render。
    private static var failedKeys: Set<CacheKey> = []

    /// 把 SwiftUI Color 在当前绘制外观下解析成固定 sRGB NSColor。
    /// appearance 为空时退回直接解析（无外观上下文时仅作兜底）。
    static func resolvedColor(_ color: Color, appearance: NSAppearance?) -> NSColor {
        var resolved = NSColor.labelColor
        let resolve = {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.labelColor
        }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(resolve)
        } else {
            resolve()
        }
        return resolved
    }

    /// SwiftUI colorScheme → 固定 appearance。
    /// 位图烤色后不会自动跟随明暗翻转，必须经 @Environment(\.colorScheme) 驱动
    /// updateNSView 重调（SwiftUI 只追踪环境依赖，不追踪 NSApp.effectiveAppearance），
    /// 再由此处换用对应 appearance 重新取色光栅化。
    static func appearance(for scheme: ColorScheme) -> NSAppearance {
        scheme == .dark
            ? NSAppearance(named: .darkAqua) ?? NSAppearance(named: .aqua)!
            : NSAppearance(named: .aqua)!
    }

    /// 构造缓存 key（转译 + 颜色解析后调用，保证命中率）。颜色四分量进 key 区分明暗/字色。
    private static func makeKey(latex: String, pointSize: CGFloat, srgb: NSColor, isDisplay: Bool) -> CacheKey {
        CacheKey(
            latex: latex,
            pointSize: pointSize,
            red: srgb.redComponent,
            green: srgb.greenComponent,
            blue: srgb.blueComponent,
            alpha: srgb.alphaComponent,
            isDisplay: isDisplay
        )
    }

    /// 锁内查缓存；命中时把 key 移到 LRU 尾部（最近使用）。
    private static func cachedValue(for key: CacheKey) -> Rasterized? {
        lock.lock(); defer { lock.unlock() }
        guard let value = cache[key] else { return nil }
        if let index = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: index)
            cacheOrder.append(key)
        }
        return value
    }

    /// 锁内写缓存并按 LRU 上限淘汰。成功后清除同 key 的负缓存。
    private static func storeInCache(_ value: Rasterized, for key: CacheKey) {
        lock.lock(); defer { lock.unlock() }
        failedKeys.remove(key)
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = value
        while cacheOrder.count > cacheLimit {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    /// 锁内记录解析/光栅化失败，避免后续重建/预热反复对同一畸形公式发起 render。
    private static func markFailed(_ key: CacheKey) {
        lock.lock(); defer { lock.unlock() }
        failedKeys.insert(key)
    }

    /// 主线程快速查询（**绝不触发 render**）：命中缓存 / 已知解析失败 / 未命中。
    /// 供行内两段式段落构建在首帧决定「同步装 attachment」还是「装占位 + 异步光栅化」。
    enum CacheLookup {
        case hit(Rasterized)
        case failed
        case miss
    }

    /// 锁内查缓存（命中刷新 LRU）与负缓存。转译 + 颜色解析在主线程完成（纳秒级）。
    static func lookup(latex: String, pointSize: CGFloat, color: NSColor, isDisplay: Bool) -> CacheLookup {
        let latex = MathLatexTranspiler.transpile(latex)
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let key = makeKey(latex: latex, pointSize: pointSize, srgb: srgb, isDisplay: isDisplay)
        lock.lock(); defer { lock.unlock() }
        if let value = cache[key] {
            if let index = cacheOrder.firstIndex(of: key) {
                cacheOrder.remove(at: index)
                cacheOrder.append(key)
            }
            return .hit(value)
        }
        return failedKeys.contains(key) ? .failed : .miss
    }

    /// SwiftMath 排版 + 离屏光栅化（renderLock 串行化，保证内核单线程使用）。解析失败返回 nil。
    private static func render(latex: String, pointSize: CGFloat, srgb: NSColor, isDisplay: Bool) -> Rasterized? {
        renderLock.lock(); defer { renderLock.unlock() }
        var renderer = MathImage(
            latex: latex,
            fontSize: pointSize,
            textColor: srgb,
            labelMode: isDisplay ? .display : .text,
            textAlignment: .center
        )
        let (error, image, layout) = renderer.asImage()
        guard error == nil, let image else { return nil }
        return Rasterized(
            image: image,
            size: image.size,
            ascent: layout?.ascent ?? pointSize * 0.8,
            // 兜底 descent：正数表示基线以下的深度（NSFont.descender 为负，取反）
            descent: layout?.descent ?? (-NSFont.systemFont(ofSize: pointSize).descender)
        )
    }

    /// 公式 → 位图（同步快路径，带缓存）。解析失败返回 nil，由调用方降级显示原始 LaTeX。
    /// - Parameter isDisplay: 块级用 true（display 模式，分式/积分更舒展），行内用 false（text 模式）。
    static func rasterize(latex: String, pointSize: CGFloat, color: NSColor, isDisplay: Bool) -> Rasterized? {
        // 先转译再算缓存 key：转译结果稳定，缓存命中率更高；行内/块级共用此入口。
        let latex = MathLatexTranspiler.transpile(latex)
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let key = makeKey(latex: latex, pointSize: pointSize, srgb: srgb, isDisplay: isDisplay)
        if let cached = cachedValue(for: key) { return cached }
        // 已知解析失败：不再重复同步 render（负缓存），由调用方降级显示。
        lock.lock()
        let knownFailed = failedKeys.contains(key)
        lock.unlock()
        if knownFailed { return nil }
        guard let result = render(latex: latex, pointSize: pointSize, srgb: srgb, isDisplay: isDisplay) else {
            markFailed(key)
            return nil
        }
        storeInCache(result, for: key)
        return result
    }

    /// 公式 → 位图（异步，供块级/行内视图首帧不阻塞主线程）。
    /// - 命中缓存：同步回调（调用方在主线程时即主线程回调）；
    /// - 未命中：派发后台串行队列排版/光栅化，写缓存后回主线程回调；
    /// - 同一 key 在飞行中：不重复派发，回调挂靠等待（去重）。
    static func rasterizeAsync(
        latex: String,
        pointSize: CGFloat,
        color: NSColor,
        isDisplay: Bool,
        completion: @escaping (Rasterized?) -> Void
    ) {
        let latex = MathLatexTranspiler.transpile(latex)
        let srgb = color.usingColorSpace(.sRGB) ?? color
        enqueueRasterize(
            latex: latex,
            pointSize: pointSize,
            srgb: srgb,
            isDisplay: isDisplay,
            on: rasterQueue,
            throttle: 0,
            completion: completion
        )
    }

    /// 异步/预热统一入口（B2 的关键：预热与按需共用同一 inFlight 去重表）。
    /// - queue：按需用 `.rasterQueue`（userInitiated），预热用 `.prefetchQueue`（utility）。
    /// - throttle：每次 render 完成、`renderLock` 已释放后暂停的秒数（B1），
    ///   给主线程与按需路径让出锁空窗，避免预热车队把首帧事务钉死。
    /// - completion 为 nil 表示纯预热（无回调）；命中缓存/已知失败时同步回调。
    private static func enqueueRasterize(
        latex: String,
        pointSize: CGFloat,
        srgb: NSColor,
        isDisplay: Bool,
        on queue: DispatchQueue,
        throttle: TimeInterval,
        completion: ((Rasterized?) -> Void)?
    ) {
        let key = makeKey(latex: latex, pointSize: pointSize, srgb: srgb, isDisplay: isDisplay)

        // 1. 锁内查缓存/负缓存；命中即时回调。
        lock.lock()
        if let value = cache[key] {
            if let index = cacheOrder.firstIndex(of: key) {
                cacheOrder.remove(at: index)
                cacheOrder.append(key)
            }
            lock.unlock()
            completion?(value)
            return
        }
        if failedKeys.contains(key) {
            lock.unlock()
            completion?(nil)
            return
        }
        // 2. inFlight 去重：同一 key 已在飞行则挂靠等待（预热与按需互不重复 render）。
        if inFlight[key] != nil {
            if let completion { inFlight[key]?.append(completion) }
            lock.unlock()
            return
        }
        inFlight[key] = completion.map { [$0] } ?? []
        lock.unlock()

        queue.async {
            let result: Rasterized?
            if let cached = cachedValue(for: key) {
                result = cached
            } else {
                result = render(latex: latex, pointSize: pointSize, srgb: srgb, isDisplay: isDisplay)
                if let result { storeInCache(result, for: key) } else { markFailed(key) }
            }
            lock.lock()
            let callbacks = inFlight.removeValue(forKey: key) ?? []
            lock.unlock()
            // 所有回调统一回主线程（UI 状态更新约束）。
            if !callbacks.isEmpty {
                DispatchQueue.main.async {
                    for callback in callbacks { callback(result) }
                }
            }
            // B1：render 已返回（renderLock 已释放），此处让出 1.5ms，
            // 使主线程在最坏情况下也有约 50% 的 renderLock 空窗期。
            if throttle > 0 { Thread.sleep(forTimeInterval: throttle) }
        }
    }

    /// 批量预热：后台串行逐个「查缓存 → 未命中则光栅化入缓存」，全程不阻塞主线程。
    /// 供选中会话时按会话 latex 集合预热（块级 isDisplay=true / 行内 false 各调一次）。
    /// B3：单次预热预算 = cacheLimit/2。块级与行内各调一次共用同一 512 LRU 池，
    /// 若两类都全量预热（如行内 ~600）会相互驱逐，使文档最前（首屏）的条目最先被淘汰。
    /// 列表按文档顺序排列，取前缀即「块级/首屏段落优先」；溢出部分不预热，
    /// 交由按需异步路径兜底（B1/B2 已保证其不阻塞主线程且与预热去重）。
    static func prefetch(latexList: [String], pointSize: CGFloat, color: NSColor, isDisplay: Bool) {
        guard !latexList.isEmpty else { return }
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let budget = cacheLimit / 2
        let targets = latexList.count > budget ? Array(latexList.prefix(budget)) : latexList
        prefetchQueue.async {
            for latex in targets {
                let transpiled = MathLatexTranspiler.transpile(latex)
                enqueueRasterize(
                    latex: transpiled,
                    pointSize: pointSize,
                    srgb: srgb,
                    isDisplay: isDisplay,
                    on: prefetchQueue,
                    throttle: 0.0015,
                    completion: nil
                )
            }
        }
    }
}

// MARK: - 行内公式 Attachment

/// NSTextAttachment 构造：图片 + bounds（基线对齐）。
/// ⚠ 仅接受**已光栅化结果**——主线程绝不在此触发同步 render（缓存命中才可同步装 attachment）。
enum InlineMathAttachment {
    static func make(from raster: MathRasterizer.Rasterized) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = raster.image
        // y = -descent：把图片整体下压 descent 深度，使公式基线与整行文本基线重合
        attachment.bounds = CGRect(
            x: 0,
            y: -raster.descent,
            width: raster.size.width,
            height: raster.size.height
        )
        return attachment
    }
}

// MARK: - 块级公式视图

/// 块级公式：包 NSImageView，display 模式光栅化，等比缩放不下溢。
/// 失败降级由调用方处理（本视图 image 为 nil 时不显示内容）。
struct MathBlockView: NSViewRepresentable {
    let latex: String
    var fontSize: CGFloat = 14
    var color: Color = Color.primary

    /// 明暗翻转追踪：SwiftUI 环境变化才触发 updateNSView 重调（读 NSApp.effectiveAppearance
    /// 不被追踪，外观切换后旧位图会钉死），翻转后经缓存 key（含颜色分量）自动换新位图。
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        let nsColor = MathRasterizer.resolvedColor(color, appearance: MathRasterizer.appearance(for: colorScheme))
        let raster = MathRasterizer.rasterize(
            latex: latex, pointSize: fontSize, color: nsColor, isDisplay: true
        )
        view.image = raster?.image
    }
}

// MARK: - 含行内公式的段落视图

/// 含行内公式的段落：包 NSTextField（wrapsLabel），NSAttributedString 内嵌 NSTextAttachment。
/// 通过 sizeThatFits 把 proposed width 设为 preferredMaxLayoutWidth 后重新测量高度。
struct MathParagraphView: NSViewRepresentable {
    let inlines: [InlineToken]
    var baseSize: CGFloat = 13
    var weight: Font.Weight = .regular
    var color: Color = Color.primary.opacity(0.80)

    /// 明暗翻转追踪：同 MathBlockView，环境驱动 updateNSView 重调后重新取色光栅化；
    /// 原先读 field.effectiveAppearance 依赖视图已挂入窗口，且翻转不触发刷新。
    @Environment(\.colorScheme) private var colorScheme

    /// 测量缓存 + 行内公式两段式回填状态。
    final class Coordinator {
        var measuredWidth: CGFloat = -1
        var measuredHeight: CGFloat = 0
        /// 回填世代令牌：每次 updateNSView 自增；异步回调仅在世代未变时写回，
        /// 防止旧外观/旧内容的滞回结果覆盖新段落（防竞态）。
        var generation = 0
        /// 本段待回填公式计数：全部归零后一次性重建整段（避免 N 个公式触发 N 次重建）。
        var pendingRemaining = 0
        /// 回填写回目标字段（弱引用：视图销毁后回调自动失效）。
        weak var field: NSTextField?
        /// 本段内容 hash（updateNSView 时算一次）：全局高度缓存的 key 之一。
        var contentHash = 0
        /// 本段是否已「测量稳定」（无待回填公式：命中缓存或已知失败）：只有稳定测量才写入全局缓存，
        /// 避免用「占位文本高度」污染持久缓存。
        var measurementStable = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: NSAttributedString())
        field.isEditable = false
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.isBezeled = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.field = field
        // 世代推进：本次更新后，任何在途旧回调作废。
        coordinator.generation += 1
        let generation = coordinator.generation

        let nsColor = MathRasterizer.resolvedColor(color, appearance: MathRasterizer.appearance(for: colorScheme))
        let nsFont = MarkdownInlineNS.font(size: baseSize, weight: MarkdownInlineNS.nsWeight(weight))
        let renderResult = MarkdownInlineNS.renderNS(
            inlines,
            baseFont: nsFont,
            baseColor: nsColor,
            baseSize: baseSize
        )
        field.attributedStringValue = renderResult.attributed
        field.invalidateIntrinsicContentSize()
        // 内容/外观变化使旧测量失效：清缓存，下次 sizeThatFits 重新测量。
        coordinator.measuredWidth = -1
        // 全局高度缓存 key 的内容部分（updateNSView 时算一次；sizeThatFits 只补宽度/字号/字重）。
        coordinator.contentHash = MathLayoutCache.contentHash(inlines)
        // 诊断埋点（临时）：段落重建时刻 + pending 公式数——定位 doc 大塌缩的子视图来源。
        // 稳定性：本帧无待回填公式（全部命中缓存或已知失败）→ 测得的高度才写入全局缓存。
        coordinator.measurementStable = renderResult.pendingMath.isEmpty

        // 两段式（方案 A）：命中缓存的公式已同步装 attachment；未命中者在上面写成等宽
        // 占位文本，此处批量发起异步光栅化，全部完成后**只重建一次**整段（避免 N 次重建）。
        let pending = renderResult.pendingMath
        guard !pending.isEmpty else { return }
        coordinator.pendingRemaining = pending.count

        // 捕获本次世代下的取色/字体与内容，供回填重建使用（外观变化会再次进入并推进世代）。
        let tokens = inlines
        let size = baseSize
        let rebuildFlush: () -> Void = {
            let rebuilt = MarkdownInlineNS.renderNS(
                tokens,
                baseFont: nsFont,
                baseColor: nsColor,
                baseSize: size
            )
            // ⚠ 无任何 opacity/动画过渡：直接替换，避免 CA 事务竞态把内容层卡在近零透明度。
            coordinator.field?.attributedStringValue = rebuilt.attributed
            coordinator.field?.invalidateIntrinsicContentSize()
            // 位图回填改变内容尺寸：清测量缓存，驱动 sizeThatFits 重新测量高度。
            coordinator.measuredWidth = -1
            // 回填后本段所有公式均已缓存/已知失败 → 后续测量为稳定测量，可写入全局高度缓存。
            coordinator.measurementStable = true
        }

        for item in pending {
            MathRasterizer.rasterizeAsync(
                latex: item.latex,
                pointSize: item.pointSize,
                color: item.color,
                isDisplay: false
            ) { _ in
                // 统一延迟到下一 runloop：命中缓存/已知失败时的同步回调会在发起循环内触发，
                // 若立即重建会重入；延迟后所有回调在发起循环结束后统一结算。
                DispatchQueue.main.async {
                    guard generation == coordinator.generation else { return }
                    coordinator.pendingRemaining -= 1
                    guard coordinator.pendingRemaining <= 0 else { return }
                    rebuildFlush()
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        // 无宽度建议时交回系统；有宽度则钉死换行宽度后重新测量高度。
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        // 内容已就绪（updateNSView 已写入 attributedString）且宽度未变时，复用上次测量结果，
        // 避免同一测量周期内重复强制 layout。
        // ⚠️ guarded by attributedStringValue.length > 0：sizeThatFits 可能早于首次 updateNSView
        // 被调用（此时为占位空串），若把这种空测量的极小高度写入缓存，段落会被钉死塌陷为不可见。
        let hasContent = nsView.attributedStringValue.length > 0
        if hasContent, context.coordinator.measuredWidth == width {
            return CGSize(width: width, height: context.coordinator.measuredHeight)
        }
        // 全局持久高度缓存：跨实例/跨 LRU 重建命中即免测量（首帧成本只与屏幕成正比的关键）。
        // key 含内容 hash + 宽度桶 + 外观 + 字号 + 字重；内容变则键变，天然自洽。
        let globalKey = MathLayoutCache.ParagraphKey(
            contentHash: context.coordinator.contentHash,
            widthBucket: Int(width.rounded()),
            isDark: colorScheme == .dark,
            pointSizeMilli: Int((baseSize * 1000).rounded()),
            weightRaw: Self.weightRaw(weight)
        )
        if hasContent, let cachedHeight = MathLayoutCache.paragraphHeight(for: globalKey) {
            nsView.preferredMaxLayoutWidth = width
            context.coordinator.measuredWidth = width
            context.coordinator.measuredHeight = cachedHeight
            return CGSize(width: width, height: cachedHeight)
        }
        nsView.preferredMaxLayoutWidth = width
        nsView.invalidateIntrinsicContentSize()
        nsView.layoutSubtreeIfNeeded()
        let height = max(nsView.fittingSize.height, nsView.intrinsicContentSize.height)
        if hasContent {
            context.coordinator.measuredWidth = width
            context.coordinator.measuredHeight = height
            // 仅稳定测量（无待回填公式）写入全局缓存，避免占位文本高度污染持久缓存。
            if context.coordinator.measurementStable {
                MathLayoutCache.storeParagraphHeight(height, for: globalKey)
            } else {
                // 诊断埋点（临时）：占位测量（pending 段落）——大塌缩的直接形态。
            }
        }
        return CGSize(width: width, height: height)
    }

    /// `Font.Weight` → 稳定整数（全局缓存 key 用）。
    private static func weightRaw(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight: return 1
        case .thin: return 2
        case .light: return 3
        case .regular: return 4
        case .medium: return 5
        case .semibold: return 6
        case .bold: return 7
        case .heavy: return 8
        case .black: return 9
        default: return 4
        }
    }
}

// MARK: - NSAttributedString 行内渲染（镜像 MarkdownInline.render 语义）

/// 单条待异步光栅化的行内公式（段落构建时收集，用于两段式回填）。
struct PendingInlineMath {
    let latex: String
    let pointSize: CGFloat
    let color: NSColor
}

/// 行内渲染结果：attributed 已含「命中位图 attachment 或未命中占位」，
/// pendingMath 为本段需要后台光栅化的公式清单（全部完成后重建一次整段）。
struct InlineMathRender {
    let attributed: NSAttributedString
    let pendingMath: [PendingInlineMath]
}

/// 行内 token → NSAttributedString（供含公式的段落使用）。
/// 语义严格对齐 SwiftUI 版 MarkdownInline.render：
/// text→引号归一 + baseColor/baseFont；code→等宽 + surfaceTrack 底；
/// bold→semibold + labelColor；italic→斜体；link→accent + 下划线（title 忽略）；
/// strikethrough→strikethroughStyle；underline→underlineStyle；
/// highlight→accent 半透明 backgroundColor；subscript/superscript→小号字体 + baselineOffset；
/// lineBreak→换行；footnoteRef→小号 accent 上标；image→链接样式「[图片: alt]」降级；
/// math→缓存命中装 NSTextAttachment / 未命中装等宽占位并登记异步回填。
enum MarkdownInlineNS {

    /// SwiftUI Font.Weight → AppKit NSFont.Weight。
    static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    /// 正文字体（SF Pro）。
    static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// 等宽字体（SF Mono），对应 Theme.Typography.mono。
    static func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// 行内代码底色：chatInlineCodeFill = Color.primary.opacity(0.10) 的 NSColor 近似。
    private static var codeBackground: NSColor {
        NSColor.labelColor.withAlphaComponent(0.10)
    }

    /// 高亮（`<mark>`）底色：半透明强调色（与 SwiftUI 路径同 accent 色系，0.15 降噪）。
    private static var highlightBackground: NSColor {
        accentColor.withAlphaComponent(0.15)
    }

    /// accent 的 NSColor 近似：优先取当前主题 accent 解析值，失败退回系统 linkColor。
    private static var accentColor: NSColor {
        MathRasterizer.resolvedColor(Theme.Colors.accent, appearance: NSApp.effectiveAppearance)
    }

    static func renderNS(
        _ tokens: [InlineToken],
        baseFont: NSFont,
        baseColor: NSColor,
        baseSize: CGFloat
    ) -> InlineMathRender {
        let result = NSMutableAttributedString()
        var pending: [PendingInlineMath] = []
        render(
            into: result,
            tokens: tokens,
            baseFont: baseFont,
            baseColor: baseColor,
            baseSize: baseSize,
            pending: &pending
        )
        return InlineMathRender(attributed: result, pendingMath: pending)
    }

    private static func render(
        into result: NSMutableAttributedString,
        tokens: [InlineToken],
        baseFont: NSFont,
        baseColor: NSColor,
        baseSize: CGFloat,
        pending: inout [PendingInlineMath]
    ) {
        for token in tokens {
            switch token {
            case let .text(value):
                let piece = NSAttributedString(
                    string: MarkdownInline.normalizeQuotes(value),
                    attributes: [.font: baseFont, .foregroundColor: baseColor]
                )
                result.append(piece)

            case let .code(value):
                let piece = NSAttributedString(
                    string: value,
                    attributes: [
                        .font: monoFont(size: 12.5),
                        .foregroundColor: baseColor,
                        .backgroundColor: codeBackground,
                    ]
                )
                result.append(piece)

            case let .bold(inner):
                // 加粗档提为 labelColor（contentPrimary），与 SwiftUI 版一致
                render(
                    into: result,
                    tokens: inner,
                    baseFont: font(size: baseSize, weight: .semibold),
                    baseColor: .labelColor,
                    baseSize: baseSize,
                    pending: &pending
                )

            case let .italic(inner):
                let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                render(
                    into: result,
                    tokens: inner,
                    baseFont: italicFont,
                    baseColor: baseColor,
                    baseSize: baseSize,
                    pending: &pending
                )

            case let .link(label, url, _):
                let start = result.length
                render(
                    into: result,
                    tokens: label,
                    baseFont: baseFont,
                    baseColor: baseColor,
                    baseSize: baseSize,
                    pending: &pending
                )
                applyLinkStyle(to: result, from: start, url: url)

            case let .strikethrough(inner):
                let start = result.length
                render(
                    into: result,
                    tokens: inner,
                    baseFont: baseFont,
                    baseColor: baseColor,
                    baseSize: baseSize,
                    pending: &pending
                )
                applyAttribute(
                    to: result, from: start,
                    key: .strikethroughStyle, value: NSUnderlineStyle.single.rawValue
                )

            case let .underline(inner):
                let start = result.length
                render(
                    into: result,
                    tokens: inner,
                    baseFont: baseFont,
                    baseColor: baseColor,
                    baseSize: baseSize,
                    pending: &pending
                )
                applyAttribute(
                    to: result, from: start,
                    key: .underlineStyle, value: NSUnderlineStyle.single.rawValue
                )

            case let .highlight(inner):
                let start = result.length
                render(
                    into: result,
                    tokens: inner,
                    baseFont: baseFont,
                    baseColor: baseColor,
                    baseSize: baseSize,
                    pending: &pending
                )
                applyAttribute(to: result, from: start, key: .backgroundColor, value: highlightBackground)

            case let .`subscript`(inner):
                renderScript(
                    into: result, tokens: inner,
                    baseFont: baseFont, baseColor: baseColor, baseSize: baseSize,
                    sizeDelta: -2, baselineOffset: -3, pending: &pending
                )

            case let .superscript(inner):
                renderScript(
                    into: result, tokens: inner,
                    baseFont: baseFont, baseColor: baseColor, baseSize: baseSize,
                    sizeDelta: -2, baselineOffset: 3, pending: &pending
                )

            case .lineBreak:
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [.font: baseFont, .foregroundColor: baseColor]
                ))

            case let .footnoteRef(id):
                result.append(NSAttributedString(
                    string: id,
                    attributes: [
                        .font: derivedFont(from: baseFont, size: max(baseSize - 3, 1)),
                        .foregroundColor: accentColor,
                        .baselineOffset: CGFloat(4),
                    ]
                ))

            case let .image(alt, url, _):
                // AppKit/NSTextField 路径不做异步图片：降级为链接样式文本（公式+图片同段罕见）。
                let label = alt.isEmpty ? "[图片]" : "[图片: \(alt)]"
                let piece = NSMutableAttributedString(
                    string: label,
                    attributes: [
                        .font: baseFont,
                        .foregroundColor: accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]
                )
                if let linkURL = URL(string: url) {
                    piece.addAttribute(
                        .link, value: linkURL,
                        range: NSRange(location: 0, length: piece.length)
                    )
                }
                result.append(piece)

            case let .math(latex):
                // 方案 A：主线程**只做锁内快速查询**，绝不触发同步 render。
                switch MathRasterizer.lookup(latex: latex, pointSize: baseSize, color: baseColor, isDisplay: false) {
                case let .hit(raster):
                    // 命中缓存：纯内存装 attachment（纳秒级，走既有基线对齐路径）。
                    result.append(NSAttributedString(attachment: InlineMathAttachment.make(from: raster)))
                case .failed:
                    // 已知解析失败：降级显示原始 LaTeX 文本，不再重复请求。
                    appendMathFallback(into: result, latex: latex, color: baseColor)
                case .miss:
                    // 未命中：先装等宽原始 LaTeX 占位（首帧可读、真实文本宽度、段落高度合理），
                    // 登记待回填；全部异步完成后用真实 attachment 重建整段。
                    appendMathFallback(into: result, latex: latex, color: baseColor)
                    pending.append(PendingInlineMath(latex: latex, pointSize: baseSize, color: baseColor))
                }
            }
        }
    }

    /// 行内公式占位/失败降级：等宽原始 LaTeX 文本（12pt），保证首帧非空白且尺寸近似。
    private static func appendMathFallback(into result: NSMutableAttributedString, latex: String, color: NSColor) {
        result.append(NSAttributedString(
            string: latex,
            attributes: [.font: monoFont(size: 12), .foregroundColor: color]
        ))
    }

    // MARK: 新 token 辅助

    /// 由现有字体派生指定字号的同族字体（保留字重 / 斜体等 trait）。
    private static func derivedFont(from font: NSFont, size: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    }

    /// 对 [start, result.length) 区间应用单一属性（区间为空则跳过）。
    private static func applyAttribute(
        to result: NSMutableAttributedString,
        from start: Int,
        key: NSAttributedString.Key,
        value: Any
    ) {
        let range = NSRange(location: start, length: result.length - start)
        guard range.length > 0 else { return }
        result.addAttribute(key, value: value, range: range)
    }

    /// 链接样式：accent 前景 + 下划线 + `.link` 属性（url 非法时仅保留视觉样式）。
    private static func applyLinkStyle(to result: NSMutableAttributedString, from start: Int, url: String) {
        let range = NSRange(location: start, length: result.length - start)
        guard range.length > 0 else { return }
        result.addAttribute(.foregroundColor, value: accentColor, range: range)
        result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        if let linkURL = URL(string: url) {
            result.addAttribute(.link, value: linkURL, range: range)
        }
    }

    /// 上下标：以派生小号字体递归渲染 inner，再对整段应用 baselineOffset。
    /// baseSize 一并传入小号值，保证嵌套 bold/italic/math 同步缩小。
    private static func renderScript(
        into result: NSMutableAttributedString,
        tokens: [InlineToken],
        baseFont: NSFont,
        baseColor: NSColor,
        baseSize: CGFloat,
        sizeDelta: CGFloat,
        baselineOffset: CGFloat,
        pending: inout [PendingInlineMath]
    ) {
        let start = result.length
        let scriptSize = max(baseSize + sizeDelta, 1)
        render(
            into: result,
            tokens: tokens,
            baseFont: derivedFont(from: baseFont, size: scriptSize),
            baseColor: baseColor,
            baseSize: scriptSize,
            pending: &pending
        )
        applyAttribute(to: result, from: start, key: .baselineOffset, value: baselineOffset)
    }
}

// MARK: - SwiftUI 统一行内入口

/// 行内文本统一入口：
/// - 含顶层图片：按「文本段 / 图片项」交替拆段，文本段递归走下方双路径，图片项交给
///   `MarkdownImageView`，整体 `VStack(leading)` 顺序排列；
/// - 含公式（含嵌套在粗体/斜体/链接等内的公式）：NSTextField + NSTextAttachment 路径；
/// - 其余：原 SwiftUI AttributedString 路径。
struct MarkdownInlineText: View {
    let inlines: [InlineToken]
    var bodyColor: Color = Color.primary.opacity(0.80)
    var baseSize: CGFloat = 13
    var weight: Font.Weight = .regular
    var explicitColor: Color? = nil

    var body: some View {
        if inlines.containsImage {
            imageLayout
        } else if inlines.containsMath {
            MathParagraphView(
                inlines: inlines,
                baseSize: baseSize,
                weight: weight,
                color: explicitColor ?? bodyColor
            )
        } else {
            plainText
        }
    }

    /// 含顶层图片：交替拆段（纯结构操作，无 IO），文本段复用本视图递归渲染，
    /// 文本段与图片以 `VStack(leading)` 自然换行相邻。
    private var imageLayout: some View {
        let segments = inlines.imageSegments
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .text(tokens):
                    MarkdownInlineText(
                        inlines: tokens,
                        bodyColor: bodyColor,
                        baseSize: baseSize,
                        weight: weight,
                        explicitColor: explicitColor
                    )
                case let .image(alt, url, title, linkURL):
                    MarkdownImageView(alt: alt, url: url, title: title, linkURL: linkURL)
                }
            }
        }
    }

    /// 非公式路径：严格复刻各调用点原有的 Text + font(+foregroundColor) modifier 组合。
    @ViewBuilder
    private var plainText: some View {
        let base = Text(MarkdownInline.render(inlines, bodyColor: bodyColor))
            .font(Theme.Typography.text(baseSize, weight))
        if let explicitColor {
            base.foregroundColor(explicitColor)
        } else {
            base
        }
    }
}

// MARK: - 图片拆段单元

/// 图片拆段后的显示单元：文本段（继续行内渲染）或图片项（交给 `MarkdownImageView`）。
/// `linkURL` 非 nil 表示该图片来自链接内嵌（`[![alt](img)](link)`），成功态可点击打开。
private enum InlineDisplaySegment {
    case text([InlineToken])
    case image(alt: String, url: String, title: String?, linkURL: String?)
}

// MARK: - 公式 / 图片检测（递归）

private extension Array where Element == InlineToken {
    /// 是否含公式 token（递归粗体/斜体/链接/删除线/下划线/高亮/上下标内部）。
    var containsMath: Bool { contains { $0.containsMath } }

    /// 是否含**顶层**图片 token（不递归进入链接内层）。
    var containsTopLevelImage: Bool {
        contains { if case .image = $0 { return true } else { return false } }
    }

    /// 是否触发图片拆段：顶层 `.image`，或顶层 `.link` 的 text 顶层含 `.image`
    /// （即 `[![alt](img)](link)`）。仅处理「一层 link 包 image」，不再深入嵌套以避免无限递归。
    var containsImage: Bool {
        contains { token in
            switch token {
            case .image:
                return true
            case let .link(text, _, _):
                return text.containsTopLevelImage
            default:
                return false
            }
        }
    }

    /// 仅按顶层 `.image` 拆段（老逻辑），供链接内层拆解复用。
    /// 顺序保持，连续文本归一段，图片各自成项，空文本段丢弃。
    var topLevelImageSegments: [InlineDisplaySegment] {
        var segments: [InlineDisplaySegment] = []
        var buffer: [InlineToken] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            segments.append(.text(buffer))
            buffer.removeAll()
        }
        for token in self {
            if case let .image(alt, url, title) = token {
                flush()
                segments.append(.image(alt: alt, url: url, title: title, linkURL: nil))
            } else {
                buffer.append(token)
            }
        }
        flush()
        return segments
    }

    /// 把顶层 token 序列拆为交替的文本段与图片项：顺序保持，连续文本归一段，
    /// 图片各自成项，空文本段丢弃。
    /// 升级：顶层 `.link` 的 text 顶层含 `.image` 时，递归拆解其内层——image 提升为图片项并
    /// 携带 linkURL，非图片 token 归并到相邻文本段（不保留链接样式，可接受）。
    var imageSegments: [InlineDisplaySegment] {
        var segments: [InlineDisplaySegment] = []
        var buffer: [InlineToken] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            segments.append(.text(buffer))
            buffer.removeAll()
        }
        for token in self {
            switch token {
            case let .image(alt, url, title):
                flush()
                segments.append(.image(alt: alt, url: url, title: title, linkURL: nil))
            case let .link(text, linkURL, _) where text.containsTopLevelImage:
                for inner in text.topLevelImageSegments {
                    switch inner {
                    case let .image(alt, url, title, _):
                        flush()
                        segments.append(.image(alt: alt, url: url, title: title, linkURL: linkURL))
                    case let .text(tokens):
                        buffer.append(contentsOf: tokens)
                    }
                }
            default:
                buffer.append(token)
            }
        }
        flush()
        return segments
    }
}

private extension InlineToken {
    var containsMath: Bool {
        switch self {
        case .math:
            return true
        case let .bold(inner), let .italic(inner),
             let .strikethrough(inner), let .underline(inner), let .highlight(inner),
             let .superscript(inner):
            return inner.containsMath
        case let .`subscript`(inner):
            return inner.containsMath
        case let .link(text, _, _):
            return text.containsMath
        case .text, .code, .image, .lineBreak, .footnoteRef:
            return false
        }
    }
}