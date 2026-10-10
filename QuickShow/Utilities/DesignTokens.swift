import SwiftUI
import AppKit

// MARK: - 明暗模式（全 App 范围）
// NSApp.appearance 一变，所有窗口（面板玻璃/NSHostingView 语义色/设置窗口）的
// effectiveAppearance 全部联动翻转，内容层零改动；琥珀色板的 dynamicProvider 双模式自动适配
enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto = "auto"      // 跟随系统
    case light = "light"
    case dark = "dark"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .auto: return String(localized: "自动")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }
    
    /// 全 App 即时应用（面板显示中切换也即时生效，无需重建窗口）
    func apply() {
        switch self {
        case .auto:  NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:  NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - 主题变体
// standard = 黑曜石现状（值一字不改）；amber = 琥珀暖色（仅暖色化强调点缀与主时钟渐变，
// 文本主语义色/表面层级/玻璃材质完全不动，状态语义色绿=健康红=警告保持惯例）
enum ThemeVariant: String, CaseIterable, Identifiable {
    case standard = "standard"
    case amber = "amber"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .standard: return String(localized: "默认（黑曜石）")
        case .amber: return String(localized: "琥珀暖色")
        }
    }
}

// MARK: - 主题色板（变体间可变的颜色通道；未入板的令牌 = 全主题固定值）
struct ThemePalette {
    let accent: Color               // 主强调色（CPU正常态/上传/蓝牙/pinned/链接/清理按钮）
    let actionButtonFill: Color     // 实心操作钮底色（亮暗双模式自适应：琥珀暖金/科技青）
    let actionButtonForeground: Color // 实心操作钮前景色（亮暗双模式自适应：确保对比度达标）
    let clockGradientTop: Color     // 主时钟渐变顶
    let clockGradientBottom: Color  // 主时钟渐变底
    let secondsGradientTop: Color   // 秒数渐变顶
    let secondsGradientBottom: Color// 秒数渐变底
    
    // 亮暗双模式自适应构造（解析跟随视图 effectiveAppearance，与玻璃明暗同步）
    private static func adaptive(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    
    /// 默认主题：现状值原样（中性黑白渐变 + 系统青强调；实心钮暗色亮青配黑标、亮色深青蓝配白标）
    static let standard = ThemePalette(
        accent: Color.cyan,
        actionButtonFill: adaptive(dark: (0.15, 0.78, 0.88), light: (0.03, 0.52, 0.65)),
        actionButtonForeground: adaptive(dark: (0.05, 0.05, 0.05), light: (1.0, 1.0, 1.0)),
        clockGradientTop: Color.primary,
        clockGradientBottom: Color.primary.opacity(0.9),
        secondsGradientTop: Color.primary.opacity(0.85),
        secondsGradientBottom: Color.primary.opacity(0.65)
    )
    
    /// 琥珀暖色：暖金琥珀调（暗色取明亮金 #F5B942 系配高对比深褐黑标；
    /// 亮色实心操作钮取暖金琥珀橙 #BF5700 配纯白标，对比度 4.8:1，告别发暗泥褐）
    static let amber = ThemePalette(
        accent: adaptive(dark: (0.96, 0.73, 0.26), light: (0.71, 0.33, 0.04)),
        actionButtonFill: adaptive(dark: (0.96, 0.73, 0.26), light: (0.75, 0.35, 0.02)),
        actionButtonForeground: adaptive(dark: (0.10, 0.07, 0.02), light: (1.0, 1.0, 1.0)),
        clockGradientTop: adaptive(dark: (0.99, 0.90, 0.71), light: (0.55, 0.32, 0.05)),
        clockGradientBottom: adaptive(dark: (0.94, 0.66, 0.24), light: (0.76, 0.45, 0.06)),
        secondsGradientTop: adaptive(dark: (0.99, 0.90, 0.71), light: (0.55, 0.32, 0.05)).opacity(0.85),
        secondsGradientBottom: adaptive(dark: (0.94, 0.66, 0.24), light: (0.76, 0.45, 0.06)).opacity(0.65)
    )
}

// MARK: - 全局设计令牌系统（Design Tokens）
// 所有视觉硬编码值的单一来源：颜色层级 / 字体角色 / 间距档位 / 圆角 / 布局尺寸 / 动画时长。
// 原则：
// 1. 令牌值 = 现状值的纯收敛（外观零变化），未来主题变体只需改本文件
// 2. 语义色直接转发系统语义色（primary/secondary），明暗翻转由 effectiveAppearance 驱动，不钉死
// 3. 注意：系统 tertiary 亮色实测 ≈2.3:1 不达标已弃用，说明小字统一走 contentTertiary（≈4.7:1）
enum Theme {
    
