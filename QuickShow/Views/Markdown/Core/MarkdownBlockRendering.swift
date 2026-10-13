import SwiftUI
import AppKit

// MARK: - 渲染上下文

/// Markdown 渲染上下文：传递字号基准、主题色阶、外观明暗与缓存策略。
struct MarkdownRenderContext {
    let baseFontSize: CGFloat
    let useCache: Bool
    let bodyColor: Color
    let contentPrimaryColor: Color
    let isDark: Bool
    var customPayload: [String: Any]

    init(
        baseFontSize: CGFloat = 13,
        useCache: Bool = true,
        bodyColor: Color = Color.primary.opacity(0.80),
        contentPrimaryColor: Color = Theme.Colors.contentPrimary,
        isDark: Bool = false,
        customPayload: [String: Any] = [:]
    ) {
        self.baseFontSize = baseFontSize
        self.useCache = useCache
        self.bodyColor = bodyColor
        self.contentPrimaryColor = contentPrimaryColor
        self.isDark = isDark
        self.customPayload = customPayload
    }
}

// MARK: - 块级排版能力声明

/// 声明块级节点支持的排版流能力（供分流器做 TextKit 连续流合并决策）。
struct BlockCapabilities: OptionSet {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    /// 支持无缝并入 TextKit 连续原生排版流（支持悬挂缩进、制表符两列对齐与全篇连贯框选复制）。
    static let textFlowCompatible = BlockCapabilities(rawValue: 1 << 0)
    /// 独立交互组件岛屿（代码块复制、表格横滚、WebView 图表、带图段落等）。
    static let interactiveWidget = BlockCapabilities(rawValue: 1 << 1)
}

// MARK: - 块级渲染器契约（开闭原则 OCP 核心）

/// 块级渲染器统一协议：负责判定、间距节奏、TextKit 流拼接及独立 Widget 渲染。
protocol MarkdownBlockRenderer: AnyObject {
    /// 优先级：多渲染器匹配同一块时，数值高者优先接管，便于外部无侵入覆盖或插件注入。
    var priority: Int { get }

    /// 判定本渲染器是否可接管该 AST 块。
    func canRender(block: MarkdownBlock) -> Bool

    /// 返回该块具备的排版能力（供流切分器进行 TextFlow 合并决策）。
    func capabilities(for block: MarkdownBlock) -> BlockCapabilities

    /// 间距节奏：计算该块在 previous 之后的顶距（若返回 nil 则回退至默认 16）。
    func topSpacing(for block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat?

    /// TextKit 原生连续文本流拼接（仅当具备 textFlowCompatible 能力时被调用）。
    func appendTextFlow(
        block: MarkdownBlock,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString,
        context: MarkdownRenderContext
    )

    /// 独立组件视图渲染（生成 SwiftUI 交互视图）。
    @ViewBuilder
    func renderWidget(block: MarkdownBlock, context: MarkdownRenderContext) -> AnyView
}

extension MarkdownBlockRenderer {
    var priority: Int { 0 }

    func appendTextFlow(
        block: MarkdownBlock,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString,
        context: MarkdownRenderContext
    ) {
        // 默认空实现（仅 widget 节点无需拼装文本流）
    }
}
