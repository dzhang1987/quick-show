// 从 AIChatScrollNavigation.swift 机械拆分：AI 会话滚动与浏览导航——刻度轨布局 / 刻度轨视图 / 预览小三角。
//
// 2026-10 性能重构（消除光标移动时整轨 O(n) 重算 · 重渲染）：
// - 静止几何缓存（C1）：pitch 自适应 / 容器垂直居中 / 各 tick 静止 Voronoi 槽只依赖
//   「会话 tick 数 + 可用高」，封进纯值 ChatTickRailRestLayout，由 ChatTickRailRestLayoutCache
//   缓存；会话数据或尺寸不变时 body 只读缓存，光标移动不再触发其重算。
// - 光标下沉（C2）：cursorY / 放大渐入量 / hover 下标全部私有于 ChatTickRailInteractive
//   子视图；整轨绘制收进单个 Canvas（ChatTickRailCanvas），onContinuousHover 只让该 Canvas
//   重绘——不再逐帧重建 n 个 tick 视图、不触发整轨 SwiftUI 视图失效（旧实现 30% CPU 根因）。
// - 邻近局部化（C3）：逐帧放大只对光标余弦钟形窗口 [lo,hi]（≈2·radius/pitch 枚）做 O(窗口)
//   重算；窗口外槽心只是「窗口累计生长」的刚性平移常量，O(1) 取用。整轨几何与旧
//   ChatTickRailLayout 逐点等价（放大/明暗/吸附完全保留），仅渲染路径由视图树换成 Canvas。

import SwiftUI

// MARK: - 静止几何缓存（纯数据，与光标解耦）

/// 刻度轨静止几何：仅由「会话 tick 数 + 可用高」决定，与光标/放大完全解耦，可安全缓存。
/// 放大态在原静止槽心上叠加窗口累计生长位移（见 ChatTickRailMagnifier），本结构只承担
/// pitch 自适应收缩、容器垂直居中与静止 Voronoi 槽（无放大窗口时的回退几何）。
struct ChatTickRailRestLayout: Equatable {
    struct Slot: Equatable {
        var center: CGFloat      // 槽心 y（容器静止坐标系；tick 视觉锚点）
        var frameTop: CGFloat    // 命中槽顶（相邻槽心中点切分）
        var frameHeight: CGFloat // 命中槽高（槽间恒无缝）
    }

    let count: Int
    let pitch: CGFloat
    /// 静止总高（容器固定高 = n × pitch）
    let restHeight: CGFloat
    /// 容器顶缘在几何区（overlay 可用区）坐标系中的 y（垂直居中换算）
    let containerTop: CGFloat
    /// 首/末静止命中槽的外缘（容器坐标系，可越出 [0, restHeight]）
    let railTop: CGFloat
    let railBottom: CGFloat
    let slots: [Slot]

    init(count: Int, availableHeight: CGFloat) {
        let tokens = Theme.Layout.self
        let n = max(count, 0)
        let avail = max(availableHeight, 1)
        // 放大生长余量（worst-case 上界 Σ(scale−1)·pitch ≤ (maxScale−1)·(radius+pitch)）：
        // 静止总高预算先扣除它 → 光标扫到峰值时整轨视觉高也不超可用区
        let growthReserve = (tokens.chatTickMagnifyMaxScale - 1)
            * (tokens.chatTickMagnifyRadius + tokens.chatTickPitch)
        // 密度自适应：优先在可用区内收缩 pitch（保底 pitchMin）；极端窄窗 + 大量 tick 时
        // pitchMin 地板失守，再加拟合上界 avail/n 兜底，把静止总高与全部槽位收进可用区。
        let p = n > 0
            ? min(tokens.chatTickPitch,
                  max(tokens.chatTickPitchMin, (avail - growthReserve) / CGFloat(n)),
                  avail / CGFloat(n))
            : tokens.chatTickPitch
        self.count = n
        pitch = p
        restHeight = min(p * CGFloat(n), avail)
        containerTop = (avail - restHeight) / 2

        guard n > 0 else {
            slots = []
            railTop = 0
            railBottom = 0
            return
        }
        let centerAt: (Int) -> CGFloat = { p * (CGFloat($0) + 0.5) }
        var result: [Slot] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            let c = centerAt(i)
            // 命中槽 = 相邻槽心中点切分；端点槽向外延伸自身半步（可越容器缘）
            let top = i > 0
                ? (centerAt(i - 1) + c) / 2
                : c - (n > 1 ? (centerAt(1) - c) / 2 : p / 2)
            let bottom = i < n - 1
                ? (c + centerAt(i + 1)) / 2
                : c + (n > 1 ? (c - centerAt(i - 1)) / 2 : p / 2)
            result.append(Slot(center: c, frameTop: top, frameHeight: bottom - top))
        }
        slots = result
        railTop = result[0].frameTop
        railBottom = result[n - 1].frameTop + result[n - 1].frameHeight
    }
}

