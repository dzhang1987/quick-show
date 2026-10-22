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
    case widget(id: String, block: MarkdownBlock, topSpacing: CGFloat, leadingIndent: CGFloat = 0)

    var id: String {
        switch self {
        case let .textFlow(id, _, _): return id
        case let .widget(id, _, _, _): return id
        }
    }

    var topSpacing: CGFloat {
        switch self {
        case let .textFlow(_, _, spacing): return spacing
        case let .widget(_, _, spacing, _): return spacing
        }
    }

    static func == (lhs: MarkdownDisplaySegment, rhs: MarkdownDisplaySegment) -> Bool {
        switch (lhs, rhs) {
        case let (.textFlow(id1, content1, s1), .textFlow(id2, content2, s2)):
            return id1 == id2 && s1 == s2 && content1.isEqual(to: content2)
        case let (.widget(id1, b1, s1, i1), .widget(id2, b2, s2, i2)):
            return id1 == id2 && s1 == s2 && i1 == i2 && b1 == b2
        default:
            return false
        }
    }
}
