import SwiftUI
import AppKit

// MARK: - 混合排版渲染段（Display Segment）

/// 混合排版片段：将 Markdown AST 切分为连续原生排版文本流与独立交互岛屿。
/// - textFlow: 连续的标题、段落、列表项合并为统一 NSAttributedString，由 AppKit 原生 TextKit 渲染，
///   完美支持 NSTextTab 两列对齐、悬挂缩进（headIndent）、精确段落与列表间距（paragraphSpacing），
///   并支持全篇真正一拖到底的系统级连续划选与复制。
/// - widget: 代码块（带复制按钮与横滚）、表格、公式、图片段落等保留为独立 SwiftUI 组件。
enum MarkdownDisplaySegment: Identifiable, Equatable {
    case textFlow(id: String, content: NSAttributedString, topSpacing: CGFloat)
    case widget(id: String, block: MarkdownBlock, topSpacing: CGFloat)

    var id: String {
        switch self {
        case let .textFlow(id, _, _): return id
        case let .widget(id, _, _): return id
        }
    }

    var topSpacing: CGFloat {
        switch self {
        case let .textFlow(_, _, spacing): return spacing
        case let .widget(_, _, spacing): return spacing
        }
    }

    static func == (lhs: MarkdownDisplaySegment, rhs: MarkdownDisplaySegment) -> Bool {
        switch (lhs, rhs) {
        case let (.textFlow(id1, content1, s1), .textFlow(id2, content2, s2)):
            return id1 == id2 && s1 == s2 && content1.isEqual(to: content2)
        case let (.widget(id1, b1, s1), .widget(id2, b2, s2)):
            return id1 == id2 && s1 == s2 && b1 == b2
        default:
            return false
        }
    }
}

// MARK: - 线性分段切分器

enum MarkdownBlockSegmenter {
    /// 判断某个块是否可以直接进入连续单文本流
    static func isTextFlowCompatible(_ block: MarkdownBlock) -> Bool {
        switch block {
        case let .heading(level, inlines):
            // H2 ~ H6 为纯排版标题；H1 带有底部分割线 Rectangle，作为独立 widget 渲染以保质感
            return level >= 2 && !inlines.containsImage && !inlines.containsMath
        case let .paragraph(inlines):
            // 普通段落无图片、无行内公式时直接进入文本流
            return !inlines.containsImage && !inlines.containsMath
        case let .orderedList(items), let .unorderedList(items):
            // 列表项全部为文本流兼容块时整体进入文本流
            return items.allSatisfy { isListItemTextFlowCompatible($0) }
        default:
            return false
        }
    }

    private static func isListItemTextFlowCompatible(_ item: MarkdownListItem) -> Bool {
        item.blocks.allSatisfy { block in
            switch block {
            case let .paragraph(inlines):
                return !inlines.containsImage && !inlines.containsMath
            case let .orderedList(subItems), let .unorderedList(subItems):
                return subItems.allSatisfy { isListItemTextFlowCompatible($0) }
            default:
                return false
            }
        }
    }

    /// 将 AST 块列表聚合为分段列表
    static func segment(_ blocks: [MarkdownBlock]) -> [MarkdownDisplaySegment] {
        var segments: [MarkdownDisplaySegment] = []
        var textBuffer: [MarkdownBlock] = []
        var counter = 0
        var lastFlushedBlock: MarkdownBlock? = nil

        func flushTextBuffer() {
            guard !textBuffer.isEmpty, let firstBlock = textBuffer.first else { return }
            let spacing = lastFlushedBlock != nil ? firstBlock.topSpacing(after: lastFlushedBlock!) : 0
            let attr = MarkdownTextFlowBuilder.build(from: textBuffer)
            segments.append(.textFlow(id: "flow_\(counter)", content: attr, topSpacing: spacing))
            counter += 1
            lastFlushedBlock = textBuffer.last
            textBuffer.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            if isTextFlowCompatible(block) {
                textBuffer.append(block)
            } else {
                flushTextBuffer()
                let spacing = lastFlushedBlock != nil ? block.topSpacing(after: lastFlushedBlock!) : 0
                segments.append(.widget(id: "widget_\(counter)", block: block, topSpacing: spacing))
                counter += 1
                lastFlushedBlock = block
            }
        }
        flushTextBuffer()
        return segments
    }
}

// MARK: - 文本流 NSAttributedString 生成器（TextKit 殿堂级精密排版版）

