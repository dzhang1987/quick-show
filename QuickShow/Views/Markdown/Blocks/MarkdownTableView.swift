import SwiftUI

// 从 MarkdownBlocks.swift 拆出：Markdown 表格渲染器。

// MARK: - 表格

/// 表格：表头行底色 + 表头下实线 + 数据行斑马纹 + 提亮描边卡片。
/// 用 VStack 行结构（而非 Grid）以便整行铺底色；列等宽，列间距 16。
/// 首帧固有高度设计（与 MarkdownCodeBlock 统一）：
/// - 短表（数据行 ≤ 10 行）：纯自适应同步撑开，彻底杜绝异步 preference 测高导致的高度突变与跳动；
/// - 极限长表（数据行 > 10 行）：高度锁定在 380pt 内部滚动，表头常驻。
struct MarkdownTableView: View {
    let table: MarkdownTable

    /// 行数限高阈值（10 行 × ~34pt ≈ 340pt ≤ 380pt）
    private static let maxRowsBeforeScroll = 10

    private var needsVerticalScroll: Bool {
        table.rows.count > Self.maxRowsBeforeScroll
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 表头：加粗 + 整行底色；每列按 alignments 设置对齐
            HStack(spacing: Theme.Spacing.card) {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { column, header in
                    MarkdownInlineText(
                        inlines: header,
                        bodyColor: Theme.Colors.contentPrimary,
                        baseSize: 13,
                        weight: .bold,
                        explicitColor: Theme.Colors.contentPrimary
                    )
                    .multilineTextAlignment(textAlignment(at: column))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: frameAlignment(at: column))
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
            .background(Theme.Colors.chatTableHeader)

            // 表头下实线（提亮档，确保在斑马纹前清晰可辨）
            Rectangle()
                .fill(Theme.Colors.chatStrokeStrong)
                .frame(height: Theme.Layout.dividerHeight)

            // 数据行：短表自适应同步贴合，零异步测高抖动；超长数据在主交付限高（380pt）内滚动
            if needsVerticalScroll {
                ScrollView(.vertical, showsIndicators: true) {
                    tableRowsContent
                }
                .frame(height: Theme.Layout.chatBlockMaxHeight)
            } else {
                tableRowsContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
    }

    private var tableRowsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: Theme.Spacing.card) {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        MarkdownInlineText(
                            inlines: cell,
                            bodyColor: Theme.Colors.contentPrimary,
                            baseSize: 12.5,
                            explicitColor: Theme.Colors.contentPrimary
                        )
                        .lineSpacing(Theme.Spacing.xs)
                        .multilineTextAlignment(textAlignment(at: column))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: frameAlignment(at: column))
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.xl)
                .background(rowIndex % 2 == 1 ? Theme.Colors.chatTableRowAlternate : Color.clear)
            }
        }
    }

    /// 列对齐 → SwiftUI Frame Alignment（越界回退 leading）。
    private func frameAlignment(at column: Int) -> Alignment {
        switch alignment(at: column) {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }

    /// 列对齐 → 多行文本对齐。
    private func textAlignment(at column: Int) -> TextAlignment {
        switch alignment(at: column) {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }

    private func alignment(at column: Int) -> MarkdownTableAlignment? {
        guard column >= 0, column < table.alignments.count else { return nil }
        return table.alignments[column]
    }
}