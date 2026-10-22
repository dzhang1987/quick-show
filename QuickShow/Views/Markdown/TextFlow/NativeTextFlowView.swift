import SwiftUI
import AppKit

// MARK: - TextKit 原生连续流自定义属性

extension NSAttributedString.Key {
    /// 标记该区间为引用块（Blockquote），驱动 LayoutManager 绘制左侧装饰细条与衬底
    static let flowBlockquote = NSAttributedString.Key("quickshow.flow.blockquote")
    /// 标记该区间为 H1 标题，驱动 LayoutManager 在末尾绘制底部分割线
    static let flowHeading1 = NSAttributedString.Key("quickshow.flow.heading1")
    /// 标记该区间为水平分割线（Horizontal Rule），驱动 LayoutManager 绘制水平居中细线
    static let flowHorizontalRule = NSAttributedString.Key("quickshow.flow.horizontalRule")
}

// MARK: - 连续文本流排版与背景装饰管理器

/// 负责在 TextKit 排版底层绘制引用块竖条、H1 分隔线与水平分割线，
/// 从而使富文本能够在单个 NSTextView / TextStorage 内部保持连贯，支持跨块连贯拖拽选区与复制。
final class FlowLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {

    override init() {
        super.init()
        self.delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.delegate = self
    }

    // MARK: - NSLayoutManagerDelegate（解决首块处于容器顶部的段前间距折叠）

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let storage = textStorage else { return false }
        let charIndex = characterIndexForGlyph(at: glyphRange.location)
        guard charIndex < storage.length else { return false }
        let isQuote = storage.attribute(.flowBlockquote, at: charIndex, effectiveRange: nil) != nil
        // 当引用块处于文本容器绝对顶端（y == 0，即全文第一块且上方无正文），TextKit 默认会折叠首行 paragraphSpacingBefore。
        // 此处主动平移首行 8pt，确保容器顶部的引用块同样拥有 8pt 呼吸空间，与普通情形保持绝对一致。
        if isQuote && lineFragmentRect.pointee.origin.y == 0 {
            lineFragmentRect.pointee.origin.y += 8
            lineFragmentUsedRect.pointee.origin.y += 8
            return true
        }
        return false
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let validCharRange = NSIntersectionRange(charRange, NSRange(location: 0, length: storage.length))
        guard validCharRange.length > 0 else { return }

        // 1. 绘制引用块（Blockquote）：背景底色与左侧装饰竖线
        drawBlockquotes(in: validCharRange, origin: origin)

        // 2. 绘制 H1 标题底部分割线
        drawHeading1Dividers(in: validCharRange, origin: origin)