    /// 当前主题变体（轻量读取通道：由 AppState 启动与切换时写入，避免 Theme 反向依赖 AppState；
    /// 切换时 AppState 触发 objectWillChange → 全视图树 re-render → 下方计算属性重新求值生效）
    static var variant: ThemeVariant = .standard
    
    /// 当前色板
    static var palette: ThemePalette {
        switch variant {
        case .standard: return .standard
        case .amber: return .amber
        }
    }
    
    // MARK: - 颜色令牌（未来主题变体的核心切换点）
    enum Colors {
        // 内容层级（直接转发系统语义色，随玻璃/材质明暗自动翻转；全主题固定，不被主题洗掉）
        static let contentPrimary = Color.primary
        static let contentSecondary = Color.secondary
        // 面板玻璃专用二级文本：系统 secondary 在亮玻璃上实测 ≈3.9:1 不达 WCAG AA 4.5:1，
        // 面板承载的是「一瞥即读」的关键数值（SSID/曲名/卡片副标），自建 0.65 下限（亮 ≈7:1 / 暗 ≈8.8:1）；
        // 设置窗口（非玻璃、系统表单材质）仍用系统 secondary，此处不动
        static let contentSecondaryStrong = Color.primary.opacity(0.65)
        
        // 结构性元素（亮玻璃对比度下限保护：黑色低 alpha 是"阴影"型弱对比，需高于暗色白线的发光感）
        static let dividerOpacity: Double = 0.25          // 分割线中段峰值
        // 一瞥倒计时微光进度条（贴面板底边、水平居中，随倒计时从左右两侧向中间对称收拢：
        // 峰值强于分割线 0.25 保证剩余时间可读，又显著弱于内容色，克制不抢戏；
        // featherEdge = 光带单侧羽化带宽度比例，两端渐隐至透明，与分割线的对称渐隐语言一致）
        static let glanceProgressOpacity: Double = 0.45
        static let glanceProgressFeatherEdge: CGFloat = 0.12
        static let cardStroke = Color.primary.opacity(0.09)      // Bento 卡片描边
        static let groupCardStroke = Color.primary.opacity(0.08) // 速查组卡描边（0.5pt 细线）
        
        // 表面填充（玻璃上的微质感层级：越深结构越强）
        static let surfaceCard = Color.primary.opacity(0.03)     // 卡片底
        static let surfaceInset = Color.primary.opacity(0.02)    // 内层卡底
        static let surfaceBadge = Color.primary.opacity(0.04)    // 未激活徽章底
        static let surfaceButton = Color.primary.opacity(0.05)   // 微按钮底
        static let surfaceTrack = Color.primary.opacity(0.06)    // 进度槽轨道
        static let surfaceKeyCap = Color.primary.opacity(0.06)   // 快捷键键帽底（与轨道同值，语义独立）
        
        // 徽章（日期/toast：需可感知存在感，toast 为强提示再高一档）
        static let badgeFill = Color.primary.opacity(0.08)
        static let badgeStroke = Color.primary.opacity(0.15)
        static let toastFill = Color.primary.opacity(0.13)
        static let toastStroke = Color.primary.opacity(0.25)
        
        // 交互元素（明确静止可见态 + hover 增强态）
        static let iconRest = Color.primary.opacity(0.60)        // 图钉/箭头静止态（可读下限）
        static let iconHover = Color.primary.opacity(0.95)       // hover 增强
        static let iconHoverBg = Color.primary.opacity(0.10)     // hover 圆底
        static let closeIcon = Color.primary.opacity(0.55)       // CheatSheet 关闭钮
        static let wifiOff = Color.primary.opacity(0.55)         // WiFi 断连弱化（亮色对比度下限 0.55）
        static let idleText = Color.primary.opacity(0.45)        // "就绪"等弱化文字（亮色 ≈3.5:1 装饰下限）
        static let presetText = Color.primary.opacity(0.55)      // 番茄预设未选中
        // 三级说明文本（替代系统 .tertiary：亮色模式系统三级 ≈2.3:1 远低于 WCAG AA 4.5:1，
        // 0.55 不透明度双模式实测 ≈4.7:1 达标；用于农历小字/说明/时间戳等辅助文本）
        static let contentTertiary = Color.primary.opacity(0.55)
        
