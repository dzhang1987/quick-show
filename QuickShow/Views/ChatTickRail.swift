// 从 AIChatScrollNavigation.swift 机械拆分：AI 会话滚动与浏览导航——刻度轨布局 / 刻度轨视图 / 预览小三角。

import SwiftUI

// MARK: - 浏览导航刻度轨（Dock 放大手感）

/// 刻度轨布局数学（纯值模型，光标每帧移动即整轨 O(n) 重算）：
/// - 静止态：均匀紧凑 pitch（可用高 ÷ 条数自适应收缩、保底 pitchMin），容器高恒为
///   静止总高并垂直居中——**坐标系恒定是丝滑的关键**：放大只改槽内偏移与 scale，
///   容器几何不随放大变化，跟踪坐标无反馈漂移、无边界追逐振荡；
/// - 放大态：每枚 tick 按「光标 → 静止中心」距离的余弦钟形得权重 w（Dock 经典衰减：
///   峰在光标正下方、radius 处平滑归零、域外恒 0）；槽心 = 静止中心 + 上方累计生长
///   − 全局生长一半（绕几何中心对称生长）——所有 tick（含当前消息 tick）均正常
///   参与放大布局，彼此推开；
/// - 明暗与大小共用同一条 w：不透明度 = rest + t×(lerp(dim, bright, w) − rest)，
///   光标正下方最亮、远端比静止更暗，两个维度同步流动；
/// - 命中槽由相邻槽心中点切分（Voronoi），无缝相接、随放大同步长大——hover 判定与
///   点击目标在任何放大态下都严丝合缝。
struct ChatTickRailLayout {
    struct Slot: Equatable {
        var center: CGFloat      // 槽心 y（容器静止坐标系；tick 视觉锚点）
        var frameTop: CGFloat    // 命中槽顶（相邻槽心中点切分，可溢出容器上下缘）
        var frameHeight: CGFloat // 命中槽高（槽间恒无缝）
        var scale: CGFloat       // 放大倍率（1 = 静止态）
        var opacity: Double      // 普通刻度明暗梯度（rest 0.42 → dim 0.28 / bright 0.60）
        var activeOpacity: Double // 选中刻度明暗梯度（rest 0.65 → dim 0.40 / bright 1.00）
    }

    let pitch: CGFloat
    /// 静止总高（容器固定高 = n × pitch）
    let restHeight: CGFloat
    /// 容器顶缘在几何区（overlay 可用区）坐标系中的 y（垂直居中换算；跟踪层局部坐标
    /// 经 trackTop 偏移换算到本坐标系后使用）
    let containerTop: CGFloat
    /// 首/末命中槽的外缘（容器坐标系，可越出 [0, restHeight]）——hover 判定的上下界
    let railTop: CGFloat
    let railBottom: CGFloat
    let slots: [Slot]