        // 3. 绘制水平分割线（Horizontal Rule）
        drawHorizontalRules(in: validCharRange, origin: origin)
    }

    private func drawBlockquotes(in charRange: NSRange, origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let fullLength = storage.length
        let entireRange = NSRange(location: 0, length: fullLength)

        var handledRanges = Set<NSRange>()

        storage.enumerateAttribute(.flowBlockquote, in: charRange, options: []) { value, subRange, _ in
            guard value != nil else { return }

            // 扩展到该 blockquote 在整篇文档中的完整有效区间，避免局部脏区重绘导致底板与竖条被切断
            var effectiveRange = NSRange(location: NSNotFound, length: 0)
            _ = storage.attribute(.flowBlockquote, at: subRange.location, longestEffectiveRange: &effectiveRange, in: entireRange)
            guard effectiveRange.location != NSNotFound, effectiveRange.length > 0 else { return }

            // 同一个重绘周期内去重，避免重复绘制
            guard handledRanges.insert(effectiveRange).inserted else { return }

            let glyphRange = self.glyphRange(forCharacterRange: effectiveRange, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return }

            var firstLineTop: CGFloat?
            var lastLineBottom: CGFloat = 0
            var maxLineWidth: CGFloat = 0

            self.enumerateLineFragments(forGlyphRange: glyphRange) { rect, usedRect, _, _, _ in
                if firstLineTop == nil {
                    // 首行真实字形墨水顶边（完全不受外部空白污染）
                    firstLineTop = usedRect.minY
                }
                // 末行真实字形墨水底边（完全绕过任何段后 paragraphSpacing 污染）
                lastLineBottom = max(lastLineBottom, usedRect.maxY)
                maxLineWidth = max(maxLineWidth, rect.width)
            }
            guard let firstTop = firstLineTop, lastLineBottom > firstTop else { return }

            // 统一垂直内边距：上下严格对称 8pt
            let padV: CGFloat = 8
            let textTop = origin.y + firstTop
            let textBottom = origin.y + lastLineBottom
            let cardTop = textTop - padV
            let cardBottom = textBottom + padV
            let cardHeight = cardBottom - cardTop
            let cardWidth = max(container.size.width, maxLineWidth)

            // 背景衬底（圆角微底板，对应 Theme.Colors.surfaceBadge）
            let bgRect = NSRect(
                x: origin.x,
                y: cardTop,
                width: cardWidth,
                height: cardHeight
            )
            let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6)
            MarkdownInlineNS.adaptiveLabel(opacity: 0.04).setFill()
            bgPath.fill()

            // 左侧 Accent 质感竖线：严格内嵌于 bgRect，上下留出 4pt 安全呼吸感（杜绝任何冒头与贴底）
            let barInsetV: CGFloat = 4
            let barRect = NSRect(
                x: origin.x + 4,
                y: cardTop + barInsetV,
                width: 3,
                height: max(cardHeight - barInsetV * 2, 4)
            )
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
            MarkdownInlineNS.accentColor.setFill()
            barPath.fill()
        }
    }

    private func drawHeading1Dividers(in charRange: NSRange, origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }

        storage.enumerateAttribute(.flowHeading1, in: charRange, options: []) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return }

            let lastGlyph = glyphRange.location + glyphRange.length - 1
            var effectiveRange = NSRange(location: NSNotFound, length: 0)
            let lastLineRect = self.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: &effectiveRange)
            guard !lastLineRect.isEmpty else { return }

            let lineY = origin.y + lastLineRect.maxY - 1
            let dividerRect = NSRect(
                x: origin.x,
                y: lineY,
                width: container.size.width,
                height: 0.5
            )
            MarkdownInlineNS.adaptiveLabel(opacity: 0.09).setFill()
            NSBezierPath(rect: dividerRect).fill()
        }
    }

    private func drawHorizontalRules(in charRange: NSRange, origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }

        storage.enumerateAttribute(.flowHorizontalRule, in: charRange, options: []) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return }

            var effectiveRange = NSRange(location: NSNotFound, length: 0)
            let lineRect = self.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: &effectiveRange)
            guard !lineRect.isEmpty else { return }

            let lineY = origin.y + lineRect.midY
            let dividerRect = NSRect(
                x: origin.x,
                y: lineY,
                width: container.size.width,
                height: 0.5
            )
            MarkdownInlineNS.adaptiveLabel(opacity: 0.09).setFill()
            NSBezierPath(rect: dividerRect).fill()
        }
    }
}

// MARK: - AppKit 原生无拦截轻量文本视图（TextKit 宿主）

final class NonScrollingTextView: NSTextView, NSTextViewDelegate {
    convenience init() {
        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        let layoutManager = FlowLayoutManager()
        layoutManager.addTextContainer(textContainer)
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)
        self.init(frame: .zero, textContainer: textContainer)
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setupDefaults()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupDefaults()
    }

    private func setupDefaults() {
        isEditable = false
        isSelectable = true
        drawsBackground = false
        backgroundColor = .clear
        textColor = .labelColor
        isHorizontallyResizable = false
        // 关键防线：禁止 TextKit 在 ensureLayout 时自动调用 setFrameSize 篡改自身 frame——
        // 视图高度完全由 SwiftUI 的 sizeThatFits 决策，若开启 isVerticallyResizable，
        // AppKit 布局遍历中途 frame 被改会冒泡标记父级 NSHostingView dirty，引发 300 次布局死循环。
        isVerticallyResizable = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        focusRingType = .none
        delegate = self
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // 垂直滚轮手势平滑穿透：让外层聊天窗口的 NSScrollView 自然滚动
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    // 点击链接直接在默认浏览器打开
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL {
            NSWorkspace.shared.open(url)
            return true
        } else if let string = link as? String, let url = URL(string: string) {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }

    @discardableResult
    func setAttributedStringIfNeeded(_ newAttr: NSAttributedString) -> Bool {
        guard let ts = textStorage else { return false }
        if !ts.isEqual(to: newAttr) {
            ts.setAttributedString(newAttr)
            needsDisplay = true
            return true
        }
        return false
    }
}

// MARK: - SwiftUI 包装视图（精确自适应高度 + 离屏无副作用测量缓存）