        // 实心翻转按钮（播放钮：底随明暗翻转，文字取窗口背景反色保证双模式对比）
        static let solidButtonFill = Color.primary.opacity(0.92)
        static let solidButtonText = Color(.windowBackgroundColor)
        
        // 状态语义色（全主题固定：绿=接电/健康、红=低电警告，惯例不被主题洗掉）
        static let statusGood = Color(red: 0.35, green: 0.90, blue: 0.45)
        static let statusWarning = Color(red: 1.0, green: 0.35, blue: 0.35)
        
        // 变体通道（计算属性，随 Theme.variant 切换；调用点无需感知主题存在）
        static var accent: Color { Theme.palette.accent }
        static var actionButtonFill: Color { Theme.palette.actionButtonFill }
        static var actionButtonForeground: Color { Theme.palette.actionButtonForeground }
        static var clockGradientTop: Color { Theme.palette.clockGradientTop }
        static var clockGradientBottom: Color { Theme.palette.clockGradientBottom }
        static var secondsGradientTop: Color { Theme.palette.secondsGradientTop }
        static var secondsGradientBottom: Color { Theme.palette.secondsGradientBottom }

        // MARK: AI 对话窗专用（2026-10 视觉层次专项）
        // 设计逻辑：≥90% 不透明度底板稳定阅读区（玻璃穿透曾致文字对比度随位置波动、
        // 侧栏出现模糊残影），半透明只留给窗体外缘；层级靠「底板深浅差 + 0.5pt 描边」
        // 而非透明度叠加；全部随明暗模式自适应、与主题变体正交（不被琥珀/黑曜石洗掉）。
        /// 主区底板：暗色近黑 94% / 亮色近白 95%
        static let chatBase = aiAdaptive(dark: (0.115, 0.115, 0.125, 0.94), light: (0.99, 0.99, 0.99, 0.95))
        /// 侧栏底板：比主区深半档的轻纱层（层级分区靠深浅差而非实色）——整窗真玻璃后
        /// 透明度 0.95→0.35，玻璃折射/透底从侧栏穿出（旧实色是「整窗无玻璃」时代的
        /// 压底设计，真玻璃上即窗中窗割裂）
        static let chatSidebarBase = aiAdaptive(dark: (0.085, 0.085, 0.095, 0.35), light: (0.955, 0.955, 0.96, 0.35))
        /// 助手消息气泡：比主区亮一档的低对比底板（亮色近纯白靠描边出层级）
        static let chatAssistantBubble = aiAdaptive(dark: (1, 1, 1, 0.065), light: (1, 1, 1, 0.90))
        /// 输入卡底板：操作焦点再亮半档，与主区明确拉开
        static let chatInputCard = aiAdaptive(dark: (1, 1, 1, 0.085), light: (1, 1, 1, 0.95))
        /// 提亮档描边（0.14）：输入卡 / 表格卡 / 浮动操作条——比 cardStroke(0.09) 高一档
        static let chatStrokeStrong = Color.primary.opacity(0.14)
        /// 表格表头行底色（与 surfaceTrack 同值，语义独立）
        static let chatTableHeader = Color.primary.opacity(0.05)
        /// 表格斑马纹（±4% 白量级，偶数行）
        static let chatTableRowAlternate = Color.primary.opacity(0.035)

