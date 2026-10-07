// 从 AIChatView.swift 机械拆分：浮岛输入坞（输入卡 + 生长区 + 抽屉连续玻璃体）。

import AppKit
import Combine
import SwiftUI

// MARK: - 浮岛输入坞

/// 浮岛输入坞：输入卡（文本区 + 底部工具行）、生长区（队列/附件/剪贴板胶囊）、
/// 抽屉连续玻璃体与坞体实测高度上报。由父级 AIChatView 以 overlay(alignment: .bottom)
/// 悬浮于消息列表之上；坞内状态（安静/激活、环境 modelList、会话配置戳、窗口 key 态）
/// 全部私有化随本组件保活——父级只注入会话状态与既有出口闭包。
/// 与 SessionMessageList / AIChatSidebarView 同构：外部注入 + 内部 @State 自治。
@MainActor
struct AIChatInputDock: View {
    @ObservedObject var state: AIChatState
    /// 输入坞抽屉交互中心：观察 request 驱动抽屉展开/收起（权限确认 / AI 提问）。
    @ObservedObject private var interaction = ChatInteractionCenter.shared
    /// 坞体实测总高（单向写回父级：供消息列表尾部留白 / 空态 overlay / toast 位置消费；
    /// 值单向流出、绝不反向影响坞体布局，无反馈环）。
    @Binding var dockTotalHeight: CGFloat
    /// 附加剪贴板文本（父级 attachClipboard）。
    let onAttachClipboard: () -> Void
    /// 导出整段对话 Markdown（父级 exportConversation）。
    let onExportConversation: () -> Void
    /// ESC 兜底出口（父级 handleEscape：抽屉 → 重命名 → 中止 → 关窗）。
    let onEscape: () -> Void

    /// 输入框占位文案（快捷键语义由各控件 .qsHelp() tooltip 承担，占位只留一句）。
    private let inputPlaceholder = "问点什么…"

    /// 输入内容空态：独立于 state.inputText 的回写通道（IME 组字期间由 setMarkedText 回调驱动）。
    /// 显隐判据须与 state.inputText.isEmpty 取与：@State 初值固定为 true 且首挂载无变化事件
    /// （onChange 不响应初始值、updateNSView 周期内写 state 不可靠），单通道会在草稿恢复
    /// （重启载入 / 程序化填充）时与既有文字重影；派生条件首帧求值即正确，零时序依赖。
    @State private var inputEmpty = true

    /// 模型列表（AIChatService 非 @Published，随环境刷新主动拉取；
    /// 当前生效模型改读 state 会话级绑定，此处不再镜像选中态）。
    @State private var modelList: [AIModel] = []

    /// 坞区 hover 态：安静/激活两态切换的触发源之一（鼠标进入坞区即浮现完整工具行）。
    /// 输入框唤出即自动聚焦（windowDidBecomeKey 兜底），"聚焦"恒为真、无法作披露信号，
    /// 故渐进披露的诚实触发源 = 坞区 hover + 内容存在（草稿/附件/队列/生成中）。
    @State private var dockHovered = false
    /// 输入坞微胶囊 hover 态（⊕ / 剪贴板 / 模型 chip / 思考 chip 的 hover 提亮）。
    /// （窗口 key 态已下沉到 DockFocusRim 自持——原先 windowIsKey 挂在坞级 @State，
    /// 每次焦点翻转都带着整个输入坞视图重算（含 representable diff），是聚焦/失焦
    /// 卡顿的触发器之一；隔离后焦点切换只重算那个 30 行小视图。）
    @State private var attachHovered = false
    @State private var clipboardHovered = false
    @State private var chipHovered = false
    @State private var thinkingChipHovered = false

    /// 会话配置变化戳（"modelId|level"）：state 的会话级模型/思考档位是读 store 的计算属性，
    /// 且 state 的消息扇出管线按 messages 去重（只改模型/档位时消息数组不变、不扇出）——
    /// 此处作 chip 刷新的触发器：订阅当前会话两字段，变化时更新戳驱动 body 重算；
    /// 赋值幂等（重放同值不写入），防 onReceive 重订阅重放导致的更新循环。
    @State private var sessionConfigStamp = ""

