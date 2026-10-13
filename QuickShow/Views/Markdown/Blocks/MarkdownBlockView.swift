import SwiftUI

// MARK: - 协议驱动块级统一分发视图（开闭原则门面）

/// 块级分发视图：完全由 `MarkdownBlockRegistry` 契约驱动，
/// 不包含任何硬编码 switch，支持任意自定义 Block 渲染器无侵入扩展。
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var context: MarkdownRenderContext

    init(block: MarkdownBlock, context: MarkdownRenderContext = MarkdownRenderContext()) {
        self.block = block
        self.context = context
    }

    var body: some View {
        MarkdownBlockRegistry.shared.renderer(for: block).renderWidget(block: block, context: context)
    }
}

// MARK: - 块间距节奏扩展（兼容既有代码调用）

extension MarkdownBlock {
    /// 块顶距：间距节奏的唯一来源，由注册中心/对应渲染器决定。
    func topSpacing(after previous: MarkdownBlock) -> CGFloat {
        MarkdownBlockRegistry.shared.topSpacing(for: self, after: previous)
    }
}