        // —— 2026-10 视觉质感专项（浮岛化/控件语言/气泡）——
        /// 用户消息气泡实底：琥珀语言（亮色低饱和烧琥珀暖纸 #F6EEDF 系 / 暗色深琥珀 #362C14 系，
        /// 暗色留 8% 透明随玻璃微光）；与主题变体正交——用户气泡恒为琥珀，不随黑曜石/琥珀切换。
        static let chatUserBubble = aiAdaptive(dark: (0.216, 0.173, 0.098, 0.92), light: (0.965, 0.933, 0.875, 1.0))
        /// 输入坞微胶囊 0.5pt 白 rim（⊕/剪贴板/模型 chip 的受光边：浅色白 40% / 深色白 20%）
        static let chatCapsuleRim = aiAdaptive(dark: (1, 1, 1, 0.20), light: (1, 1, 1, 0.40))
        /// 发送钮禁用态底：浅灰实底，与输入卡底保持 ≥1.2:1 对比（杜绝旧版 1.04:1 隐形事故）
        static let chatSendDisabledFill = aiAdaptive(dark: (1, 1, 1, 0.18), light: (0, 0, 0, 0.14))

        // —— 2026-10 AI 窗视觉重设计（刻度轨导航 / 行内代码提亮 / 浮层深底）——
        /// 行内代码 chip 底色：比面板亮一档（primary 0.10，旧值 surfaceTrack 0.06 在玻璃上近乎隐形）；
        /// AttributedString 渲染管线不支持背景框描边，对比度由底色 + 主文字色承担
        static let chatInlineCodeFill = Color.primary.opacity(0.10)
        // 刻度轨明暗梯度（与大小放大共用同一条余弦权重曲线，大小与明暗同步流动）：
        // 静止 = rest；光标正下方 = bright；远端 = dim（比静止更暗——放大态下全轨变暗、
        // 波峰提亮，梯度可辨）；当前条恒 accent、明暗与大小共用余弦权重同步流动
        static let chatTickRestOpacity: Double = 0.42
        static let chatTickBrightOpacity: Double = 0.60
        static let chatTickDimOpacity: Double = 0.28
        // 选中刻度明暗梯度（方案 A：高辨识度基底，随光标波峰提亮、远端暗淡）：
        static let chatTickActiveRestOpacity: Double = 0.65
        static let chatTickActiveBrightOpacity: Double = 1.00
        static let chatTickActiveDimOpacity: Double = 0.40
        /// 浏览导航浮层深底（预览胶囊 / 回底圆钮共用）：近不透明深面板，
        /// 玻璃上稳定承载白字，与坞/工具条同一家族
        static let chatNavFloatFill = aiAdaptive(dark: (0.15, 0.15, 0.165, 0.95), light: (0.98, 0.98, 0.985, 0.95))
        /// 已压缩消息行降档不透明度（0.55：与 contentTertiary 同 alpha 档，双模式实测
        /// ≈4.7:1 达 WCAG AA——原文仍是用户的阅读资产，只降视觉层级，不折叠不隐藏）
        static let summarizedRowOpacity: Double = 0.55

        // 窗口边缘 rim light（方向性内描边：顶部受光最强 → 侧缘弱 → 底缘近无，
        // 受光方向 = 玻璃厚度感；替代旧版均匀 1px 灰线的无方向感）
        static let rimTopOpacity: Double = 0.70      // 顶缘白
        static let rimSideOpacity: Double = 0.15     // 左右侧缘白
        static let rimBottomOpacity: Double = 0.05   // 底缘白
        static let rimDarkEdgeOpacity: Double = 0.08 // 底缘内侧 1pt 黑色重边（与窗影衔接）
        /// 输入卡聚焦态 rim：窗口 key 时叠加的 accent 低透明度环（材质对状态有响应）
        static let dockFocusRimOpacity: Double = 0.35

