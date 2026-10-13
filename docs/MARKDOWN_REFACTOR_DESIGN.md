# QuickShow Markdown 模块化与协议化架构设计方案

## 0. 设计背景与第一性原理

在 QuickShow 的架构中，Markdown 渲染是承载 AI 会话与富文本呈现的核心管道。随着支持的语法特性逐渐完备（涵盖 GFM、数学公式 LaTeX、Mermaid 矢量图表、TextKit 精密排版、东亚注音 Ruby、多级表格等），原有视图层逐渐积累了以下架构痛点：

1. **单文件体量过重与职责杂糅（违背单一职责原则 SRP）**：
   - `MermaidWebView.swift` 体量超过 1550 行，其中 1200+ 行为 JavaScript 语法修复、CSS 样式与 HTML 模版，前端微引擎代码以多行字符串形式混杂在 Swift 视图宿主中；
   - `MathLatexTranspiler.swift` 超过 800 行，单函数容纳了数十种 LaTeX 命令的替换规则与括号匹配，缺乏流水线阶段划分；
   - `MarkdownInlineNS.swift` 达 580 行，同时承载了 `NSAttributedString` 构建、SwiftUI 入口 `MarkdownInlineText`、图片分段拆解与多项 AST 辅助扩展；
   - `MarkdownBlocks.swift` 达 470 行，将 7 类不同的块级视图（引用、列表、Alert、折叠等）全部堆在一个文件中。
2. **缺乏面向协议与接口的抽象（违背开闭原则 OCP）**：
   - 块级视图 `MarkdownBlockView` 内部采用庞大的 `switch-case` 硬编码分发，主流程与具体视图强耦合；
   - 无法在不侵入核心主文件的情况下新增或替换块级渲染器（如新增思维导图、可执行终端块、或替换代码块渲染器）。
3. **混合排版流能力未契约化**：
   - 当前分段器（`MarkdownBlockSegmenter`）通过硬编码判定某个块是否兼容 TextKit 连续文本流，无法让自定义扩展块自主声明排版能力。

为了彻底解决以上问题，本项目采取**一步到位、协议化注册、内聚解耦、严格符合开闭原则（OCP）**的重构策略，确保**主流程稳定不变，任意新增功能扩展仅需实现协议并注册**。

---

## 1. 整体架构全景图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          AssistantMarkdownView (主渲染宿主)                   │
│         (管理落定/流式状态、视口高度自适应首帧分批、脚注收集，主流程永远保持稳定)            │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
                         [MarkdownBlock] 块级 AST 流
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                       MarkdownBlockSegmenter (流切分器)                     │
│    通过 BlockRenderer.capabilities 判定 TextFlow 兼容性，将连续块聚合为富文本流     │
└───────────────────┬─────────────────────────────────────┬───────────────────┘
                    │                                     │
           [textFlow] (连续排版段)                       [widget] (独立组件岛屿)
                    │                                     │
                    ▼                                     ▼
┌──────────────────────────────────────┐  ┌───────────────────────────────────┐
│        NativeTextFlowView            │  │      MarkdownBlockRegistry        │
│ (AppKit NonScrollingTextView+TextKit)│  │   (协议化动态注册表 / OCP 核心工厂)  │
│      悬挂缩进 / \t 对齐 / 全篇连选    │  └─────────────────┬─────────────────┘
└──────────────────────────────────────┘                    │
                                                            │ 分发至对应 BlockRenderer
                                                            ▼
                                   ┌───────────────────────────────────────────┐
                                   │       遵循 MarkdownBlockRenderer 协议      │
                                   ├───────────────┬───────────────┬───────────┤
                                   │ Heading       │ Code (Mermaid)│ Math      │
                                   │ Alert (GFM)   │ Details       │ Table     │
                                   │ Blockquote    │ List          │ Future... │
                                   └───────────────┴───────────────┴───────────┘
```

---

## 2. 核心协议体系与注册中心设计（OCP 核心引擎）

### 2.1 渲染上下文：`MarkdownRenderContext`
解耦视图环境依赖，统一传递排版基准与状态：

```swift
public struct MarkdownRenderContext {
    public let baseFontSize: CGFloat
    public let useCache: Bool
    public let bodyColor: Color
    public let contentPrimaryColor: Color
    public let isDark: Bool
    public var customPayload: [String: Any]

