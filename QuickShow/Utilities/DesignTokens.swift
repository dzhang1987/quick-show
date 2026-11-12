import SwiftUI
import AppKit

func qsDebugLog(_ message: String) {
    NSLog("QS_DEBUG: %@", message)
    if let data = (message + "\n").data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: "/tmp/qs_debug.log") {
            _ = fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        }
    }
}

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
        case .standard: return String(localized: "默认（黑曜石 · 极光蓝）")
        case .amber: return String(localized: "琥珀暖色（香槟金）")
        }
    }
}

// MARK: - 主题色板（变体间可变的颜色通道；未入板的令牌 = 全主题固定值）
struct ThemePalette {
    let accent: Color               // 主强调色（CPU正常态/上传/蓝牙/pinned/链接/清理按钮/交互高亮）
    let actionButtonFill: Color     // 实心操作钮底色（亮暗双模式自适应：极光蓝/琥珀暖金）
    let actionButtonForeground: Color // 实心操作钮前景色（亮暗双模式自适应：确保对比度达标）
    let userBubbleFill: Color       // 用户气泡底色（微透流光自适应：黑曜极光蓝 / 琥珀香槟金）
    let userBubbleStroke: Color     // 用户气泡受光边（0.5pt 精细微光描边，与主题色同源）
    let userBubbleForeground: Color // 用户气泡前景色（保证双模式高对比）
    let clockGradientTop: Color     // 主时钟渐变顶
    let clockGradientBottom: Color  // 主时钟渐变底
    let secondsGradientTop: Color   // 秒数渐变顶
    let secondsGradientBottom: Color// 秒数渐变底
    let ambientSecondary: Color     // 极光氛围副色（与 accent 组成双色环境光，参考 ArcZip/Raycast 彩色光晕）
    