/// 静止几何缓存：键 =（tick 数, 可用高）。命中则直接复用，避免在会话数据/尺寸稳定时重复布局。
private final class ChatTickRailRestLayoutCache {
    private var cachedCount = -1
    private var cachedHeight: CGFloat = -1
    private var cached: ChatTickRailRestLayout?

    func layout(count: Int, availableHeight: CGFloat) -> ChatTickRailRestLayout {
        if let cached, cachedCount == count, cachedHeight == availableHeight {
            return cached
        }
        let layout = ChatTickRailRestLayout(count: count, availableHeight: availableHeight)
        cached = layout
        cachedCount = count
        cachedHeight = availableHeight
        return layout
    }
}

// MARK: - 光标驱动的放大解算（仅窗口 O(窗口)，窗口外 O(1) 刚性平移）

/// 由「静止几何 + 光标 y + 渐入量 + 锚点下标」解出每枚 tick 的放大态几何。
///
/// 与旧 ChatTickRailLayout 完全等价：先算余弦钟形窗口内各 tick 的 w → scale / 不透明度 /
/// 生长量，再以累计生长（锚点钉死为零位）求槽心。差异只在实现：窗口外槽心的
/// `累计生长 − 锚点前累计生长` 恒为常量，故按下标分三段 O(1) 取用，不必遍历全轨。
private struct ChatTickRailMagnifier {
    let rest: ChatTickRailRestLayout
    let amount: CGFloat

    private let windowLo: Int
    private let windowHi: Int
    private let hasWindow: Bool
    private let windowScale: [CGFloat]     // [windowLo...windowHi]
    private let windowOpacity: [Double]    // [windowLo...windowHi]
    private let windowPrefix: [CGFloat]    // prefix[k] = Σ_{j=windowLo}^{windowLo+k-1} growth
    private let totalGrowth: CGFloat
    private let pivot: CGFloat             // 锚点前累计生长（无锚点 = totalGrowth/2）

    init(rest: ChatTickRailRestLayout, cursorY: CGFloat, amount: CGFloat, pinnedIndex: Int?) {
        let tokens = Theme.Layout.self
        let colors = Theme.Colors.self
        self.rest = rest
        let t = min(max(amount, 0), 1)
        self.amount = t

        let n = rest.count
        let pinned = pinnedIndex.flatMap { $0 >= 0 && $0 < n ? $0 : nil }
        guard n > 0 else {
            windowLo = 0; windowHi = -1; hasWindow = false
            windowScale = []; windowOpacity = []; windowPrefix = [0]
            totalGrowth = 0; pivot = 0
            return
        }
        let p = rest.pitch
        let maxGain = tokens.chatTickMagnifyMaxScale - 1
        let radius = tokens.chatTickMagnifyRadius
        let containerTop = rest.containerTop
        // 窗口 = |cursorY − (containerTop + p·(i+0.5))| < radius 的整数下标范围（时间 O(1)）。
        // 静止槽心对 i 线性，直接闭式换算，不遍历全轨。
        let lo = max(0, Int(ceil((cursorY - radius - containerTop) / p - 0.5)))
        let hi = min(n - 1, Int(floor((cursorY + radius - containerTop) / p - 0.5)))
        guard hi >= lo else {
            windowLo = 0; windowHi = -1; hasWindow = false
            windowScale = []; windowOpacity = []; windowPrefix = [0]
            totalGrowth = 0; pivot = 0
            return
        }
        windowLo = lo
        windowHi = hi
        hasWindow = true

        var scales: [CGFloat] = []; scales.reserveCapacity(hi - lo + 1)
        var opacities: [Double] = []; opacities.reserveCapacity(hi - lo + 1)
        var growths: [CGFloat] = []; growths.reserveCapacity(hi - lo + 1)
        for i in lo...hi {
            let center = containerTop + p * (CGFloat(i) + 0.5)
            let d = abs(cursorY - center)
            let w: CGFloat = d < radius ? 0.5 * (1 + cos(.pi * d / radius)) : 0
            // 锚点不参与放大布局：scale 恒 1（颜色恒 accent）
            let scale = i == pinned ? 1 : 1 + maxGain * w * t
            scales.append(scale)
            growths.append((scale - 1) * p)
            // 明暗与大小共用同一条 w：rest → lerp(dim, bright, w)
            let target = colors.chatTickDimOpacity
                + (colors.chatTickBrightOpacity - colors.chatTickDimOpacity) * Double(w)
            opacities.append(colors.chatTickRestOpacity + Double(t) * (target - colors.chatTickRestOpacity))
        }
        windowScale = scales
        windowOpacity = opacities
        var prefix = [CGFloat](repeating: 0, count: growths.count + 1)
        for k in growths.indices { prefix[k + 1] = prefix[k] + growths[k] }
        windowPrefix = prefix
        totalGrowth = prefix[growths.count]
        // 锚点前累计生长：锚点恒钉死在静止位（零位）
        if let pin = pinned {
            if pin < lo { pivot = 0 }
            else if pin > hi { pivot = totalGrowth }
            else { pivot = prefix[pin - lo] }
        } else {
            pivot = totalGrowth / 2  // 无锚点：绕几何中心对称生长
        }
    }

