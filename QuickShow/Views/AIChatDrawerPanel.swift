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
// - ESC 语义：抽屉在场时 ESC 优先取消抽屉（权限 = 拒绝 / 提问 = 取消），
//   窗口层 / 视图层 / 按键监听三条链路均已前置（见 AIWindowManager 与 AIChatView）。
// - 状态本地化：选中态/自由输入文本存 @State；调用方给面板 .id(request.id)，
//   请求切换即整树重建、状态天然重置。
//
// 数据契约：只消费 ChatInteractionCenter 发布的 ChatDrawerRequest；
// resolve/submit/cancel 后逻辑层清空 request，抽屉随动画收起。

/// 抽屉视觉常量（本特性私有节拍：0.25s 滑入与 Motion tokens 现有档位皆不同，
/// 是否收编进 DesignTokens 留给设计系统统一决定，先就近收敛在本文件）。
enum AIChatDrawerMetrics {
    /// 抽屉滑入/滑出时长（easeOut）
    static let slideDuration: Double = 0.25
    /// 提问面板题目区限高（超出内部滚动；抽屉整体不把输入卡推出窗口）
    static let questionsMaxHeight: CGFloat = 260
    /// 权限面板完整参数区限高（超出内部滚动）
    static let argumentsMaxHeight: CGFloat = 160
    /// 统一输入条固定高度（常驻 2 行）：2 × 12pt 正文行高(≈14.8) + TextEditor 垂直内边距(≈7)
    /// + 1pt 防裁切余量 ≈ 38；内容超出 2 行时内部滚动（滚动条已隐藏，见 UserQuestionDrawer）
    static let freeInputHeight: CGFloat = 38
    /// 参数原文超过该长度即视为「长命令」，默认折叠为单行摘要
    static let argumentsShortLimit: Int = 120
}

// MARK: - 抽屉分派容器

/// 输入坞抽屉：按请求类型分派权限确认 / 用户提问两套面板。
/// 调用方负责 transition / 动画 / 玻璃容器 / .id 状态重置；本视图仅排版内容。
struct AIChatDrawerPanel: View {
    let request: ChatDrawerRequest

    var body: some View {
        switch request {
        case .toolConfirmation(let confirmation):
            ToolConfirmationDrawerContent(request: confirmation)
        case .userQuestions(let questions):
            UserQuestionDrawerContent(request: questions)
        }
    }
}