    init(count: Int, availableHeight: CGFloat, cursorY: CGFloat, amount: CGFloat) {
        let tokens = Theme.Layout.self
        let n = max(count, 0)
        let avail = max(availableHeight, 1)
        // 放大生长余量（worst-case 上界 Σ(scale−1)·pitch ≤ (maxScale−1)·(radius+pitch)）：
        // 静止总高预算先扣除它 → 光标扫到峰值时整轨视觉高也不超可用区
        let growthReserve = (tokens.chatTickMagnifyMaxScale - 1)
            * (tokens.chatTickMagnifyRadius + tokens.chatTickPitch)
        // 密度自适应：优先在可用区内收缩 pitch（保底 pitchMin）。但极端窄窗 + 大量 tick
        // （dock 增高与会话变长叠加）时 pitchMin 地板仍会令 p×n > avail，轨体上下溢出
        // overlay 边缘。再加拟合上界 avail/n：正常区间不生效，只在地板失守时兜底，把
        // 静止总高与全部槽位（均以 p 为步长铺开）一并收进可用区——密度语义（均匀 pitch、
        // shrink-to-fit）不变，仅可读性让位于「绝不溢出」。
        let p = n > 0
            ? min(tokens.chatTickPitch,
                  max(tokens.chatTickPitchMin, (avail - growthReserve) / CGFloat(n)),
                  avail / CGFloat(n))
            : tokens.chatTickPitch
        pitch = p
        restHeight = min(p * CGFloat(n), avail)
        containerTop = (avail - restHeight) / 2

        guard n > 0 else {
            slots = []
            railTop = 0
            railBottom = 0
            return
        }
        let t = min(max(amount, 0), 1)
        let maxGain = tokens.chatTickMagnifyMaxScale - 1
        let radius = tokens.chatTickMagnifyRadius
        let colors = Theme.Colors.self

        // 第一遍：各 tick 的权重 w（余弦钟形）→ scale / 不透明度 / 生长量（所有刻度统一参与放大）
        var scales: [CGFloat] = []
        scales.reserveCapacity(n)
        var opacities: [Double] = []
        opacities.reserveCapacity(n)
        var activeOpacities: [Double] = []
        activeOpacities.reserveCapacity(n)
        var growths: [CGFloat] = []
        growths.reserveCapacity(n)
        for i in 0..<n {
            let center = containerTop + p * (CGFloat(i) + 0.5)
            let d = abs(cursorY - center)
            let w: CGFloat = d < radius ? 0.5 * (1 + cos(.pi * d / radius)) : 0
            let scale = 1 + maxGain * w * t
            scales.append(scale)
            growths.append((scale - 1) * p)
            // 明暗双维度：与大小共用同一 w 与渐入量 t（普通刻度 rest → lerp(dim, bright, w)）
            let target = colors.chatTickDimOpacity + (colors.chatTickBrightOpacity - colors.chatTickDimOpacity) * Double(w)
            opacities.append(colors.chatTickRestOpacity + Double(t) * (target - colors.chatTickRestOpacity))
            // 选中刻度明暗梯度（方案 A：activeRest → lerp(activeDim, activeBright, w)）
            let activeTarget = colors.chatTickActiveDimOpacity + (colors.chatTickActiveBrightOpacity - colors.chatTickActiveDimOpacity) * Double(w)
            activeOpacities.append(colors.chatTickActiveRestOpacity + Double(t) * (activeTarget - colors.chatTickActiveRestOpacity))
        }
        // 第二遍：槽心 = 静止中心 + 上方累计生长 − 全局生长一半（绕几何中心对称生长）
        var growthAbove: [CGFloat] = []
        growthAbove.reserveCapacity(n)
        var running: CGFloat = 0
        var totalGrowth: CGFloat = 0
        for i in 0..<n {
            growthAbove.append(running)
            running += growths[i]
            totalGrowth += growths[i]
        }
        let pivot = totalGrowth / 2
        var centers: [CGFloat] = []
        centers.reserveCapacity(n)
        for i in 0..<n {
            centers.append(p * (CGFloat(i) + 0.5) + growthAbove[i] - pivot)
        }
        // 第三遍：命中槽 = 相邻槽心中点切分（端点槽向外延伸自身半步，可越容器缘）
        var result: [Slot] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            let top = i > 0
                ? (centers[i - 1] + centers[i]) / 2
                : centers[0] - (n > 1 ? (centers[1] - centers[0]) / 2 : p * scales[0] / 2)
            let bottom = i < n - 1
                ? (centers[i] + centers[i + 1]) / 2
                : centers[i] + (n > 1 ? (centers[i] - centers[i - 1]) / 2 : p * scales[i] / 2)
            result.append(Slot(center: centers[i], frameTop: top,
                               frameHeight: bottom - top, scale: scales[i],
                               opacity: opacities[i], activeOpacity: activeOpacities[i]))
        }
        slots = result
        railTop = result[0].frameTop
        railBottom = result[n - 1].frameTop + result[n - 1].frameHeight
    }

    /// 几何区坐标 → 光标正下方的 tick 下标：横坐标须落在轨体内（左伸接近带只驱动放大、
    /// 不触发 hover），纵坐标须落在命中槽域内；槽无缝相接，命中即返。
    func hoveredIndex(at point: CGPoint, trackWidth: CGFloat, railWidth: CGFloat) -> Int? {
        guard !slots.isEmpty, point.x >= trackWidth - railWidth else { return nil }
        let y = point.y - containerTop
        guard y >= railTop, y <= railBottom else { return nil }
        for (i, slot) in slots.enumerated() where y >= slot.frameTop && y < slot.frameTop + slot.frameHeight {
            return i
        }
        return slots.indices.last  // y == railBottom 边界兜底
    }
}