    public init(
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
```

### 2.2 块级能力声明：`BlockCapabilities`

```swift
public struct BlockCapabilities: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// 支持并入 TextKit 连续单文本流（支持悬挂缩进、制表符对齐与全篇无缝连选）
    public static let textFlowCompatible = BlockCapabilities(rawValue: 1 << 0)
    /// 独立交互组件（代码块复制、表格横滚、WebView 矢量图表等）
    public static let interactiveWidget = BlockCapabilities(rawValue: 1 << 1)
}
```

### 2.3 块级渲染器契约：`MarkdownBlockRenderer`

```swift
public protocol MarkdownBlockRenderer {
    /// 优先级（高优先级优先接管，支持外部无侵入覆盖默认渲染器）
    var priority: Int { get }

    /// 判定该渲染器能否处理目标 AST 块
    func canRender(block: MarkdownBlock) -> Bool

    /// 返回该块具备的能力特性（供分流器做 TextKit 流式合并决策）
    func capabilities(for block: MarkdownBlock) -> BlockCapabilities

    /// 间距节奏计算：该块紧随 previous 之后的顶距（nil 则回退到统一默认间距 16）
    func topSpacing(for block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat?

    /// TextKit 原生文本流拼装逻辑（仅当具备 textFlowCompatible 时被调用）
    func appendTextFlow(
        block: MarkdownBlock,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString,
        context: MarkdownRenderContext
    )

    /// 独立组件视图渲染（生成 SwiftUI 交互卡片或视图）
    @ViewBuilder
    func renderWidget(block: MarkdownBlock, context: MarkdownRenderContext) -> AnyView
}

public extension MarkdownBlockRenderer {
    var priority: Int { 0 }
    func appendTextFlow(
        block: MarkdownBlock,
        nextBlock: MarkdownBlock?,
        into result: NSMutableAttributedString,
        context: MarkdownRenderContext
    ) {}
}
```

### 2.4 注册中心与工厂：`MarkdownBlockRegistry`

```swift
public final class MarkdownBlockRegistry {
    public static let shared = MarkdownBlockRegistry()

    private var renderers: [MarkdownBlockRenderer] = []
    private let lock = NSLock()

    private init() {
        registerBuiltInRenderers()
    }

    /// 动态注册新的渲染器（自动按 priority 降序排列）
    public func register(_ renderer: MarkdownBlockRenderer) {
        lock.lock()
        defer { lock.unlock() }
        renderers.removeAll { type(of: $0) == type(of: renderer) }
        renderers.append(renderer)
        renderers.sort { $0.priority > $1.priority }
    }

    /// 查找首个能接管该块的渲染器
    public func renderer(for block: MarkdownBlock) -> MarkdownBlockRenderer {
        lock.lock()
        defer { lock.unlock() }
        if let matched = renderers.first(where: { $0.canRender(block: block) }) {
            return matched
        }
        return FallbackBlockRenderer.shared
    }