struct NativeTextFlowView: NSViewRepresentable {
    let attributedString: NSAttributedString

    init(attributedString: NSAttributedString) {
        self.attributedString = attributedString
    }

    final class Coordinator {
        var measuredWidth: CGFloat = -1
        var measuredHeight: CGFloat = 0
        /// 缓存测量时对应的富文本内容快照。
        /// ⚠️ 关键防线（2026-10 事故定证，切勿修改）：
        /// 绝不可仅按 measuredWidth 比对复用缓存！当大模型流式输出或会话渐进分批渲染时，
        /// 同一个 NativeTextFlowView 的富文本内容（如追加了后续列表）会大幅增长。
        /// 若仅判断 width 相同，sizeThatFits 会错误返回旧的较矮高度（例如仅含标题时的 27pt），
        /// 导致外层 ChatMessageActionRow 错误排在正文中间，底层真实文本溢出绘制到操作按钮下方。
        var cachedAttrString: NSAttributedString?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // 独立于任何 NSView 的纯离屏 TextKit 测量栈（仅主线程使用）：
    // 与 NonScrollingTextView 共享完全一致的 lineFragmentPadding = 0 与排版算法，
    // 但不挂载任何视图，确保 sizeThatFits 测量全程零视图树副作用、不触发任何重排冒泡。
    @MainActor
    private static let measureStorage = NSTextStorage()
    @MainActor
    private static let measureLayoutManager: NSLayoutManager = {
        let lm = FlowLayoutManager()
        measureStorage.addLayoutManager(lm)
        return lm
    }()
    @MainActor
    private static let measureContainer: NSTextContainer = {
        let tc = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        measureLayoutManager.addTextContainer(tc)
        return tc
    }()

    @MainActor
    private static func measureHeight(for attr: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attr.length > 0 else { return 0 }
        measureStorage.setAttributedString(attr)
        measureContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        measureLayoutManager.ensureLayout(for: measureContainer)
        let used = measureLayoutManager.usedRect(for: measureContainer)
        var totalHeight = ceil(used.height)

        // 关键防线：若富文本末尾属于引用块，卡片底板在文字墨水底边之下额外延伸了 8pt 的对称内边距。
        // TextKit 的 usedRect 仅测量字形墨水边界，在末尾无换行符时绝不会预留底板向下扩展的空间。
        // 此处必须为末尾卡片底板留足实际视图物理高度（8pt 底部内边距 + 2pt 安全微距），
        // 彻底杜绝卡片底板与其 6pt 底角圆角被父级视图 Frame 边界直角腰斩。
        if attr.length > 0 {
            var hasTrailingQuote = false
            for idx in stride(from: attr.length - 1, through: max(0, attr.length - 10), by: -1) {
                if attr.attribute(.flowBlockquote, at: idx, effectiveRange: nil) != nil {
                    hasTrailingQuote = true
                    break
                }
            }
            if hasTrailingQuote {
                totalHeight += 10
            }
        }

        return totalHeight
    }

    func makeNSView(context: Context) -> NonScrollingTextView {
        let textView = NonScrollingTextView()
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        textView.setAttributedStringIfNeeded(attributedString)
        return textView
    }

    func updateNSView(_ nsView: NonScrollingTextView, context: Context) {
        if nsView.setAttributedStringIfNeeded(attributedString) {
            context.coordinator.measuredWidth = -1
            context.coordinator.cachedAttrString = nil
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NonScrollingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let coordinator = context.coordinator
        // 只有在视口宽度一致，且测量的富文本内容完全一致（引用一致或 isEqual 判定）时，方可安全复用缓存
        if abs(coordinator.measuredWidth - width) < 0.5,
           coordinator.measuredHeight > 0,
           let cached = coordinator.cachedAttrString,
           cached.isEqual(to: attributedString) {
            qsDebugLog("sizeThatFits CACHED width=\(width) height=\(coordinator.measuredHeight) str=\(attributedString.string.prefix(20))...")
            return CGSize(width: width, height: coordinator.measuredHeight)
        }
        let height = Self.measureHeight(for: attributedString, width: width)
        coordinator.measuredWidth = width
        coordinator.measuredHeight = height
        coordinator.cachedAttrString = attributedString
        qsDebugLog("sizeThatFits RECOMPUTED width=\(width) height=\(height) str=\(attributedString.string.prefix(20))...")
        return CGSize(width: width, height: height)
    }
}