        /// AI 窗专用自适应色构造（rgba 四元组，解析跟随视图 effectiveAppearance）
        private static func aiAdaptive(
            dark: (Double, Double, Double, Double),
            light: (Double, Double, Double, Double)
        ) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let c = isDark ? dark : light
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
            })
        }
    }
    
    // MARK: - 字体角色（按语义角色命名，同值角色各自独立以便未来分调）
    // 字体族策略：正文一律 SF Pro（系统 .system），纯数字/时钟/键帽走 SF Mono（.monospaced）。
    // 字号阶梯 2026-10 系统性上调一档（微字号保底 9pt）：信息密度不能以「看不清」为代价。
    enum Typography {
        // 字体族入口（统一构造点，消灭散落的裸 .system 调用）
        static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)                                  // SF Pro 正文
        }
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)             // SF Mono 数字
        }
        
        // 主时钟（随面板实际渲染宽度连续缩放：min(max(宽×scale, min), max)）
        static let clockScale: CGFloat = 0.183
        static let clockMin: CGFloat = 84
        static let clockMax: CGFloat = 126
        static let secondsRatio: CGFloat = 0.42   // 秒数 = 主时钟 × 0.42
        static let periodRatio: CGFloat = 0.22    // 上午/下午 = 主时钟 × 0.22
        
        static let micro: CGFloat = 9        // 微型图标/文字（农历小字下限）
        static let tiny: CGFloat = 9.5       // 微按钮文字
        static let mini: CGFloat = 10        // 微型徽章文字
        static let caption: CGFloat = 10.5   // 说明/辅助文字
        static let footnote: CGFloat = 11    // 静音/授权等小字
        static let label: CGFloat = 11.5     // 标签（CPU 负载/系统磁盘）
        static let body: CGFloat = 12        // 正文/状态栏图标/描述
        static let callout: CGFloat = 12.5   // 卡片标题/状态数值
        static let iconLarge: CGFloat = 13   // 电池图标（视觉偏小需加大一档）
        static let toast: CGFloat = 13.5     // toast 文字
        static let badge: CGFloat = 14       // 日期徽章/CheatSheet 标题
        static let badgeTracking: CGFloat = 1.2
        static let closeButton: CGFloat = 16 // CheatSheet 关闭钮
        static let keyCap: CGFloat = 11.5    // 快捷键键帽（mono bold，与 label 同值）
        static let pomodoro: CGFloat = 21    // 番茄钟倒计时大字
        static let title: CGFloat = 18       // 设置页大标题（关于/速查页眉）
        static let settingsIcon: CGFloat = 26 // 设置页装饰大图标（关于页）
        
        // 日历专用档位（2026-10 可读性修复：格子主内容用足 48pt 格子空间，与顶栏标题拉开层级）
        static let calendarDay: CGFloat = 13.5   // 格子日期数字（格子主内容，semibold）
        static let calendarLunar: CGFloat = 10   // 农历/节气/节日小字（medium 字重起步）
        static let calendarWeekday: CGFloat = 11 // 周标题表头
        static let calendarTitle: CGFloat = 15   // 日历面板主标题（年月/日期范围，全面板视觉锚点）
    }
    
    // MARK: - 间距档位
    enum Spacing {
        static let xxxs: CGFloat = 1.5   // 微按钮垂直内边
        static let xxs: CGFloat = 2      // 图标文字微对、卡片顶部补偿
        static let xs: CGFloat = 3       // 图标文字对、键帽垂直内边
        static let sm: CGFloat = 4       // 紧凑元素对
        static let smd: CGFloat = 4.5    // 徽章胶囊垂直内边、图标数值对
        static let chip: CGFloat = 5     // 微徽章内边、图标标题对
        static let md: CGFloat = 6       // 小组件内边距
        static let mdlg: CGFloat = 7     // 微胶囊水平内边
        static let lg: CGFloat = 8       // 标准元素间距
        static let xl: CGFloat = 10      // 卡片内分组距
        static let xxl: CGFloat = 12     // 双列卡片网格距
        static let xxxl: CGFloat = 14    // 次级区块边距
        static let card: CGFloat = 16    // 卡片内边距
        static let section: CGFloat = 18 // 区块边距
        static let divider: CGFloat = 20 // 监控区分割线水平内收
        static let panel: CGFloat = 24   // 面板主水平内边距
        static let chatGroupGap: CGFloat = 36 // AI 对话消息轮次间距（26 → 36，三级节奏顶层；组内用 xl=10）
    }
    
    // MARK: - 圆角（连续曲率）
    enum Radius {
        static let panel: CGFloat = 26      // 面板（PanelManager 玻璃双写 + 降级路径裁剪 的单一来源）
        static let cheatSheet: CGFloat = 24 // CheatSheet 卡
        static let card: CGFloat = 16       // Bento 大卡
        static let groupCard: CGFloat = 12  // 速查组卡
        static let insetCard: CGFloat = 10  // 内层卡（番茄钟台/日历卡）
        static let keyCap: CGFloat = 5      // 快捷键键帽
        static let userBubble: CGFloat = 18 // 用户消息气泡（groupCard 12 → 18，更圆的对话语言）
        static let previewCapsule: CGFloat = 8 // 刻度轨预览胶囊（2026-10 重设计）
    }
    
    // MARK: - 布局尺寸（面板尺寸档位的单一来源；ScreenHelper.metrics 引用此处，逻辑不搬）
    enum Layout {
        // 面板三档尺寸（标准/适中/极简）
        // 高度账目（展开态内容实需）：hero 8 + 日期徽章 ~34 + 呼吸 ~10 + 分割 0.5
        // + 状态栏上 10 + 状态栏 ~35 + 下 12 + 监控占位 259.5 + 时钟（窗宽×0.183 连续缩放）。
        // 全局字号上调后旧高度即溢出账本：内容超高被根帧 .center 双向居中裁剪（顶徽章/底卡同裁），
        // 故舒适/极简展开高修正为按标准档（520，已验证结余 ~14pt）同账同余量的值。
        static let standardCompact = NSSize(width: 680, height: 340)
        static let standardExpanded = NSSize(width: 740, height: 520)
        static let comfortCompact = NSSize(width: 540, height: 280)
        static let comfortExpanded = NSSize(width: 620, height: 512)
        static let legacyCompact = NSSize(width: 440, height: 258)
        static let legacyExpanded = NSSize(width: 520, height: 494)
        // 日历视图尺寸（按 G 任意状态直达日历档；与三档尺寸偏好同语义联动）
        static let standardCalendar = NSSize(width: 740, height: 640)
        static let comfortCalendar = NSSize(width: 620, height: 560)
        static let legacyCalendar = NSSize(width: 520, height: 500)
        // AI 对话窗尺寸（窄长居中，跟随主面板三档偏好；standard 基准 560×680，
        // compact 约 0.88 比例递减，legacy 约 0.78 比例，保持与主面板档位相同的递减风格）
        static let standardAIChat = NSSize(width: 560, height: 680)
        static let comfortAIChat = NSSize(width: 500, height: 600)
        static let legacyAIChat = NSSize(width: 440, height: 520)
        // 日历视图整面板内边距（日历态无时钟/底栏，日历贴面板主边距排布）
        static let calendarTop: CGFloat = 18       // 日历卡片顶部呼吸
        static let calendarBottom: CGFloat = 14    // 日历卡片底部呼吸
        static let centerLift: CGFloat = 26  // 面板中心上移量（黄金分割视线位）
        
        // 展开进度公式端点（expandProgress 线性插值的值源；公式结构在 PanelView，此处仅供值）
        static let heroTopCompact: CGFloat = 30      // 时钟顶距（紧凑）
        static let heroTopExpanded: CGFloat = 8      // 时钟顶距（展开：贴近顶部）
        static let breathCompact: CGFloat = 36       // 呼吸间距上限（紧凑）
        static let breathExpanded: CGFloat = 12      // 呼吸间距上限（展开）
        static let statusTopCompact: CGFloat = 16
        static let statusTopExpanded: CGFloat = 10
        static let statusBottomCompact: CGFloat = 24
        static let statusBottomExpanded: CGFloat = 12
        static let monitorBreath: CGFloat = 14       // 监控区底部呼吸（占位端点 = 内容高 + 此值）
        
        // 监控区
        static let monitorCardHeight: CGFloat = 229  // Bento 卡片黄金高度（字号上调后 +4 补偿）
        // 监控区理想内容总高 = 分割线 0.5 + 间距 8 + 卡片 229 + 卡片上下 padding 2+6
        static let monitorContentHeight: CGFloat = 245.5
        // 日历格子行高（月视图，按档；日历态整面板填充，垂直空间充裕）
        static let calendarCellStandard: CGFloat = 48
        static let calendarCellComfort: CGFloat = 40
        static let calendarCellLegacy: CGFloat = 32
        static let meterHeight: CGFloat = 5          // 进度槽高
        static let metricValueWidth: CGFloat = 36    // 百分比数值右对齐宽度
        static let miniButtonSize: CGFloat = 20      // 重置钮
        static let iconButtonSize: CGFloat = 24      // 图钉/箭头按钮
        // 番茄行紧凑档的统计小字宽上限：ViewThatFits 第二档（预设转紧凑字距）时，
        // 统计小字让出横向预算给可点的预设胶囊，超出部分尾省略号
        static let pomodoroStatsCompactWidth: CGFloat = 64
        static let dividerHeight: CGFloat = 0.5      // 微光分割线（严格 0.5pt）
        static let glanceProgressHeight: CGFloat = 2.5  // 一瞥倒计时微光进度条高（细若光丝，2x 屏 5px 清晰可辨）

        // AI 对话阅读列限宽（消息列/输入坞/浮动导航簇/顶栏图钉共用，经 .chatReadingColumn() 应用）：
        // 行长控制——760 ≈ 正文 ~95 字符、等宽 12.5pt 代码 ~93 列（扣除列边距与代码卡内边距）；
        // 窗口更宽时整列居中、两侧透出玻璃呼吸。原 600 在宽窗下留白占比失衡、长代码行折行严重
        static let chatContentMaxWidth: CGFloat = 760
        // 阅读列水平边距宽档：内容区 ≥720pt 时由 Spacing.section(18) 升为 28——
        // 宽窗列几近铺满时仍保留玻璃呼吸边（28 = 18×1.56，感知可辨而不突兀）。
        // 双侧另有 chatTickRailLane(28) 对称内缩：720~872pt 区间列宽 = 内容宽 − 112；
        // ≥872pt 列锁 760，两侧留白随窗自然生长
        static let chatReadingWideBreakpoint: CGFloat = 720
        static let chatReadingWidePadding: CGFloat = 28
        // AI 对话浮岛输入坞：坞体真实高度不做静态预算，由 inputArea 整体实测直写
        // （GeometryReader onAppear/onChange 事件路径，先例同原生长区高度键）。本常量
        // 仅作布局链建立前的首帧兜底（输入框 72 + 工具行 ≈32 + 底缝 12），实测后立即
        // 校准——尾部留白 = 实测坞高 + 呼吸缝，真穿透设计下滚动内容穿入坞底被玻璃
        // 实时 blur 采样。
        // （2026-10：静态 90/110 预算时代一常量双职锚定渐隐带与尾部留白，工具行高度动态
        // 超估算导致末条消息被坞体压制、渐隐带与坞体脱开断层 → 改为实测单一真实来源）
        static let chatDockHeightFallback: CGFloat = 116
        // 尾部留白在坞顶之上的呼吸缝：滚到底时末条消息底边与坞顶的可见间距
        // （真穿透：再往上滚，消息即自然穿入玻璃坞下被 blur 采样）
        static let chatDockTailBreathing: CGFloat = 20
        // AI 对话思考过程（reasoning）展开区限高，超出内部滚动
        static let reasoningMaxHeight: CGFloat = 160

        // —— 2026-10 AI 窗视觉重设计 ——
        static let chatTopBarHeight: CGFloat = 36      // 顶栏高（28→36，图钉归入顶栏节奏）
        static let chatInputHeight: CGFloat = 72       // 输入框固定高（44→72 常驻 3 行：3×13pt 行高≈16 + 垂直内边距 12×2；超出内部滚动、滚动条隐藏）
        static let chatNavDockGap: CGFloat = 10        // 回底圆钮与坞顶间距
        static let chatToBottomButtonSize: CGFloat = 28 // 回底圆钮直径
        // 浏览导航（刻度轨/回底钮）离底浮现门槛：上滚一点点（门槛内）滚动跟随照常
        // 暂停（pin 解除不受影响），但 UI 不浮现；越过才淡入，滚回门槛内即淡出。
        // 显隐与跟随解耦的动机：pin 解除必须「上滚立即生效」（滚动卡死根治），
        // 显隐若直接绑 pin 就会在 1pt 上滚时冒 UI——太敏感。
        static let chatNavRevealDistance: CGFloat = 120
        // 右缘刻度轨 tick：基础 10×2 圆头（所有刻度几何尺寸统一，当前条仅以 accent 色彩区分）。
        // 排布为 Dock 放大模型（详见 AIChatView.ChatTickRail）：静止按 pitch 紧凑密排，
        // 光标进入右缘通道后按余弦钟形衰减实时放大并彼此推开，离开平滑收拢。
        static let chatTickWidth: CGFloat = 10
        static let chatTickHeight: CGFloat = 2
        static let chatTickTrailing: CGFloat = 4       // tick 右端距窗口右内缘
        // 刻度轨专用让位通道：阅读列（消息/坞/图钉/回底钮/顶栏图钉共用 ChatReadingColumn）
        // 左右双侧各内缩此值——右侧与刻度轨留足呼吸带（覆盖放大峰值宽度），左侧镜像对称，
        // 内容列左右边距恒相等（窄窗 18+28=46 / 宽窗 28+28=56）
        static let chatTickRailLane: CGFloat = 28
        static let chatTickPitch: CGFloat = 10         // 静止基线间距（紧凑密排）
        static let chatTickPitchMin: CGFloat = 4       // 密度自适应下限（tick 多时再密也不低于此）
        static let chatTickMagnifyMaxScale: CGFloat = 1.9  // 光标正下方峰值放大（Dock ≈1.8~2.2 手感带）
        static let chatTickMagnifyRadius: CGFloat = 44     // 余弦钟形衰减半径（峰要陡：相邻 tick 权重差拉开才读得出梯度）
        static let chatTickTrackSlop: CGFloat = 10     // 跟踪通道左伸接近带（光标接近即开始响应）
        static let chatTickMaxCount = 72               // 超限时按视口取样（当前锚点前后各半）；密度主由自适应 pitch 承担，取样仅作极端兜底
        static let chatTickPreviewGap: CGFloat = 12    // 预览胶囊与 tick 水平间距
        static let chatTickPreviewMaxWidth: CGFloat = 230 // 预览胶囊单行截断上限
        static let chatCodeBlockPaddingV: CGFloat = 12 // 代码块上下内边距（对称）
        static let chatCodeBlockPaddingH: CGFloat = 14 // 代码块左右内边距
        static let chatCodeBlockHeaderGap: CGFloat = 8 // 代码块 header 与代码区间距
    }

    // MARK: - 投影档位（浮起层级的值源：接触影贴身定锚 + 环境影拉开纵深，禁止单层贴身影）
    enum Shadow {
        // 输入坞双层阴影（SwiftUI shadow radius ≈ blur/2，两次 .shadow 叠加）
        static let dockContactRadius: CGFloat = 3    // 接触影 blur 6
        static let dockContactY: CGFloat = 2
        static let dockContactOpacity: Double = 0.12
        static let dockAmbientRadius: CGFloat = 16   // 环境影 blur 32
        static let dockAmbientY: CGFloat = 12
        static let dockAmbientOpacity: Double = 0.08
        // 浏览导航浮层（预览胶囊 / 回底圆钮）：单层轻影，不抢坞的纵深
        static let navFloatRadius: CGFloat = 7       // blur 14
        static let navFloatY: CGFloat = 2
        static let navFloatOpacity: Double = 0.28
    }
    
    // MARK: - 动画时长（窗口尺寸动画是唯一尺寸时钟，其余为显隐/淡入淡出节奏）
    enum Motion {
        static let windowResize: Double = 0.18   // 窗口尺寸动画（AppKit 唯一尺寸时钟）
        static let panelFadeIn: Double = 0.08    // 面板呼出淡入
        static let panelFadeOut: Double = 0.08   // 面板极速淡出
        static let contentFade: Double = 0.16    // 内容显隐（CheatSheet/toast/监控区 opacity）
        static let toastOut: Double = 0.20       // toast 淡出
        static let toastDuration: Double = 1.6   // toast 停留时长
        static let progressReset: Double = 0.08  // 一瞥进度重置动画
        static let framePollHz: Double = 60      // 窗口动画期间尺寸轮询频率
        static let toastScale: CGFloat = 0.95    // toast 入场缩放
        static let overlayScale: CGFloat = 0.97  // CheatSheet 入场缩放
        static let caretBlink: Double = 0.55       // 流式块状光标闪烁节拍（近似系统 caret，只闪光标不呼吸整行）
        static let messageArriveOffset: CGFloat = 2 // 新消息落定位移（配合 contentFade：0.16s 淡入 + 2pt 上移）
        static let chatTickMagnifyIn: Double = 0.12   // 刻度轨放大渐入（光标进入通道）
        static let chatTickMagnifyOut: Double = 0.24  // 刻度轨收拢回弹（光标离开通道，easeOut）
        static let chatTickHoverFade: Double = 0.15   // tick 提亮 / 预览胶囊显隐
    }
}
