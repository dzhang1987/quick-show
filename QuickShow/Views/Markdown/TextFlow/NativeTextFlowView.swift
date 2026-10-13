import SwiftUI
import AppKit

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

    init(attributedString: NSAttributedString) {
        self.attributedString = attributedString
    }

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
