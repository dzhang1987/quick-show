// 来源拆分：AIChatMathViews.swift — 数学公式光栅化 LaTeX → NSImage（MathRasterizer）。
import SwiftUI
import AppKit
import SwiftMath

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