    /// 槽心相对静止位的位移：窗口内用局部累计生长，窗口外为刚性平移常量。
    private func offset(at i: Int) -> CGFloat {
        guard hasWindow else { return 0 }
        if i < windowLo { return -pivot }
        if i > windowHi { return totalGrowth - pivot }
        return windowPrefix[i - windowLo] - pivot
    }

    /// 槽心 y（容器静止坐标系）。
    func center(at i: Int) -> CGFloat {
        rest.pitch * (CGFloat(i) + 0.5) + offset(at: i)
    }

    /// 放大倍率（1 = 静止/锚点/窗口外）。
    func scale(at i: Int) -> CGFloat {
        guard hasWindow, i >= windowLo, i <= windowHi else { return 1 }
        return windowScale[i - windowLo]
    }

    /// 明暗梯度输出（仅普通 tick 使用；accent 锚点忽略）。
    func opacity(at i: Int) -> Double {
        let colors = Theme.Colors.self
        guard hasWindow, i >= windowLo, i <= windowHi else {
            return colors.chatTickRestOpacity
                + Double(amount) * (colors.chatTickDimOpacity - colors.chatTickRestOpacity)
        }
        return windowOpacity[i - windowLo]
    }

    /// 命中槽顶：i>0 取相邻槽心中点；端点槽向外延伸自身半步。
    private func frameTop(at i: Int) -> CGFloat {
        let n = rest.count
        if i == 0 {
            if n > 1 { return center(at: 0) - (center(at: 1) - center(at: 0)) / 2 }
            return center(at: 0) - rest.pitch * scale(at: 0) / 2
        }
        return (center(at: i - 1) + center(at: i)) / 2
    }

    /// 末槽底缘（容器坐标系）。
    private func frameBottom(at i: Int) -> CGFloat {
        let n = rest.count
        if i < n - 1 { return frameTop(at: i + 1) }
        if n > 1 { return center(at: i) + (center(at: i) - center(at: i - 1)) / 2 }
        return center(at: i) + rest.pitch * scale(at: i) / 2
    }

    /// 几何区坐标 → 光标正下方的 tick 下标：横坐标须落在轨体内（左伸接近带只驱动放大、
    /// 不触发 hover）；纵坐标须落在命中槽域内。槽无缝相接，命中即返。
    func hoveredIndex(at point: CGPoint, trackWidth: CGFloat, railWidth: CGFloat) -> Int? {
        let n = rest.count
        guard n > 0 else { return nil }
        guard point.x >= trackWidth - railWidth else { return nil }
        let y = point.y - rest.containerTop
        guard y >= frameTop(at: 0), y <= frameBottom(at: n - 1) else { return nil }
        for i in 0..<n {
            if y >= frameTop(at: i) && y < frameBottom(at: i) { return i }
        }
        return n - 1  // y == railBottom 边界兜底
    }
}

// MARK: - 整轨 Canvas（唯一逐帧重绘面：无 n 个 tick 视图可供失效）

