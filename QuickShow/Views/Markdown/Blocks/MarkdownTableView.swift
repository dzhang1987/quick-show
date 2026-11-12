import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 从 MarkdownBlocks.swift 拆出：Markdown 表格渲染器。

// MARK: - 表格

/// 表格：表头行底色 + 表头下实线 + 数据行斑马纹 + 提亮描边卡片。
/// 用 VStack 行结构（而非 Grid）以便整行铺底色。
/// 2026-11 横滚重设计：列宽内容驱动（MarkdownTableLayout 同步测量）——
/// 窄表拉伸铺满阅读列（观感同旧版），宽表按夹取宽度排布、整卡横向滚动
/// （表头与数据行同处一个横滚内容，水平天然同步）；垂直方向保持旧行为：
/// 短表（数据行 ≤ 10 行）纯自适应同步撑开，长表高度锁定 380pt 内部滚动、表头常驻。
/// 首帧固有宽度设计（与 MarkdownCodeBlock 统一）：同步测量，零异步抖动。
/// 复制 / 下载：hover 右上角浮现双钮（复制图标钮直拷 Markdown；下载图标钮弹
/// Markdown / TSV / CSV 格式菜单走 NSSavePanel 存盘），与代码块同一交互语言；
/// 双钮常驻卡片右上角、不随内部滚动；单元格启用文本划选（跨格不连续，SwiftUI 选区边界）。
struct MarkdownTableView: View {
    let table: MarkdownTable

    @State private var hovered = false
    /// 阅读列视口实测宽（background GeometryReader 事件直写，同输入坞总高先例）：
    /// 驱动列宽布局「放得下拉伸 /放不下横滚」判定；首帧兜底阅读列上限，次帧校准。
    @State private var viewportWidth: CGFloat = 0

    /// 行数限高阈值（10 行 × ~34pt ≈ 340pt ≤ 380pt）
    private static let maxRowsBeforeScroll = 10

    private var needsVerticalScroll: Bool {
        table.rows.count > Self.maxRowsBeforeScroll
    }

    private var effectiveViewportWidth: CGFloat {
        viewportWidth > 0 ? viewportWidth : Theme.Layout.chatContentMaxWidth
    }

    var body: some View {
        // 横向滚动承载宽表：内容窄于视口时网格经列宽布局拉伸铺满，卡片观感同旧版
        ScrollView(.horizontal, showsIndicators: true) {
            MarkdownTableGrid(
                table: table,
                viewportWidth: effectiveViewportWidth,
                needsVerticalScroll: needsVerticalScroll
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
        // 复制 / 下载双钮：hover 浮现（透明度切换，零布局跳动），常驻右上角不随内部滚动
        .overlay(alignment: .topTrailing) {
            HStack(spacing: Theme.Spacing.xxs) {
                CodeCopyButton(
                    textToCopy: { table.copyMarkdown },
                    isHovered: hovered,
                    iconOnly: true,
                    help: String(localized: "复制表格为 Markdown")
                )
                TableDownloadButton(table: table, isHovered: hovered)
            }
            .padding(Theme.Spacing.md)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
        // 视口宽实测：不占布局，只在宽度变化（窗口缩放 / 侧栏开合）时求值，事件级频率
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { noteViewportWidth(geo.size.width) }
                    .onChange(of: geo.size.width) { noteViewportWidth($0) }
            }
        )
    }

    /// 视口宽回写：去抖（<0.5pt 跳过）防微抖重排；0 不写（首帧瞬态）。
    private func noteViewportWidth(_ width: CGFloat) {
        guard width > 0, abs(width - viewportWidth) > 0.5 else { return }
        viewportWidth = width
    }
}

/// 表格内容网格（参数化子视图：hover 等父级状态变化被 SwiftUI 值 diff 短路，
/// 列宽测量只在 table / 视口变化时重跑——同 CodeBlockText 先例）。
/// 列宽由 MarkdownTableLayout 同步计算，表头与数据行共用同一宽度数组，永不失配。
private struct MarkdownTableGrid: View {
    let table: MarkdownTable
    let viewportWidth: CGFloat
    let needsVerticalScroll: Bool