enum MarkdownTextFlowBuilder {
    /// 将连续的普通文本块拼装为单个具备层次样式的 NSAttributedString
    static func build(from blocks: [MarkdownBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let next = index < blocks.count - 1 ? blocks[index + 1] : nil
            append(block: block, nextBlock: next, into: result)
        }
        return result
    }

    private static func append(
        block: MarkdownBlock,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString
    ) {
        switch block {
        case let .heading(level, inlines):
            appendHeading(level: level, inlines: inlines, nextBlock: nextBlock, into: result)
        case let .paragraph(inlines):
            appendParagraph(inlines: inlines, nextBlock: nextBlock, into: result)
        case let .orderedList(items):
            appendList(items: items, ordered: true, depth: 0, nextBlock: nextBlock, into: result)
        case let .unorderedList(items):
            appendList(items: items, ordered: false, depth: 0, nextBlock: nextBlock, into: result)
        default:
            break
        }
    }

    // MARK: - 标题排版
    private static func appendHeading(
        level: Int,
        inlines: [InlineToken],
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString
    ) {
        let (size, weight): (CGFloat, NSFont.Weight) = {
            switch level {
            case 2: return (16, .semibold)
            case 3: return (14, .semibold)
            case 4: return (13, .semibold)
            case 5: return (12.5, .semibold)
            default: return (12, .semibold)
            }
        }()

        let font = MarkdownInlineNS.font(size: size, weight: weight)
        let render = MarkdownInlineNS.renderNS(
            inlines,
            baseFont: font,
            baseColor: .labelColor,
            baseSize: size
        )
        let headingPiece = NSMutableAttributedString(attributedString: render.attributed)

        let hasNext = nextBlock != nil
        if hasNext {
            headingPiece.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = hasNext ? 8 : 0 // 标题紧随内容收紧成组
        headingPiece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: headingPiece.length))