/// 把整轨 tick 画进单个 Canvas。cursorY / 渐入量变化只让本 Canvas 重绘，不产生
/// SwiftUI 视图树 diff；放大几何由 ChatTickRailMagnifier 解算（窗口 O(窗口)）。
/// amount 实现 Animatable → 进入/离开的 withAnimation 仍逐帧插值（与旧逐 tick
/// scaleEffect/offset 插值轨迹一致：二者对 amount 均线性）。
private struct ChatTickRailCanvas: View, Animatable {
    let rest: ChatTickRailRestLayout
    let items: [ChatTickRail.Item]
    let pinnedIndex: Int?
    let cursorY: CGFloat
    let trackTop: CGFloat
    let trackWidth: CGFloat
    var amount: CGFloat

    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    var body: some View {
        Canvas { context, _ in
            let n = rest.count
            guard n > 0, items.count == n else { return }
            let tokens = Theme.Layout.self
            let mag = ChatTickRailMagnifier(rest: rest, cursorY: cursorY,
                                            amount: amount, pinnedIndex: pinnedIndex)
            // 容器局部 y → 跟踪带（Canvas）局部 y
            let originY = rest.containerTop - trackTop
            for index in 0..<n {
                let item = items[index]
                let baseWidth = item.isCurrent ? tokens.chatTickActiveWidth : tokens.chatTickWidth
                let baseHeight = item.isCurrent ? tokens.chatTickActiveHeight : tokens.chatTickHeight
                let scale = mag.scale(at: index)
                let w = baseWidth * scale
                let h = baseHeight * scale
                // 右基准线钉死：tick frame 尾随对齐 → 视觉中心 x 恒为 trackWidth − baseWidth/2，
                // scaleEffect 绕中心缩放（旧布局一致）
                let centerX = trackWidth - baseWidth / 2
                let centerY = originY + mag.center(at: index)
                let rect = CGRect(x: centerX - w / 2, y: centerY - h / 2, width: w, height: h)
                let path = Path(roundedRect: rect, cornerRadius: min(w, h) / 2, style: .continuous)
                if item.isCurrent {
                    context.fill(path, with: .color(Theme.Colors.accent))
                } else {
                    context.fill(path, with: .color(Color.primary.opacity(mag.opacity(at: index))))
                }
            }
        }
    }
}

// MARK: - 交互层（光标状态私有于此，整轨 body 不再随光标失效）

/// 磁吸带交互层：拥有光标派生状态（cursorY / 渐入量 / hover 下标），承载
/// onContinuousHover 与点击命中。光标移动只重绘内部 Canvas 与（hover 变化时的）预览胶囊。
private struct ChatTickRailInteractive: View {
    let items: [ChatTickRail.Item]
    let availableSize: CGSize
    let trackWidth: CGFloat
    let railWidth: CGFloat
    let onSelect: (UUID) -> Void

    /// 静止几何缓存（仅会话数据 / 尺寸变化才重算）
    @State private var restCache = ChatTickRailRestLayoutCache()
    /// 光标 y（几何区坐标系；直接赋值 = 零动画即时跟随）
    @State private var cursorY: CGFloat = 0
    /// 放大渐入量 0…1：唯一走动画的分量（进入点亮 / 离开收拢）
    @State private var magnifyAmount: CGFloat = 0
    /// 被悬停 tick 下标（预览胶囊锚点），由跟踪坐标派生
    @State private var hoveredIndex: Int?