    // 亮暗双模式自适应构造（RGB 三元组）
    private static func adaptive(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    
    // 亮暗双模式自适应构造（RGBA 四元组，支持微透流光底板）
    private static func adaptiveRGBA(dark: (Double, Double, Double, Double), light: (Double, Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }
    
    /// 默认主题（黑曜石 · 钛空极光蓝）：冷峻深邃的钛空极光蓝主强调，通透流光微透气泡，中性冷钛时钟
    static let standard = ThemePalette(
        accent: adaptive(dark: (0.32, 0.62, 0.98), light: (0.10, 0.45, 0.88)),
        actionButtonFill: adaptive(dark: (0.28, 0.58, 0.98), light: (0.08, 0.42, 0.86)),
        actionButtonForeground: adaptive(dark: (1.0, 1.0, 1.0), light: (1.0, 1.0, 1.0)),
        userBubbleFill: adaptiveRGBA(dark: (0.12, 0.22, 0.38, 0.88), light: (0.92, 0.95, 0.99, 0.95)),
        userBubbleStroke: adaptiveRGBA(dark: (0.35, 0.65, 1.0, 0.35), light: (0.10, 0.45, 0.88, 0.25)),
        userBubbleForeground: Color.primary,
        clockGradientTop: Color.primary,
        clockGradientBottom: Color.primary.opacity(0.92),
        secondsGradientTop: Color.primary.opacity(0.85),
        secondsGradientBottom: Color.primary.opacity(0.65),
        // 极光副色：冷紫（与极光蓝主色组成 ArcZip 式双色环境光）
        ambientSecondary: adaptive(dark: (0.55, 0.36, 0.96), light: (0.48, 0.32, 0.86))
    )
    
    /// 琥珀暖色（香槟暖金）：提亮暗阶的高光香槟金，复古温润仪表质感，暖金微透气泡
    static let amber = ThemePalette(
        accent: adaptive(dark: (0.98, 0.74, 0.26), light: (0.76, 0.38, 0.04)),
        actionButtonFill: adaptive(dark: (0.96, 0.73, 0.26), light: (0.75, 0.35, 0.02)),
        actionButtonForeground: adaptive(dark: (0.10, 0.07, 0.02), light: (1.0, 1.0, 1.0)),
        userBubbleFill: adaptiveRGBA(dark: (0.28, 0.21, 0.11, 0.90), light: (0.97, 0.94, 0.88, 0.95)),
        userBubbleStroke: adaptiveRGBA(dark: (0.98, 0.74, 0.26, 0.35), light: (0.76, 0.38, 0.04, 0.25)),
        userBubbleForeground: Color.primary,
        clockGradientTop: adaptive(dark: (0.99, 0.90, 0.71), light: (0.55, 0.32, 0.05)),
        clockGradientBottom: adaptive(dark: (0.94, 0.66, 0.24), light: (0.76, 0.45, 0.06)),
        secondsGradientTop: adaptive(dark: (0.99, 0.90, 0.71), light: (0.55, 0.32, 0.05)).opacity(0.85),
        secondsGradientBottom: adaptive(dark: (0.94, 0.66, 0.24), light: (0.76, 0.45, 0.06)).opacity(0.65),
        // 极光副色：暖橙红（与香槟金主色组成 Raycast 式暖光晕）
        ambientSecondary: adaptive(dark: (0.96, 0.45, 0.22), light: (0.86, 0.40, 0.12))
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
    
    // MARK: - 对比度下限（可读性阈值单一来源）
    // 可读性不是「调色主观题」而是可判定的常量：正文/辅助文字一律按 WCAG AA 正文档裁决，
    // 代码高亮的自动校正与令牌审计脚本共用同一组阈值，杜绝「这个色应该够了吧」式估算。
    enum Accessibility {
        /// 正文级文字（< 18pt 常规字重）WCAG AA 下限
        static let minTextContrast: Double = 4.5
        /// 大号文字（≥ 18pt 常规 / ≥ 14pt 粗体）WCAG AA 下限
        static let minLargeTextContrast: Double = 3.0
    }
    
    // MARK: - 代码块纸面（双模式数值真源）
    // 代码背景与语法色必须成对治理：主题色板是为「主题自带底色」配的，一旦把底色剥离
    // 换成浮动的半透明层，色板就与底色脱钩（实测同一套 atom-one-light 在深灰底上
    // 正文只有 1.0–1.4:1）。故代码块拥有唯一、确定、不透明的纸面，高亮校正以同一
    // 数值为参照——「画出来的底色」与「校正时参照的底色」物理同源，永不漂移。
    enum CodePaper {
        /// 亮色：近白冷灰纸面（比阅读纸面深半档，形成凹陷层次）
        static let light = ContrastColor(0.957, 0.959, 0.968)
        /// 暗色：抬升半档的深灰纸面（比阅读纸面亮一档，形成浮起层次）
        static let dark = ContrastColor(0.153, 0.155, 0.165)
        
        static func resolve(dark: Bool) -> ContrastColor { dark ? self.dark : self.light }
        
        /// 代码块可见不透明度：留 12% 底透（与阅读纸面同源的玻璃感），
        /// 高亮校正以「最亮合成底」为参照（白底透出时的合成值 = 对比度最坏情形），
        /// 因而任何壁纸下校正结论都成立，不会出现「按标称底色校正、实际底更亮」的漏判。
        static let viewAlpha: Double = 0.88
        
        /// 对比度校正的参照底色 = 纸面以 viewAlpha 叠在最亮背景（纯白）上的合成值
        static func contrastReference(dark: Bool) -> ContrastColor {
            resolve(dark: dark).blended(over: .white, alpha: viewAlpha)
        }
        
        /// 自绘底色（跟随视图 effectiveAppearance；数值来自上方真源）
        static var color: Color { Theme.dynamic(dark: dark, light: light, alpha: viewAlpha) }
    }
    
    /// 双模式色构造（数值真源为 ContrastColor，跟随视图 effectiveAppearance 解析）
    static func dynamic(dark: ContrastColor, light: ContrastColor, alpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return (isDark ? dark : light).nsColor.withAlphaComponent(CGFloat(alpha))
        })
    }
    
    // MARK: - 颜色令牌（未来主题变体的核心切换点）
    enum Colors {
        // 内容层级（直接转发系统语义色，随玻璃/材质明暗自动翻转；全主题固定，不被主题洗掉）
        static let contentPrimary = Color.primary
        static let contentSecondary = Color.secondary
        // 面板玻璃专用二级文本：系统 secondary 在亮玻璃上实测 ≈3.9:1 不达 WCAG AA 4.5:1，
        // 面板承载的是「一瞥即读」的关键数值（SSID/曲名/卡片副标），自建 0.65 下限（亮 ≈7:1 / 暗 ≈8.8:1）；
        // 设置窗口（非玻璃、系统表单材质）仍用系统 secondary，此处不动
        // 0.65 → 0.72：阅读纸面留 20% 底透后，最坏壁纸下 0.65 在暗色底只到 4.3:1（不达 AA），
        // 0.72 双模式均 ≥5:1 且仍与主文本拉开层级
        static let contentSecondaryStrong = Color.primary.opacity(0.72)
        
        // 结构性元素（亮玻璃对比度下限保护：黑色低 alpha 是"阴影"型弱对比，需高于暗色白线的发光感）
        static let dividerOpacity: Double = 0.25          // 分割线中段峰值
        static let divider = Color.primary.opacity(0.25)  // 分割线基色
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
        static let surfaceField = Color.primary.opacity(0.04)    // 搜索/输入域容器底（弱于按钮底，不抢焦点）
        static let accentSoftFill = Color.accentColor.opacity(0.15)  // hover 胶囊/选中态强调柔底
        static let accentSoftStroke = Color.accentColor.opacity(0.40) // 聚焦/选中态强调环
        static let closeIcon = Color.primary.opacity(0.55)       // CheatSheet 关闭钮
        static let wifiOff = Color.primary.opacity(0.55)         // WiFi 断连弱化（亮色对比度下限 0.55）
        static let idleText = Color.primary.opacity(0.45)        // "就绪"等弱化文字（亮色 ≈3.5:1 装饰下限）
        static let presetText = Color.primary.opacity(0.55)      // 番茄预设未选中
        // 三级说明文本（替代系统 .tertiary：亮色模式系统三级 ≈2.3:1 远低于 WCAG AA 4.5:1，
        // 0.55 不透明度双模式实测 ≈4.7:1 达标；用于农历小字/说明/时间戳等辅助文本）
        // 0.55 → 0.64：同上，纸面留底后 0.55 在最坏壁纸暗色底掉到 3.8:1；
        // 0.64 双模式 ≥4.5:1，仍弱于 contentSecondaryStrong(0.72)，三级层级不塌
        static let contentTertiary = Color.primary.opacity(0.64)
        
        // 实心翻转按钮（播放钮：底随明暗翻转，文字取窗口背景反色保证双模式对比）
        static let solidButtonFill = Color.primary.opacity(0.92)
        static let solidButtonText = Color(.windowBackgroundColor)
        
        // 状态语义色（全主题固定：绿=接电/健康、红=低电警告，惯例不被主题洗掉）
        static let statusGood = Color(red: 0.35, green: 0.90, blue: 0.45)
        static let statusPositive = statusGood                   // 正向/成功状态别名
        static let statusWarning = Color(red: 1.0, green: 0.35, blue: 0.35)
        
        // 变体通道（计算属性，随 Theme.variant 切换；调用点无需感知主题存在）
        static var accent: Color { Theme.palette.accent }
        static var actionButtonFill: Color { Theme.palette.actionButtonFill }
        static var actionButtonForeground: Color { Theme.palette.actionButtonForeground }
        static var userBubbleFill: Color { Theme.palette.userBubbleFill }
        static var userBubbleStroke: Color { Theme.palette.userBubbleStroke }
        static var userBubbleForeground: Color { Theme.palette.userBubbleForeground }
        static var clockGradientTop: Color { Theme.palette.clockGradientTop }
        static var clockGradientBottom: Color { Theme.palette.clockGradientBottom }
        static var secondsGradientTop: Color { Theme.palette.secondsGradientTop }
        static var secondsGradientBottom: Color { Theme.palette.secondsGradientBottom }
        static var ambientSecondary: Color { Theme.palette.ambientSecondary }

        // MARK: AI 对话窗专用（2026-10 视觉层次专项 / 2026-11 可读性根治 + 质感分区）
        // 设计逻辑：内容层必须有「确定底色」——玻璃透壁纸会把文字对比度变成环境的函数
        // （动态壁纸下正文对比度实测可在 1.0–11:1 之间漂移，代码块深底时正文近乎消失）。
        // 故分区处理：正文区铺 80% 不透明阅读纸面（对比度设计常量），顶栏带走同色相
        // 52% 轻纱（原生 Liquid Glass 透出，主浮窗同款活感）——小字 4.5:1 归纸面，
        // 大字/图标 3:1 归轻纱，两个标准各自落在确定的结构上。
        /// 阅读面基色（单一来源）：纸面与顶栏轻纱同色相，仅不透明度不同
        private enum ChatSurface {
            static let dark = ContrastColor(0.113, 0.113, 0.124)
            static let light = ContrastColor(0.988, 0.988, 0.992)
        }
        /// 内容层阅读纸面（顶栏以下整块纸面：消息流 + 侧栏）
        /// 0.80 = 质感与可读性的临界：壁纸仍有 20% 透出（模糊/色彩流动可见，
        /// 玻璃窗的「活」还在），同时最坏壁纸下正文 12.8:1、辅助字按次级透明度仍达 AA。
        /// 降到 0.75 需要辅助字提到 0.69、0.70 需要 0.78——层级会被压平，故 0.80 是下限。
        static let chatReadingSurface = Theme.dynamic(
            dark: ChatSurface.dark,
            light: ChatSurface.light,
            alpha: 0.80
        )
        /// 顶栏轻纱带（窗口顶部 chatTopBarHeight 高）：同色相半透明，原生 Liquid Glass
        /// 在此透出。仅承载大字（14pt semibold，WCAG large-text 3:1 档）与图标；
        /// 小字功能区（子代理导航条）出现时该带整体回纸面（AIChatView 条件切换）。
        /// 0.52 下最亮玻璃输出（实测 ≈0.6 亮度）合成底 ≈0.27，全主色大字 ≥3:1 成立。
        static let chatReadingVeilTop = Theme.dynamic(
            dark: ChatSurface.dark,
            light: ChatSurface.light,
            alpha: 0.52
        )
        /// 顶栏（轻纱带）图标静止色：纱下合成底随壁纸浮动（暗壁纸近黑、亮端 ≈0.27），
        /// iconRest(0.60) 在亮端不足 3:1，rest 提到 0.85（hover 仍走 iconHover 0.95）
        static let chatVeilIconRest = Color.primary.opacity(0.85)
        /// 代码块纸面（不透明：高亮色板的对比度基准，见 Theme.CodePaper）
        static var chatCodeBlockPaper: Color { Theme.CodePaper.color }
        /// 主区底板的通用别名（浮层/胶囊在其上再叠加时使用，语义等同阅读纸面）
        static let chatBase = aiAdaptive(dark: (0.115, 0.115, 0.125, 0.94), light: (0.99, 0.99, 0.99, 0.95))
        /// 侧栏分层 shade：在阅读纸面上压半档暗调（不另铺不透明底，避免把玻璃带整块吃掉）——
        /// 亮色 0.988→0.943 / 暗色 0.113→0.093，与主列的「深浅半档」层级关系保持原设计意图
        static let chatSidebarShade = aiAdaptive(dark: (0, 0, 0, 0.18), light: (0, 0, 0, 0.045))
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
        /// 用户消息气泡实底：微透流光自适应（随当前主题色流动：黑曜石钛空极光蓝 / 琥珀暖金；
        /// 兼顾毛玻璃微透折射与 0.5pt 精细微光受光 rim，向前兼容通道）
        static var chatUserBubble: Color { Theme.palette.userBubbleFill }
        /// 输入坞微胶囊 0.5pt 白 rim（⊕/剪贴板/模型 chip 的受光边：浅色白 40% / 深色白 20%）
        static let chatCapsuleRim = aiAdaptive(dark: (1, 1, 1, 0.20), light: (1, 1, 1, 0.40))
        /// 发送钮禁用态底：浅灰实底，与输入卡底保持 ≥1.2:1 对比（杜绝旧版 1.04:1 隐形事故）
        static let chatSendDisabledFill = aiAdaptive(dark: (1, 1, 1, 0.18), light: (0, 0, 0, 0.14))

        // —— 2026-10 AI 窗视觉重设计（刻度轨导航 / 行内代码提亮 / 浮层深底）——
        /// 行内代码 chip 底色：自适应通透中性柔底（方案 A：暗色 12% 白 / 亮色 5.5% 黑）
        static let chatInlineCodeFill = aiAdaptive(dark: (1, 1, 1, 0.12), light: (0, 0, 0, 0.055))
        /// 行内代码 0.5pt 微描边颜色（方案 A：暗色 14% 白 / 亮色 9% 黑）
        static let chatInlineCodeStroke = aiAdaptive(dark: (1, 1, 1, 0.14), light: (0, 0, 0, 0.09))
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
        /// 光与纸：0.35 → 0.45，聚焦态品牌色响应更可辨（仍克制，不喧宾夺主）
        static let dockFocusRimOpacity: Double = 0.45

        // MARK: 光与纸质感重塑（2026-11）
        // 在可读性纸面之上重建「光、色、节奏」：纸面获得受光垂直渐变、顶部极淡品牌色氛围光、
        // agent 获得渐变徽标身份、输入坞浮起为视觉焦点。
        // 对比度纪律：纸面渐变顶端与 chatReadingSurface 完全一致（零回归），底端只更暗更不透明
        // （白字对比只升不降）；氛围光是集中在顶部区域的极淡装饰光层，不参与正文对比度预算。

        /// 纸面渐变顶端（与 chatReadingSurface 同值：顶部对比度零回归）
        static let chatPaperTop = Theme.dynamic(
            dark: ChatSurface.dark,
            light: ChatSurface.light,
            alpha: 0.80
        )
        /// 纸面渐变底端（更暗 + 更不透明：光向下衰减形成可感知的「顶部受光」纵深，对比度只升不降）
        /// 推一档：0.096→0.082 / 0.85→0.88，加大顶底落差让「光」可读
        static let chatPaperBottom = Theme.dynamic(
            dark: ContrastColor(0.082, 0.082, 0.092),
            light: ContrastColor(0.962, 0.962, 0.968),
            alpha: 0.88
        )
        /// 游走光团主色 hue（accent；透明度/半径由动画实时随机调制，见 ChatAuroraView）
        static var auroraBlobPrimary: Color { Theme.palette.accent }
        /// 游走光团副色 hue（ambientSecondary；与主色光团交叠出色彩流动）
        static var auroraBlobSecondary: Color { Theme.palette.ambientSecondary }
        /// 光团峰值不透明度（随机呼吸上限；克制以护住正文小字对比度）
        static let auroraBlobPeakOpacity: Double = 0.16
        /// 光团基础半径占窗口短边比例（distinct「一团光」而非满幅线性 wash）
        static let auroraBlobRadiusRatio: CGFloat = 0.30
        /// 光团纵向游走边界占窗口高度比例（光偏顶部游走，下方正文保持确定纸面）
        static let auroraVerticalBias: CGFloat = 0.62
        /// 光团柔化模糊半径（ glow 边缘羽化）
        static let auroraBlobBlur: CGFloat = 26
        /// 功能面品牌微染（表格头等：3% accent wash，不破坏小字对比度）
        static var chatAccentWash: Color { Theme.palette.accent.opacity(0.03) }
        /// 输入坞安静态品牌 rim（替代纯灰描边：常驻一丝品牌色边缘，聚焦态再升档）
        static var chatDockRestRim: Color { Theme.palette.accent.opacity(0.12) }

        /// Agent 渐变徽标顶部光泽（白光叠加：在 accent 实底上形成「顶部受光」渐变）
        static let agentMarkSheenTop = Color.white.opacity(0.28)
        static let agentMarkSheenBottom = Color.white.opacity(0.0)
        /// Agent 徽标受光 rim（0.5pt 精细高光）
        static let agentMarkRim = Color.white.opacity(0.30)
        /// Agent 徽标图标前景（accent 实底上高对比，复用实心操作钮前景通道）
        static var agentMarkForeground: Color { Theme.palette.actionButtonForeground }
        /// Agent 徽标氛围光阴影不透明度（大尺寸如欢迎页柔光；小尺寸默认关闭避免噪声）
        static let agentMarkGlowOpacity: Double = 0.35

        /// 输入坞空态发送钮幽灵 accent 底（在场但安静：品牌色 affordance，不抢视觉重心）
        static var chatSendIdleFill: Color { Theme.palette.accent.opacity(0.16) }
        /// 输入坞空态发送钮幽灵 accent 图标（弱于实心强调，静止可读）
        static var chatSendIdleForeground: Color { Theme.palette.accent.opacity(0.60) }

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
        static let chatBarTitle: CGFloat = 14 // 对话窗顶栏标题（玻璃纱带大字档：WCAG large-text 3:1）
        // 助手回合身份锚点
        static let chatTurnAnchorName: CGFloat = 11 // 助手回合锚点 agent 名（弱存在小字）
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
        static let panel: CGFloat = 18      // 面板（PanelManager 玻璃双写 + 降级路径裁剪 的单一来源，对齐 macOS 控制中心浮层标准）
        static let cheatSheet: CGFloat = 16 // CheatSheet 卡
        static let card: CGFloat = 12       // Bento 大卡
        static let groupCard: CGFloat = 10  // 速查组卡
        static let insetCard: CGFloat = 8   // 内层卡（番茄钟台/日历卡）
        static let keyCap: CGFloat = 5      // 快捷键键帽
        static let userBubble: CGFloat = 14 // 用户消息气泡（保持对话气泡圆润感）
        static let chatDock: CGFloat = 16   // 光与纸：输入坞浮岛圆角（10→16，更圆润连续曲率，浮起焦点）
        static let previewCapsule: CGFloat = 8 // 刻度轨预览胶囊（2026-10 重设计）
        static let inlineCode: CGFloat = 3.5 // 行内代码/微徽章圆角（方案 A 胶囊质感）
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
        // 刻度轨静止宽 10pt、距右缘 4pt（占 0~14pt），完全容纳于 18pt 边距内，无需额外通道。
        static let chatReadingWideBreakpoint: CGFloat = 720
        static let chatReadingWidePadding: CGFloat = 28
        // AI 对话浮岛输入坞：坞体真实高度不做静态预算，由 inputArea 整体实测直写
        // （GeometryReader onAppear/onChange 事件路径，先例同原生长区高度键）。本常量
        // 仅作布局链建立前的首帧兜底（输入框 72 + 工具行 ≈32 + 底缝 12），实测后立即
        // 校准——尾部留白 = 实测坞高 + 呼吸缝，真穿透设计下滚动内容穿入坞底被玻璃
        // 实时 blur 采样。
        // （2026-10：静态 90/110 预算时代一常量双职锚定渐隐带与尾部留白，工具行高度动态
        // 超估算导致末条消息被坞体压制、渐隐带与坞体脱开断层 → 改为实测单一真实来源）
        static let chatDockHeightFallback: CGFloat = 124
        // 尾部留白在坞顶之上的呼吸缝：滚到底时末条消息底边与坞顶的可见间距
        // （真穿透：再往上滚，消息即自然穿入玻璃坞下被 blur 采样）
        static let chatDockTailBreathing: CGFloat = 28
        // —— 嵌入型组件通用限高两档阶梯规范（统一标准） ——
        // 1. 主交付内容级默认限高（约 20 行，覆盖：正文代码块、Markdown 表格等）：超出内部滚动、少于自适应贴合
        static let chatBlockMaxHeight: CGFloat = 380
        // 2. 次级元信息卡片默认限高（约 10 行，覆盖：思考过程卡片、工具调用详情等）：超出内部滚动、少于自适应贴合
        static let chatMetaBlockMaxHeight: CGFloat = 180

        // 语义别名兼容
        static var reasoningMaxHeight: CGFloat { chatMetaBlockMaxHeight }
        static var chatCodeBlockMaxHeight: CGFloat { chatBlockMaxHeight }

        // —— 2026-10 AI 窗视觉重设计 ——
        static let chatTopBarHeight: CGFloat = 36      // 顶栏高（28→36，图钉归入顶栏节奏）
        // Agent 渐变徽标尺寸
        static let chatTopBarMarkSize: CGFloat = 18    // 身份徽标默认尺寸
        static let chatTurnAnchorMarkSize: CGFloat = 16 // 助手回合身份锚点徽标

        static let chatInputHeight: CGFloat = 72       // 输入框最小高（44→72 常驻 3 行：3×13pt 行高≈16 + 垂直内边距 12×2；内容超出向上生长，见 chatInputMaxLines）
        // 输入框自动增高上限行数（2026-11 用户决策：最多 10 行）：内容高在
        // [chatInputHeight, 行高×10+内边距] 夹取，超上限内部滚动并浮现 overlay 滚动条
        static let chatInputMaxLines: Int = 10
        // Markdown 表格内容驱动列宽夹取（2026-11 横滚重设计）：下限保窄列可读（≈4 个汉字），
        // 上限防单条长备注无限撑宽表格（超出折行）；总宽超视口即横向滚动
        static let chatTableMinColumnWidth: CGFloat = 56
        static let chatTableMaxColumnWidth: CGFloat = 300
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
        // 刻度轨专用让位通道已退役：刻度轨（10~19pt）静止时完全容于标准边距 18pt 内，
        // 消除额外双侧内缩，保留该 token 归零兼容。
        static let chatTickRailLane: CGFloat = 0
        static let chatTickPitch: CGFloat = 10         // 静止基线间距（紧凑密排）
        static let chatTickPitchMin: CGFloat = 4       // 密度自适应下限（tick 多时再密也不低于此）
        static let chatTickMagnifyMaxScale: CGFloat = 1.9  // 光标正下方峰值放大（Dock ≈1.8~2.2 手感带）
        static let chatTickMagnifyRadius: CGFloat = 44     // 余弦钟形衰减半径（峰要陡：相邻 tick 权重差拉开才读得出梯度）
        static let chatTickTrackSlop: CGFloat = 10     // 跟踪通道左伸接近带（光标接近即开始响应）
        static let chatTickMaxCount = 72               // 超限时按视口取样（当前锚点前后各半）；密度主由自适应 pitch 承担，取样仅作极端兜底
        static let chatTickPreviewGap: CGFloat = 12    // 预览胶囊与 tick 水平间距
        static let chatTickPreviewMaxWidth: CGFloat = 230 // 预览胶囊单行截断上限
        static let chatCodeBlockPaddingV: CGFloat = 12 // 代码块上内边距（底部留白改由 scrollerGutter 单一承担）
        static let chatCodeBlockPaddingH: CGFloat = 14 // 代码块左右内边距
        static let chatCodeBlockHeaderGap: CGFloat = 8 // 代码块 header 与代码区间距

        // 滚动条槽：macOS overlay 滚动条浮于内容之上、不占布局空间（≈7pt 胶囊 + 上下留白
        // ≈ 14pt 带宽），滚动一启动就压住末行内容（代码块横滚最刺眼）。内容侧垫满该带宽，
        // 滚动条即落在留白里；卡片自身底部内边距随之让位归零，静止观感不变。
        // 见 ScrollerGutter.swift。
        static let scrollerGutter: CGFloat = 14
        // 候选模型滚动视口（AI 服务设置）：约 6 行候选行（行高 ≈24pt + 行距 2pt），
        // 视口高度单一来源，行结构见 AIServiceSettingsForm.candidateRowView
        static let modelCandidateViewportHeight: CGFloat = 168
    }

    // MARK: - 投影档位（浮起层级的值源：接触影贴身定锚 + 环境影拉开纵深，禁止单层贴身影）
    enum Shadow {
        // 输入坞双层阴影（SwiftUI shadow radius ≈ blur/2，两次 .shadow 叠加）
        static let dockContactRadius: CGFloat = 3    // 接触影 blur 6
        static let dockContactY: CGFloat = 2
        static let dockContactOpacity: Double = 0.16 // 光与纸：0.12→0.16，贴身定锚更实
        static let dockAmbientRadius: CGFloat = 18   // 环境影 blur 36（光与纸：16→18 拉开纵深）
        static let dockAmbientY: CGFloat = 12
        static let dockAmbientOpacity: Double = 0.12 // 光与纸：0.08→0.12，浮岛感更强
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
        static let transientFeedbackDuration: Double = 1.2 // 复制成功、临时按钮等瞬态反馈保留时长
        static let progressReset: Double = 0.08  // 一瞥进度重置动画
        static let framePollHz: Double = 60      // 窗口动画期间尺寸轮询频率
        static let toastScale: CGFloat = 0.95    // toast 入场缩放
        static let overlayScale: CGFloat = 0.97  // CheatSheet 入场缩放
        static let caretBlink: Double = 0.55       // 流式块状光标闪烁节拍（近似系统 caret，只闪光标不呼吸整行）
        static let messageArriveOffset: CGFloat = 2 // 新消息落定位移（配合 contentFade：0.16s 淡入 + 2pt 上移）
        static let chatTickMagnifyIn: Double = 0.12   // 刻度轨放大渐入（光标进入通道）
        static let chatTickMagnifyOut: Double = 0.24  // 刻度轨收拢回弹（光标离开通道，easeOut）
        static let chatTickHoverFade: Double = 0.15   // tick 提亮 / 预览胶囊显隐
        // 光与纸·动态极光：游走光团（TimelineView 驱动，有机 wander + 随机呼吸；尊重减弱动态）
        static let auroraFrameInterval: Double = 1.0 / 30.0 // 30fps 上限（性能与流畅平衡）
        static let auroraTimeScale: Double = 1.0            // 游走/呼吸整体速度倍率
    }
}
