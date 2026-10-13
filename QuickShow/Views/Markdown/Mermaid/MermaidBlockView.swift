import AppKit
import SwiftUI

// MARK: - Mermaid 图表卡片

/// Mermaid 图表渲染卡片：
/// 1. 默认展示矢量图表视图（MermaidWebView），支持深浅色无缝自适应；
/// 2. Header 操作栏提供「代码 / 图表」双模切换，方便查阅源码与快速复制；
/// 3. 语法未完成或解析失败时，平滑降级为等宽高亮代码块，绝不破坏界面；
/// 4. 视觉尺寸与 CodeBlockView 完全对齐。
struct MermaidBlockView: View {
    let code: String

    @State private var hovered = false
    @State private var copied = false
    @State private var isShowingCode = false
    @State private var renderFailed = false
    @State private var renderedHeight: CGFloat = 80
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(MermaidLook.storageKey) private var lookRaw: String = MermaidLook.classic.rawValue
    @AppStorage(MermaidTheme.storageKey) private var themeRaw: String = MermaidTheme.auto.rawValue

    init(code: String) {
        self.code = code
    }

    private var currentLook: MermaidLook {
        MermaidLook(rawValue: lookRaw) ?? .classic
    }

    private var currentTheme: MermaidTheme {
        MermaidTheme(rawValue: themeRaw) ?? .auto
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.chatCodeBlockHeaderGap) {
            // Header: 语言标签 + 状态提示 + (风格切换 + 主题菜单 + 图表/代码切换 + 复制按钮)
            HStack(spacing: Theme.Spacing.md) {
                Text("mermaid")
                    .font(Theme.Typography.mono(10, .semibold))
                    .foregroundColor(Theme.Colors.contentTertiary)

                if renderFailed {
                    Text(String(localized: "语法未闭合或暂不可预览"))
                        .font(Theme.Typography.text(9.5, .medium))
                        .foregroundColor(Theme.Colors.contentTertiary)
                }

                Spacer(minLength: 0)

                // 风格与主题快捷控件：仅在图表模式且渲染成功时显示，视觉与右侧「代码 / 复制」胶囊按钮完全统一
                if !renderFailed && !isShowingCode {
                    // 1. 外观风格选择按钮 (classic / neo / handDrawn)
                    Button(action: showLookMenu) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: currentLook.iconName)
                                .font(Theme.Typography.text(9.5, .medium))
                            Text(currentLook.shortName)
                                .font(Theme.Typography.text(9.5, .medium))
                        }
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                                .fill(Theme.Colors.surfaceButton)
                        )
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help(String(localized: "选择 Mermaid 外观风格 (look)"))
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
                    .accessibilityHidden(!hovered)

                    // 2. 内置主题选择按钮
                    Button(action: showThemeMenu) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "paintpalette")
                                .font(Theme.Typography.text(9.5, .medium))
                            Text(currentTheme.shortName)
                                .font(Theme.Typography.text(9.5, .medium))
                        }
                        .foregroundColor(Theme.Colors.contentTertiary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                                .fill(Theme.Colors.surfaceButton)
                        )
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help(String(localized: "选择 Mermaid 内置主题"))
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
                    .accessibilityHidden(!hovered)
                }

                // 模式切换按钮：仅在渲染成功后显示（失败时自动降级展示代码）
                if !renderFailed {
                    Button(action: { isShowingCode.toggle() }) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: isShowingCode ? "arrow.triangle.branch" : "chevron.left.forwardslash.chevron.right")
                                .font(Theme.Typography.text(9.5, .medium))
                            Text(isShowingCode ? String(localized: "图表") : String(localized: "代码"))
                                .font(Theme.Typography.text(9.5, .medium))
                        }
                        .foregroundColor(Theme.Colors.contentTertiary)
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

                // 复制按钮
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

            // 内容区：ZStack 双层常驻，确保流式期间 WebView 始终能接收增量代码并恢复渲染
            ZStack(alignment: .topLeading) {
                MermaidWebView(
                    code: code,
                    isDark: colorScheme == .dark,
                    look: currentLook,
                    theme: currentTheme,
                    renderedHeight: $renderedHeight,
                    renderFailed: $renderFailed
                )
                .frame(height: (isShowingCode || renderFailed) ? nil : max(renderedHeight, 36))
                .opacity((isShowingCode || renderFailed) ? 0 : 1)
                .allowsHitTesting(!isShowingCode && !renderFailed)

                if isShowingCode || renderFailed {
                    CodeBlockText(code: code, language: "mermaid")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        .onChange(of: code) { _ in
            if renderFailed {
                renderFailed = false
            }
        }
    }

    private func showLookMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var actions: [MermaidMenuAction] = []

        for item in MermaidLook.allCases {
            let action = MermaidMenuAction {
                lookRaw = item.rawValue
            }
            actions.append(action)
            let menuItem = NSMenuItem(title: item.displayName, action: #selector(MermaidMenuAction.invoke), keyEquivalent: "")
            menuItem.target = action
            menuItem.state = (item == currentLook) ? .on : .off
            menu.addItem(menuItem)
        }

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func showThemeMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var actions: [MermaidMenuAction] = []

        for item in MermaidTheme.allCases {
            let action = MermaidMenuAction {
                themeRaw = item.rawValue
            }
            actions.append(action)
            let menuItem = NSMenuItem(title: item.displayName, action: #selector(MermaidMenuAction.invoke), keyEquivalent: "")
            menuItem.target = action
            menuItem.state = (item == currentTheme) ? .on : .off
            menu.addItem(menuItem)
        }

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func copyCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

private final class MermaidMenuAction: NSObject {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}
