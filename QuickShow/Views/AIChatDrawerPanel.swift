import SwiftUI
import AppKit

// MARK: - 输入坞抽屉（权限确认 / AI 提问）
//
// 设计目标（2026-10 拍板）：
// - 无缝一体：抽屉紧贴输入卡上沿、衔接处无间隙。玻璃面/圆角/描边/阴影由 AIChatView
//   的坞体连续容器统一施加（抽屉 + 输入卡共享同一个 Radius.groupCard 连续体），
//   本文件只提供抽屉「内容」，不再自带材质——抽屉是输入框"长出"的上半部分，不是独立弹窗。
// - 动画：从输入卡上沿向上滑入（.move(edge: .bottom) + opacity，0.25s easeOut，
//   由 AIChatView 在 request id 变化处统一施加），窗口 frame 不动、纯视图内布局
//   （规避整窗玻璃 + SwiftUI 测量链死锁，与监控看板绕开同一路径）。
// - 高度纪律（2026-11 事故定证）：两类抽屉共享同一高度预算——整抽屉 ≤ 窗口内容高度的 80%。
//   坞体是底部锚定的 overlay，不做预算的抽屉会向上顶穿窗口被裁掉（长 heredoc 命令曾把
//   标题行与终端顶栏整段推到窗外）。故：头尾固定区恒可见，只有正文区在预算内滚动。
// - ESC 语义：抽屉在场时 ESC 优先取消抽屉（权限 = 拒绝 / 提问 = 取消），
//   窗口层 / 视图层 / 按键监听三条链路均已前置（见 AIWindowManager 与 AIChatView）。
// - 状态本地化：选中态/自由输入文本存 @State；调用方给面板 .id(request.id)，
//   请求切换即整树重建、状态天然重置。
//
// 数据契约：只消费 ChatInteractionCenter 发布的 ChatDrawerRequest；
// resolve/submit/cancel 后逻辑层清空 request，抽屉随动画收起。

/// 抽屉视觉与高度常量（本特性私有节拍，是否收编进 DesignTokens 留给设计系统统一决定）。
enum AIChatDrawerMetrics {
    /// 抽屉滑入/滑出时长（easeOut）
    static let slideDuration: Double = 0.25
    /// 整抽屉高度上限 = 窗口内容高度 × 该比例（未量到窗口高度时按 fallback 折算）
    static let maxHeightRatio: CGFloat = 0.8
    /// 窗口高度未量到（首帧 / UI 未上屏）时的折算基准：× 0.8 = 420pt 历史兜底预算
    static let fallbackWindowHeight: CGFloat = 525
    /// 正文区最小保底高度：窗口极小时也保留几行可读空间（头尾固定区已吃掉大半预算时兜底）
    static let bodyMinHeight: CGFloat = 72
    /// 参数原文超过该长度即视为「长命令」，默认折叠为单行摘要
    static let argumentsShortLimit: Int = 120

    /// 整抽屉可用总高（窗口高度 → 80% 预算）
    static func totalHeight(for windowHeight: CGFloat) -> CGFloat {
        (windowHeight > 200 ? windowHeight : fallbackWindowHeight) * maxHeightRatio
    }
}

/// 抽屉高度预算的窗口来源（唯一真源）。
/// 优先取托管的 AI 面板内容高度：不依赖 key 状态，设置窗/主面板为 key 时也不会取错。
@MainActor
enum AIChatDrawerBudget {
    static var windowHeight: CGFloat {
        let managed = AIWindowManager.shared.contentHeight
        if managed > 200 { return managed }
        if let height = NSApp.keyWindow?.contentView?.bounds.height, height > 200 { return height }
        return 0
    }
}

// MARK: - 抽屉正文区（两类抽屉共用）

/// 正文区高度纪律：
/// - 自然高度 ≤ 预算：完全由内容撑开（紧凑包裹，无多余留白，不出滚动条）；
/// - 自然高度 > 预算：锁在预算内，内部滚动（滚动条按需出现）；
///   头尾固定区（标题 / 告警 / 记忆胶囊 / 操作按钮）永远在滚动区之外，绝不随长内容滚出窗外。
///
/// 测量走「GeometryReader 内容 onAppear/onChange 直写 @State」：本视图上下文里
/// PreferenceKey 冒泡不可靠（见 AIChatInputDock 坞高实测头注），故与坞体同一可靠路径。
struct DrawerBodyArea<Content: View>: View {
    /// 正文区可用高度预算（调用方已扣除头尾固定区高度）
    let availableHeight: CGFloat
    /// 正文内容；回传 ScrollViewProxy 供调用方做滚动定位（多题切换等）
    @ViewBuilder let content: (ScrollViewProxy) -> Content

    /// 正文自然高度实测
    @State private var naturalHeight: CGFloat = 0

    /// 是否超出预算（决定滚动条是否常显）
    private var isOverflowing: Bool { naturalHeight > availableHeight + 0.5 }

    /// 锁定高度：未量到自然高度时交回 SwiftUI 理想布局（滑动动画期间即完成首轮校准）
    private var lockedHeight: CGFloat? {
        guard naturalHeight > 0 else { return nil }
        return min(naturalHeight, max(availableHeight, 0))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: isOverflowing) {
                content(proxy)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { noteNaturalHeight(geo.size.height) }
                                .onChange(of: geo.size.height) { noteNaturalHeight($0) }
                        }
                    )
            }
            .frame(height: lockedHeight)
        }
    }

    /// 自然高度回写（0.5pt 去抖，防测量微抖引发的重渲染回环）
    private func noteNaturalHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        if abs(height - naturalHeight) > 0.5 {
            naturalHeight = height
        }
    }
}

// MARK: - 固定区高度实测

extension View {
    /// 固定区（标题行 / 操作行）高度实测：直写 @State，供抽屉预算扣减。
    /// 与坞高实测同一可靠路径——本视图上下文里 PreferenceKey 冒泡会断在链尾。
    func measureDrawerHeight(into binding: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { noteDrawerChromeHeight(geo.size.height, into: binding) }
                    .onChange(of: geo.size.height) { noteDrawerChromeHeight($0, into: binding) }
            }
        )
    }
}

/// 固定区高度回写（0.5pt 去抖；0 视为瞬态测量失败直接忽略）
private func noteDrawerChromeHeight(_ height: CGFloat, into binding: Binding<CGFloat>) {
    guard height > 0 else { return }
    if abs(height - binding.wrappedValue) > 0.5 {
        binding.wrappedValue = height
    }
}

// MARK: - 抽屉分派容器
/// 输入坞抽屉：按请求类型分派权限确认 / 用户提问两套面板。
/// 调用方负责 transition / 动画 / 玻璃容器 / .id 状态重置；本视图负责统一高度预算与内容分派。
struct AIChatDrawerPanel: View {
    let request: ChatDrawerRequest

    /// 窗口内容高度（抽屉预算基准）；窗口拖拽缩放时同步刷新
    @State private var windowHeight: CGFloat = 0

    private var heightBudget: CGFloat {
        AIChatDrawerMetrics.totalHeight(for: windowHeight)
    }

    var body: some View {
        Group {
            switch request {
            case .toolConfirmation(let confirmation):
                ToolConfirmationDrawerContent(request: confirmation, heightBudget: heightBudget)
            case .userQuestions(let questions):
                UserQuestionDrawerContent(request: questions, heightBudget: heightBudget)
            }
        }
        .onAppear { windowHeight = AIChatDrawerBudget.windowHeight }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in
            let current = AIChatDrawerBudget.windowHeight
            if abs(current - windowHeight) > 0.5 {
                windowHeight = current
            }
        }
    }
}