        result.append(headingPiece)
    }

    // MARK: - 段落排版
    private static func appendParagraph(
        inlines: [InlineToken],
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString
    ) {
        let baseFont = MarkdownInlineNS.font(size: 13, weight: .regular)
        let baseColor = MarkdownInlineNS.adaptiveLabel(opacity: 0.80)
        let render = MarkdownInlineNS.renderNS(
            inlines,
            baseFont: baseFont,
            baseColor: baseColor,
            baseSize: 13
        )
        let paraPiece = NSMutableAttributedString(attributedString: render.attributed)

        let hasNext = nextBlock != nil
        if hasNext {
            paraPiece.append(NSAttributedString(string: "\n", attributes: [.font: baseFont, .foregroundColor: baseColor]))
        }

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        // 间距节奏：紧随标题前拉开大锚点（20pt）；紧随段落/列表舒适 14pt；末段为 0
        if let next = nextBlock {
            if case .heading = next {
                style.paragraphSpacing = 20
            } else {
                style.paragraphSpacing = 14
            }
        } else {
            style.paragraphSpacing = 0
        }
        paraPiece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paraPiece.length))

        result.append(paraPiece)
    }

    // MARK: - 列表排版（NSTextTab 两列精密对齐）
    private static func appendList(
        items: [MarkdownListItem],
        ordered: Bool,
        depth: Int,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString
    ) {
        for (idx, item) in items.enumerated() {
            let isLastInCurrentList = (idx == items.count - 1)
            let nextBlockForLastItem = isLastInCurrentList ? nextBlock : nil
            appendListItem(
                item: item,
                ordered: ordered,
                depth: depth,
                isLastItem: isLastInCurrentList,
                nextBlock: nextBlockForLastItem,
                into: result
            )
        }
    }

    private static func appendListItem(
        item: MarkdownListItem,
        ordered: Bool,
        depth: Int,
        isLastItem: Bool,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString
    ) {
        let itemPiece = NSMutableAttributedString()

        // 1. 前导标号与制表符（\t 实现精准两列对齐，彻底告别单空格贴脸）
        let prefixText: String
        let prefixFont: NSFont
        let prefixColor: NSColor
        var baselineOffset: CGFloat = 0

        if let state = item.taskState {
            prefixText = (state ? "✓" : "○") + "\t"
            prefixFont = MarkdownInlineNS.font(size: 12.5, weight: .medium)
            prefixColor = state ? MarkdownInlineNS.accentColor : NSColor.tertiaryLabelColor
        } else if ordered {
            prefixText = "\(item.number ?? 1).\t"
            prefixFont = MarkdownInlineNS.monoFont(size: 12)
            prefixColor = NSColor.secondaryLabelColor
        } else {
            prefixText = (depth == 0 ? "•" : "◦") + "\t"
            prefixFont = MarkdownInlineNS.font(size: 12, weight: .medium)
            prefixColor = NSColor.secondaryLabelColor
            if depth == 0 && item.taskState == nil {
                baselineOffset = 0.5 // 中文混排下圆点几何居中光学微调
            }
        }

        var prefixAttrs: [NSAttributedString.Key: Any] = [
            .font: prefixFont,
            .foregroundColor: prefixColor,
        ]
        if baselineOffset != 0 {
            prefixAttrs[.baselineOffset] = baselineOffset
        }
        itemPiece.append(NSAttributedString(string: prefixText, attributes: prefixAttrs))

        // 2. 正文内容
        let bodyOpacity: CGFloat = item.taskState == true ? 0.55 : 0.80
        var subLists: [(items: [MarkdownListItem], ordered: Bool)] = []

        let bodyFont = MarkdownInlineNS.font(size: 13, weight: .regular)
        let bodyColor = MarkdownInlineNS.adaptiveLabel(opacity: bodyOpacity)

        for block in item.blocks {
            switch block {
            case let .paragraph(inlines):
                let bodyRender = MarkdownInlineNS.renderNS(
                    inlines,
                    baseFont: bodyFont,
                    baseColor: bodyColor,
                    baseSize: 13
                )
                itemPiece.append(bodyRender.attributed)
            case let .orderedList(subItems):
                subLists.append((subItems, true))
            case let .unorderedList(subItems):
                subLists.append((subItems, false))
            default:
                break
            }
        }

        // 是否需要追加末尾换行
        let needsTrailingNewline = !isLastItem || nextBlock != nil || !subLists.isEmpty
        if needsTrailingNewline {
            itemPiece.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        }

        // 3. 悬挂缩进 + NSTextTab 精准两列对齐
        // 有序列表 14pt 标号 + 10pt 呼吸留白 = 24pt；任务列表 = 20pt；无序列表圆点 + 10pt 留白 = 18pt
        let baseIndent: CGFloat = CGFloat(depth) * 22
        let hangingOffset: CGFloat = item.taskState != nil ? 20 : (ordered ? 24 : 18)
        let hangingIndent: CGFloat = baseIndent + hangingOffset

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        style.firstLineHeadIndent = baseIndent
        style.headIndent = hangingIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: hangingIndent)]

        // 项间与退出留白节奏：
        // 子列表存在时：父项正文到子列表紧随 6pt
        // 当前项不是最后一项：项间 10pt 呼吸留白（对齐第一张图的通透感，彻底告别文字墙）
        // 当前项是列表最后一项：
        //   - 若后随标题：22pt（大组锚点）
        //   - 若后随段落：16pt（清晰步出列表）
        //   - 若为整段末尾：0pt
        if !subLists.isEmpty {
            style.paragraphSpacing = 6
        } else if !isLastItem {
            style.paragraphSpacing = 10
        } else if let next = nextBlock {
            if case .heading = next {
                style.paragraphSpacing = 22
            } else {
                style.paragraphSpacing = 16
            }
        } else {
            style.paragraphSpacing = 0
        }

        itemPiece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: itemPiece.length))
        result.append(itemPiece)

        // 4. 递归追加子列表
        for (sIdx, sub) in subLists.enumerated() {
            let isLastSub = sIdx == subLists.count - 1
            let nextForSub = isLastSub ? nextBlock : nil
            appendList(items: sub.items, ordered: sub.ordered, depth: depth + 1, nextBlock: nextForSub, into: result)
        }
    }
}

// MARK: - AppKit 原生无拦截轻量文本视图（TextKit 宿主）

final class NonScrollingTextView: NSTextView, NSTextViewDelegate {
    convenience init() {
        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
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

    final class Coordinator {
        var measuredWidth: CGFloat = -1
        var measuredHeight: CGFloat = 0
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
        let lm = NSLayoutManager()
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
        return ceil(used.height)
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
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NonScrollingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let coordinator = context.coordinator
        if abs(coordinator.measuredWidth - width) < 0.5, coordinator.measuredHeight > 0 {
            return CGSize(width: width, height: coordinator.measuredHeight)
        }
        let height = Self.measureHeight(for: attributedString, width: width)
        coordinator.measuredWidth = width
        coordinator.measuredHeight = height
        return CGSize(width: width, height: height)
    }
}
