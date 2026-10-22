import SwiftUI
import AppKit

// MARK: - 引用块渲染器

final class MarkdownBlockquoteRenderer: MarkdownBlockRenderer {
    var priority: Int { 10 }

    func canRender(block: MarkdownBlock) -> Bool {
        if case .blockquote = block { return true }
        return false
    }

    func capabilities(for block: MarkdownBlock) -> BlockCapabilities {
        guard case let .blockquote(blocks) = block else { return .interactiveWidget }
        // 凡是子块全部为 TextFlow 兼容的引用块，均整体合流进入原生连续文本流，支持跨块连贯拖选
        if blocks.allSatisfy({ MarkdownBlockSegmenter.isTextFlowCompatible($0) }) {
            return .textFlowCompatible
        }
        return .interactiveWidget
    }

    func topSpacing(for block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat? {
        if let prev = previous, case .heading = prev { return Theme.Spacing.lg }
        return Theme.Spacing.card
    }

    func appendTextFlow(
        block: MarkdownBlock,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString,
        context: MarkdownRenderContext
    ) {
        guard case let .blockquote(blocks) = block, !blocks.isEmpty else { return }
        let startIndex = result.length

        for (index, child) in blocks.enumerated() {
            let isLast = (index == blocks.count - 1)
            let childNext = isLast ? nextBlock : blocks[index + 1]
            let renderer = MarkdownBlockRegistry.shared.renderer(for: child)
            renderer.appendTextFlow(block: child, nextBlock: childNext, into: result, context: context)
        }

        let blockquoteLength = result.length - startIndex
        guard blockquoteLength > 0 else { return }
        let blockquoteRange = NSRange(location: startIndex, length: blockquoteLength)

        // 打上 flowBlockquote 属性供 FlowLayoutManager 绘制左侧装饰细竖条与轻背景
        result.addAttribute(.flowBlockquote, value: true, range: blockquoteRange)

        // 为引文块内所有段落增加 18pt 缩进，为左侧细竖条与边距预留呼吸空间
        let quoteIndent: CGFloat = 18
        var ranges: [NSRange] = []
        result.enumerateAttribute(.paragraphStyle, in: blockquoteRange, options: []) { _, range, _ in
            ranges.append(range)
        }

        for (idx, range) in ranges.enumerated() {
            let value = result.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent += quoteIndent
            style.headIndent += quoteIndent
            style.tailIndent = -quoteIndent

            // 关键几何对齐：若内部含有制表位（如列表项），必须同步平移制表位位置！
            // 否则光标在首行缩进后超过原制表位，排版引擎会强制换行导致标号与文本断裂排成两行。
            if !style.tabStops.isEmpty {
                style.tabStops = style.tabStops.map { tab in
                    NSTextTab(textAlignment: tab.alignment, location: tab.location + quoteIndent, options: tab.options)
                }
            }

            // 引文内首段增加 8pt 顶部呼吸内边距空间，与卡片底板向上扩展的 8pt 形成对称呼吸
            if idx == 0 {
                style.paragraphSpacingBefore += 8
            }

            // 引文内部非末尾段落的段间距紧致收敛（如“正确测试方式：”与后续列表之间收紧至 4pt，彻底消除空洞）
            let isLastRange = (idx == ranges.count - 1)
            if !isLastRange {
                style.paragraphSpacing = min(style.paragraphSpacing, 4)
            } else {
                // 末尾段后留出 8pt 底板内边距空间；若后续还有下一个块，追加 14pt 块间外边距
                style.paragraphSpacing = 8 + (nextBlock != nil ? 14 : 0)
            }

            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    func renderWidget(block: MarkdownBlock, context: MarkdownRenderContext) -> AnyView {
        guard case let .blockquote(blocks) = block else { return AnyView(EmptyView()) }
        return AnyView(MarkdownBlockquoteView(blocks: blocks))
    }
}

// MARK: - 独立引用块视图

struct MarkdownBlockquoteView: View {
    let blocks: [MarkdownBlock]

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                MarkdownBlockView(block: child)
            }
        }
        .foregroundColor(Theme.Colors.contentSecondaryStrong)
        .padding(.leading, Theme.Spacing.xl + 3)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.Colors.accent.opacity(0.80), Theme.Colors.accent.opacity(0.50)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 3)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .fill(Theme.Colors.surfaceBadge)
        )
    }
}
