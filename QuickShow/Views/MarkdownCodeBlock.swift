import AppKit
import SwiftUI

// 从 MarkdownBlocks.swift 拆出：Markdown 围栏代码块渲染器（含高亮内容子视图）。

// MARK: - 代码块

/// 围栏代码块：语言标签 + 等宽内容；hover 右上角渐显复制钮（成功变对勾轻反馈）。
/// 语法高亮：首帧立即纯色等宽渲染，同时后台计算高亮 AttributedString，完成后替换
/// （失败/不支持语言保持纯色）。高亮计算全程异步，绝不阻塞流式渲染。
struct CodeBlockView: View {
    let language: String?
    let code: String

    /// 行级 hover（由消息列表容器级分发器经环境注入）：驱动复制钮揭示。
    /// 原先是本块整体 contentShape + onHover 注册跟踪区——代码块在大会话里数量多，
    /// 是逐叶子跟踪区的主要来源；上收为行级后，块内不再注册任何跟踪区。
    @Environment(\.messageRowHovered) private var rowHovered
    @State private var copied = false

    /// 复制钮揭示态 = 所在消息行 hover。复制成功反馈（copied）期间保持可见。
    private var showsCopyButton: Bool { rowHovered || copied }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.chatCodeBlockHeaderGap) {
            HStack(spacing: Theme.Spacing.lg) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(Theme.Typography.mono(10, .semibold))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }
                Spacer(minLength: 0)
                // 布局稳定化：按钮常驻布局（header 行高度恒定），hover 仅切换透明度，
                // 不触发布局变化。
                // 显隐由行级 hover（showsCopyButton）单独驱动；copied 仅是复制成功的瞬时内容反馈
                // （鼠标离开时按钮随 hovered 隐去，不会残留悬空的第二按钮）。
                Button(action: copyCode) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: copied ? "checkmark" : "square.on.square")
                            .font(Theme.Typography.text(9.5, .medium))
                        Text(copied ? "已复制" : "复制")
                            .font(Theme.Typography.text(9.5, .medium))
                    }
                    .foregroundColor(copied ? Theme.Colors.accent : Theme.Colors.contentTertiary)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                            .fill(Theme.Colors.surfaceButton)
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .opacity(showsCopyButton ? 1 : 0)
                .allowsHitTesting(showsCopyButton)
                .accessibilityHidden(!showsCopyButton)
            }
            .frame(minHeight: 14)
            // 揭示/隐去与旧 withAnimation(contentFade) 观感一致（只动画透明度）。
            .animation(.easeOut(duration: Theme.Motion.contentFade), value: showsCopyButton)

            // 高亮状态与渲染内聚于子视图（见 CodeBlockText）：hover 变化引起的
            // 父 body 重算会被 SwiftUI 子视图值 diff 短路，大段高亮文本永不重建。
            CodeBlockText(code: code, language: language)
        }
        // 2026-10 重设计：上下对称、左右一致（12/14，旧值 10/12 上下失衡、重心悬空）
        .padding(.horizontal, Theme.Layout.chatCodeBlockPaddingH)
        .padding(.vertical, Theme.Layout.chatCodeBlockPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .fill(Theme.Colors.surfaceTrack)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.insetCard, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
    }

    private func copyCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        copied = true
        // 轻反馈：对勾短暂停留后复位
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

/// 代码内容子视图：高亮状态（`highlighted`）与高亮渲染、高亮 task 全部内聚于此。
///
/// 状态半径原则：hover（复制按钮显隐）是 CodeBlockView 的状态，其变化触发父 body
/// 重算；本视图作为参数化子视图，参数（code/language）不变时 SwiftUI 值 diff 会
/// 短路父重算——本视图 body 不重跑，`Text(highlighted)`（大段 AttributedString，
/// 构造需解析 runs，成本高一个数量级）永不重建。滚动中 hover 进出风暴的重算成本
/// 由此被压缩到 header 一行（语言标签 + 小按钮）。
private struct CodeBlockText: View {
    let code: String
    let language: String?

    @Environment(\.colorScheme) private var colorScheme
    /// 后台高亮结果；nil = 尚未完成 / 不可用 / 降级纯色。
    @State private var highlighted: AttributedString?

    var body: some View {
        // 高亮版优先、否则降级为纯色等宽文本（现状行为）。
        // 代码块内不转 Markdown，纯等宽显示。
        // 长行不折行：横向滚动承载超长行——折行会破坏缩进结构、复制粘贴混入换行符。
        // 嵌套滚动安全：底层 NSScrollView 不消费垂直滚轮 delta（沿 responder chain 上传
        // 外层垂直滚动，滚轮鼠标体验与现状一致），仅消费水平 delta（shift+滚轮/双指横滑）；
        // 内容短于视口时贴 scroll origin（leading），与旧 frame(alignment: .leading) 等价。
        // fixedSize(horizontal: true)：水平按固有宽度布局（ScrollView 提议无限宽，双保险防
        // 折行）；vertical: false 服从容器高度（= 内容固有行高，无循环依赖）。
        ScrollView(.horizontal, showsIndicators: true) {
            Group {
                if let highlighted {
                    Text(highlighted)
                } else {
                    Text(code)
                        .font(Theme.Typography.mono(12.5))
                        .foregroundColor(Theme.Colors.contentPrimary)
                }
            }
            .lineSpacing(6)
            .fixedSize(horizontal: true, vertical: false)
        }
        .task(id: HighlightTask(code: code, language: language, darkMode: colorScheme == .dark)) {
            // 首帧保持纯色等宽（highlighted == nil）；后台计算高亮后替换。
            highlighted = nil
            let code = self.code
            let language = self.language
            let result = await Task.detached(priority: .utility) {
                MarkdownHighlighter.highlightSwiftUI(code, language: language, darkMode: colorScheme == .dark)
            }.value
            guard !Task.isCancelled else { return }
            highlighted = result
        }
    }

    /// 高亮 task 键：内容 / 语言 / 外观任一变化即重高亮（外观切换换主题，
    /// 流式期间 code 增长重算）。
    private struct HighlightTask: Equatable {
        let code: String
        let language: String?
        let darkMode: Bool
    }
}