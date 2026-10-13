import AppKit
import CoreText
import SwiftUI

// MARK: - 诗歌注音对齐模型

/// 诗词/歌赋对仗行结构：将连续注音字符拆为按列对齐的网格单元，保留行末标点。
struct RubyVerseLine: Equatable {
    struct Item: Equatable {
        let base: [InlineToken]
        let ruby: String
        let position: RubyPosition
    }
    let items: [Item]
    let trailingPunctuation: String
}

// MARK: - 诗句行识别判定扩展

extension Array where Element == InlineToken {
    /// 尝试将当前行内 Token 解析为诗词/对仗句式行结构。
    /// 当段落中全部行均为纯注音字序列（加行末标点）时判定为诗词网格模式，实现教科书级的字字垂直对齐。
    func parseRubyVerseLines() -> [RubyVerseLine]? {
        var rawLines: [[InlineToken]] = []
        var currentLine: [InlineToken] = []

        func flushLine() {
            if !currentLine.isEmpty {
                rawLines.append(currentLine)
                currentLine.removeAll()
            }
        }

        for token in self {
            switch token {
            case .lineBreak:
                flushLine()
            case let .text(str):
                if str.contains("\n") {
                    let parts = str.components(separatedBy: "\n")
                    for (idx, part) in parts.enumerated() {
                        if !part.isEmpty {
                            currentLine.append(.text(part))
                        }
                        if idx < parts.count - 1 {
                            flushLine()
                        }
                    }
                } else {
                    currentLine.append(token)
                }
            default:
                currentLine.append(token)
            }
        }
        flushLine()

        guard !rawLines.isEmpty else { return nil }

        let punctuationSet = CharacterSet(charactersIn: "，。！？；：、,.!?;: ")
        var verseLines: [RubyVerseLine] = []

        for lineTokens in rawLines {
            var items: [RubyVerseLine.Item] = []
            var trailingPunct = ""
            var otherTextCount = 0
            var hasSeenPunctuation = false

            for token in lineTokens {
                switch token {
                case let .ruby(base, ruby, position):
                    // 若在标点之后再次出现注音汉字，说明是行内逗号切分的复合句（文赋/散文），绝非单行诗句
                    if hasSeenPunctuation {
                        return nil
                    }
                    items.append(RubyVerseLine.Item(base: base, ruby: ruby, position: position))
                case let .text(txt):
                    let trimmed = txt.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }
                    if trimmed.unicodeScalars.allSatisfy({ punctuationSet.contains($0) }) {
                        hasSeenPunctuation = true
                        trailingPunct.append(trimmed)
                    } else {
                        otherTextCount += trimmed.count
                    }
                default:
                    otherTextCount += 1
                }
            }

            // 诗词单行硬性判准：
            // 1. 每行注音字数严格在 3 到 8 个字之间（三言、四言、五言、六言、七言、八言）
            // 2. 行内无大段普通非注音文本（otherTextCount == 0）
            // 3. 行末标点长度不超过 2 个字符（避免多重标点错位累加）
            guard items.count >= 3, items.count <= 8, otherTextCount == 0, trailingPunct.count <= 2 else {
                return nil
            }
            verseLines.append(RubyVerseLine(items: items, trailingPunctuation: trailingPunct))
        }

        // 多行诗句一致性校验：各行字数差不超过 1（律绝严谨对仗，散文各句长短悬殊）
        if verseLines.count >= 2 {
            let minCount = verseLines.map(\.items.count).min() ?? 0
            let maxCount = verseLines.map(\.items.count).max() ?? 0
            guard maxCount - minCount <= 1 else { return nil }
        }

        return verseLines
    }
}

// MARK: - 诗词网格列对齐视图（Poetry Ruby Grid View）

/// 专为诗词绝句设计的等宽网格排版视图：跨段落采用统一列宽，汉字与拼音严格居中对齐，标点在末字紧随。
private struct PoetryRubyGridView: View {
    let verseLines: [RubyVerseLine]
    var baseSize: CGFloat = 13.5
    var weight: Font.Weight = .regular
    var bodyColor: Color = Color.primary.opacity(0.85)

    private var rubySize: CGFloat {
        max(baseSize * 0.58, 8.5)
    }

