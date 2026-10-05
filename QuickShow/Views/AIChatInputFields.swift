// 从 AIChatView.swift 机械拆分：输入框文本系统（主输入框 / 自定义 NSTextView / 就地编辑输入框）。

import AppKit
import Combine
import SwiftUI

// MARK: - 输入框（NSTextView 包装）

/// NSTextView 包装：实现 ⏎ 发送 / ⇧⏎ 换行 / 中文输入法组字放行 / 图片粘贴与拖入。
/// 为什么不用 SwiftUI TextField/TextEditor：⏎ 语义必须自定义，且必须在 doCommandBy 层
/// 通过 markedRange 判定中文输入法组字，避免组字回车被误判为发送。
struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    /// 输入内容是否为空的独立回写通道：IME 组字期间 SwiftUI 绑定不更新，
    /// 需由 setMarkedText 回调驱动，避免组字文本与 placeholder 重叠。
    @Binding var isInputEmpty: Bool
    let onSubmit: () -> Void
    /// ⌥⏎ 追问：生成中入 follow-up 队列 / 非生成中退化普通发送（语义由调用方承载）。
    let onSubmitFollowUp: () -> Void
    let onEscape: () -> Void
    /// 粘贴/拖入图片（NSImage 数组，由调用方转附件）。
    let onInsertImages: ([NSImage]) -> Void
    /// ⌘⌫ 撤回队首（仅空输入框时由 NSTextView 触发；空队列时调用方静默不动作）。
    let onRecallFirst: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 手工搭建文本系统：scrollableTextView() 返回基类 NSTextView，无法插入自定义子类
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = ChatInputNSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.onEscape = onEscape
        textView.onInsertImages = onInsertImages
        textView.onRecallFirst = onRecallFirst
        // IME 组字（marked text）不触发 textDidChange：靠该回调同步组字文本与空态，
        // 避免 placeholder 重叠，并让绑定不滞后于组字内容（防止 updateNSView 误回写）。
        textView.onContentStateChanged = { [weak coordinator = context.coordinator] in
            guard let coordinator, let tv = coordinator.textView else { return }
            coordinator.syncInputState(tv)
        }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        // 关闭各类自动替换/检查，避免对话输入被系统“纠正”并出现下划线噪音
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        // 内边距与 SwiftUI 占位文案 padding 对齐：左右 18pt（section），垂直 12pt
        //（配 44pt 输入行高视觉近居中；56→44 收紧后同步调整）
        textView.textContainerInset = NSSize(
            width: Theme.Spacing.section,
            height: Theme.Spacing.xxl
        )
        textView.textContainer?.lineFragmentPadding = 0
        // 追加注册图片拖放类型（不影响默认文本拖入；jpeg 无内置常量，用 UTI 字符串）
        textView.registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")])

        let scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        context.coordinator.textView = textView
        context.coordinator.startObservingWindow()
        // 首帧若窗口已就绪则聚焦；窗口后续成为 key 时由观察者兜底聚焦。
        // 若此刻其他 NSTextView（如侧栏重命名 field editor）已持焦点则让位（一致性保险）。
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            if let responder = window.firstResponder as? NSTextView, responder !== textView {
                return
            }
            window.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.onEscape = onEscape
        textView.onInsertImages = onInsertImages
        textView.onRecallFirst = onRecallFirst
        // 外部（发送清空 / ⌘K / 重试）修改文本时回写；仅在内容不一致时写。
        // 关键防线：IME 组字期间（markedRange 非空）绝不做程序化回写——textDidChange 在组字时不触发，
        // 绑定必然滞后于组字文本（如首键 "a" 尚未进绑定），此时回写会摧毁组字导致首字母闪失。
        // 组字提交/取消后 textDidChange（或 syncInputState 回调）会补齐绑定，届时再对账。
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObservingWindow()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        weak var textView: ChatInputNSTextView?

        init(_ parent: ChatInputTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // 提交/普通输入：合并同步 text 与空态（仅在不等时写，避免与 updateNSView 形成回写回路）
            syncInputState(tv)
        }

        /// 同步输入状态（供 textDidChange 与 IME setMarkedText/unmarkText 回调共用）：
        /// - 组字期间 textDidChange 不触发，绑定会滞后；这里把组字文本实时写入 parent.text，
        ///   使 `.onChange(of: state.inputText)` 与 updateNSView 对账天然一致；
        /// - 组字取消 setMarkedText("") 时绑定随之清空，placeholder 正确恢复；
        /// - 同时刷新 isInputEmpty（独立于 state.inputText 的 placeholder 通道）。
        func syncInputState(_ tv: NSTextView) {
            if parent.text != tv.string {
                parent.text = tv.string
            }
            let empty = tv.string.isEmpty
            if parent.isInputEmpty != empty {
                parent.isInputEmpty = empty
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // ⏎：中文 IME 组字期间 markedRange 非空 → 放行给输入法先提交候选字，绝不触发发送
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if textView.hasMarkedText() { return false }
                if NSEvent.modifierFlags.contains(.shift) {
                    // ⇧⏎ 换行：忽略 field editor 语义，强制插入软换行（⌥⇧⏎ 同按 ⇧ 处理）
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else if NSEvent.modifierFlags.contains(.option) {
                    // ⌥⏎ 追问（组字守卫与 ⏎ 一致，上面已先行放行输入法）
                    parent.onSubmitFollowUp()
                } else {
                    parent.onSubmit()
                }
                return true
            }
            // ⇧⏎ / ⌥⏎ 在默认键绑定（$↩ / ~↩）下多映射为该命令：
            // ⌥⏎ → 追问（组字守卫同上）；⇧⏎ 及其余 → 交给默认实现插入换行
            if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                if NSEvent.modifierFlags.contains(.option), !NSEvent.modifierFlags.contains(.shift) {
                    if textView.hasMarkedText() { return false }
                    parent.onSubmitFollowUp()
                    return true
                }
                return false
            }
            return false
        }

        /// 监听窗口成为 key：保证 AI 窗每次唤出时输入框拿到第一响应者。
        /// 同挂抽屉关闭通知：抽屉内的自由输入条持焦期间点提交/取消，
        /// 焦点随抽屉移除悬空，须主动归还主输入框。
        func startObservingWindow() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(refocusInputRequested(_:)),
                name: .aiChatRefocusInput,
                object: nil
            )
        }

        func stopObservingWindow() {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func windowDidBecomeKey(_ note: Notification) {
            guard let window = note.object as? NSWindow,
                  window === textView?.window else { return }
            // 侧栏行内重命名等文本控件已持焦点时让位，不抢占第一响应者
            // （重命名 TextField 的 field editor 也是 NSTextView；区别于本输入框）
            if let responder = window.firstResponder as? NSTextView, responder !== textView {
                return
            }
            window.makeFirstResponder(textView)
        }

        /// 抽屉关闭后焦点归还：其他文本控件（如侧栏重命名 field editor）持焦时同样让位。
        @objc private func refocusInputRequested(_ note: Notification) {
            guard let textView, let window = textView.window else { return }
            if let responder = window.firstResponder as? NSTextView, responder !== textView {
                return
            }
            window.makeFirstResponder(textView)
        }
    }
}