/// 右缘消息刻度轨（Dock magnification 手感）：
/// 每条用户消息一枚 tick，静止紧凑密排（pitch 按可用高度自适应收缩）；光标进入磁吸
/// 跟踪带（轨体 + 上下各一个衰减半径 + 左伸接近带）后，光标附近的 tick 按余弦钟形
/// 衰减实时放大并彼此推开、明暗同步流动；离开平滑收拢。hover 预览胶囊、点击直达、
/// 当前条 accent 高亮标记全部保留并正常参与放大。
///
/// 丝滑的关键路径：
/// - **跟踪面必须挂在覆盖整个交互区的共同祖先上**（历史根因：跟踪层曾是 tick 层
///   下方兄弟节点，光标压上可命中的 tick 即触发 hover exit → 放大瞬间塌缩、胶囊
///   永不出现）——现在 contentShape + onContinuousHover 挂在包裹 tick 层的磁吸带
///   容器上，tick 是其后代，从左邻带到轨上 hover 连续不断流；
/// - 光标 y 直接赋值驱动每帧布局（无隐式动画、即时跟随）；只有 magnifyAmount 的
///   进入 0→1 / 离开 1→0 走显式 easeOut 动画（渐入点亮 / 收拢回弹）——进入动画
///   只在 hover 生命周期开始播一次（amount 目标值即时为 1，后续移动不重复触发）；
/// - hover 写入不走 withAnimation（防同事物染指槽位布局），胶囊过渡由 tick 内层
///   值域动画 `.animation(_:value:)` 承担（只在 hover 变化帧生效，光标移动帧零动画）；
/// - 光标状态私有于本视图——每帧重算只触及刻度轨子树，不冲刷消息列表。
struct ChatTickRail: View {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let preview: String
        let isCurrent: Bool
    }

    let items: [Item]
    let onSelect: (UUID) -> Void

    /// 光标 y（几何区坐标系；直接驱动 = 零动画即时跟随）
    @State private var cursorY: CGFloat = 0
    /// 放大渐入量 0…1：唯一走动画的分量（进入点亮 / 离开收拢）
    @State private var magnifyAmount: CGFloat = 0
    /// 被悬停 tick 的消息 id（预览胶囊锚点），由跟踪坐标派生
    @State private var hoveredTickId: UUID?

    /// 轨体宽 = 刻度峰值放大后宽度（tick 右缘对齐，放大向左生长，右基准线钉死不动）
    private var railWidth: CGFloat {
        Theme.Layout.chatTickWidth * Theme.Layout.chatTickMagnifyMaxScale
    }

    /// 跟踪带宽 = 轨体宽 + 左伸接近带（光标逼近即开始响应，Dock 同款「迎光标」）
    private var trackWidth: CGFloat {
        railWidth + Theme.Layout.chatTickTrackSlop
    }

    var body: some View {
        GeometryReader { geo in
            let model = ChatTickRailLayout(
                count: items.count,
                availableHeight: geo.size.height,
                cursorY: cursorY,
                amount: magnifyAmount
            )
            let radius = Theme.Layout.chatTickMagnifyRadius
            // 磁吸带 = 轨体 ± 一个衰减半径（几何区坐标）；不铺满全高——带外衰减恒零
            // （手感无差），右缘其余区域不占用命中（滚动条可拖拽）
            let trackTop = max(0, model.containerTop - radius)
            let trackHeight = min(geo.size.height, model.containerTop + model.restHeight + radius) - trackTop
            ZStack(alignment: .topTrailing) {
                // tick 层：容器恒为静止总高；放大形变全部收在槽内偏移与 scale
                ZStack(alignment: .top) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        tick(item, slot: model.slots[index])
                    }
                }
                .frame(width: railWidth, height: model.restHeight, alignment: .top)
                .offset(y: model.containerTop - trackTop)
            }
            .frame(width: trackWidth, height: trackHeight, alignment: .topTrailing)
            // 单一跟踪面：覆盖整个交互区（接近带 + 轨体），tick 是其后代 →
            // 光标在带内任意位置 hover 连续；点击仍由 tick 自身的 tap 手势命中
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let y = location.y + trackTop  // 带局部 → 几何区坐标系
                    cursorY = y
                    updateHover(at: CGPoint(x: location.x, y: y), model: model)
                    if magnifyAmount < 1 {
                        withAnimation(.easeOut(duration: Theme.Motion.chatTickMagnifyIn)) {
                            magnifyAmount = 1
                        }
                    }
                case .ended:
                    withAnimation(.easeOut(duration: Theme.Motion.chatTickMagnifyOut)) {
                        magnifyAmount = 0
                        hoveredTickId = nil
                    }
                }
            }
            .position(x: geo.size.width - trackWidth / 2, y: trackTop + trackHeight / 2)
        }
    }

    /// 跟踪坐标派生 hover：命中槽含光标即点亮该 tick；变化才写状态（去抖防每帧 setState）。
    /// 刻意裸写不走 withAnimation——胶囊过渡由 tick 内层 .animation(_:value:) 承担，
    /// 本路径若带动画事务会染指同一渲染帧里的槽位布局（放大跟手性受损）。
    private func updateHover(at location: CGPoint, model: ChatTickRailLayout) {
        let newId = model.hoveredIndex(at: location, trackWidth: trackWidth, railWidth: railWidth)
            .map { items[$0].id }
        guard newId != hoveredTickId else { return }
        hoveredTickId = newId
    }

    /// 单枚 tick：基础 10×2 圆头（所有刻度几何尺寸统一，当前条仅以 accent 色彩区分）；
    /// 明暗随槽位梯度输出（普通刻度 0.42→0.28/0.60，当前条 0.65→0.40/1.00）；点击直达该条消息。
    /// 命中区 = Voronoi 槽（随放大同步长大、槽间无缝），胶囊视觉锚定槽心、scaleEffect 放大。
    /// 动画作用域纪律：`.animation(_:value:)` 只罩颜色/胶囊/缩放内层（hover 变化帧才生效）；
    /// 槽位 offset/frame 外壳零动画修饰——光标移动帧的布局即时跟随，绝不橡胶延迟。
    @ViewBuilder
    private func tick(_ item: Item, slot: ChatTickRailLayout.Slot) -> some View {
        let hovered = hoveredTickId == item.id
        let baseWidth = Theme.Layout.chatTickWidth
        let baseHeight = Theme.Layout.chatTickHeight
        let fillOpacity = item.isCurrent ? slot.activeOpacity : slot.opacity
        let fillColor = item.isCurrent ? Theme.Colors.accent : Color.primary
        Capsule(style: .continuous)
            .fill(fillColor.opacity(fillOpacity))
            .frame(width: baseWidth, height: baseHeight)
            .scaleEffect(slot.scale)
            .overlay(alignment: .trailing) {
                // 预览胶囊：hover 弹出，锚定放大后 tick 左侧（overlay trailing = 垂直中心
                // 即 tick 视觉中心）；空文本（纯图片等）消息不弹胶囊；纯展示不吞命中
                if hovered && !item.preview.isEmpty {
                    tickPreviewCapsule(item.preview)
                        .padding(.trailing, baseWidth * slot.scale + Theme.Layout.chatTickPreviewGap)
                        .transition(.opacity.combined(with: .offset(x: 5)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: Theme.Motion.chatTickHoverFade), value: hovered)
            .animation(.easeOut(duration: Theme.Motion.chatTickHoverFade), value: item.isCurrent)
            // —— 以下外壳定位属性无动画修饰覆盖：光标驱动即时跟随 ——
            // 视觉锚定槽心（命中槽与视觉中心在轨端略有错位，故不用槽 frame 的中心对齐）
            .offset(y: slot.center - slot.frameTop - baseHeight / 2)
            .frame(width: railWidth, height: slot.frameHeight, alignment: .topTrailing)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(item.id) }
            // 刻意不挂 .help()——系统 tooltip 与预览胶囊语义冗余，且贴右缘没有 tip 落点空间
            .offset(y: slot.frameTop)
    }

    /// 预览胶囊：深面板底 + 0.5pt 描边 + 8pt 圆角 + 轻投影，白字单行截断；
    /// 右端小三角指回 tick（方向性锚点）。
    ///
    /// 布局关键（空壳事故根因）：本视图挂在 tick 的 overlay 里，SwiftUI overlay 会把
    /// 宿主 tick 的窄尺寸（≈10~16pt）作为宽度 proposal 传进来，Text 会被压扁截断、
    /// 只剩描边空壳。修复 = 先 frame(maxWidth:) 再 fixedSize：fixedSize 让本视图忽略
    /// 宿主 proposal，frame(maxWidth:) 在自由 proposal 下把超长文本钳到上限截断。
    /// 顺序不可换（fixedSize 在前会让 frame 重新收到窄 proposal，前功尽弃）。
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