    var body: some View {
        let rest = restCache.layout(count: items.count, availableHeight: availableSize.height)
        let radius = Theme.Layout.chatTickMagnifyRadius
        // 磁吸带 = 轨体 ± 一个衰减半径（几何区坐标）；带外衰减恒零，右缘其余区域不占命中
        let trackTop = max(0, rest.containerTop - radius)
        let trackHeight = max(0, min(availableSize.height,
                                    rest.containerTop + rest.restHeight + radius) - trackTop)
        let pinnedIndex = items.firstIndex(where: { $0.isCurrent })

        ZStack(alignment: .topTrailing) {
            ChatTickRailCanvas(rest: rest, items: items, pinnedIndex: pinnedIndex,
                               cursorY: cursorY, trackTop: trackTop, trackWidth: trackWidth,
                               amount: magnifyAmount)
            // 预览胶囊单独成层：动画作用域只罩本层（Canvas 是兄弟节点，不被 hover 动画染指），
            // 保证 hover 变化帧的光标位移仍即时跟随、不做隐式动画。
            ChatTickRailPreviewLayer(items: items, rest: rest, pinnedIndex: pinnedIndex,
                                     hoveredIndex: hoveredIndex, cursorY: cursorY,
                                     amount: magnifyAmount, trackTop: trackTop,
                                     trackWidth: trackWidth)
        }
        .frame(width: trackWidth, height: trackHeight, alignment: .topTrailing)
        // 单一跟踪面：覆盖整个交互区（接近带 + 轨体）。tick 现由 Canvas 绘制，交互手势挂在本层。
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                let geometryY = location.y + trackTop  // 带局部 → 几何区坐标系
                cursorY = geometryY
                updateHover(atLocal: location, geometryY: geometryY, rest: rest, pinnedIndex: pinnedIndex)
                if magnifyAmount < 1 {
                    withAnimation(.easeOut(duration: Theme.Motion.chatTickMagnifyIn)) {
                        magnifyAmount = 1
                    }
                }
            case .ended:
                withAnimation(.easeOut(duration: Theme.Motion.chatTickMagnifyOut)) {
                    magnifyAmount = 0
                    hoveredIndex = nil
                }
            }
        }
        // 点击直达：命中槽（Voronoi，随放大同步移动）由 Magnifier 解算；非轨体内不触发
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    let mag = ChatTickRailMagnifier(rest: rest, cursorY: cursorY,
                                                    amount: magnifyAmount, pinnedIndex: pinnedIndex)
                    let point = CGPoint(x: value.location.x, y: value.location.y + trackTop)
                    if let index = mag.hoveredIndex(at: point, trackWidth: trackWidth, railWidth: railWidth),
                       index >= 0, index < items.count {
                        onSelect(items[index].id)
                    }
                }
        )
        .position(x: availableSize.width - trackWidth / 2, y: trackTop + trackHeight / 2)
    }

    /// 跟踪坐标派生 hover：命中槽含光标即点亮该 tick；变化才写状态（去抖防每帧 setState）。
    private func updateHover(atLocal location: CGPoint, geometryY: CGFloat,
                             rest: ChatTickRailRestLayout, pinnedIndex: Int?) {
        let mag = ChatTickRailMagnifier(rest: rest, cursorY: geometryY,
                                        amount: magnifyAmount, pinnedIndex: pinnedIndex)
        let index = mag.hoveredIndex(at: CGPoint(x: location.x, y: geometryY),
                                     trackWidth: trackWidth, railWidth: railWidth)
        guard index != hoveredIndex else { return }
        hoveredIndex = index
    }
}

// MARK: - 预览胶囊层（动画作用域与 Canvas 隔离）

/// 悬停预览胶囊：独立成层只为把 `.animation(value: hoveredIndex)` 的作用域钉在本层，
/// 使 hover 变化帧的动画不波及兄弟 Canvas（光标位移保持即时、无隐式动画）。
/// 锚点 = 零尺寸视图钉在轨右基准线（x = trackWidth）并垂直对齐槽心；
/// overlay trailing + trailing padding 等价于旧 tick overlay(alignment:.trailing) + padding。
private struct ChatTickRailPreviewLayer: View {
    let items: [ChatTickRail.Item]
    let rest: ChatTickRailRestLayout
    let pinnedIndex: Int?
    let hoveredIndex: Int?
    let cursorY: CGFloat
    let amount: CGFloat
    let trackTop: CGFloat
    let trackWidth: CGFloat

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .offset(y: anchorCenterY)
            // 条件渲染放在 overlay 内：.transition 直接作用于胶囊自身，与旧 tick 内层
            // overlay(alignment:.trailing){ if hovered { 胶囊.transition(...) } } 语义等价。
            .overlay(alignment: .trailing) {
                if let index = hoveredIndex, index >= 0, index < items.count, !items[index].preview.isEmpty {
                    previewCapsule(index: index)
                }
            }
            // 作用域钉在本层：只动画胶囊过渡，不波及兄弟 Canvas 的光标位移。
            .animation(.easeOut(duration: Theme.Motion.chatTickHoverFade), value: hoveredIndex)
            .allowsHitTesting(false)
    }

    /// 锚点垂直位置 = 悬停 tick 的放大态视觉中心（几何区 → 跟踪带局部）。
    private var anchorCenterY: CGFloat {
        guard let index = hoveredIndex, index >= 0, index < items.count else { return 0 }
        let mag = ChatTickRailMagnifier(rest: rest, cursorY: cursorY,
                                        amount: amount, pinnedIndex: pinnedIndex)
        return (rest.containerTop - trackTop) + mag.center(at: index)
    }

    @ViewBuilder
    private func previewCapsule(index: Int) -> some View {
        let mag = ChatTickRailMagnifier(rest: rest, cursorY: cursorY,
                                        amount: amount, pinnedIndex: pinnedIndex)
        let baseWidth = items[index].isCurrent
            ? Theme.Layout.chatTickActiveWidth
            : Theme.Layout.chatTickWidth
        let scale = mag.scale(at: index)
        tickPreviewCapsule(items[index].preview)
            .padding(.trailing, baseWidth * scale + Theme.Layout.chatTickPreviewGap)
            .transition(.opacity.combined(with: .offset(x: 5)))
    }
}

