import AppKit
import SwiftUI

// MARK: - 表格内容驱动列宽布局

/// MarkdownTableView 的列宽计算器（2026-11 横滚重设计）：
/// - 每列取全部单元格（含表头）单行理想宽度的最大值，经 AppKit 渲染路径同步测量
///   （字体与渲染严格一致，含行内代码 / 加粗等混合字体；公式走占位路径，不触发光栅化）；
/// - 夹取到 [chatTableMinColumnWidth, chatTableMaxColumnWidth]；
/// - 总宽 ≤ 视口：按理想宽比例拉伸铺满阅读列（窄表观感与旧版铺满一致，窄列仍相对窄）；
///   总宽 > 视口：按夹取宽度排布，调用方启用横向滚动。
/// 纯函数、同步、确定：首帧即得固有宽度，零异步测高抖动（与代码块首帧固有高度同一设计语言）。
enum MarkdownTableLayout {
    /// 表头 / 正文字号字重（与 MarkdownTableGrid 渲染参数严格同源）。
    static let headerSize: CGFloat = 13
    static let headerWeight: NSFont.Weight = .bold
    static let bodySize: CGFloat = 12.5
    static let bodyWeight: NSFont.Weight = .regular

    /// 计算各列最终宽度。
    /// - viewportWidth：阅读列视口实测宽（调用方首帧兜底为阅读列上限）；
    /// - columnSpacing / horizontalPadding：列间距与行水平内边距（与渲染几何同源）。
    static func columnWidths(
        for table: MarkdownTable,
        viewportWidth: CGFloat,
        columnSpacing: CGFloat,
        horizontalPadding: CGFloat
    ) -> [CGFloat] {
        let columnCount = table.headers.count
        guard columnCount > 0 else { return [] }
        let chrome = horizontalPadding * 2 + columnSpacing * CGFloat(columnCount - 1)
        // 视口极窄时保底「每列最小宽」，宁可横滚也不把列压到不可读
        let available = max(
            viewportWidth - chrome,
            CGFloat(columnCount) * Theme.Layout.chatTableMinColumnWidth
        )

        var ideals = [CGFloat](repeating: 0, count: columnCount)
        for (column, header) in table.headers.enumerated() {
            ideals[column] = max(ideals[column], idealWidth(of: header, size: headerSize, weight: headerWeight))
        }
        for row in table.rows {
            for (column, cell) in row.enumerated() where column < columnCount {
                ideals[column] = max(ideals[column], idealWidth(of: cell, size: bodySize, weight: bodyWeight))
            }
        }
        let clamped = ideals.map {
            min(max($0, Theme.Layout.chatTableMinColumnWidth), Theme.Layout.chatTableMaxColumnWidth)
        }
        let total = clamped.reduce(0, +)
        guard total < available else { return clamped }

        // 放得下：按理想宽比例拉伸铺满视口；末列吸收浮点舍入差，总宽严格等于 available
        let scale = available / total
        var stretched = clamped.map { $0 * scale }
        stretched[columnCount - 1] += available - stretched.reduce(0, +)
        return stretched
    }

    /// 单元格单行理想宽度：复用 AppKit 渲染路径取真实字体富文本，无限宽测量
    /// （硬换行多行取最宽行）。公式占位避免光栅化；ruby / 图片以渲染路径的
    /// 文本宽度作估计，误差由列宽上下限夹取兜底。
    private static func idealWidth(of inlines: [InlineToken], size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        guard !inlines.isEmpty else { return 0 }
        let rendered = MarkdownInlineNS.renderNS(
            inlines,
            baseFont: MarkdownInlineNS.font(size: size, weight: weight),
            baseColor: .labelColor,
            baseSize: size,
            mathPlaceholder: true
        ).attributed
        guard rendered.length > 0 else { return 0 }
        let rect = rendered.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.width)
    }
}