    var body: some View {
        inputArea
            // 挂载即拉取模型列表并补窗口 key 初值（窗口可能已 key，onAppear 先于通知时兜底）。
            .onAppear {
                refreshModelList()
            }
            // AI 窗成为 key：刷新模型列表（设置窗口改动后即时生效）；
            // 只在 AI 窗自身变化时计入（其他窗口激活不误触）。
            // （焦点态 rim 的 windowIsKey 已下沉 DockFocusRim，此回调不再写坞级 @State。）
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard note.object is AIPanel else { return }
                DispatchQueue.main.async {
                    refreshModelList()
                }
            }
            // 外部清空输入（发送 / ⌘K / 重试）经 state.inputText 变化同步空态。
            // 组字期间 ChatInputNSTextView 的 setMarkedText 回调已实时同步 state.inputText（见 syncInputState），
            // 因此这里对组字文本同样生效；绑定与 textView.string 一致后不会形成回写回路。
            .onChange(of: state.inputText) { newValue in
                inputEmpty = newValue.isEmpty
            }
            // 会话级模型/思考档位变化 → 模型/思考 chip 跟随刷新（触发器为何必要的说明
            // 见 sessionConfigStamp 注释；切会话路径由父级 messages 扇出管线天然覆盖）。
            .onReceive(
                state.store.$sessions
                    .map { sessions -> String in
                        let current = sessions.first(where: { $0.id == state.store.currentSessionId })
                        return "\(current?.modelId ?? "")|\(current?.thinkingLevel?.rawValue ?? "")"
                    }
                    .removeDuplicates()
            ) { stamp in
                if stamp != sessionConfigStamp { sessionConfigStamp = stamp }
            }
    }

    // MARK: - 输入区（浮岛输入坞）

    // MARK: 坞体安静/激活两态（渐进披露）

    /// 安静态判据：无草稿、无附件、无待注入队列、非生成中、无抽屉请求，且鼠标不在坞区。
    /// 安静态下坞收敛为「纯输入行 + 弱化小字 chip + 无底灰箭头」——无 accent rim、
    /// 无实心色块、低频工具隐去，空态视觉重心让回中部引导区；
    /// 悬停坞区 / 开始输入 / 附加内容 / 生成开始 / 抽屉展开即切换激活态（0.16s 淡入，contentFade）。
    private var dockQuiet: Bool {
        // 空态判据双通道与：草稿恢复期 inputEmpty 可能滞后（@State 初值 true、首帧无变化事件），
        // state.inputText 非空即有草稿，首帧即正确（见 inputEmpty 声明处注释）。
        inputEmpty
            && state.inputText.isEmpty
            && state.clipboardAttachment == nil
            && state.imageAttachments.isEmpty
            && state.pendingQueue.isEmpty
            && !state.isStreaming
            && interaction.request == nil
            && !dockHovered
    }

    /// 低频工具组（压缩/水位/剪贴板）显隐：安静态隐去（保留占位、纯透明渐变、布局零跳动）；
    /// 两类破格常显，同源同档：水位逼近上限（需要警示的时刻不沉默）+ 压缩进行中
    /// （进行中的操作不消失——2026-10 用户决策：压缩中圆环转不定态 spinner，必须留在
    /// 视口内；压缩结束恢复随安静态隐去）。
    private var showDockSecondaryTools: Bool { !dockQuiet || watermarkBreaksThrough || state.isCompacting }

    /// 水位警示破格：用量占比 > 0.8（与细条进红同一阈值）。
    private var watermarkBreaksThrough: Bool { (state.contextWatermark?.ratio ?? 0) > 0.8 }

    /// 发送钮实心态判据：可发送或生成中（驱动 禁用灰箭头 ⇄ 实心强调色 的淡变）。
    private var sendButtonSolid: Bool { state.isStreaming || canSend }

    /// 生长区是否在场（队列/附件/剪贴板任一非空）：与 inputArea 生长区容器的 if 判据同源。
    private var hasDockGrowth: Bool {
        !state.pendingQueue.isEmpty
            || !state.imageAttachments.isEmpty
            || state.clipboardAttachment != nil
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // 生长区（输入卡上方：队列胶囊 / 附件条 / 剪贴板胶囊）：容器化以便整段实测高度
            // （background 内 GeometryReader + preference，macOS 13 无 onGeometryChange；
            // 先例见 ChatReadingColumn 的宽度读取）。间距语义与三段直接并列完全等价——
            // 段间 lg 收进内层，末段与输入卡的 lg 仍由外层承担，三段全空时容器整体缺席，
            // 布局与展开前逐点一致。
            if hasDockGrowth {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    // 待注入队列（steering 转向 / follow-up 追问）：生成中 ⏎/⌥⏎ 的消息在此排队，
                    // 点击胶囊取回编辑；队列区置于坞体顶部、随内容向上生长，宽度与坞一致。
                    if !state.pendingQueue.isEmpty {
                        VStack(spacing: Theme.Spacing.sm) {
                            ForEach(state.pendingQueue) { item in
                                QueuedInputCapsule(item: item) {
                                    state.recallQueuedInput(id: item.id)
                                }
                                .transition(.opacity.combined(with: .scale(scale: Theme.Motion.toastScale)))
                            }
                        }
                        .animation(.easeOut(duration: Theme.Motion.contentFade), value: state.pendingQueue)
                    }

                    // 待发送图片附件条：缩略图胶囊横排，可单个移除
                    if !state.imageAttachments.isEmpty {
                        ImageAttachmentStrip(attachments: state.imageAttachments) { id in
                            state.removeImageAttachment(id: id)
                        }
                    }

                    // 剪贴板附加胶囊：非 nil 时显示，可一键移除
                    if let clip = state.clipboardAttachment {
                        ClipboardAttachmentCapsule(charCount: clip.count) {
                            state.removeClipboardAttachment()
                        }
                    }
                }
                // 坞体高度上报已上移至 inputArea 根（整体实测直写 @State），
                // 生长区容器不再单独上报——生长区高度变化经总高自然捕获。
            }

            // 连续玻璃体（2026-10 抽屉式交互）：抽屉（在场时）+ 输入卡共享同一个
            // GlassSurface / accent rim / 双层阴影——抽屉是输入卡"长出"的上半部分，
            // 衔接处零间隙、圆角恒为 Radius.groupCard，中间仅一条 0.5pt 极淡分隔线。
            // 窗口 frame 不动：抽屉展开纯视图内布局（聊天流自动让位收缩），
            // 规避整窗玻璃 + SwiftUI 测量链死锁。
            VStack(spacing: 0) {
                // 抽屉（权限确认 / AI 提问）：从输入卡上沿向上滑入；
                // .id(request.id) 使请求切换时整树重建、面板内 @State 天然重置。
                if let request = interaction.request {
                    AIChatDrawerPanel(request: request)
                        .id(request.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    // 衔接处极淡分隔（0.5pt，水平内收与抽屉内容边距一致）
                    Rectangle()
                        .fill(Theme.Colors.cardStroke)
                        .frame(height: Theme.Layout.dividerHeight)
                        .padding(.horizontal, Theme.Spacing.section)
                        .transition(.opacity)
                }

                inputCardContent
            }
            // 功能层：输入坞是典型控件面（输入条/发送/附件/模型 chip），26+ 官方 Liquid Glass，
            // <26 退化为 ultraThinMaterial + 0.5pt 描边；坞悬浮于消息流之上，玻璃采样到真实
            // 内容流（blur-through）。纪律：坞内控件（⊕/chip/发送/剪贴板）绝不再用 glassEffect
            // （glass-on-glass），一律纯灰图标 hover 出圆底（与图钉同一克制语言）。
            // <26 降级描边随安静/激活换档：安静态降到 cardStroke(0.09) 近无感，激活态回 0.14。
            .modifier(GlassSurface(
                shape: RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous),
                strokeColor: dockQuiet ? Theme.Colors.cardStroke : Theme.Colors.chatStrokeStrong
            ))
            // 激活态 rim：坞体激活（悬停/输入/附件/生成中/抽屉在场）且窗口 key 时叠加
            // accent 低透明度环，材质对状态有响应；安静态零描边。
            // 性能：rim 由 DockFocusRim 自持窗口 key 态——焦点切换只重算这个小视图，
            // 不再触发整个输入坞 body 重算（原先 dockRimActive 读坞级 windowIsKey）。
            // allowsHitTesting(false) 在 DockFocusRim 内部实现（防描边层吞点击）。
            .overlay(DockFocusRim(quiet: dockQuiet))
            // 双层阴影：接触影贴身定锚 + 环境影拉开纵深（旧单层贴身影 = 卡片糊在底板上）
            .shadow(color: .black.opacity(Theme.Shadow.dockContactOpacity), radius: Theme.Shadow.dockContactRadius, y: Theme.Shadow.dockContactY)
            .shadow(color: .black.opacity(Theme.Shadow.dockAmbientOpacity), radius: Theme.Shadow.dockAmbientRadius, y: Theme.Shadow.dockAmbientY)
            // 拖到输入卡边缘 padding 区也能接住（主路径在 NSTextView 子类）
            .onDrop(of: ["public.image", "public.file-url"], isTargeted: nil) { providers in
                handleDropProviders(providers)
            }
            // 水位圆环详情卡宿主：必须位于 GlassSurface 之后——26+ 的 .glassEffect 会把
            // 内容裁剪进玻璃形状，挂早了浮层会被输入卡顶缘切断（机制见组件头注）
            .contextRingDetailHost()
            // 抽屉展开/收起动画：0.25s easeOut 滑入滑出（本特性私有节拍，令牌见
            // AIChatDrawerPanel.swift 头注）；尾部留白经 dockTotalHeight 实测自动跟随抽屉顶。
            .animation(.easeOut(duration: AIChatDrawerMetrics.slideDuration), value: interaction.request?.id)
        }
        // 浮岛坞与消息列同限宽、同居中；快捷键提示条已删（提示由各控件 .qsHelp() tooltip 承担，
        // 清空会话入口移入 ⊕ 菜单），坞体即输入区全部。
        // 顶部零 padding：真穿透后坞顶上方无任何过渡带，内容直接滚到玻璃坞下；
        // 底部 12pt 为坞与窗缘的呼吸缝
        .padding(.bottom, Theme.Spacing.xxl)
        // 坞体总高实测（生长区 + 输入卡 + 底缝）：background GeometryReader 不占布局、
        // 只在坞高变化（胶囊增删/工具行换态）时求值，事件级频率非逐帧。
        // 机制说明：经实测 preference 冒泡在本视图上下文中断——发射值到不了链尾观察点
        // （恒收 defaultValue 0，写死常量发射亦然，而发射视图 onAppear 正常在渲染）；
        // 改用 GeometryReader 内容的 onAppear/onChange 直写 @State（同视图事件已被
        // 实证可靠触发，首帧即拿到真实高度、坞体生长时跟随更新）。
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { noteDockTotalHeight(geo.size.height) }
                    .onChange(of: geo.size.height) { noteDockTotalHeight($0) }
            }
        )
        .chatReadingColumn()
        // 坞区 hover：驱动坞体安静→激活切换（低频工具组淡入、accent rim 点亮）。
        // B2：不再于 hover 时主动读取 NSPasteboard（剪贴板改为显式点击时按需读取）。
        .onHover { hovering in
            dockHovered = hovering
        }
    }

    /// 坞体总高回写：去抖（<0.5pt 跳过）防微抖重渲染；首帧 fallback → 实测校准一次。
    private func noteDockTotalHeight(_ height: CGFloat) {
        if abs(height - dockTotalHeight) > 0.5 {
            dockTotalHeight = height
        }
    }

    /// B3：模型列表仅在内容变化时刷新（AIChatService.modelList 非 @Published，
    /// 窗口激活/挂载时按需拉取；缓存比对避免同值重复赋值触发无谓重渲染）。
    private func refreshModelList() {
        let latest = AIChatService.shared.modelList
        if latest != modelList { modelList = latest }
    }

    /// 输入卡内容（连续玻璃体的下半部分）：文本区 + 底部工具行
    /// （⊕ 附件 / 模型 chip / 思考 chip ║ 低频工具组 / 发送）；安静/激活两态语义见 dockQuiet。
    /// 玻璃面/描边/阴影由外层连续体容器统一施加，本视图只排版内容。
    private var inputCardContent: some View {
        VStack(spacing: 0) {
            // 输入框：NSViewRepresentable 包装 NSTextView（自定义 ⏎/⇧⏎ 与中文 IME 组字语义）
            ZStack(alignment: .topLeading) {
                ChatInputTextView(
                    text: $state.inputText,
                    isInputEmpty: $inputEmpty,
                    onSubmit: { submitInput() },
                    onSubmitFollowUp: { submitFollowUp() },
                    onEscape: { onEscape() },
                    onInsertImages: { images in insertImages(images) },
                    onRecallFirst: { state.recallFirstQueuedInput() }
                )
                // 双通道与：草稿恢复期 inputEmpty 滞后为 true（@State 初值、首帧无变化事件），
                // state.inputText 非空即有文字，placeholder 不显示——防重影（见 inputEmpty 声明处注释）。
                if inputEmpty && state.inputText.isEmpty {
                    Text(inputPlaceholder)
                        .font(Theme.Typography.text(13))
                        .foregroundColor(Theme.Colors.idleText)
                        // 与 textContainerInset 同步：光标距卡边 18pt；垂直 12pt 与固定 3 行框（72pt）首行顶对齐
                        .padding(.horizontal, Theme.Spacing.section)
                        .padding(.vertical, Theme.Spacing.xxl)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: Theme.Layout.chatInputHeight)

            // 底部工具行（2026-10 重设计）：左组 = ⊕ 附件 / 模型 chip / 思考 chip /
            // 水位圆环（低频工具组随 showDockSecondaryTools 显隐）；
            // 右组 = 剪贴板（hover 坞浮现）+ 发送钮。元素间距统一 lg(8)。
            HStack(spacing: Theme.Spacing.lg) {
                attachMenuButton
                modelChip
                thinkingChip
                // 低频工具组（水位圆环：水位/详情/压缩三合一，AIChatContextRingView）：
                // 安静态整体隐去——保留占位、纯透明度渐变、布局零跳动；
                // 悬停/输入/附件/生成中淡入；两类破格常显：水位 >0.8（警戒亮弧语义在
                // 组件内）+ 压缩进行中（spinner 必须可见，见 showDockSecondaryTools）
                if let watermark = state.contextWatermark {
                    AIChatContextRingView(
                        watermark: watermark,
                        isCompacting: state.isCompacting,
                        summarizedCount: state.compactionInfo?.summarizedCount,
                        compactionOutcome: state.currentSessionOutcome,
                        onCompact: { state.compactNow() }
                    )
                    .opacity(showDockSecondaryTools ? 1 : 0)
                    .allowsHitTesting(showDockSecondaryTools)
                    .accessibilityHidden(!showDockSecondaryTools)
                    .animation(.easeOut(duration: Theme.Motion.contentFade), value: showDockSecondaryTools)
                }
                Spacer(minLength: 0)
                clipboardButton
                    .opacity(showDockSecondaryTools ? 1 : 0)
                    .allowsHitTesting(showDockSecondaryTools)
                    .accessibilityHidden(!showDockSecondaryTools)
                    .animation(.easeOut(duration: Theme.Motion.contentFade), value: showDockSecondaryTools)
                sendButton
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.lg)
        }
    }

    /// ⊕ 附件菜单：剪贴板导入 / 从文件选择… / 清空会话（清空入口自底部提示条迁入）。
    /// 克制语言：静止纯灰图标、无底无 rim（与顶栏图钉同款），hover 才出圆底提亮。
    private var attachMenuButton: some View {
        Menu {
            Button {
                attachImageFromPasteboard()
            } label: {
                Label("剪贴板导入", systemImage: "photo.on.rectangle")
            }

            Button {
                chooseImageFiles()
            } label: {
                Label("从文件选择…", systemImage: "folder")
            }

            Divider()

            Button {
                onExportConversation()
            } label: {
                Label("导出对话", systemImage: "square.and.arrow.up")
            }
            .disabled(state.messages.isEmpty)

            Button {
                state.clearSession()
            } label: {
                Label("清空会话", systemImage: "trash")
            }
            .disabled(state.messages.isEmpty)
        } label: {
            Image(systemName: "plus")
                .font(Theme.Typography.text(13, .medium))
                .foregroundColor(attachHovered ? Theme.Colors.iconHover : Theme.Colors.iconRest)
                .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
                .background(Circle().fill(attachHovered ? Theme.Colors.iconHoverBg : Color.clear))
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { attachHovered = hovering }
        }
        .qsHelp("添加图片附件（可粘贴/拖入）· 导出对话 · 清空会话（⌘K）")
    }

    /// 模型 chip：显示当前会话绑定模型（未绑定时回落全局默认），点击弹下拉切换。
    /// 选中写入会话级绑定（state.setSessionModel），不再写全局；仅多模型时显示，单模型弱化隐藏。
    /// 弱化小字语言：无胶囊底无 rim 的三级灰小字常驻（当前模型名需可瞥见），hover 才出圆底提亮。
    @ViewBuilder
    private var modelChip: some View {
        if modelList.count > 1 {
            Menu {
                ForEach(modelList) { model in
                    Button {
                        state.setSessionModel(model.modelId)
                    } label: {
                        if model.modelId == effectiveModelId {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(currentModelName)
                        .font(Theme.Typography.text(11, .regular))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Theme.Typography.text(8, .medium))
                        .foregroundColor(Theme.Colors.idleText)
                }
                .foregroundColor(chipHovered ? Theme.Colors.iconHover : Theme.Colors.contentTertiary)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.xxxs)
                .frame(height: Theme.Layout.iconButtonSize)
                .background(
                    Capsule(style: .continuous)
                        .fill(chipHovered ? Theme.Colors.iconHoverBg : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering in
                withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { chipHovered = hovering }
            }
            .qsHelp("切换本会话模型（下一轮对话生效）")
        }
    }

    /// 当前生效模型 id：会话级绑定优先，未绑定（nil）回落全局默认模型。
    private var effectiveModelId: String {
        state.currentSessionModelId ?? AIChatService.shared.selectedModel
    }

    private var currentModelName: String {
        if let matched = modelList.first(where: { $0.modelId == effectiveModelId }) {
            return matched.name
        }
        return effectiveModelId.isEmpty ? "模型" : effectiveModelId
    }

    /// 思考强度 chip：会话级档位（默认 = 跟随当前模型自身默认），与模型 chip 同弱化小字语言。
    /// 默认态三级灰小字，选定档位后提到二级对比度——一眼可辨「已覆盖」，但不再是白粗胶囊。
    /// 「关闭」档仅当当前生效模型允许关闭思考时出现（如 GLM-5.3 不可关则不显示该档）。
    private var thinkingChip: some View {
        Menu {
            Button {
                state.setThinkingLevel(nil)
            } label: {
                if state.currentThinkingLevel == nil {
                    Label("默认", systemImage: "checkmark")
                } else {
                    Text("默认")
                }
            }
            ForEach(ThinkingLevel.allCases, id: \.self) { level in
                if level != .off || state.canDisableThinking(for: effectiveModelId) {
                    Button {
                        state.setThinkingLevel(level)
                    } label: {
                        if state.currentThinkingLevel == level {
                            Label(thinkingLevelTitle(level), systemImage: "checkmark")
                        } else {
                            Text(thinkingLevelTitle(level))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(thinkingChipTitle)
                    .font(Theme.Typography.text(11, .regular))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.Typography.text(8, .medium))
                    .foregroundColor(Theme.Colors.idleText)
            }
            .foregroundColor(thinkingChipHovered
                             ? Theme.Colors.iconHover
                             : (state.currentThinkingLevel == nil
                                ? Theme.Colors.contentTertiary
                                : Theme.Colors.contentSecondaryStrong))
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.xxxs)
            .frame(height: Theme.Layout.iconButtonSize)
            .background(
                Capsule(style: .continuous)
                    .fill(thinkingChipHovered ? Theme.Colors.iconHoverBg : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { thinkingChipHovered = hovering }
        }
        .qsHelp("调整思考强度（本会话生效）")
    }

    /// chip 标题：默认态只露「思考」二字（弱化），选定档位后紧凑显示「思考·高」式后缀。
    private var thinkingChipTitle: String {
        guard let level = state.currentThinkingLevel else { return "思考" }
        switch level {
        case .off: return "思考·关"
        case .low: return "思考·低"
        case .medium: return "思考·中"
        case .high: return "思考·高"
        }
    }

    /// 菜单档位名（中文全字，与 chip 缩略后缀区分场景）。
    private func thinkingLevelTitle(_ level: ThinkingLevel) -> String {
        switch level {
        case .off: return "关闭"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    /// 剪贴板附加钮：低频功能，安静态随低频工具组整体隐去（见 showDockSecondaryTools）；
    /// 克制语言：静止纯灰图标无底无 rim（与图钉同款），hover 才出圆底提亮。
    /// B2：可用态不再依赖窗口激活时的主动探测（已移除）；恒可点，点击时按需读取剪贴板。
    private var clipboardButton: some View {
        Button {
            onAttachClipboard()
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(Theme.Typography.text(13, .medium))
                .foregroundColor(clipboardHovered ? Theme.Colors.iconHover : Theme.Colors.iconRest)
                .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
                .background(Circle().fill(clipboardHovered ? Theme.Colors.iconHoverBg : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Theme.Motion.contentFade)) { clipboardHovered = hovering }
        }
        .qsHelp("附加剪贴板内容作为上下文")
    }

    private var sendButton: some View {
        Button {
            if state.isStreaming {
                state.abortStreaming()
            } else {
                state.send()
            }
        } label: {
            Image(systemName: state.isStreaming ? "stop.fill" : "arrow.up")
                .font(Theme.Typography.text(13, .bold))
                .foregroundColor(sendButtonForeground)
                .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
                .background(Circle().fill(sendButtonFill))
                .animation(.easeOut(duration: Theme.Motion.contentFade), value: sendButtonSolid)
        }
        .buttonStyle(.plain)
        .disabled(!state.isStreaming && !canSend)
        .qsHelp(state.isStreaming ? "中止生成" : "发送（⏎）· 追问（⌥⏎）")
    }

    // MARK: - 状态与动作

    private var canSend: Bool {
        !state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || state.clipboardAttachment != nil
            || !state.imageAttachments.isEmpty   // 纯图片也可发送
    }

    /// ⏎ 发送键路（ChatInputNSTextView 回调）：
    /// - 非生成中：普通发送，清空由 send() 内部完成（含未配置端点时保留输入的语义）；
    /// - 生成中：数据层把 send() 转入 steering 队列（send 内 isStreaming 分支提前返回，
    ///   不消费输入态），此处按「入队反馈 = 输入框清空 + 队列胶囊浮现」由 UI 侧补齐清空。
    private func submitInput() {
        let wasStreaming = state.isStreaming
        state.send()
        if wasStreaming { clearDraft() }
    }

    /// ⌥⏎ 追问键路（ChatInputNSTextView 回调）：
    /// - 生成中：入 follow-up 队列（本轮将停时注入再跑一轮），随后按发送同款清空输入
    ///   （enqueueFollowUp 与 enqueueSteering 同样不消费输入态）；
    /// - 非生成中：退化为普通发送（与 ⏎ 同路径，send 内自守门控）。
    private func submitFollowUp() {
        // 门控信号与数据层 enqueueFollowUp 同源（isStreaming）：
        // 残留边界（消息态生成中但流集合已清）下入队会被拒，此处退化为普通发送不丢草稿。
        guard state.isStreaming else {
            state.send()
            return
        }
        let text = state.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = state.imageAttachments
        guard !text.isEmpty || !images.isEmpty else { return }
        state.enqueueFollowUp(text: text, images: images)
        clearDraft()
    }

    /// 清空草稿态（文本 / 剪贴板附加 / 图片附件）——与 state.send() 正常分支内清空同款。
    /// 同时丢弃已持久化的会话草稿（steering / follow-up 入队不会经 state.send() 消费输入态）。
    private func clearDraft() {
        state.discardCurrentDraft()
        state.inputText = ""
        state.clipboardAttachment = nil
        state.imageAttachments = []
    }

    /// 发送键底：可用 = 主题强调色实心（琥珀/青，全图最强图底反转——强调只在可发送瞬间登场），
    /// 流式 = 警告红；空态/禁用 = 无底（透明），杜绝空态下高亮实心色块抢夺视觉重心。
    private var sendButtonFill: Color {
        if state.isStreaming { return Theme.Colors.statusWarning.opacity(0.9) }
        return canSend ? Theme.Colors.accent : Color.clear
    }

    /// 发送键图标：实心强调色底上取深色（琥珀/青均属亮色底，深图标对比最稳），
    /// 流式红底用白色；禁用态 contentTertiary（≈4.7:1，灰箭头静止可读但不抢眼）。
    private var sendButtonForeground: Color {
        if state.isStreaming { return .white }
        if canSend { return Color.black.opacity(0.72) }
        return Theme.Colors.contentTertiary
    }

    /// 从剪贴板导入图片附件。
    private func attachImageFromPasteboard() {
        insertImages(PasteboardImageExtractor.images(from: NSPasteboard.general))
    }

    /// 从文件选择器导入图片附件。
    private func chooseImageFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "选择图片"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let attachment = ImageAttachmentProcessor.makeAttachment(fromFileURL: url) {
                state.addImageAttachment(attachment)
            }
        }
    }

    /// 粘贴/拖入图片的统一落点（编码失败静默跳过）。
    private func insertImages(_ images: [NSImage]) {
        for image in images {
            _ = state.addImage(image)
        }
    }

    /// SwiftUI 层拖放（输入卡边缘区域）：按 NSImage / 文件 URL 两类加载。
    private func handleDropProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { item, _ in
                    guard let image = item as? NSImage else { return }
                    DispatchQueue.main.async { [state] in
                        _ = state.addImage(image)
                    }
                }
            } else if provider.canLoadObject(ofClass: NSURL.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSURL.self) { item, _ in
                    guard let url = item as? URL else { return }
                    DispatchQueue.main.async { [state] in
                        if let attachment = ImageAttachmentProcessor.makeAttachment(fromFileURL: url) {
                            state.addImageAttachment(attachment)
                        }
                    }
                }
            }
        }
        return handled
    }
}

// MARK: - 输入坞激活 rim（焦点性能隔离）

/// 输入坞激活 rim：自持窗口 key 态监听的小视图（参考 perf/ai-window-focus-lag 分支思路移植）。
/// 性能设计：焦点切换（聚焦/失焦）只重算本视图——原先 windowIsKey 挂在输入坞 @State，
/// 每次焦点翻转都会带着整个输入坞视图（含 representable diff）重算一遍；
/// 隔离后坞 body 与焦点事件彻底解耦。
/// 安静语义不变：坞体激活（悬停/输入/附件/生成中/抽屉在场）且窗口 key 才点亮 accent 环。
private struct DockFocusRim: View {
    let quiet: Bool
    @State private var windowIsKey = false

    private var active: Bool { windowIsKey && !quiet }

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.groupCard, style: .continuous)
            .strokeBorder(
                Theme.Colors.accent.opacity(active ? Theme.Colors.dockFocusRimOpacity : 0),
                lineWidth: 1
            )
            .allowsHitTesting(false)
            .animation(.easeOut(duration: Theme.Motion.contentFade), value: active)
            .onAppear { windowIsKey = NSApp.keyWindow is AIPanel }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard note.object is AIPanel else { return }
                DispatchQueue.main.async {
                    if !windowIsKey { windowIsKey = true }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                guard note.object is AIPanel else { return }
                DispatchQueue.main.async {
                    if windowIsKey { windowIsKey = false }
                }
            }
    }
}
