// SettingsField: 设置页统一输入组件（单行 / 密码 / 多行容器）。
//
// 第一性原理：SwiftUI TextField 在 macOS 上每次键入都把 binding 写回底层控件，
// 写回会重置 field editor 的尾随空格排版与光标（空格不实时渲染的根因）。
// 原生 NSTextField/NSSecureTextField 的 field editor 本身实时渲染空格、光标与
// 中文 IME 组字均走 AppKit 标准行为——故单行/密码输入改用原生内核，
// 且「编辑期间绝不写回 stringValue」，只在非编辑态同步外部值。
//
// 视觉单一来源：surfaceField 底 + groupCardStroke 细描边 + 聚焦 accentSoftStroke
// 强调环；显式左对齐（macOS Form 默认右对齐是旧系统偏好遗留，不沿用）。
// 多行输入（人设提示词）保留 SwiftUI TextField(axis: .vertical)，经
// settingsFieldContainer 共享同一容器外观。

import SwiftUI
import AppKit

// MARK: - 统一容器外观（单行组件与多行输入共用）

struct SettingsFieldContainer: ViewModifier {
    var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard)
                    .fill(Theme.Colors.surfaceField)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.insetCard)
                    .stroke(
                        isFocused ? Theme.Colors.accentSoftStroke : Theme.Colors.groupCardStroke,
                        lineWidth: isFocused ? 1 : 0.5
                    )
            )
    }
}

extension View {
    /// 设置页输入容器外观；多行 SwiftUI 输入用此 modifier 与单行组件统一。
    func settingsFieldContainer(focused: Bool) -> some View {
        modifier(SettingsFieldContainer(isFocused: focused))
    }
}

// MARK: - 单行 / 密码统一输入组件

struct SettingsField<Leading: View, Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool
    var monospaced: Bool
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    @State private var isFocused = false

    init(
        placeholder: String,
        text: Binding<String>,
        isSecure: Bool = false,
        monospaced: Bool = false,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.placeholder = placeholder
        self._text = text
        self.isSecure = isSecure
        self.monospaced = monospaced
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            leading
            NativeSettingsField(
                text: $text,
                placeholder: placeholder,
                isSecure: isSecure,
                monospaced: monospaced,
                isFocused: $isFocused
            )
            trailing
        }
        .frame(maxWidth: .infinity)
        .settingsFieldContainer(focused: isFocused)
    }
}

// MARK: - 原生内核（编辑期间不写回，保护空格/光标/IME）

private struct NativeSettingsField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isSecure: Bool
    let monospaced: Bool
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = isSecure ? NSSecureTextField() : NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .left
        field.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: Theme.Typography.body, weight: .regular)
            : NSFont.systemFont(ofSize: Theme.Typography.body)
        field.placeholderString = placeholder
        field.stringValue = text
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
        // 编辑期间绝不写回：field editor 持有真实文本（含尾随空格与 IME 组字），
        // 写回会重置排版与光标——这正是 SwiftUI TextField 空格不实时渲染的根因。
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeSettingsField

        init(_ parent: NativeSettingsField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFocused = false
        }
    }
}