/// 自定义 NSTextView：ESC 触发注入回调（先中止/后关窗由调用方决定）；
/// 粘贴/拖入图片优先转附件（剪贴板或拖拽源含图片时消费，不落入文本）。
/// FloatingPanel 系面板对 firstResponder is NSTextView 全键放行，ESC 可能直达此处；
/// 由 AIChatView.handleEscape 承载两阶段语义；无回调时走默认 cancelOperation。
final class ChatInputNSTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onInsertImages: (([NSImage]) -> Void)?
    /// ⌘⌫ 撤回队首回调（仅输入框为空且非组字时触发；有文字时 ⌘⌫ 保留系统「删到行首」语义）。
    var onRecallFirst: (() -> Void)?
    /// 内容状态变化回调（IME 组字/取消组字时 textDidChange 不触发，需单独通知 placeholder）。
    var onContentStateChanged: (() -> Void)?

    /// IME 组字更新：marked text 变化不触发 textDidChange，这里主动通知空态变化。
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onContentStateChanged?()
    }

    /// 取消/提交组字：ESC 取消组字会走 unmarkText（string 可能回到空），同样通知空态。
    override func unmarkText() {
        super.unmarkText()
        onContentStateChanged?()
    }

    // 无 Edit 菜单的轻量应用里，文本系统的标准编辑键等效可能不被派发——
    // 显式接住，保证 ⌘V 粘贴 / ⌘C 拷贝 / ⌘X 剪切 / ⌘A 全选任何环境下可用
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 9: paste(nil); return true       // V
            case 8: copy(nil); return true        // C
            case 7: cut(nil); return true         // X
            case 0: selectAll(nil); return true   // A
            case 51:                              // ⌫
                // ⌘⌫：仅空输入框（且非 IME 组字中）消费为「撤回队首」——撤回后文字回填进
                // 输入框，心智自洽；有文字时放行，保留系统 ⌘⌫「删到行首」语义，不吞正常编辑。
                if string.isEmpty, !hasMarkedText(), let onRecallFirst {
                    onRecallFirst()
                    return true
                }
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// 粘贴：剪贴板含图片（截图位图 / Finder 图片文件）时优先转为图片附件，否则走默认文本粘贴。
    override func paste(_ sender: Any?) {
        let images = PasteboardImageExtractor.images(from: NSPasteboard.general)
        if !images.isEmpty {
            onInsertImages?(images)
            return
        }
        super.paste(sender)
    }

    /// 拖入：拖拽源含图片时高亮接收并转附件，否则交给默认文本拖放。
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if PasteboardImageExtractor.containsImage(sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = PasteboardImageExtractor.images(from: sender.draggingPasteboard)
        if !images.isEmpty {
            onInsertImages?(images)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape {
            onEscape()
        } else {
            super.cancelOperation(sender)
        }
    }
}

