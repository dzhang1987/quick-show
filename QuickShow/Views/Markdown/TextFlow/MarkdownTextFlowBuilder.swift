import Foundation
import AppKit

// MARK: - 文本流 NSAttributedString 生成器（TextKit 殿堂级精密排版）

enum MarkdownTextFlowBuilder {

    /// 将连续的普通文本块拼装为单个具备层次样式的 NSAttributedString（协议委托各 Renderer）
    static func build(
        from blocks: [MarkdownBlock],
        context: MarkdownRenderContext = MarkdownRenderContext()
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let next = index < blocks.count - 1 ? blocks[index + 1] : nil
            let renderer = MarkdownBlockRegistry.shared.renderer(for: block)
            renderer.appendTextFlow(block: block, nextBlock: next, into: result, context: context)
        }
        return result
    }
}
