import SwiftUI

// MARK: - 块级渲染器注册中心（动态注册表 / OCP 核心）

final class MarkdownBlockRegistry {
    static let shared = MarkdownBlockRegistry()

    private var renderers: [MarkdownBlockRenderer] = []
    private let lock = NSLock()

    private init() {
        registerBuiltIns()
    }

    /// 动态注册渲染器（自动按 priority 降序排列，支持高优先级覆盖默认实现）。
    func register(_ renderer: MarkdownBlockRenderer) {
        lock.lock()
        defer { lock.unlock() }
        renderers.removeAll { type(of: $0) == type(of: renderer) }
        renderers.append(renderer)
        renderers.sort { $0.priority > $1.priority }
    }

    /// 根据 AST 节点查找首个匹配的渲染器。
    func renderer(for block: MarkdownBlock) -> MarkdownBlockRenderer {
        lock.lock()
        defer { lock.unlock() }
        if let matched = renderers.first(where: { $0.canRender(block: block) }) {
            return matched
        }
        return FallbackBlockRenderer.shared
    }

    /// 计算指定块在其前驱块之后的顶距（间距节奏）。
    func topSpacing(for block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat {
        if let spacing = renderer(for: block).topSpacing(for: block, after: previous) {
            return spacing
        }
        if let prev = previous, case .heading = prev {
            return Theme.Spacing.lg // 8: 标题后收紧成组
        }
        return Theme.Spacing.card // 16: 默认间距
    }

    /// 注册内置的全部核心块渲染器（解耦实例化）
    private func registerBuiltIns() {
        register(MarkdownHeadingRenderer())
        register(MarkdownParagraphRenderer())
        register(MarkdownListRenderer())
        register(MarkdownBlockquoteRenderer())
        register(MarkdownAlertRenderer())
        register(MarkdownDetailsRenderer())
        register(MarkdownTableRenderer())
        register(MarkdownCodeBlockRenderer())
        register(MarkdownMathRenderer())
        register(MarkdownHorizontalRuleRenderer())
        register(MarkdownDefinitionListRenderer())
        register(MarkdownFootnoteRenderer())
    }
}

// MARK: - 降级渲染器

/// 兜底渲染器：当未注册对应块的专用渲染器时，输出空占位以避免崩溃。
final class FallbackBlockRenderer: MarkdownBlockRenderer {
    static let shared = FallbackBlockRenderer()
    var priority: Int { -100 }

    func canRender(block: MarkdownBlock) -> Bool { true }
    func capabilities(for block: MarkdownBlock) -> BlockCapabilities { .interactiveWidget }
    func topSpacing(for block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat? { Theme.Spacing.card }

    func renderWidget(block: MarkdownBlock, context: MarkdownRenderContext) -> AnyView {
        AnyView(EmptyView())
    }
}