    var body: some View {
        let widths = MarkdownTableLayout.columnWidths(
            for: table,
            viewportWidth: viewportWidth,
            columnSpacing: Theme.Spacing.card,
            horizontalPadding: Theme.Spacing.xl
        )
        VStack(alignment: .leading, spacing: 0) {
            // 表头：加粗 + 整行底色；每列按 alignments 设置对齐
            HStack(spacing: Theme.Spacing.card) {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { column, header in
                    MarkdownInlineText(
                        inlines: header,
                        bodyColor: Theme.Colors.contentPrimary,
                        baseSize: MarkdownTableLayout.headerSize,
                        weight: .bold,
                        explicitColor: Theme.Colors.contentPrimary
                    )
                    .multilineTextAlignment(textAlignment(at: column))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width(at: column, in: widths), alignment: frameAlignment(at: column))
                    .textSelection(.enabled)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
            .background(Theme.Colors.chatTableHeader)
            // 光与纸·推一档：表头品牌微染（3% accent wash，不破坏小字对比度）
            .background(Theme.Colors.chatAccentWash)

            // 表头下实线（提亮档，确保在斑马纹前清晰可辨）
            Rectangle()
                .fill(Theme.Colors.chatStrokeStrong)
                .frame(height: Theme.Layout.dividerHeight)

            // 数据行：短表自适应同步贴合，零异步测高抖动；超长数据在主交付限高（380pt）内滚动
            if needsVerticalScroll {
                ScrollView(.vertical, showsIndicators: true) {
                    tableRowsContent(widths)
                }
                .frame(height: Theme.Layout.chatBlockMaxHeight)
            } else {
                tableRowsContent(widths)
            }
        }
        // 滚动条槽：横滚恒开 → 底部留白；长表竖滚 → 右侧留白
        // （系统 overlay 滚动条落进留白，不压表头 / 末行，与代码块同一语言）
        .scrollerGutter(needsVerticalScroll ? [.horizontal, .vertical] : .horizontal)
    }

    private func tableRowsContent(_ widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: Theme.Spacing.card) {
                    // 按表头列数遍历（缺格补空）：行宽恒等于表头宽，斑马纹整行铺满
                    ForEach(0..<table.headers.count, id: \.self) { column in
                        MarkdownInlineText(
                            inlines: column < row.count ? row[column] : [],
                            bodyColor: Theme.Colors.contentPrimary,
                            baseSize: MarkdownTableLayout.bodySize,
                            explicitColor: Theme.Colors.contentPrimary
                        )
                        .lineSpacing(Theme.Spacing.xs)
                        .multilineTextAlignment(textAlignment(at: column))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: width(at: column, in: widths), alignment: frameAlignment(at: column))
                        .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.xl)
                .background(rowIndex % 2 == 1 ? Theme.Colors.chatTableRowAlternate : Color.clear)
            }
        }
    }

    /// 列宽越界兜底（防异常 AST 布局崩溃）。
    private func width(at column: Int, in widths: [CGFloat]) -> CGFloat {
        guard !widths.isEmpty else { return Theme.Layout.chatTableMinColumnWidth }
        return widths[min(column, widths.count - 1)]
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

// MARK: - 表格下载钮

/// 表格下载格式：菜单标题 / 扩展名 / UTType / 序列化内容一一对应，新增格式只加 case。
private enum TableDownloadFormat: CaseIterable {
    case markdown
    case tsv
    case csv

    var menuTitle: String {
        switch self {
        case .markdown: return String(localized: "Markdown (.md)")
        case .tsv: return String(localized: "TSV (.tsv)")
        case .csv: return String(localized: "CSV (.csv)")
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .tsv: return "tsv"
        case .csv: return "csv"
        }
    }

    var contentType: UTType {
        switch self {
        // UTType.markdown 常量在高版本 SDK 才声明；按扩展名动态解析，兼容 macOS 13 部署目标
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .tsv: return .tabSeparatedText
        case .csv: return .commaSeparatedText
        }
    }

    func text(from table: MarkdownTable) -> String {
        switch self {
        case .markdown: return table.copyMarkdown
        case .tsv: return table.copyTSV
        case .csv: return table.copyCSV
        }
    }
}

/// 下载图标钮：点击弹格式菜单（Markdown / TSV / CSV），选定后 NSSavePanel 存盘，
/// 成功图标变对勾轻反馈（与复制钮同节奏）。
/// 菜单走 Button + NSMenu（与生成 chip 同源）：label 是真 SwiftUI 视图、hover 可靠；
/// item 动作走共享 MenuActionProxy，生命周期由 MenuActionRetainer 强持有。
private struct TableDownloadButton: View {
    let table: MarkdownTable
    var isHovered: Bool

    @State private var saved = false

    var body: some View {
        Button(action: showFormatMenu) {
            Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                .font(Theme.Typography.text(9.5, .medium))
                .copyControlChrome(highlighted: saved)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .opacity((isHovered || saved) ? 1 : 0)
        .allowsHitTesting(isHovered || saved)
        .accessibilityHidden(!isHovered && !saved)
        .help(String(localized: "下载表格（Markdown / TSV / CSV）"))
    }

    private func showFormatMenu() {
        MenuActionRetainer.shared.reset()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for format in TableDownloadFormat.allCases {
            let action = MenuActionProxy { save(format) }
            MenuActionRetainer.shared.retain(action)
            let item = NSMenuItem(
                title: format.menuTitle,
                action: #selector(MenuActionProxy.invoke),
                keyEquivalent: ""
            )
            item.target = action
            menu.addItem(item)
        }
        // 用户刚点击按钮，鼠标即在锚点处；Retainer 持有期间动作生命期绝对安全
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func save(_ format: TableDownloadFormat) {
        let text = format.text(from: table)
        guard !text.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = String(localized: "表格") + "." + format.fileExtension
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(text.utf8).write(to: url)
                saved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.transientFeedbackDuration) {
                    saved = false
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "保存失败")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}