// MARK: - 右缘消息刻度轨（Dock 放大手感）

/// 每条用户消息一枚 tick，静止紧凑密排（pitch 按可用高度自适应收缩）；光标进入磁吸
/// 跟踪带（轨体 + 上下各一个衰减半径 + 左伸接近带）后，光标附近的 tick 按余弦钟形
/// 衰减实时放大并彼此推开、明暗同步流动；离开平滑收拢。hover 预览胶囊、点击直达、
/// 当前条 accent 锚点（钉死不动）全部保留。
///
/// 丝滑的关键路径：
/// - **跟踪面挂在覆盖整个交互区的共同祖先上**：contentShape + onContinuousHover 挂在
///   磁吸带容器（交互层）上，从左邻带到轨上 hover 连续不断流；
/// - 光标 y 直接赋值驱动 Canvas 逐帧重绘（无隐式动画、即时跟随）；只有 magnifyAmount 的
///   进入 0→1 / 离开 1→0 走显式 easeOut 动画（Canvas 实现 Animatable，轨迹与旧逐 tick
///   scaleEffect/offset 插值一致）；
/// - 布局与光标解耦：静止几何缓存（ChatTickRailRestLayout）只在会话数据/尺寸变化时重算；
///   逐帧放大只解算窗口内少量 tick，整轨不做 O(n) 视图失效。
struct ChatTickRail: View {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let preview: String
        let isCurrent: Bool
    }

    let items: [Item]
    let onSelect: (UUID) -> Void

    /// 轨体宽 = 当前条峰值放大后宽度（tick 右缘对齐，放大向左生长，右基准线钉死不动）
    private var railWidth: CGFloat {
        Theme.Layout.chatTickActiveWidth * Theme.Layout.chatTickMagnifyMaxScale
    }

    /// 跟踪带宽 = 轨体宽 + 左伸接近带（光标逼近即开始响应，Dock 同款「迎光标」）
    private var trackWidth: CGFloat {
        railWidth + Theme.Layout.chatTickTrackSlop
    }

    var body: some View {
        GeometryReader { geo in
            ChatTickRailInteractive(items: items,
                                    availableSize: geo.size,
                                    trackWidth: trackWidth,
                                    railWidth: railWidth,
                                    onSelect: onSelect)
        }
    }
}

// MARK: - 预览胶囊

/// 预览胶囊：深面板底 + 0.5pt 描边 + 8pt 圆角 + 轻投影，白字单行截断；右端小三角指回 tick。
///
/// 布局关键（空壳事故根因）：本视图挂在 tick 位置锚点旁，SwiftUI overlay 会把宿主窄尺寸
/// 作为宽度 proposal 传进来，Text 会被压扁截断、只剩描边空壳。修复 = 先 frame(maxWidth:)
/// 再 fixedSize：fixedSize 让本视图忽略窄 proposal，frame(maxWidth:) 在自由 proposal 下把
/// 超长文本钳到上限截断。顺序不可换。
private func tickPreviewCapsule(_ text: String) -> some View {
    Text(text)
        .font(Theme.Typography.text(Theme.Typography.footnote))
        .foregroundColor(Theme.Colors.contentPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: Theme.Layout.chatTickPreviewMaxWidth - Theme.Spacing.xl * 2)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.previewCapsule, style: .continuous)
                .fill(Theme.Colors.chatNavFloatFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.previewCapsule, style: .continuous)
                .stroke(Theme.Colors.chatStrokeStrong, lineWidth: 0.5)
        )
        .overlay(alignment: .trailing) {
            TickPreviewTail()
                .fill(Theme.Colors.chatNavFloatFill)
                .frame(width: 5, height: 8)
                .offset(x: 4.5)
        }
        .shadow(color: .black.opacity(Theme.Shadow.navFloatOpacity),
                radius: Theme.Shadow.navFloatRadius,
                y: Theme.Shadow.navFloatY)
}

// MARK: - 浏览导航预览胶囊小三角

/// 预览胶囊右端指向 tick 的小三角（方向性锚点）。
struct TickPreviewTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}