    private func registerBuiltInRenderers() {
        // 内置默认渲染器注册
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
```

---

## 3. 大文件拆解与重构明细

### 3.1 Mermaid 图表子系统（1555 行 → 模块化隔离）
- **核心痛点**：Swift 视图代码与 1200+ 行的前端 JS/HTML 代码混在一起，无 IDE 语法高亮且维护风险高。
- **解耦结构**：
  1. `MermaidModels.swift` (~60 行)：抽离 `MermaidLook` 与 `MermaidTheme` 枚举，保持持久化存储键及配置兼容；
  2. `MermaidScriptLoader.swift` (~40 行)：全局单例持有 `mermaid.min.js` 的 `WKUserScript` 内存缓存，避免重复磁盘 IO；
  3. `MermaidTemplateProvider.swift` (~180 行)：专门管理 HTML 骨架、CSS 对比度样式与通信脚本，彻底移出纯视图文件；
  4. `MermaidNormalizerScript.swift` (~350 行)：独立管理针对 classDiagram、sequenceDiagram、flowchart、erDiagram 的语法归一化与字符转义前端引擎；
  5. `MermaidWebView.swift` (~160 行)：纯粹的 AppKit WKWebView 宿主与 Coordinator 桥接；
  6. `MermaidBlockView.swift` (~200 行)：保持外层卡片与工具栏交互。

### 3.2 LaTeX 数学公式转译流水线（818 行 → Pipeline 模式）
- **核心痛点**：`MathLatexTranspiler` 单函数包含 40 余类命令的替换，逻辑混杂且无法独立单测。
- **解耦结构**：
  1. `MathBalancedParser.swift` (~90 行)：独立通用的平衡括号（`{...}`、`[...]`）提取纯函数；
  2. `MathSyntaxSanitizer.swift` (~160 行)：负责分数族（`\dfrac`, `\cfrac`）、多重积分、间距符、逻辑关系符的基础映射；
  3. `MathEnvironmentMapper.swift` (~180 行)：负责 `matrix`、`aligned`、`cases` 等环境映射，以及 2 列收敛处理；
  4. `MathArgumentRewriter.swift` (~200 行)：负责带参命令（`\overset`, `\xrightarrow`, `\textcolor`, `\color`）的参数重写；
  5. `MathCommandPatcher.swift` (~120 行)：负责装饰去壳（`\boxed`, `\cancel`）与字体命令补丁；
  6. `MathLatexPipeline.swift` (~80 行)：主入口，以流水线方式串联上述阶段，对外保持原 `MathLatexTranspiler.transpile` 契约不变。

### 3.3 TextKit 连续文本流排版引擎（504 行 → 职责单一化）
- **解耦结构**：
  1. `MarkdownDisplaySegment.swift` (~50 行)：定义排版段枚举（`.textFlow` 与 `.widget`）；
  2. `MarkdownBlockSegmenter.swift` (~80 行)：根据 `MarkdownBlockRegistry` 的能力声明智能切分；
  3. `MarkdownTextFlowBuilder.swift` (~120 行)：调用各渲染器的 `appendTextFlow`，处理段落间距与列表项缩进；
  4. `NativeTextFlowView.swift` (~150 行)：管理 `NonScrollingTextView`（AppKit TextKit 宿主）与离屏无副作用纯内存高度测量栈。

### 3.4 行内渲染体系（`MarkdownInlineNS.swift` & `MarkdownInline.swift`）
- **解耦结构**：
  1. `InlineToken+Inspection.swift` (~80 行)：收敛 `containsMath`、`containsImage`、`containsRuby` 与图片分段扩展；
  2. `MarkdownInlineText.swift` (~100 行)：SwiftUI 统一行内视图，负责根据 Token 类型路由到普通 Text、`MathParagraphView`、`RubyParagraphView` 或 `MarkdownImageView`；
  3. `MarkdownInlineNS.swift` (~260 行)：纯粹的 AppKit/TextKit 路径，将 `[InlineToken]` 渲染为带公式 Attachment 的 `NSAttributedString`；
  4. `MarkdownInline.swift` (~180 行)：纯粹的 SwiftUI 路径，将 `[InlineToken]` 渲染为 `AttributedString`。

### 3.5 块级独立组件化（475 行 → 12 个单一职责文件）
每个块级类型均有其独立的 View 与 Renderer，遵循单一职责：
- `MarkdownHeadingRenderer.swift`
- `MarkdownParagraphRenderer.swift`
- `MarkdownListRenderer.swift` (`MarkdownListView`, `MarkdownListItemRow`)
- `MarkdownBlockquoteRenderer.swift` (`MarkdownBlockquoteView`)
- `MarkdownAlertRenderer.swift` (`MarkdownAlertView`)
- `MarkdownDetailsRenderer.swift` (`MarkdownDetailsView`)
- `MarkdownDefinitionListRenderer.swift` (`MarkdownDefinitionListView`)
- `MarkdownTableRenderer.swift` (`MarkdownTableView`)
- `MarkdownCodeBlockRenderer.swift` (`CodeBlockView` 与 `MermaidBlockView`)
- `MarkdownMathRenderer.swift` (`AsyncMathBlockView`)
- `MarkdownHorizontalRuleRenderer.swift`
- `MarkdownFootnoteRenderer.swift` (`MarkdownFootnoteSection`)

---

## 4. 重构后物理目录结构设计

所有 Markdown 相关源码按层次集中于 `QuickShow/Views/Markdown/`：

```text
QuickShow/Views/Markdown/
├── AssistantMarkdownView.swift            # [入口宿主] 渐进分批与缓存控制（顶层稳定）
│
├── Core/                                  # [协议与调度核心]
│   ├── MarkdownBlockRendering.swift       # 核心协议与上下文定义
│   ├── MarkdownBlockRegistry.swift        # 注册表与内置渲染器加载
│   └── MarkdownDisplaySegment.swift       # DisplaySegment 枚举定义
│
├── TextFlow/                              # [TextKit 原生连续排版]
│   ├── MarkdownBlockSegmenter.swift       # 连续流智能切分器
│   ├── MarkdownTextFlowBuilder.swift      # NSAttributedString 拼装器
│   └── NativeTextFlowView.swift           # NonScrollingTextView & 离屏测量栈
│
├── Inline/                                # [行内排版与分发]
│   ├── InlineToken+Inspection.swift       # AST 扩展 (containsMath/Image/Ruby)
│   ├── MarkdownInlineText.swift           # 行内 SwiftUI 视图统一入口
│   ├── MarkdownInline.swift               # SwiftUI AttributedString 渲染器
│   ├── MarkdownInlineNS.swift             # AppKit NSAttributedString 渲染器
│   ├── MarkdownImageView.swift            # 独立图片/点击预览组件
│   └── MarkdownRubyView.swift             # 东亚注音组件
│
├── Blocks/                                # [独立块级渲染器与视图组件]
│   ├── MarkdownHeadingRenderer.swift
│   ├── MarkdownParagraphRenderer.swift
│   ├── MarkdownListRenderer.swift
│   ├── MarkdownBlockquoteRenderer.swift
│   ├── MarkdownAlertRenderer.swift
│   ├── MarkdownDetailsRenderer.swift
│   ├── MarkdownDefinitionListRenderer.swift
│   ├── MarkdownTableRenderer.swift
│   ├── MarkdownCodeBlockRenderer.swift
│   ├── MarkdownMathRenderer.swift
│   ├── MarkdownHorizontalRuleRenderer.swift
│   └── MarkdownFootnoteRenderer.swift
│
├── Mermaid/                               # [Mermaid 图表独立引擎]
│   ├── MermaidModels.swift                # MermaidLook & MermaidTheme 枚举
│   ├── MermaidScriptLoader.swift          # 单例 WKUserScript 加载器
│   ├── MermaidTemplateProvider.swift      # HTML/JS 模板装配
│   ├── MermaidNormalizerScript.swift      # 语法预归一化脚本
│   ├── MermaidWebView.swift               # 纯粹的 AppKit WKWebView 宿主
│   └── MermaidBlockView.swift             # 外层卡片交互视图
│
└── Math/                                  # [LaTeX 数学公式独立引擎]
    ├── Pipeline/                          # 转译流水线
    │   ├── MathBalancedParser.swift       # 括号平衡提取纯算法
    │   ├── MathSyntaxSanitizer.swift      # 符号与命令基础清洗
    │   ├── MathEnvironmentMapper.swift    # 环境转换与两列收敛
    │   ├── MathArgumentRewriter.swift     # 复杂命令带参重写
    │   ├── MathCommandPatcher.swift       # 装饰去壳与字体补丁
    │   └── MathLatexPipeline.swift        # 流水线执行宿主 (原 MathLatexTranspiler)
    └── Views/                             # 公式光栅化与视图
        ├── MathRasterizer.swift           # SwiftMath 位图渲染引擎
        ├── MathViews.swift                # MathParagraphView / MathBlockView
        ├── AsyncMathBlockView.swift       # 异步加载占位块
        ├── MathLayoutCache.swift          # 布局缓存
        └── MathLatexCollector.swift       # 公式预热收集器
```

---

## 5. 开闭原则（OCP）扩展性验证

若未来需新增一个「交互式思维导图 Mindmap」或「内嵌执行沙箱 SandboxTerminal」块：
1. **主渲染流程零修改**：`AssistantMarkdownView`、`MarkdownBlockSegmenter`、`NativeTextFlowView` 代码完全无需改动；
2. **新增一个 Renderer 类即可**：
   ```swift
   final class MindmapBlockRenderer: MarkdownBlockRenderer {
       var priority: Int = 100
       func canRender(block: MarkdownBlock) -> Bool {
           if case let .codeBlock(lang, _) = block { return lang == "mindmap" }
           return false
       }
       func capabilities(for block: MarkdownBlock) -> BlockCapabilities { .interactiveWidget }
       func topSpacing(for block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat? { 16 }
       func renderWidget(block: MarkdownBlock, context: MarkdownRenderContext) -> AnyView {
           AnyView(MindmapCardView(...))
       }
   }
   ```
3. **调用注册即可全量生效**：
   ```swift
   MarkdownBlockRegistry.shared.register(MindmapBlockRenderer())
   ```

---

## 6. 第一性原理与性能零退化保证

1. **会话秒开与首帧平稳性**：
   - 保留首帧视口自适应分批（8~16 块初始挂载）；
   - 落定态（`useCache=true`）全量渲染保证上滚零抖动；
   - 流式中间态（`useCache=false`）16ms 步进自适应分批。
2. **TextKit 排版精度**：
   - 完整保留 `\t` 制表符两列对齐、`headIndent` 悬挂缩进、段内软换行 `\u{2028}`。
3. **Mermaid 离线渲染稳定**：
   - 完整保留针对复杂语法报错的预归一化脚本，离线 `mermaid.min.js` 内存共享。
4. **编译与工程无缝映射**：
   - 基于 `project.yml` 对 `QuickShow/` 目录的自动遍历规则，模块迁移后执行 `xcodegen generate` 自动生效。
