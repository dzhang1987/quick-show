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

    @State private var hovered = false
    @State private var copied = false

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
                // 显隐由 hovered 单独驱动；copied 仅是复制成功的瞬时内容反馈
                // （鼠标离开时按钮随 hovered 隐去，不会残留悬空的第二按钮）。
                Button(action: copyCode) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: copied ? "checkmark" : "square.on.square")
                            .font(Theme.Typography.text(9.5, .medium))
                        Text(copied ? String(localized: "已复制") : String(localized: "复制"))
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
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
                .accessibilityHidden(!hovered)
            }
            .frame(minHeight: 14)

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
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { hovered = hovering }
        }
    }

    private func copyCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        copied = true
        // 轻反馈：对勾短暂停留后复位
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.transientFeedbackDuration) { copied = false }
    }
}

/// 代码内容子视图：高亮状态（`highlighted`）与高亮渲染、高亮 task 全部内聚于此。
///
/// 状态半径原则：hover（复制按钮显隐）是 CodeBlockView 的状态，其变化触发父 body
/// 重算；本视图作为参数化子视图，参数（code/language）不变时 SwiftUI 值 diff 会
/// 短路父重算——本视图 body 不重跑，`Text(highlighted)`（大段 AttributedString，
/// 构造需解析 runs，成本高一个数量级）永不重建。滚动中 hover 进出风暴的重算成本
/// 由此被压缩到 header 一行（语言标签 + 小按钮）。
struct CodeBlockText: View {
    let code: String
    let language: String?

    @Environment(\.colorScheme) private var colorScheme
    /// 后台高亮结果；nil = 尚未完成 / 不可用 / 降级纯色。
    @State private var highlighted: AttributedString?

    /// 代码行数（单行纯等宽行高约 21pt：12.5pt 字体 + 6pt lineSpacing）
    private var lineCount: Int {
        code.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// 限高阈值行数（380pt / 21pt ≈ 18 行）
    private static let maxLinesBeforeScroll = 18

    var body: some View {
        Group {
            if lineCount <= Self.maxLinesBeforeScroll {
                // 短代码块（≤18 行）：垂直方向零滚动、纯自适应撑开（首帧同步确定固有高度，
                // 彻底杜绝异步 preference 测高导致的父级 ChatMessageActionRow 错位与跳动）；
                // 仅保留水平滚动以承载超长行。
                ScrollView(.horizontal, showsIndicators: true) {
                    textContent
                }
            } else {
                // 长代码块（>18 行）：高度锁定在 380pt，双向滚动。首帧即确定为 380pt 恒定高度，零布局抖动。
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    textContent
                }
                .frame(height: Theme.Layout.chatBlockMaxHeight)
            }
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

    private var textContent: some View {
        Group {
            if let highlighted {
                Text(highlighted)
            } else {
                Text(code)
                    .foregroundColor(Theme.Colors.contentPrimary)
            }
        }
        .font(Theme.Typography.mono(12.5))
        .lineSpacing(6)
        .fixedSize(horizontal: true, vertical: false)
        .textSelection(.enabled)
    }

    /// 高亮 task 键：内容 / 语言 / 外观任一变化即重高亮（外观切换换主题，
    /// 流式期间 code 增长重算）。
    private struct HighlightTask: Equatable {
        let code: String
        let language: String?
        let darkMode: Bool
    }
}