// MARK: - 就地编辑输入框（最后一轮 user 消息）

/// 就地编辑输入框：与主输入框 ChatInputTextView 同源语义——⏎ 确认 / ⇧⏎ 换行 /
/// 中文 IME 组字放行 / ESC 取消 / 图片粘贴追加附件，复用 ChatInputNSTextView 子类。
/// 差异：不挂窗口级焦点观察（只在进入编辑态时主动拿一次焦点，避免与主输入框抢响应者）；
/// 内容高度经 contentHeight 实测回写，驱动编辑气泡随文本自适应生长（封顶后内部滚动）。
struct ChatInlineEditTextView: NSViewRepresentable {
    @Binding var text: String
    /// 内容高度回写（编辑气泡 frame 高度的唯一来源）。
    @Binding var contentHeight: CGFloat
    let onSubmit: () -> Void
    let onEscape: () -> Void
    /// 粘贴/拖入图片（NSImage 数组，由调用方转附件）。
    let onInsertImages: ([NSImage]) -> Void

    /// 高度下限（单行 13pt ≈ 17）与上限（封顶后由内置 scrollView 滚动）。
    private let minHeight: CGFloat = 18
    private let maxHeight: CGFloat = 160

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 手工搭建文本系统（与主输入框同理：scrollableTextView() 无法插入自定义子类）
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = ChatInputNSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.onEscape = onEscape
        textView.onInsertImages = onInsertImages
        // IME 组字（marked text）不触发 textDidChange：靠该回调同步草稿文本与高度
        textView.onContentStateChanged = { [weak coordinator = context.coordinator] in
            guard let coordinator, let tv = coordinator.textView else { return }
            coordinator.syncState(tv)
        }
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        // 关闭各类自动替换/检查（与主输入框同一纪律，避免编辑被系统"纠正"）
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        // 编辑气泡的内边距已由外层 padding 承担，文本系统零内边距（高度回写即纯文本高）
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // 追加注册图片拖放类型（与主输入框一致）
        textView.registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")])
        textView.string = text

        let scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        context.coordinator.textView = textView
        // 进入编辑态：首帧布局后同步初始高度、聚焦并把光标移到文尾
        DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
            guard let textView else { return }
            coordinator?.syncState(textView)
            guard let window = textView.window else { return }
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.onEscape = onEscape
        textView.onInsertImages = onInsertImages
        // 外部回写防线与主输入框一致：IME 组字期间绝不程序化改写（防摧毁组字）
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        context.coordinator.syncHeight(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInlineEditTextView
        weak var textView: ChatInputNSTextView?

        init(_ parent: ChatInlineEditTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            syncState(tv)
        }

        /// 合并同步草稿文本与高度（textDidChange 与 IME 组字回调共用；仅在不等时写，防回写回路）。
        func syncState(_ tv: NSTextView) {
            if parent.text != tv.string {
                parent.text = tv.string
            }
            syncHeight(tv)
        }

        /// 内容高度对账：usedRect 实测文本高，钳制到 [minHeight, maxHeight] 后回写。
        func syncHeight(_ tv: NSTextView) {
            guard let layoutManager = tv.layoutManager, let textContainer = tv.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let fitted = layoutManager.usedRect(for: textContainer).height
            let clamped = min(max(fitted, parent.minHeight), parent.maxHeight)
            if abs(parent.contentHeight - clamped) > 0.5 {
                parent.contentHeight = clamped
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // ⏎：中文 IME 组字期间 markedRange 非空 → 放行给输入法先提交候选字，绝不触发确认
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if textView.hasMarkedText() { return false }
                if NSEvent.modifierFlags.contains(.shift) {
                    // ⇧⏎ 换行：忽略 field editor 语义，强制插入软换行
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            // ⇧⏎ 在部分系统路径下映射为该命令：交给默认实现插入换行
            if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                return false
            }
            return false
        }
    }
}
