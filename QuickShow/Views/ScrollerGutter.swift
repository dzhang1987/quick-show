import SwiftUI

// MARK: - 滚动条槽（Scroller Gutter）

/// 为系统 overlay 滚动条预留内容留白，根治「滚动一启动，滚动条压住末行文字」。
///
/// 本质原因是 AppKit 的 overlay 滚动条**浮在内容之上、不占布局空间**
/// （`NSScrollView.scrollerStyle == .overlay`，macOS 默认档）。代码块横向滚动时，
/// 末行长行恰好贴着滚动条轨道，一滚就被半透明胶囊盖住。
///
/// 系统行为不可改，改从内容侧让位：把与滚动条带宽等宽的留白垫进**滚动内容**，
/// 胶囊便落在留白里，文字永不入轨。留白同时承接卡片的底部内边距（各调用点把
/// 自身底部 padding 归零），静止观感与旧版一致——不白长高度，也不破坏上下对称。
///
/// - 水平轴向（横向滚动）→ 底部留白；垂直轴向（纵向滚动）→ 右侧留白。
/// - 带宽单源：`Theme.Layout.scrollerGutter`。
struct ScrollerGutterModifier: ViewModifier {
    let axes: Axis.Set

    func body(content: Content) -> some View {
        content
            .padding(.bottom, axes.contains(.horizontal) ? Theme.Layout.scrollerGutter : 0)
            .padding(.trailing, axes.contains(.vertical) ? Theme.Layout.scrollerGutter : 0)
    }
}

extension View {
    /// 见 `ScrollerGutterModifier`。入参填该滚动视图实际启用的轴向。
    func scrollerGutter(_ axes: Axis.Set) -> some View {
        modifier(ScrollerGutterModifier(axes: axes))
    }
}