    /// 统一标准列宽：
    /// 中文拼音最长为 6 字母（如 chuáng, shuāng），8.5pt 下约 28pt；汉字约 14pt；
    /// 统一设为 38pt（随 baseSize 微调），确保一首诗的不同小节之间每一列绝对纵向对齐。
    private var colWidth: CGFloat {
        max(baseSize * 2.8, 38)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(Array(verseLines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    ForEach(Array(line.items.enumerated()), id: \.offset) { itemIdx, item in
                        let isLast = itemIdx == line.items.count - 1
                        let punct = isLast ? line.trailingPunctuation : nil
                        rubyItemView(item, trailingPunct: punct)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rubyItemView(_ item: RubyVerseLine.Item, trailingPunct: String?) -> some View {
        switch item.position {
        case .over:
            VStack(alignment: .center, spacing: 2) {
                Text(item.ruby)
                    .font(Theme.Typography.text(rubySize, .regular))
                    .foregroundColor(bodyColor.opacity(0.75))
                    .lineLimit(1)
                baseWithPunctuation(item.base, punct: trailingPunct)
            }
            .frame(width: colWidth)

        case .right:
            HStack(alignment: .lastTextBaseline, spacing: 1) {
                baseWithPunctuation(item.base, punct: trailingPunct)
                Text(item.ruby)
                    .font(Theme.Typography.text(rubySize, .regular))
                    .foregroundColor(bodyColor.opacity(0.75))
                    .lineLimit(1)
            }
            .frame(width: colWidth)

        case .under:
            VStack(alignment: .center, spacing: 2) {
                baseWithPunctuation(item.base, punct: trailingPunct)
                Text(item.ruby)
                    .font(Theme.Typography.text(rubySize, .regular))
                    .foregroundColor(bodyColor.opacity(0.75))
                    .lineLimit(1)
            }
            .frame(width: colWidth)
        }
    }

    @ViewBuilder
    private func baseWithPunctuation(_ base: [InlineToken], punct: String?) -> some View {
        HStack(spacing: 0) {
            Text(MarkdownInline.render(base, bodyColor: bodyColor, size: baseSize, baseWeight: weight))
            if let punct, !punct.isEmpty {
                Text(punct)
                    .font(Theme.Typography.text(baseSize, weight))
                    .foregroundColor(bodyColor)
            }
        }
        .fixedSize()
    }
}

// MARK: - CoreText Ruby 散文排版视图

/// 专为散文混排设计的原生 CoreText 渲染视图：支持连续文本自然流折行与出版级垂直行距。
final class RubyTextNSView: NSView {
    var attributedString: NSAttributedString = NSAttributedString() {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              attributedString.length > 0 else { return }

        let bounds = self.bounds
        let vPadding: CGFloat = 3
        let drawHeight = bounds.height - vPadding * 2
        guard drawHeight > 0 else { return }

        let framesetter = CTFramesetterCreateWithAttributedString(attributedString as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 0, y: vPadding, width: bounds.width, height: drawHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributedString.length), path, nil)

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1.0, y: -1.0)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    override func accessibilityLabel() -> String? {
        attributedString.string
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .staticText
    }
}

private struct RubyProseRepresentable: NSViewRepresentable {
    let inlines: [InlineToken]
    var baseSize: CGFloat = 13.5
    var weight: Font.Weight = .regular
    var color: Color = Color.primary.opacity(0.80)

    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> RubyTextNSView {
        let view = RubyTextNSView()
        updateContent(in: view)
        return view
    }

    func updateNSView(_ nsView: RubyTextNSView, context: Context) {
        updateContent(in: nsView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RubyTextNSView, context: Context) -> CGSize? {
        if nsView.attributedString.length == 0 {
            updateContent(in: nsView)
        }
        guard nsView.attributedString.length > 0 else { return nil }
        let width = (proposal.width != nil && proposal.width! > 0 && proposal.width!.isFinite) ? proposal.width! : 400
        let framesetter = CTFramesetterCreateWithAttributedString(nsView.attributedString as CFAttributedString)
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: nsView.attributedString.length),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            &fitRange
        )
        // 增加 8pt（对应 top/bottom 各 3~4pt 绘制安全边距），防止顶部拼音声调被边缘裁切
        return CGSize(width: width, height: ceil(suggested.height) + 8)
    }

    private func updateContent(in view: RubyTextNSView) {
        let nsColor = MathRasterizer.resolvedColor(color, appearance: MathRasterizer.appearance(for: colorScheme))
        let nsFont = MarkdownInlineNS.font(size: baseSize, weight: MarkdownInlineNS.nsWeight(weight))
        let renderResult = MarkdownInlineNS.renderNS(
            inlines,
            baseFont: nsFont,
            baseColor: nsColor,
            baseSize: baseSize
        )

        let mutable = NSMutableAttributedString(attributedString: renderResult.attributed)
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = 11
        pStyle.minimumLineHeight = 26
        pStyle.lineBreakMode = .byWordWrapping
        mutable.addAttribute(
            .paragraphStyle,
            value: pStyle,
            range: NSRange(location: 0, length: mutable.length)
        )

        if !view.attributedString.isEqual(to: mutable) {
            view.attributedString = mutable
        }
    }
}

// MARK: - 对外统一 Ruby 段落入口

/// 自动根据内容结构在「诗词等宽网格」与「散文流式」之间自适应分流：
/// - 诗词/歌赋：触发等宽网格，首字、尾字与标点严丝合缝垂直对齐；
/// - 普通散文：走 CoreText 原生流式排版，享受自然折行与微观字距。
struct RubyParagraphView: View {
    let inlines: [InlineToken]
    var baseSize: CGFloat = 13.5
    var weight: Font.Weight = .regular
    var color: Color = Color.primary.opacity(0.80)

    var body: some View {
        if let verseLines = inlines.parseRubyVerseLines() {
            PoetryRubyGridView(
                verseLines: verseLines,
                baseSize: baseSize,
                weight: weight,
                bodyColor: color
            )
        } else {
            RubyProseRepresentable(
                inlines: inlines,
                baseSize: baseSize,
                weight: weight,
                color: color
            )
        }
    }
}
