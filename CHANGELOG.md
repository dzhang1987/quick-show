# Changelog

本项目所有显著变更记录于此。格式参考 Keep a Changelog，版本号遵循语义化版本。

## [Unreleased]

### Changed

- 大文件组件化拆分（收尾批：DrawerPanel 业务域 + MarkdownBlocks 独立渲染器，混杂清单清零）：
  - `AIChatDrawerPanel.swift` 540 → 52（分派容器 + `AIChatDrawerMetrics` 节拍常量留守）：拆出 `ToolConfirmationDrawer`（147，工具权限确认抽屉）/ `UserQuestionDrawer`（169，ask_user 提问抽屉）/ `DrawerWidgets`（175，OptionCapsule / ActionButton 三档样式 / OptionFlowLayout 共享控件）；5 个跨文件引用类型 private→internal（唯一放宽项），分派容器对 AIChatInputDock 的契约零变化；抽屉统一设计维持现状——容器契约（动画/玻璃/ESC/状态重置）与控件层已统一，两抽屉装配差异属语义性，模板化按三次法则等第三种抽屉类型出现再做
  - `MarkdownBlocks.swift` 486 → 264：拆出 `MarkdownTableView`（87，表格渲染器）与 `MarkdownCodeBlock`（141，CodeBlockView + CodeBlockText）；实证修正评估结论——CodeBlockView 的跨文件「引用」实为注释提及，实际构造点仅块分派处，可见性维持 internal 不放宽
- 大文件组件化拆分（第四批：中等体量文件的职责混杂域拆分，8 条并行 lane，全部经 HEAD 逐字 diff 验证）：
  - `AIChatScrollNavigation.swift` 726 行拆三后删除：`AIChatKeyMonitor`（64，⌘N/⌘B/⌘F 监听）/ `ChatScrollCoordinator`（342，滚动状态机 + BridgeView + 虚拟化行容器）/ `ChatTickRail`（325，刻度轨布局 + 视图 + 预览尾）——键盘监听、滚动状态机、浏览刻度轨三域原本互不相干
  - `AIChatMessageRow.swift` 724 → 580：抽出 `ChatMessageActionRow`（103，操作行 + `ChatActionIconButton` 随迁）与 `MessageEditBubble`（115，就地编辑气泡 + 编辑会话草稿态随气泡生命周期创建/销毁，父级只持 `editing` 条件开关）；用户气泡渲染 / hover / 上下文菜单 / assistant 分支 / 流式外围小视图全部留守
  - `CalendarView.swift` 659 行拆三后删除：`CalendarGridViews`（388，网格面板 + 日格 + 日程行）/ `CalendarEventDetailView`（129）/ `CalendarEventEditView`（146，EventKit 编辑表单）——`CalendarPanelView` 对 PanelView 的契约零变化
  - `AIToolCardView.swift` 619 → 393：抽出 `AskUserToolViews`（195，ask_user 问答存档渲染域，三类型 private→internal）与 `ToolJSONText`（32，跨卡复用的 JSON 美化展示）
  - `WebTools.swift` 529 → 255：抽出 `WebToolsConfig`（141，Tavily 凭证存取/Keychain 迁移，AISettingsSections 引用兼容）/ `HTMLTextExtractor`（140，通用 HTML→文本引擎，8 个 private 实例方法函数化）；`BuiltInTools.swift` 614 → 591（`toolSuccessJSON`/`requiredString` 迁入共享 `ToolHelpers`，WebTools/MapTools 引用不变）——**HTML 实体表与 MarkdownParser 经实证语义不一致（nbsp 解码字符不同、实体覆盖 9 vs 48、amp 解码顺序刻意不同），保留独立实现不去重**
  - `AIChatMapCardView.swift` 478 → 235：抽出 `MapCardModels`（84，DTO + 派生 + `MapCardProvider` 注册）/ `InteractiveMapView`（162，MKMapView 桥）；fileprivate 常量随迁收紧为 private，零放宽
  - `AssistantMarkdownView.swift` 422 → 169：抽出 `MarkdownASTCache`（65，线程安全 AST 缓存）/ `MathLatexCollector`（82，latex 预热收集）/ `AsyncMathBlockView`（107，异步栅格化块）；`FootnoteEntry` 嵌套类型留守（MarkdownBlocks 依赖）
  - `AIChatMessageList.swift` 534 → 516：派生计算 8 项（tick/压缩边界/最后可重生成/最后可编辑/分组缓存）函数化迁入 `MessageListDerivations`（118）；**滚动协调器接线 / 快照恢复 / 手动虚拟化状态机一字未动**（ScrollController 抽取为已知高风险项，留待后续评估）
- 大文件组件化拆分（第三批收官：AIChatService 域拆分 + AIChatView 输入坞抽离 + AppState 门面化与 tick 事件总线）：
  - `AIChatService.swift` 1021 → 174 行：方法按域拆出 4 个 extension 文件（`+Config` 配置与 API Key/Keychain 迁移、`+Streaming` SSE 流式主链路（含 TaskCancellationBox/FirstTokenFlag 随迁）、`+Completion` 非流式补全与模型列表、`+RequestEncoding` 请求编码/工具声明/Responses 映射），存储属性与 init 留守主文件
  - `AIChatView.swift` 1307 → 675 行：浮岛输入坞抽离为 `AIChatInputDock`（691 行）——契约模式与 SessionMessageList/Sidebar 同构（@ObservedObject state + 8 个显式参数），输入区 / 附件菜单 / 模型与思考 chip / 剪贴板 / 发送键路 / 图片四件套 / drop 整体迁入，GlassSurface 修饰链逐字剪切（字节级比对保真），**零 private 放宽**（父级方法以闭包值在父作用域传出）；compactionStamp（消息列表唯一刷新触发器）/ 导出 toast / ESC 三链路总线 / keyMonitor / 侧栏留守；hover 等瞬态从 dirty 整个父体收敛为只 dirty 坞子树
  - `AppState.swift` 1220 → 320 行装配门面：`TickEngine` 单一 1s 主时钟 + `PassthroughSubject<AppTick>` 广播（show/dismiss 原位替换 startClock/stopClock，「面板隐藏即零消耗」由 Timer cancel 天然保持，runloop 归属原样）；6 个域 store（Settings / SystemStatus / Monitoring / Media / Pomodoro / Calendar）+ 转发扩展 + 动作扩展共 9 文件；19 处 `@ObservedObject` 视图零改动（计算属性转发构成 WritableKeyPath + objectWillChange 合并订阅）；tick 相位常量（%5==2 / %60==10 等）与 init 订阅顺序逐字搬运；statusRefreshQueue 收敛为 `BackgroundQueues`；明确不拆 glance 倒计时 / 上下文路由（装配契约本体）
  - 收官指标：千行文件 9 → 0 个，全工程最大文件 818 行（`MathLatexTranspiler`，单一职责纯函数模块）
- 压缩中圆环转不定态 spinner（AI 窗输入坞水位圆环，视觉/交互调整）：手动/自动压缩进行中，水位弧让位于固定 1/4 圈亮弧、线性匀速 1s/圈的不定态转圈（禁用点击但全亮——「进行中」是活跃信号，取代先前「0.5 降透明度弱化 + 禁用」的约定）；停止时禁用动画归零、不残留中间角度，下次恒从 12 点干净起步；调用侧 `showDockSecondaryTools` 新增压缩中破格常显（与水位 > 0.8 警戒破格同源同档）——进行中的操作不消失，压缩结束恢复随安静态隐去
- 输入坞尾部呼吸缝 10 → 20pt（AI 窗对话底部间距）：滚到底时末条消息底边与坞顶的可见间距加倍——10pt 用户体感「太挤」（真穿透设计下再往上滚消息即自然穿入玻璃坞下被 blur 采样，呼吸缝即视觉安全垫）；
- 手动压缩语义重设计（AI 窗上下文管理，行为变化）：手动压缩改为「历史全部压缩 + 豁免最后一轮」——全部未压缩消息合并进单份摘要（与 Claude Code `/compact` 等主流产品的手动语义对齐，经官方文档 / 源码实证调研），但最后一个 user 消息起的最后一轮（含内嵌工具调用与结果，轮边界与 `trimmedContextMessages` 分轮规则一致）保持原文，当前对话上下文高保真、后续回复不建立在二次摘要之上；删除原「水位未超标时只压最旧 6 条」的兜底分支（不匹配任何用户心智模型的孤立设计，用户实测吐槽触发）；仅剩最近一轮无可压时给出明确 toast 反馈「早期对话均已压缩（最近一轮保持原文）」而非静默；自动压缩语义不变（水位 ≥70% 触发、从最旧压到 ≤40%、≥6 条防碎片）；一次性输入成本 = 全部历史 token（与 /compact 同款），摘要输出恒 ≤2000 token
- 大文件组件化拆分（第二批，含唯一的运行时架构改造）：
  - `AIChatState.swift` 1767 → 543 行：方法按职责域拆出 6 个 extension 文件（`+Streaming` 流式回路 / 合帧 / 收尾、`+Compaction` 上下文压缩、`+RequestAssembly` 请求组装、`+Queue` 待注入队列、`+SessionEdits` 撤回 / 编辑 / 导出、`+Notifications` 标题摘要 / 系统通知），69 个方法全量核对一致；存储属性与 init / Combine 订阅留守主文件，跨文件引用的 `private` 成员放宽 internal
  - `AIChatMathViews.swift` 1151 行全量拆为 4 文件后删除：`MathLayoutCache` / `MathRasterizer` / `MathViews`（公式视图层）/ `MarkdownInlineNS`（NSAttributedString 行内渲染，两个私有扩展与使用者同文件保持 private）
  - `AIChatMarkdownView.swift` 1377 行拆为 4 文件后删除：`AssistantMarkdownView`（装配 + 缓存基建）/ `MarkdownBlocks`（各块渲染器）/ `MarkdownImageView` / `MarkdownInline`（SwiftUI 行内），3 处 private 放宽
  - `SystemStatusProvider.swift` 1551 行**真子 provider 架构拆**（本批唯一动运行时结构）：DTO 层 `SystemStatusModels` + 6 个子 provider（`NowPlayingProvider` adapter 进程 / 流 / 封面、`AudioProvider` CoreAudio HAL + C 监听、`CalendarProvider` EventKit、`SystemMetricsProvider` 差分采集、`DeviceProvider` 定位 / 电池 / WiFi / 蓝牙 / DND、`SystemActions` 无状态动作）+ 237 行薄聚合门面；对外契约逐项保真（`shared` / 全部方法签名 / `$nowPlayingInfo` publisher 经回调喂数 / `audioChangeSubject` 稳定转发 / CoreAudio C 指针生命周期模式原样 / adapter 进程终止三入口 / willTerminate 钩子），AppState 等约 40 处调用方零改动
- ask_user 互动纪律提示词重写（内置 system 引导，`AIChatState.builtinSystemGuidance`，堵「该问不问」放水口）：模型实际对话自证旧纪律失效——「不明确 / 歧义 / 有分支时先问」与「无需提问：指令已明确 / 细节琐碎」全为形容词，是否豁免由模型自行裁量，叠加用户自定义行动派人格 systemPrompt（拼接在同条 system 且靠后，recency 权重更高）后默认行为滑向直接执行，被用户指出后仅在对话文本里口头认错、下一轮照样放水（口头认错非修复）；重写为举证责任反转的硬判定结构：
  - **必问触发清单（或，任一命中必须先问）**：① 在两种以上都合理的做法之间犹豫过（哪怕一瞬间）——犹豫即分支；② 操作有副作用（写 / 删文件、执行命令、改配置等不可逆或影响系统）；③ 用户意图存在一种以上合理理解；④ 缺少完成任务的必要信息（路径、命名、目标值等）
  - **豁免条件（与，须同时满足才可直接执行）**：执行路径唯一 + 操作无副作用且可逆 + 用户指令已包含全部必要信息；外加兜底句「拿不准算不算满足时，一律视为不满足，回到先问」——专门堵「靠自觉」的裁量口子
  - 保留条款：「直接做」明示豁免、合并提问（≤5 题、每题 2-6 选项）不变；注入时机与拼接结构零改动（ask_user 启用时注入、内置在前 + 用户自定义在后合并单条 system），清单核对式结构在拼接行动派人格时依然压制宽豁免倾向
- 大文件组件化拆分（第一批低风险机械拆分，行为零变化）：7 个巨型文件按已有类型边界拆为 30 个文件，全部纯机械搬家经逐字节 diff 校验（逻辑 / 格式 / `@AppStorage` 键名 / 持久化解码契约零改动），唯一语义变化为 66 处顶层 `private → internal`（Swift 同文件可见性限制的必然放宽）：
  - `AIChatView.swift` 4096 → 1303 行：子视图族拆出 6 个文件——`AIChatLayoutSupport`（布局修饰符 / 偏好键 / 分组缓存）、`AIChatScrollNavigation`（滚动协调器 / 刻度轨 / 虚拟化行 / 键监听）、`AIChatMessageList`（会话消息列表保活单元）、`AIChatMessageRow`（消息行 / 流式 / 推理折叠 / 失败态一族）、`AIChatStatusViews`（队列胶囊 / 欢迎页 / 引导页）、`AIChatInputFields`（输入框 AppKit 三件套）；主 struct（窗口装饰 / 输入坞 / 会话管理）留守
  - `AIChatMathViews.swift` 1966 → 1151 行：拆出 `MathLatexTranspiler`（818 行零依赖 LaTeX 纯函数转译器）
  - `AIChatService.swift` 1674 → 1021 行：拆出 `AIChatWireModels`（26 个请求 / 响应 wire DTO，含访问控制连锁放宽 17 处）
  - `SettingsView.swift` 1604 → 189 行：6 个 tab 表单拆出 `SettingsGeneralForms` / `SettingsShortcutsForm` / `AIServiceSettingsForm` / `AISettingsSections`，外壳仅保留 tab 枚举 / 路由 / KeyBadge
  - `MarkdownParser.swift` 1551 → 317 行：AST 独立成 `MarkdownAST`，解析域拆出 `MarkdownParser+Inline` / `+List` / `+HTML` / `+Links` 四个扩展文件（20 个跨域调用函数放宽 internal）
  - `ExpandedMonitoringView.swift` 747 → 42 行：左右卡片拆出 `PerformanceCard` / `FocusWorkCard`，`NowPlayingCardRow` / `PomodoroPresetButton` 独立成文件，原文件仅剩布局壳
  - `ChatSessionStore.swift` 690 → 470 行：模型层（ChatMessage / ChatSession / 附件 / 工具记录 / 分组）拆出 `ChatModels`，`CodingKeys` 与兼容解码逐字节原样

## [1.13.0] - 2026-10-05

### Added

- preview_file 本地文件预览工具 + QuickLook 富卡片（AI 窗，文件预览专项，内置工具 20 → 21）：
  - **preview_file 工具**（`PreviewFileTool.swift`）：对话中预览本地文件——图片 / PDF / 文本 / 音视频 / Office 等任意系统 Quick Look 可预览格式（复用系统 Quick Look 引擎零解析代码，与地图卡自绘 MKMapView 平行的 RichCard 第二张卡片）；`~` 展开、存在性 / 非目录校验、50MB 上限（超限错误带人类可读大小）；kind 识别优先 `typeIdentifier` 回退扩展名小写；结果 `card` + `data` 双写信封（与 ShowMapTool 同模式，随 ToolCallRecord 持久化，历史会话可回放）
  - **QuickLook 富卡片**（`AIChatPreviewCardView.swift`）：视觉机械复刻 MapCard 范式（chatAssistantBubble 底 + cardStroke 0.5pt 描边 + groupCard 圆角，头部信息条 = 文件名 + kind → 预览区）；渲染主体 NSViewRepresentable 包装 QLPreviewView——`autostarts`、清自带背景融入卡片容器、Coordinator URL / 标题指纹 diff（父视图刷新 / 历史回放不重置用户缩放与滚动位置）、`dismantleNSView` 清预览项防 QuickLook 后台生成器持有已销毁视图、可失败构造兜底空白 NSView 绝不崩
  - **高度按类型自适应**：文档族（文本 / 表格 / PDF）520pt、媒体类（图片 / 音视频 / 未知）300pt——300pt 下长文档看不到完整语义单元（.md 表格约 5.5 行且末行截断、PDF 页底约 15% 被裁，截图实测定档）；判定优先 `UTType(kind).conforms(to: .text / .pdf)`（系统权威分类，覆盖 plain-text / source-code / markdown / json / csv 全文本族），kind 为扩展名回退值时用 22 项扩展名集合兜底；macOS 13 部署目标用单参 `UTType(_:)` 构造（两参 `allowUndeclared` 形式为 27+ API）
  - **降级安全**：渲染期 `FileManager` 探测文件存在（历史回放时文件可能已被清理）——已删 / 移走显示「文件不存在或已被移动」占位不崩；payload 解码失败返回可读错误卡；卡片未注册类型降级 JSON 展示（前后向兼容均安全）
- ask_user 提问工具 + 输入坞抽屉交互体系（AI 窗，交互抽屉专项，内置工具 19 → 20）：
  - **ask_user 工具**（`AskUserTool.swift`）：模型在需求不明确 / 有歧义 / 方案有分支时先提问再执行——一次 1-5 题、每题 2-6 个选项（单选 / 多选）、支持自由输入作答；入参校验（空 / 超 5 题 / 选项不足 / label 空 → 抛「参数不合规」）；结果按题目顺序还原（选中 option id → label + custom 文本），取消返回 `ok:false`；协议层新增 `isInteractive` 声明（默认 false），执行器对 true 豁免 30s 超时无限静候用户
  - **ChatInteractionCenter 交互中心**（`ChatInteractionCenter.swift`）：`ChatDrawerRequest`（权限确认 / 用户提问二选一挂起，同一时刻仅一个请求）发布-挂起-应答管道；UI 在场登记（`markUIActive`，AIChatView onAppear/onDisappear 维护）——UI 离场时挂起中的请求唤醒为兜底结果（确认 → 拒绝 / 提问 → 取消）防泄漏；危险工具「总是允许」会话记忆（工具名 + 参数原文为键，会话切换 `resetSessionMemory` 幂等清除，防误清当前会话的旧值判定）
  - **危险确认 NSAlert → 抽屉化**（`AIToolExecutor`）：原主线程 NSAlert（sheet 附着 / runModal 双路径）整体移除，改经交互中心发布抽屉请求挂起等待；三按钮 = 拒绝（次要）/ 执行（主要）/ 本会话总是允许（描边第三样式）；会话记忆命中直接放行不再打扰
  - **输入坞抽屉**（`AIChatDrawerPanel.swift` + `AIChatView` 连续玻璃体重构）：抽屉从输入卡上沿向上滑入（0.25s easeOut），与输入卡共享同一个 GlassSurface / accent rim / 双层阴影——衔接处零间隙、圆角恒为 Radius.groupCard、中间仅 0.5pt 极淡分隔线，「抽屉是输入卡长出的上半部分，不是独立弹窗」；窗口 frame 不动、纯视图内布局（规避整窗玻璃 + SwiftUI 测量链死锁），聊天流经 dockTotalHeight 实测自动让位；提问面板题目区限高 260pt 内部滚动（抽屉不把输入卡推出窗口）、权限面板长命令默认单行摘要点击展开（120 字阈值，短参数不制造折叠切换）、自由输入条 22-60pt 生长；选中态 / 自由输入存 @State，调用方 `.id(request.id)` 请求切换整树重建状态天然重置；抽屉收起后焦点主动归还主输入框（`aiChatRefocusInput` 通知，ChatInputTextView 观察）；`dockQuiet` 安静态判据补「无抽屉请求」
  - **ESC 三阶段语义**：⓪ 抽屉在场先取消抽屉（权限 = 拒绝 / 提问 = 取消，`AIPanel.onCancelDrawer` 前置接线）→ ① 流式生成中先中止 → ② 关窗还焦点
  - **ask_user 工具卡专属呈现**（`AIToolCardView`）：调参侧「问题摘要」块（题数 / 每题选项数与单多选）、结果侧「用户答案」块（每题选中项 + 补充输入，取消 / denied 单行「用户取消」）；结构化解析任一环节失败回退通用 JSON 块不丢原文
  - **内置 system 引导**（`AIChatState.buildRequestMessages`）：ask_user 启用时注入互动纪律（先问再做 / 一次合并提问不反复打扰 / 2-6 个具体选项 / 何时无需提问），与用户自定义 systemPrompt 拼接为单条 system 消息共存（引导管纪律、用户文案管个性，职责不重叠；Responses 协议单条即两协议通吃）；工具禁用时不注入（不引导调用不存在的工具）
  - 设置页工具分类新增「用户互动」组（`ToolCategory.interaction`，挂分组序最后）
- 上下文水位圆环 + 压缩结果反馈（AI 窗，输入坞态势感知专项）：
  - **水位圆环三合一**（`AIChatContextRingView` 新组件，取代旧「水位小字 + ⟲ 压缩钮」双控件组合）：一枚 14pt 描边空心环同时承担三职——环体即水位（12 点起步顺时针，亮弧 = 已用/窗口比例、暗弧 = 剩余轨道）；hover 弹详情卡（已用/窗口/百分比 + 压缩摘要信息——自绘浮层经 anchorPreference 上报锚点 + 数据快照，由调用侧 `contextRingDetailHost()` 在玻璃裁剪域之外挂载，规避 macOS 26+ `glassEffect` 把 overlay 内容裁剪进玻璃形状的陷阱）；点击即压缩（整环一枚按钮）。视觉纪律与图钉/剪贴板同一克制语言：静止纯灰无底、hover 圆底提亮、ratio > 0.8 亮弧转 `statusWarning` 破格常显（阈值与低频工具组显隐同源）、压缩中降透明度禁用不换旋转
  - **压缩结果反馈**（补齐原「失败静默」路径）：`CompactionOutcome` 契约（成功 = 会话 + 本次条数 + 时间戳 / 失败 = 一句中文原因简述），`currentSessionOutcome` 仅回传当前会话（自动压缩在流结束后异步触发、落定时用户可能已切换会话，防跨会话反馈错位）；两级呈现 = 视口即时 toast（1.6s 弹完即走，与导出 toast 同位同语言）+ 圆环详情卡持久行；`runCompaction` 各 guard 失败路径全部记入，唯「会话已删除」保持静默
  - **已压缩消息降档**：`CompactionInfo.summarizedIDs`（消息 id 集合）随压缩落盘，被压缩早期消息在会话流行级透明度弱化——压缩边界视觉语义从折叠卡延伸到消息流本体
  - **工具轮上限放宽 + 软着陆**：`maxToolRounds` 8 → 16；达到「上限 - 2」轮时回路先注入软限制收尾提示引导模型自行收敛，真正达上限才硬截断落说明文本
- 排队消息撤回 + 转向注入弱标记（AI 窗，消息交互三期，补齐「生成中排队后没机会反悔」的缺口）：
  - **键路**（`ChatInputNSTextView.performKeyEquivalent`）：`⌘⌫`（keyCode 51）撤回队首排队消息——三重守卫：输入框非空放行（保留系统「删到行首」编辑语义）、IME 组字期（hasMarkedText）放行不吞组字编辑、空队列由 state 层静默返回 false；空输入时一律消费 return true（此场景系统删行首本就是 no-op，无损失）；回调经 `ChatInputTextView` 新增 `onRecallFirst` 通道挂接（照 onEscape 模式，makeNSView / updateNSView 双挂）
  - **数据层**（`AIChatState` 对外契约）：新增 `recallFirstQueuedInput() -> Bool`（撤回当前会话队列最早一条，不区分 steering / follow，整体替换回填 inputText + imageAttachments——与 recallQueuedInput 同一模式，未发明合并逻辑；空队列返回 false）；`ChatMessage` 新增 `isSteered: Bool?` 字段（CodingKeys + `decodeIfPresent` 旧 JSON 兼容，沿用 images / toolCalls / reasoning 既有兼容模式）；打标在 `injectPendingInput` 单点收口（`item.kind == .steering` → true，follow-up 不标——追问是普通追加语义；两个注入点零改动）
  - **UI**（`AIChatView`）：队列胶囊右侧 `✕` 常驻占位、hover 显形（opacity 渐变 + allowsHitTesting(hovered)，布局零跳动，同输入坞低频工具组纪律；点击 ✕ 与点击胶囊本体完全同语义——撤回并回填输入框，嵌套命中无歧义）；胶囊 tooltip 固定文案后附完整文本（补偿单行截断）；转向注入的 user 消息在气泡外上方右对齐「↪ 已转向」纯图文弱标记（10pt semibold + contentTertiary、无底色——与 AbortedTag「状态记号在内容体外」同构但更轻；图标选非 fill 版 `arrowshape.turn.up.right`，与队列胶囊 fill 版形成「排队中强调 → 注入后弱化」的语义连续；follow-up 消息不标记）；胶囊保持全宽结构、注入时机与调度语义零改动
- Markdown 渲染全量升级（AI 窗，Markdown 渲染专项）：
  - **语法覆盖补全**：一至六级标题（ATX + Setext 下划线式）、删除线 `~~`、任务列表 `- [ ]` / `- [x]`、脚注（行内引用上标 + 文末注释区聚合渲染）、表格列对齐（`:` 分隔行解析）、多反引号行内代码（N 个开启 N 个闭合）、缩进式代码块（4 空格）、任意层级递归嵌套列表（有序保留起始序号）、自动链接（裸 URL / `www.` 补全 https / 尖括号形式）、链接 title、硬换行（行尾双空格 / 反斜杠）
  - **图片渲染**：`![]()` 与行内 `<img>`；网络 URL（异步加载 + NSCache 内存缓存）、本地路径（`~` 展开）、data URI（base64）三种来源；加载 / 失败 / 成功三态（等比缩放、圆角描边复用 insetCard 体系）；`[![alt](img)](link)` 链接内嵌图片渲染为可点击图片（手型光标 + hover 提亮 + 点击跳转外层链接）；含图片段落自动拆段混排（图片与文本交替成行，纯结构操作不阻塞流式渲染）
  - **代码块语法高亮**：vendored Highlightr（highlight.js v11.11.1，192 语言，源文件 blob SHA 锁定）以独立静态库 target `HighlightrKit` 集成（模块名与主工程 `Theme` 类命名隔离；pojoaque 默认主题硬依赖随包；highlight.min.js 与主题 CSS 扁平压入主 bundle）；`MarkdownHighlighter` 服务封装：深 / 浅双 Highlightr 实例（github-dark / atom-one-light，专用串行队列互不切换主题）、语言别名归一化（objective-c / py / sh / yml 等 17 条）、(语言, 代码, 外观) 三维 LRU 96 条、token 背景剥离 + bold trait → semibold 字重映射、后台线程高亮（fastRender 自研 HTML 扫描器，绝不走强制主线程的 WebKit 导入路径）；渲染侧首帧纯色立即上屏 + 后台高亮完成后替换，外观切换随 task id 自动重高亮
  - **内嵌 HTML**：行内标签子集映射样式（`<b>`/`<strong>`→粗体、`<i>`/`<em>`→斜体、`<u>`→下划线、`<s>`/`<del>`→删除线、`<mark>`→半透明高亮、`<sub>`/`<sup>`→上下标、`<br>`→硬换行、`<code>`/`<kbd>`/`<samp>`→行内代码、`<a href>`→链接、`<img src alt>`→图片，未知标签剥壳保留内容）；40+ 常见块级标签同名深度计数剥壳后递归块级解析（整行 `<hr>` → 水平分隔线，无闭合降级段落文本）；HTML 实体解码（named 40+ 常用表 + 十进制 `&#NNN;` + 十六进制 `&#xHHHH;`）
  - **引用式链接（CommonMark 全形态）**：`[text][label]` / collapsed `[text][]` / 速记 `[label]` 及图片的 `![alt][label]` / `![alt][]` / `![alt]` 对应形式；定义行 `[label]: destination "title"` 文档级预扫描收集（跳过 fenced code 区域、label 大小写不敏感 + 内部空白折叠归一、destination 容忍 `<>` 包裹与平衡括号、title 支持 `"` / `'` / `(...)` 三种）并从正文块流移除不渲染；未命中 label 按原文显示零误伤
  - **渲染双路径同步**：SwiftUI（`AttributedString`）与 AppKit 公式路径（`NSAttributedString` + NSTextAttachment）对全部新行内 token 语义镜像（删除线 / 下划线 / 高亮 / 上下标 / 脚注引用上标 / 硬换行 / 图片降级占位）；公式检测递归穿透新包装 token；`MathLayoutCache` 哈希覆盖全部 14 个行内 case 防段落高度缓存碰撞
  - **已知取舍**：公式段落（NSTextField 路径）中的行内图片降级为 `[图片: alt]` 链接文本（异步图片与公式 attachment 混排暂不支持）；块级 HTML 复杂表格按剥壳文本处理
- 消息滚动导航簇（AI 窗，滚动交互专项）：阅读历史（非贴底态）时内容区右下角浮动浮现三键小簇——`⤓` 跳回最新（点击回底并恢复贴底跟随）、`↑` / `↓` 在用户消息间快速跳转（目标消息对齐视口顶部逐轮回顾提问，到头 / 尾对应按钮禁用）；贴底自动隐藏（0.15s 淡入淡出、hover 提亮、不遮挡消息）
- 会话级阅读位置记忆：切走会话时保存真实视口锚点（行级几何感知，与滚动方式无关），切回原位续读；首次打开定位到最新消息；LRU 逐出后重挂载同样按锚点恢复

- 模型会话级绑定 + 思考强度档位 + 上下文水位与自动总结压缩（AI 窗，上下文管理专项）：
  - **模型适配层**（`AIModelAdapter.swift` 新文件）：`ThinkingLevel`（off/low/medium/high）与 `ContextWatermark` 统一抽象，模型差异全部收敛于此——UI / 会话层零感知：关闭→`enable_thinking:false`、低/中/高→`reasoning_effort`（GLM-5.3 特殊映射 low/high/max，该模型实测被 DashScope 限制必须思考、`canDisableThinking` 门控 UI 自动隐藏「关闭」档）；映射规则基于对阿里云百炼兼容端点的全模型实测探测（7 模型 × 7 字段变体矩阵，含 reasoning_tokens 验证；另经六家协议调研——智谱/DeepSeek/Qwen/OpenAI/OpenRouter/one-api 对比确认 `reasoning_effort:"none"` 仅是中转事实标准、DashScope 不认）
  - **会话级模型绑定**：`ChatSession` 新增 `modelId`（nil=全局默认，decodeIfPresent 旧 JSON 迁移兼容）；输入区模型胶囊切换只写当前会话并持久化；发送链路模型解析优先级：会话 model → 全局 selectedModel；设置页「当前模型」语义改为「默认模型（新会话）」
  - **思考强度**：`ChatSession.thinkingLevel` 同样会话级；输入区思考胶囊（默认=不传字段跟随模型自身默认 / 关闭 / 低 / 中 / 高，`ThinkingLevel.allCases` 驱动）；`ChatCompletionRequestBody`/`ResponsesRequestBody` 改自定义编码 + `DynamicCodingKey` 支持顶层注入扩展字段；`AIChatRequestOptions`（modelId + thinkingLevel）贯通流式与非流式路径（`complete` 亦支持 maxTokens）
  - **上下文水位**：流式请求注入 `stream_options:{include_usage:true}`，usage-only 分片从「被忽略」改为专门解析、Responses 协议 `usage` 归一为 prompt tokens，真实值回写会话 `contextTokens` 持久化；输入区右缘水位指示（SF Mono 等宽数字 `12.3k / 512k` k/M 自适应 + 2.5pt 光丝细条复用 `glanceProgressHeight` 令牌、条宽锚定数字宽、超 80% 仅细条转警示色、无数据完全隐藏）；`AIModel` 新增可选 `contextWindow`（设置页模型编辑可填，缺省 512k）
  - **截断策略升级**：固定 24000 字符截断改为 token 水位驱动（窗口 × 0.8 预算、2 字符≈1 token 保守换算、条数上限 40→200）；80% 硬截断保留为兜底
  - **自动总结压缩**：每轮流式回复结束后异步检查（不阻塞输入），水位 ≥ 70% 触发、一次压回 40% 安全世界（自动 ≥6 条才压防碎片化，手动 `compactNow()` 放宽到有未压缩消息即可）；被压缩早期对话交当前会话模型合并为单份累计摘要（旧摘要 + 本批一起合并防滚雪球、max_tokens 2000、能关思考则关）；`ChatSession` 新增 `contextSummary` + `summarizedMessageIDs`（`touch:false` 落盘不改排序语义）；被压缩消息保留在会话流、仅不再发给 API（`buildRequestMessages` 排除 + systemPrompt 后注入摘要 system 消息 + 兜底截断预算扣除摘要占用）；会话流压缩边界折叠卡（「⟲ 已压缩早期对话（N 条）」收起/展开/压缩中三态、行级插入按 beforeMessageID 定位、边界上移数据驱动自然移位）+ 输入区 ⟲ 手动压缩入口（水位旁、isCompacting 禁用弱化）；防并发（`isCompacting` @Published 内存标志 + 生成中会话不压缩防半截消息入摘要）、写回前二次校验防撤回/清空竞态、失败静默下轮重试
  - 附带修复：Responses 协议 `instructions` 原先只取第一条 system 消息，注入的摘要 system 消息被丢弃，改为合并全部 system 消息
- 多会话并行生成（AI 窗，2026-10 会话并行专项）：
  - **流式上下文按会话隔离**（`AIChatState.streamContexts` 字典）：每个会话独立的回路任务、中止标记与合帧缓冲（~50ms 合帧定时器 per-session 独立节拍），可各自发起/中止生成互不干扰；网络层去全局 `abort()`（`AIChatService` 不再持有全局任务句柄——新增流局部 `TaskCancellationBox` 取消盒，首 token 看门狗 120s 超时只取消「本流」生产任务，中止语义由消费侧 Task 取消经 `onTermination` 链路传导回网络任务）；切换会话不打断进行中生成；仅约束同一会话不可并发发送
  - **侧栏状态可视化**：生成中会话显示呼吸点（6pt accent 圆 1.2s 呼吸，点击即中止该会话，≥16pt 热区 + pointing hand + tooltip）；后台完成未查看的会话行尾显示静止未读点（切回该会话自动清除）；会话被删除时自动停回路并清理流式/未读标记（从会话 id 集合消失自动检出，防回路空转与 unread 永久残留）
  - **会话视图树 LRU 保活**（`AIChatView`）：每个常驻会话一份完整独立的 `SessionMessageList`（ScrollViewReader+ScrollView+LazyVStack）叠在 ZStack 中，切换只切 `opacity`/`allowsHitTesting`——零身份重建、零重新解析，滚动位置/贴底跟随/流式状态随视图树天然保留；LRU 上限 4（活跃 + 最近 3 个），超限驱逐尾部（视图卸载），重挂载时用 `ScrollSnapshot`（顶部可见消息 id + 贴底态）恢复阅读位置；窗口级滚轮监听经 `SessionScrollRelay` 路由到当前活跃会话视图的跟随状态
  - **Markdown AST 解析缓存**（`AssistantMarkdownView`）：以 content 为 key 缓存 `MarkdownParser.parse` 结果（FIFO 淘汰，64 条 / 60 万字符预算）——切会话不再重新解析历史消息的 Markdown（含 LaTeX），根治超长会话切换卡死；流式中间态（内容每 250ms 增长）完全旁路缓存，防中间态挤掉落定消息的有用缓存
  - 侧栏 hover 语言改为「仅文字提亮不铺背景」（与选中 accent 色块拉开层级，避免双选中误读）；全局单悬停令牌（父级 `hoveredSessionId` 覆盖式置位）防流式重排/行销毁时 `onHover(exit)` 丢失导致的双高亮残留
- 行内重命名（侧栏会话行）：⏎ 提交、ESC 取消（优先于中止流/关窗的 ESC 三阶段语义）；`renamingSessionId` 提升至 `AIChatState`（keyMonitor 闭包不再捕获 View struct 的 @State 链）；重命名 TextField 挂载即请求焦点；主输入框对已持焦点的其他文本控件（重命名 field editor）让位不抢占第一响应者（首帧与窗口 become key 双路径）
- AI 地图工具链（AI 窗，内置工具 14 → 19）：
  - **新工具 5 个**：`my_location`（独立 CLLocationManager 实例 + MainActor 创建/调用 + CheckedContinuation 桥接 delegate 回调；授权三态处理——notDetermined 等系统弹窗（12s 超时）、denied 给出系统设置指引；60s 内位置缓存优先免 GPS 冷启动；坐标后 best-effort CLGeocoder 反查拼地址（6s 超时降级 null）；NSLock 单次 resume 闸门防 double-resume）与 `geocode` / `search_places` / `plan_route` / `show_map`（`MapService` 异步封装 CLGeocoder / MKLocalSearch / MKDirections，completion 主线程回调经 continuation 桥接；限流/网络错误映射中文 ToolExecutionError）
  - **「高德优先 + MapKit 兜底」分派**（`AmapService` v3 Web 服务 + `MapDispatch`）：key 运行时探测（`~/Library/Application Support/QuickShow/amap_apikey` 纯文本单行、**每次调用重读**——换 key 即时生效零重启）；地理编码 / POI 搜索（`location`+`radius` 周边检索）/ 步行 / 驾车 / 公交路线优先高德，失败 / `status!="1"` / 空结果自动回退 MapKit 并打日志（os_log category `amap`），双失败错误信息合并（key 无效 10001 提示检查配置文件）；transit 公交仅高德提供（MapKit 无公交——origin 先 regeo 反查城市再查 transit/integrated，跨城 cityd 未处理）；结果 `source` 字段如实标注 amap/mapkit；polyline 严格「经度在前分号分隔」解析；高德 GCJ-02 与 Apple 中国区地图同坐标系直透传（海外数百米偏移已知不转换，注释归档）
- 对话内交互式地图卡片 + 统一富卡片机制（AI 窗）：
  - **RichCard 统一契约**（`RichCard.swift`）：工具结果 JSON 顶层携带 `card` 信封 `{"ok":true,"card":{"type":"map","data":{...}}}`，随 `ToolCallRecord.result` 持久化（历史会话天然回放）；`RichCardRegistry` type → 视图工厂，未注册类型 / 提取失败降级为既有 JSON 卡片（前后向兼容均安全）；新增一张卡片 = 一个 Codable payload + 一个 `RichCardProvider` 实现 + `registerBuiltIns()` 注册一行，渲染链零改动
  - **交互式地图卡片**（`AIChatMapCardView.swift`）：NSViewRepresentable 包装 MKMapView——可拖动 / 滚轮缩放、禁 pitch/rotate（小卡片平面阅读）、MKPointAnnotation 系统 callout、MKPolyline 路线折线（accent 强调色 3.5pt 圆头圆接）；视野 center+spanMeters 优先、缺省按标注+路线包围盒 40pt 边距自适应（单点退化街区级跨度）；Coordinator 持 payload Equatable 指纹，`updateNSView` 指纹未变完全不动地图（用户手动拖过的视角不被父视图刷新 / 历史回放重置）；`dismantleNSView` 摘 delegate 防悬垂回调；越界坐标 `CLLocationCoordinate2DIsValid` 过滤宁丢不崩；动作行「在地图中打开」（MKMapItem 标注全带）+「复制坐标」（六位小数）；视觉完全复用工具卡令牌（chatAssistantBubble / cardStroke / groupCard），零新增设计令牌
  - 挂载点：`assistantContent` 工具卡之后 `ForEach(toolCalls)` 独立成卡（`RichCardHostView`），`registerBuiltIns` 于 `applicationDidFinishLaunching` 早期调用
- 工具展示名体系：`AITool` 协议新增必需属性 `displayName`（中文展示名）与 `category`（`ToolCategory` 六类：剪贴板 / 系统状态 / 文件 / 环境变量 / 联网 / 地图，`label` 中文组名 switch 穷举编译器强制补全）——19 个工具逐字补齐中文名（网页搜索 / 抓取网页 / 我的位置 / 地址解析 / 地点搜索 / 路线规划 / 展示地图等），漏补即编译报错；注册表新增 `toolsGroupedByCategory()`（`Dictionary(grouping:)` + `allCases` 固定组序、组内注册序）；设置页「工具」小节分组重排（中文主标题 + 行内右侧蛇形名降为次要等宽小字 + 危险徽标 / run_shell 红字警告 / Toggle 持久化逻辑零改动、`ai.tools.enabled` 落盘仍蛇形名零迁移）；聊天工具卡头部主标题换中文展示名（查表 `tool(named:)?.displayName`，未知/旧会话降级蛇形名不重复展示），蛇形名降为状态徽标左侧 mono 10 小字（弱到强视觉递进：中文名 → 蛇形小字 → 状态胶囊 → 展开箭头）
- AI 聊天消息复制 / 撤回 / 编辑 / 导出（AI 窗，消息交互一期）：
  - **数据层**（`AIChatState` 新增 extension）：`isGenerating`（当前会话是否存在 sending/streaming 助手消息，UI 门控真源）；`withdrawLastRound()`（删除最后一条 user 消息及其后全部消息，文本 + 图片附件回填输入框；非生成中且存在末轮 user 消息才生效）；`editAndResendLast(text:images:)`（删旧轮 → 走 `send()` 完整链路重发，复用上下文组装与工具回路；重发轮 user 消息 id 更新、剪贴板附加清空保证重发内容严格等于传入值）；`exportConversationMarkdown()`（会话标题一级标题 + 🧑/🤖 分段 + 动态长度代码围栏防 Markdown 注入 + 导出时间落款；跳过 sending 占位与空正文）；`ChatSessionStore` 新增 `removeMessages(from:in:)` 批量删轮接口（单次 mutate + 单次落盘，删轮后 JSON 立即同步）
  - **UI 层**（`AIChatView`）：用户消息操作行恢复（复制按钮 + 1.2s 对勾反馈，与助手操作行同构右对齐）；最后一条 user 消息 hover 浮现「编辑并重发 / 撤回该轮」按钮（常驻占位 + opacity 显隐防宽度跳动；生成中或非最后一条不显示，`lastEditableUserMessageId` 父视图计算下传）；就地编辑器 `ChatInlineEditTextView`（NSViewRepresentable，复用 `ChatInputNSTextView` 的 IME 安全 ⏎/⇧⏎/ESC 与图片粘贴；内容高度实测回写 18–160pt 封顶滚动；附件条复用 `ImageAttachmentStrip` 可单张移除；「取消/重发」胶囊钮沿用失败卡「重试」语言）；行级右键 `contextMenu`「复制消息」（图片消息复制其文本，纯工具调用空内容助手消息不显示复制项；最后一轮 user 消息追加编辑/撤回入口）；用户消息与落定/中止助手消息启用 `textSelection` 选区复制（流式中不启用）；⊕ 菜单新增「导出对话」（空会话禁用），成功后 1.6s toast 胶囊（世代令牌防连点提前收起）
  - **已知取舍**：`textSelection` 按单个 Text 生效，跨块选择不支持；公式段落（`MathParagraphView` NSTextField 路径）不可选；启用选区后文本上按下拖动为选择而非滚动列表（对标主流聊天应用）
  - **GUI 全量实测**（AppleScript/System Events 自动化冒烟）：复制按钮 pbpaste 比对原文一致、编辑重发「1+1」→「2+2」轮替换且新回复正确、撤回后落盘消息清零 + 输入框回填、导出 Markdown 格式完整；真实会话数据 diff 备份逐字节一致零破坏
- 生成中转向 / 追问双队列（AI 窗，消息交互二期，语义对齐 PI Agent 的 steering / follow-up）：
  - **数据层**（`AIChatState`）：新增 `QueuedChatInput` 与 `pendingQueues: [UUID: [QueuedChatInput]]` 按会话 id 键控的 @Published 字典（steering 与 follow 合并存储、元素顺序即入队顺序，会话间严格隔离）；`send()` 在当前会话生成中不再拒绝而是重定向入队 steering；`dequeuePending()` 消费时 **steering 严格优先于 follow**；`injectPendingInput()` 注入为标准 user 消息 + assistant 占位（与真实发送同构，完整复用工具回路）；注入由各会话回路自身按 sessionId 消费（切走会话不影响注入续跑）；两个注入点对齐 PI 语义——① 工具批结束后（仅查 steering，打断续跑）② 回复 settle 前先 steering 后 follow；`finishStream` 终态清空该会话残留队列防陈旧条目泄漏；`abortAndRecallQueue()` 中止当前会话生成 + 该会话队列换行拼接回填输入框（图片附件按 id 去重合并）；非生成中 `⌥⏎` 退化为普通发送
  - **键路**（`AIChatView` / `ChatInputNSTextView`）：`doCommandBy` 覆盖 `insertNewline` 与 `insertNewlineIgnoringFieldEditor`——无修饰 ⏎ 生成中转 steering 入队；⌥⏎ 生成中入队 follow、空闲退化为 send；⇧ 优先于 ⌥（⇧⌥⏎ = 纯换行）；IME 组字期守卫（marked text 不触发发送逻辑）；发送钮 tooltip 标注「发送（⏎）· 追问（⌥⏎）」
  - **队列胶囊 UI**：输入框上方逐条胶囊标注「转向 / 追问」；`QueuedInputCapsule`（Button plain style、hover 提亮、tooltip「点击取回编辑」）——点击即从队列移除并回填输入框；队列消费 / 取回时输入框草稿同步清空
  - **ESC 接线**（`AIWindowManager`）：生成中 ESC 从 `abortStreaming()` 换为 `abortAndRecallQueue()`（中止 + 队列回填，防排队内容随中止丢失）；侧栏呼吸点 / ⌘K 清空路径**刻意保持不回填**（回填只应写入当前会话的输入框，中止后台会话时回填会串会话）；已知取舍：对当前会话经侧栏呼吸点中止时队列清空不回填（活跃会话的中止主入口是 ESC）
  - **GUI 全量实测**（computer-use 合成输入 + System Events AX 树断言 + 落盘 JSON 校验）：steering / follow 双队列注入链（6 消息序列与模型语义服从）、生成中 send 重定向、胶囊取回、ESC 中止 + 双队列回填、多轮工具调用与注入共存全部通过；真实会话数据 diff 备份逐字节一致零破坏
- 会话草稿持久化（AI 窗，输入框按会话保存未发送文字）：
  - **存储**：独立 `AIChats/drafts.json`（`[会话 id: 草稿文本]`，JSONEncoder 原子写、空值不下盘、与既有 `persist(_:)` 同款模式）；`ChatSessionStore.load()` 显式跳过该文件名（不依赖「解码失败静默跳过」的隐式行为），新增 `loadSessionDrafts()` / `persistSessionDrafts(_:)` 配套接口
  - **内存真源与归属**：`AIChatState.drafts` 字典（非 @Published，不参与视图刷新）+ `draftOwnerSessionId` 追踪当前输入归属；草稿切换收口在 `$currentSessionId` 订阅单点 `switchDraft(to:)`——selectSession / newSession / 删会话自动切 / ensureCurrentSession 兜底建会话全部路径无遗漏；旧会话文本落回字典、新会话草稿载入输入框；被删会话有守卫不复活孤儿草稿
  - **保存时机**：输入防抖 0.5s 落盘（Combine debounce，仅写盘不回写输入框、不触碰 firstResponder）；切换 / 新建会话前与 `NSApplication.willTerminate` 立即 flush；启动时 `init` 顶部回填当前会话草稿（先于订阅挂载 + `$inputText.dropFirst()` 防初始空值覆盖磁盘草稿）；切换后改写 inputText 自动重置防抖计时，pending 旧值被新值取代不串写
  - **清理**：发送（`send()`）与转向/追问入队（视图 `clearDraft()`）即删当前会话草稿并同步落盘；删除会话从 `$sessions` 消失集合同步清理孤儿键
  - **输入体验红线**：`ChatInputNSTextView` 组字（setMarkedText/unmarkText）与按键链路（doCommandBy / performKeyEquivalent / cancelOperation）零改动

### Changed

- 坞底真穿透（AI 窗，输入坞底部视觉路线反转）：滚动区底缘 26pt 渐隐带 mask 整段删除（fadeStart/fadeEnd 渐变遮罩与 location 换算一并退役）——对话内容滚到底时自然穿入玻璃坞下方，由坞体（26+ Liquid Glass / <26 ultraThinMaterial 降级材质）实时 blur 采样透出模糊内容（a10eed7 的「内容不再穿入坞下、blur-through 让位渐隐带」路线正式反转：用户实测确认穿透为想要的设计）；尾部留白公式「实测坞高 + 渐隐带 26 + 呼吸缝」→「实测坞高 + 呼吸缝」，呼吸缝 `chatDockTailBreathing` 4 → 10（净可见间距 = 呼吸缝 10 + 组间贡献 1 ≈ 11pt——滚到底时末条消息完整悬于坞顶上方，再上滚即穿入坞下）；`chatFadeMaskHeight` 令牌删除（grep 确认全项目无残留消费点）；`dockTotalHeight` 实测链（onAppear/onChange 直写 @State）零触碰，渐隐带时代的相关注释全部更新为穿透语义
- 刻度轨 Dock 放大效果（AI 窗，浏览导航刻度轨交互升级）：静止密排 + 鼠标接近余弦钟形放大推开（macOS Dock 同款手感）——**呼吸空间**：阅读列整体右缘内缩 `chatTickRailLane` 28pt 形成贯穿窗高的右缘导航通道（消息/坞/图钉/回底钮右基准线一致，窄窗右总边距 46pt 覆盖放大峰值宽度仍有余量）；**组件化**：刻度轨重构为独立 `ChatTickRail` 组件 + 纯值布局模型 `ChatTickRailLayout`（父视图删 `hoveredTickId` 等散状态，改数据映射 `tickItems` + `onSelect` 回调；光标状态私有于组件内，hover 不再冲刷整个消息列表）；**放大机制**：静止 pitch 4~10pt 按条数自适应密排（≤72 条恒不超窗、以上退回视口取样兜底），鼠标接近时余弦钟形权重（半径 `chatTickMagnifyRadius`=44、峰值 1.9×）驱动大小与明暗双维度同步流动（光标正下方最亮 0.60、远处暗淡 0.28，与大小共用同一条权重曲线），相邻 tick 槽心随累计生长自然推开、accent 当前消息 tick 钉死为稳定锚点（不随波位移）、命中槽 Voronoi 切分随放大同步长大无缝；跟踪走 `onContinuousHover` 挂包裹 tick 层的共同祖先（磁吸带 = 轨体 ±44pt + 左伸接近带）——从左邻带到轨上沿轨扫动连续不断流，进入动画只播一次、光标移动帧即时跟随（60fps）、离开 0.24s easeOut 收拢回弹；**手感修复**（录屏逐帧像素级测量定证）：初版跟踪层是 tick 层下方兄弟节点，光标压上 tick 列即命中解析到 tick、跟踪层立即收 exit →「左侧邻带有效、轨上零放大 + 预览胶囊消失 + 间歇闪断」——跟踪面上移共同祖先根治；初版钟形半径 52 相对 pitch 10 太宽（峰顶 ±2 枚 tick 均在 97%+ 峰值区，肉眼读作全轨均匀撑大）——半径收 44、相邻权重 1.0/0.86/0.55/0.26/0.06 梯度可辨；明暗与尺寸令牌全走 DesignTokens（新增 `chatTickRestOpacity`/`chatTickBrightOpacity`/`chatTickDimOpacity` + `chatTickRailLane`/`chatTickPitch`/`chatTickPitchMin`/`chatTickMagnifyMaxScale`/`chatTickMagnifyRadius`/`chatTickTrackSlop` + motion 三枚，删除 `chatTickHoverWidth`/`chatTickHitSlop`/`chatTickSpacing`）
- AI 窗视觉重设计（浏览导航刻度轨 + 行内代码提亮 + 坞体收紧）：**浏览导航换轨**——三键浮动导航簇（⤓/↑/↓）退役，换为右缘消息刻度轨（每条消息一枚 tick：默认暗灰细短、hover 提亮、当前视口消息 accent 加粗高亮；2pt 细线配 ±7pt 隐形热区保证命中；悬停浮现预览胶囊——深底浮层 `chatNavFloatFill` 承载消息内容摘录 + 小三角指向 tick，点击直达该消息）+ 右下角回底圆钮（unpinned 浏览态显示、点击回底并恢复跟随、贴底自动隐藏，替代 ⤓）；↑/↓ 用户消息跳转随导航簇退役（刻度轨点击直达覆盖同场景）；**行内代码 chip 提亮**——底色 `surfaceTrack` 0.06→`chatInlineCodeFill` 0.10（旧值在玻璃上近乎隐形）+ 字色 0.80 次级色→主文字色，SwiftUI（AttributedString）与 AppKit（NSTextField）双渲染路径同步；`<mark>` 高亮底色 0.18→0.15 降噪（双路径同步）；**代码块节奏**——padding 上下对称 14 / 左右 12（旧 10/12 上下失衡、重心悬空）+ header 间距令牌化（`chatCodeBlockHeaderGap`）；**坞体收紧**——输入行高 56→44、顶栏 28→36（图钉归入顶栏节奏）、列表底部留白 124→90（滚动内容不再穿入坞下——blur-through 让位于底缘 26pt 渐隐带 `chatFadeMaskHeight`，底部巨型空洞收敛）；全部尺寸/颜色走 DesignTokens 单源（刻度轨尺寸组 / 预览胶囊圆角 / 浮层底色新增令牌，本文件零硬编码）
- 消息操作行极简收紧（AI 窗，消息操作按钮专项）：操作行与消息内容垂直间距 10pt → 3pt（`Theme.Spacing.xs`）、按钮间水平间距 6pt → 4pt（`Theme.Spacing.sm`）、`ChatActionIconButton` 命中区 26×26 → 18×18（图标 13pt → 10pt、圆角 6 → 4）——消除「按钮独占一大行、与消息间距过大」的观感；用户消息「编辑并重发 / 撤回」从「常驻占位 + opacity 随整行 hover 浮现」改为与复制完全一致的行为（三钮常驻可见、静止 38% 灰、整行 hover 提亮 85%），静止态唯一可见的复制按钮被透明占位顶离气泡右缘的观感错位随之消除（生成中不显示编辑/撤回的门控语义不变——两者均为替换当前轮的破坏性操作，与在途流冲突）；复制图标 `doc.on.doc`（双页文档，描边繁复）全 app 6 处统一换 `square.on.square`（两枚叠角方块，极简复制隐喻）——消息操作行 / 行右键菜单 / 代码块复制 / 工具卡复制结果 / 地图卡复制坐标 / 监控面板复制内网 IP
- 阅读体验优化（AI 窗，内容列宽 + 代码块折行专项）：对话阅读列最大宽度 600 → 760（`Theme.Layout.chatContentMaxWidth` 单源 token，替换 `AIChatView` / `SessionMessageList` 内两份硬编码副本），消息列 / 输入坞 / 浮动导航簇三处收敛到统一 `.chatReadingColumn()` ViewModifier（限宽居中 + 水平边距分级：内容区 <720pt 沿用 `Spacing.section`=18 即默认窗铺满现状、≥720pt 升 28——宽窗留白随窗成比例生长保留玻璃呼吸边；宽度读取 background GeometryReader + preference，macOS 13 部署目标不可用 onGeometryChange(14+)）；宽窗下等宽 12.5pt 代码可用列 ~72 → ~93 列；代码块长行从软换行改为横向滚动（`ScrollView(.horizontal)` + `fixedSize(horizontal: true, vertical: false)`）——折行破坏缩进结构、复制粘贴混入换行符；嵌套滚动安全：内层 NSScrollView 不消费垂直滚轮 delta（沿 responder chain 冒泡回外层消息列表，滚轮鼠标体验不变），仅消费水平 delta（shift+滚轮 / 双指横滑）；高亮 task / 流式渐进渲染 / 一屏块数估算（保守偏大的 estimatedBlockHeight）不受影响
- 滚动跟随语义重构（AI 窗，用户滚动主权最高）：用户向上滚动立即脱离贴底（几何信号判定，滚动条拖拽 / 键盘 / 触控板通吃），此后切会话 / 新消息到达 / 流式输出一律不再自动滚动；流式仅在贴底时跟随（节流 0.12s）；贴底期间内容异步长高由几何信号持续纠偏至布局静止——根治「假底部」（此前 scrollTo 按过时内容高度落点，末条消息与输入栏间恒留 200~375px 空白且每次不同、切换后 1 秒内视图连跳 5 次）

### Fixed

- 输入坞实测总高恒为 0（preference 冒泡断链，AX 几何 + 运行时日志 + 常量发射三重定证）：`dockTotalHeight` 实测链路（inputArea 根部 background GeometryReader → preference 发射 → 链尾 `onPreferenceChange` 回写）中发射值到不了观察点——`geo onAppear` 实测尺寸 (546.5, 88) 正常、发射视图正常在渲染，但观察点恒收 `defaultValue: 0`（写死常量 12345 发射亦然；紧邻发射点的中继观察点同样收 0——二分钉死断点在发射本身，机制原因未深究、教训归档于代码注释）；回写 0 后回底钮 bottom padding 塌成 10pt 沉入输入坞浮岛下方被完全盖住（视觉即「回底钮消失」——AX 实测按钮在窗口内坐标正常但被坞遮挡）、渐隐带 fadeEnd / 列表尾部留白 / 刻度轨底部预算全部锚错位。修法：弃 preference 通道（该机制在本视图上下文实测不可用），改 GeometryReader 内容 `onAppear`/`onChange(of: geo.size.height)` 直写 `@State`（`noteDockTotalHeight` 保留 <0.5pt 去抖；首帧即拿到真实高度 88 实测校准、坞体生长时跟随更新）；`ChatDockTotalHeightKey` 定义删除、`chatDockHeightFallback`=88 保留首帧兜底
- 上滚跳消息·终局根治（**手动虚拟化替换 LazyVStack**，双证据定证后的结构性修复）：子视图级埋点日志 + 录屏逐帧分析联合定证——大塌缩瞬间（doc -14306、视口瞬移 14053）**零子视图回退事件**（无 math-para 占位、无 img-seed MISS）、跳变前后画面无占位闪现（子视图缓存全命中）——排除子视图高度回退，钉死真根因 = **LazyVStack 在 macOS 13 上回收远行的高度估算归零/失准**：行实例化-回收的「估算↔真实」差（万级 pt）在停顿后的异步布局回合一次性结算成视口瞬移（视频实证：单帧 teleport、手势停止 0.25s 后发生、方向向上）。修法 = **VStack 全行常驻 + 行内「实渲染 ↔ 等高占位」切换**（新组件 `ChatVirtualRow`）：
  - 占位高度 = 行级实测高度缓存（`rowHeights`，由既有行级几何信号 `MessageRowFramePreference` 在 `updateRowFrames` 回写，变化 >0.5pt 去抖）——切换零位移 → **document 高度恒稳**
  - 虚拟化窗口 = 视口 ±2 屏（滚动惯性预热带，`virtualWindowIds` 每帧维护）：窗口内实渲染、窗口外等高占位——保留内存回收语义（远行轻量占位）
  - 首见（无缓存）恒实渲染直至测得高度（秒开诉求已取消，首帧全量渲染为既定决策）；切换禁动画（`.transaction` 置 nil，防闪烁与 CA 事务竞态）；消息入场 transition 保留在实渲染内容内部；行 id 恒定（message.id）
  - 已知取舍：超大列表（数百条消息）冷启动全渲染可能较慢（当前会话规模 19 条实测无感）；后续可加粗估占位兜底
- 上滚「跳帧 = 跳过内容」（连环塌缩雪崩，os_log 插桩 + 渲染层取证定证）：贴底上滚离开底部后，LazyVStack 把视口下方的超长消息行**整行回收再实现** → 行内 15+ 个子视图以「初始态小高度」**同步重建** → doc 高度逐子视图骤塌（实测 9ms 内 15+ 步、每步 -200~-700pt，累计塌 27%）→ LazyVStack 的「最大偏移收缩 + 底部对齐」逐批把视口向上拖 = 跳过内容（此时 pin 已正确保持解除、零程序化滚动——塌缩视觉破坏滚动层拦不住）。两大塌缩源修复（范式 = AsyncMathBlockView 的高度种子同款，@State 外置第 N 弹）：
  - **图片回落 120 占位（主力，自动触发）**：`MarkdownImageView` 的 `@State state=.loading` 初始态 + 固定 120 占位，真实图 200~700pt → 每图塌 80~600。修法三层：init 时查 `MarkdownImageCache` 图片缓存命中直接以 `success` 态种子化（重建零回落）；新增**渲染高度记忆**（url → 上次渲染高度字典，成功态 background GeometryRenderer 回写）——图片本体被 NSCache 逐出后重建的 loading 态用记忆高度作 `minHeight`（不再回落 120，首见才用 120）；`load()` 顺序修正（缓存命中路径不置 loading，防 init 种子的 success 被拉回占位态闪变）
  - **工具行展开态重置（条件触发）**：`ToolCallRow` 的 `@State expanded` 反实例化重建回默认折叠——用户展开过的行回落 300~500pt/行。修法：`ToolCallExpansionMemory`（record.id 键控外置字典）恢复上次展开态（首见仍按「失败/拒绝默认展开」策略）；点击与状态自动展开统一走 `setExpanded` 写入口同步记忆
  - 观察项（未修）：`ReasoningDisclosureView` 思考区展开回退 ≤160pt、`AsyncMathBlockView` 缓存未命中回落 ≤96——贡献量小，待主力修复实测后评估
- 滚动位置记忆失效（切换会话直接跳到底部；重启后同样丢失）——三个结构性缺陷一次修完（位置记忆子系统闭环）：
  - **快照读 pin 镜像**：`saveSnapshot`（切走/卸载时保存）仍读视图 `@State isPinned` 镜像——@State 写入对读取延迟一帧可见（pin 真源迁移时遗漏此路径），用户解除跟随后切走，快照存到旧值 `isPinned=true` → 切回/重挂载 `restoreScroll` 走贴底分支 = 跳底。修法：快照改读 `ChatScrollCoordinator.isPinnedState(of:)`（class 真源，零延迟）
  - **快照纯内存态**：`scrollSnapshots` 是 @State 字典，重启即丢——冷启动后所有会话「首次挂载」一律贴底。修法：**磁盘持久层** `AIChats/scroll_positions.json`（`[会话id: {topMessageID, isPinned}]`，与 drafts 同款模式：独立文件、原子写、`load()` 显式跳过）；`AIChatView.init` 冷启动装载，`saveSnapshot`（切走/卸载等低频时机）落盘，会话删除同步清理——重启后切回会话恢复到上次阅读位置（无快照才贴底）
  - **README 语义同步**：「会话秒开与阅读位置记忆」→「阅读位置记忆」（秒开诉求已按用户决策取消，见渲染条目；位置记忆升级为跨重启）
- 滚动跟随架构重构（AI 窗，根治性——历次补丁反复复发的终局修法）：旧架构用 **5 个状态 × 3 个时间窗（0.5s 用户滚动窗 / 0.4s 内容增长窗 / 0.12s 流式节流）× 3 类事件源（NSEvent 滚轮监听 / SwiftUI preference 几何哨兵 / 消息 onChange）** 互相调解「哨兵消失是谁干的」——时间窗对异步渲染的 settling 没有时间上界语义（公式回填 / 渐进批次可达秒级），猜测必错，每次补丁都在加新调解窗口、问题必然重现。新架构回到第一性原理（偏移变化只有两个来源：用户输入与非用户变化），**由「变化来源」直接判定**，全部时间窗与三方调解删除：
  - **`ChatScrollCoordinator`（新，替代 `SessionScrollRelay`）**：经 clipView `boundsDidChange` 通知感知滚动（滚轮 / 触控板惯性 / 滚动条拖拽 / 键盘全覆盖——它们都改 clipView bounds origin，旧的 NSEvent 滚轮监听无法覆盖滚动条与键盘已是被旧注释自认的缺陷）；origin 变化 = 用户滚动（视口在底部容差区内 → 恢复跟随 / 离开 → 解除，`isPinned` 单一写路径），origin 不变 = 纯视口尺寸变化（窗口 resize，pinned 时重新贴底，绝不当用户滚动）；经 documentView `frameDidChange` 通知感知内容高度变化——pinned 时程序化贴底（**流式跟随的唯一执行点**，与布局同步、零追赶误差，取代旧的 0.12s 节流追赶路径），unpinned 时绝不干预（用户阅读位置主权最高）
  - **程序化滚动仲裁**：我们发起的所有滚动（跳底 / restore / 导航跳转）开遮蔽窗（同步滚动短窗、动画滚动按时长 + 兜底），窗口内的 bounds 变化不计为用户输入——程序化滚动与用户滚动不再互相误伤（旧架构零此概念，`proxy.scrollTo` 与几何哨兵互相打架）
  - **内容塌缩防误判**：非 pinned 时内容塌缩（公式异步重渲染高度归零等）由 coordinator 在遮蔽窗内程序化执行 clamp 等价——否则 AppKit 自然 clamp 的 bounds 变化会被判为用户滚动、错误翻转 pin 态（**实测视频坐实的「无生成任务时突然瞬移到底 + 公式回弹后永久卡中部」双症状根因**：塌缩中几何瞬态误恢复 pin → 纠偏拉底；回弹 +600px 时 0.4s 增长窗已过期 → 误脱锚 → 跟随永久关闭）
  - **消费式跳底信号**：`scrollJumpRequests` 是瞬时发布-订阅事件，视图不在场（**空会话 `EmptyView` 首条发送时无任何 onChange 挂载点**、发送白屏重建窗口）即永久丢失——「对话首次用户输入输出不跟随」的根因族；改为挂载时补消费（存在新于挂载时刻的未消费信号即补跳底，旧信号走快照恢复不受影响）
  - **跟随路径收敛**：`onChange(of: messages.count)` / `onChange(of: messages.last)` / `handleGeometry` 几何纠偏 / `BottomAnchorYKey` preference 通道 / `AIChatScrollWheelMonitor` 全部移除，跟随统一由 frame 通知路径承担；流式结束收尾动画贴底保留（无插入动画并发，安全）
  - 删除约 60 行状态调解代码，`SessionMessageList` 状态从 8 个收敛至 4 个（`isPinned` / `topVisibleMessageID` / `isInitialHistoryLoad` / 消费式跳底标记）
- 流式输出期间向上滚不动（转向注入续写中尤为明显——被逐帧贴底循环持续拽回）：初版遮蔽机制对**非动画贴底**也用 0.05s 时间窗，而流式跟随每 ~50ms 合帧节拍执行一次贴底 → 时间窗背靠背覆盖时间线 ~100% → 用户滚轮的 bounds 变化几乎必然落在窗内被吞 → `isPinned` 永远无法解除 → 下一帧贴底又把视口拽回，表现为「滚不上去」。修法（三层）：
  - **同步作用域遮蔽**（新 `programmaticDepths`）：`clipView.scroll(to:)` 的 bounds 通知在调用栈内**同步**发出，进出作用域配对即可精确遮蔽——非动画贴底（流式高频路径）改走此机制，**零时间窗**；时间窗仅保留给动画滚动（CA 逐帧异步、作用域罩不住）与 proxy 回退路径（低频，不构成输入饥饿）
  - **逆程序化方向兜底**：任一遮蔽生效中，若 bounds origin 向远离底部方向移动且会话 pinned（用户逆着贴底跟随向上滚），立即解除全部遮蔽并按用户输入处理——即使落在动画时间窗内，用户向上滚也**立即**生效
  - **塌缩 clamp 方向歧义排除**：逆程序化兜底限定 `isPinned=true` 才触发——unpinned 时的 origin 上移可能是内容塌缩后的被动 clamp（flipped 下 offset 被压小、方向与用户上滚相同），触发兜底会把 clamp 误判为用户输入、在底部误恢复 pin（「塌缩瞬移」根因的复活路径）；塌缩路径同时保留 0.15s 时间窗遮蔽 AppKit 布局 pass 的后续自然 clamp（不在我们调用栈内、同步作用域罩不住）
- 上滚间歇被拽回 + 瞬移跳底（转向会话空闲态滚动，滚动链路 os_log 插桩逐条定证）：诊断日志实证两个叠加缺陷，均与前两轮的遮蔽机制无关——
  - **pin 真源读写可见性延迟（架构级）**：pin 态原放 SwiftUI `@State`、经通知回调闭包读写——日志显示同一毫秒内 `pin-write 0`（用户解除跟随）后立即读取仍得到旧值 `1` → 判定路径读旧值 → 用户已解除跟随仍被逐帧 `scrollToBottom` 拽回，表现为「走走停停被间歇拉回」。@State 写入对非渲染上下文的读取闭包**至少延迟一帧可见**，任何「写入后同帧需读回」的判定路径都不能用 @State 做真源。修法：pin 真源迁入 `ChatScrollCoordinator`（class 字典 `pinStates`，读写即时零延迟，唯一写入口 `setPinned`）；视图层 `isPinned` @State 降级为纯 UI 镜像（导航簇显隐），由 `onPinnedChange` 回调同步，延迟一帧无妨（不在判定路径上）
  - **塌缩瞬移的 pin 误恢复**：用户上滚离开底部后 doc 高度大规模塌缩（实测 -14166，LazyVStack 离底后尾部内容虚拟化），SwiftUI 把 origin 骤调到新 maxOffset（实测 17196→3281 瞬移 = 录屏「跳回底部」）→ 该 origin 骤变被判定为「用户回底」→ pin 误恢复 → 塌缩回填期间逐帧贴底。修法（方向守卫）：用户回底必然是向下滚（origin 向底部移动），「向上滚却判定在底部」（`movedUp && atBottom`）的矛盾组合只来自塌缩被动调整——一律吞掉不写 pin；内容不满一屏区的向上橡皮筋微滚同被吞、写同值无语义损失
  - 已知残留（另案）：塌缩瞬移本身（视口跳到新 maxOffset 处的**内容跳变**）是 LazyVStack 虚拟化/渐进渲染的高度震荡问题，本轮修复后 pin 不误恢复、瞬移后滚动立即自由，但视觉跳变仍在——根治需渲染层高度稳定性改造
- 上滚「一次跳过数条消息」（单帧瞬移 ~1500px 回坠到精确底部，滚动时序与渲染层取证定证）：用户上滚 → 视口下方长消息移出 LazyVStack 实例化窗口被**反实例化** → `AssistantMarkdownView` 的渐进渲染游标 `@State visibleBlockCount` 被静默丢弃 → 已展开到全量的长消息（实测 ~180 块 ≈ 14166px）重实例化时回到首批 8~16 块（未渲染块零高度、无占位）→ document 高度骤减 78% → 视口被 clamp 到新最大偏移 = 跳过数条消息；随后 `.task` 16ms/批逐个回填（日志 +1255）。中途一版按「渲染进度外置缓存恢复」修复，实测「滚完一遍后现象好很多」验证机制正确，但**首次**上滚遇未渲染全量的消息仍跳（渐进逐批高度增长 → LazyVStack 视口上方偏移补偿不可靠）。终局修法（用户决策：**取消秒开诉求、滚动稳定优先**）：落定态消息（`useCache=true`）**一律全量渲染**（`effectiveVisibleCount` 直接返回 total）——高度一步到位、无逐批震荡源头；流式中间态（`useCache=false`）保持游标渐进（流式增量渲染性能不变，且流式期间视口贴底跟随、高度增长不破坏阅读位置）；LazyVStack 惰性实例化保证挂载/切会话只构建视口附近几条消息，全量成本仅作用于视口附近长消息（每条 ~50-150ms 一次性布局，用户接受此代价）；渲染进度缓存方案随之删除（失去存在意义）
- 发送消息后整屏白屏 ~TTFT（用户气泡 + 历史全部消失、token 计数与侧栏运行点正常，首 token 到达才恢复；恢复瞬间落旧滚动位置再二次跳底，地图卡瓦片重载）：发送同一帧并发多路动画——LazyVStack 行入场 transition + `.animation(value: messages.count)` + 跳底的 `NSAnimationContext` AppKit animator 滚动动画 + 发送清空附件触发的生长区收起动画——而白屏防线 `.transaction { $0.animation = nil }` 只加在 `.done/.aborted` 落定替换路径、**发送插入路径完全无防护**，CA 事务竞态把内容层卡在近零透明度（与 CHANGELOG 反复记载的白屏族同源）。修法：发送跳底改**非动画**（跳底发生在内容插入前瞬间、视觉无感；消灭最大动画并发源）+ 消费式跳底信号保证重建窗口不丢（见上条）；数据扇出链经取证排除空数组帧与视图身份重建路径（CombineLatest glitch / `session(id:)` miss / LRU 淘汰均无确定性路径），未加防御性守卫（为不存在的路径加守卫会误伤合法空会话切换）
- 浅色模式下代码块语法高亮完全单色无着色：初版浅色主题选了 github light，其实测（CLI 独立驱动 Highlightr 对比多主题的 token 颜色产出）发现 github light 的 CSS 写法（多选择器共享声明）在 Highlightr 的主题解析管线下几乎不被识别——全串仅 3 色、绝大多数 run 是基色近黑；换用实测 6 色均衡的 atom-one-light（紫关键字 / 绿字符串 / 红数字 / 灰注释）后浅色高亮正常
- `[![alt](img)](link)` 链接内嵌图片解析拆坏（`!` 与 `]` 字面残留、alt 与外层 URL 变成两个断链）：行内链接 / 图片的闭合 `]` 查找未处理内层 `![...]` / `[...]` 嵌套；修法 = bracket 配对计数（遇 `[` 深度 +1、`]` 深度归零才闭合，跳过反斜杠转义）+ `(...)` 目标同样平衡括号扫描
- 引用式链接 `[text][label]` 与定义行 `[label]: url` 完全不支持（引用处方括号原样显示、定义行被当正文渲染且 URL 部分被裸链接逻辑上色）：见 Added 引用式链接条目
- 代码块复制按钮 hover 显隐导致块高度跳变（hover 时 header 行从 ~14pt 撑到 ~17pt，滚动时整个对话区域反复重排）：按钮由条件渲染改为常驻布局 + opacity 切换（header 行高度恒定）
- 代码块滚动时相邻双复制按钮残留：中版滚动期吞 hover 事件的 guard 实为吞 enter 同时也吞 exit（`hovering || !isScrollActive` 在 exit 分支等价于 `!isScrollActive`），状态与 AppKit tracking 失同步即残留双亮；该补丁连同 `ChatScrollClock` 整体移除，改由 CodeBlockText 状态半径重构根治（见 Performance）；按钮显隐改由 hovered 单独驱动，copied 仅改按钮内容（对勾 / 已复制）——复制后鼠标离开反馈随 hover 消失，悬空按钮语义上不可能
- 数学公式会话点击后 ≥1.4 秒纯白屏（其他会话均下一帧出内容）：块级公式早已异步化但**行内公式从未接入异步路径**——首帧可见区数百个行内公式在主线程同步光栅化（`InlineMathAttachment.make → rasterize` 同步路径），同时选中会话触发的后台预热队列持 `renderLock` 逐个渲染数百公式，主线程同步路径在 NSLock 不公平调度下排成 lock convoy 被钉死，第一个 CA 事务不提交、连纯文本与占位符都无法上屏；修法 = 行内公式接入与块级同款两段式（缓存命中同步装配 / 未命中等宽 LaTeX 占位 + `rasterizeAsync` 批量后台光栅化、世代令牌 + 段级计数器防竞态、回填无动画直换）+ 预热统一 `inFlight` 去重与逐公式 1.5ms 让路 + 失败负缓存防请求风暴
- 切回会话跳到最底部、阅读位置丢失（滚轮 / 滚动条 / 触控板全部复现）：三重叠加——① macOS 13 LazyVStack 的 `onAppear`/`onDisappear` 不可靠，底部哨兵 `onDisappear` 从未触发导致 `isPinned` 恒为 true（唯一脱锚感知源死亡，浮动导航簇也因此从未出现）；② 行级可见性集合只增不减，快照锚点退化为「史上最早可见消息」（LRU 重挂载后表现为置顶）；③ 常驻视图（ZStack opacity 切换）的 NSScrollView 偏移本天然保留，而激活时无条件的 `restoreScroll` 是唯一破坏源、且因 ① 恒走贴底分支。修法 = 切除激活路径滚动调用 + `PreferenceKey` 几何感知重建（底部锚点 + 行级帧双通道，`atBottom`/`isPinned`/视口锚点全部由连续几何信号驱动）
- 底部留白过大（~2 倍输入坞高度的纯背景空隙）：静态尾部 124pt 坞区留白被 LazyVStack 36pt 组间距对 4 个尾部子视图叠加（实际 270pt）+ scrollTo 过时落点短缺（200~370px 逐次漂移）；修法 = 尾部收敛为单个 `VStack(spacing: 0)` 子视图（视觉间距钉回 ~13pt）+ 几何信号驱动的持续贴底纠偏
- 超长消息渲染停在第 48 块（157 块消息中下部永久空白）：渐进渲染哨兵的结构身份在批次扩展时不变，`onAppear` 只触发一次、`visibleBlockCount` 停在 24→48；修法 = 哨兵 `.id(visibleCount)` 强制逐批重建 + 容器 `.task(id:)` 逐批推进兜底
- 冷启动白屏复发（内容闪现后转为近零透明度持续、多次点击仍白屏）：首帧骨架两段式切换把真实内容推迟到第二个独立 CA 事务、重新触发历史冷启动白屏的窗口淡入动画竞态，且 83+ 个块级公式 opacity 回填动画放大竞态；修法 = 移除骨架两段式（渐进首批 + 公式异步已保证首帧轻量）、去除公式占位→位图过渡动画、`isInitialHistoryLoad` 解除改 `withAnimation(nil)`、`sizeThatFits` 缓存加 `hasContent` 守卫防空测量写死
- 空白圆角卡片 / 230pt 空白块（「自适应大小」小节下方）：纯 LaTeX / 畸形公式占位无高度封顶，叠加未构建批次区域；修法 = 空 LaTeX 零尺寸不渲染 + 占位 `maxHeight: 96` 封顶 `clipped`
- 会话切换明显卡顿：LRU 常驻上限 4 对 ~8 会话必然每次切换逐出整树重建（超长会话重建含大量 NSTextField 段落 + 测量）+ 预热 latex 收集在主线程同步执行；修法 = 上限提至 12（≤12 会话零重建纯 opacity 切换）+ 收集移后台（解析缓存抽线程安全 `MarkdownASTCache`）+ 会话签名去重
- AirPods 等蓝牙耳机接入后面板调音量打破系统左右平衡 / 两耳音量不一致 / 音量跳变且「只响应一次就升不上去」：根因是 CoreAudio 读写路径只落单声道——`setVolume`/`toggleMute` 只写 Main element（失败再降级 element 1），而蓝牙耳机在 HAL 层按**左右声道独立 element** 暴露音量，单 element 写入只改到一只耳机；读路径同样只读单声道，读回的可能是未被写入的声道，`adjustVolume` 基于错值迭代即表现为跳变与失效。修法：`StreamConfiguration` 枚举输出声道（Main(0) + 声道 1...N），音量/静音读写统一覆盖全部声道（任一声道失败不影响其余），读取取各声道最大值、静音任一声道为真即视为静音；附带耳机识别改按 `TransportType`（Bluetooth / BluetoothLE）判定，不再只靠设备名匹配
- 音量状态实时同步：`SystemStatusProvider` 新增 CoreAudio 属性监听（`AudioObjectAddPropertyListener` + `audioChangeSubject`）——系统对象监听默认输出设备切换（AirPods 接入/拔出时音量监听自动迁移到新设备），设备对象监听音量/静音变化；键盘 / 控制中心等外部调音量时面板 ~150ms 内实时刷新（`AppState` 订阅：主线程节流 + 后台队列读值回主线程赋值），不再依赖面板唤起时的周期刷新；自身写音量触发的事件回流读值，天然修正乐观 UI 与实际值的偏差
- 富卡片静默不渲染（地图工具执行成功但对话中零占位零错误缺失卡片）：两个 SwiftUI 陷阱叠加——① `onChange` 的 action 闭包捕获**旧视图实例**，工具结果落定时读 `self.resultJSON` 恒为旧值空串，解析永远失败静默返回（工具执行中视图即以空 result 插入是常态时序）；② `Group` + 空条件分支会吞掉 `onAppear`（Group 修饰符被转发到不存在的内容上，历史会话回放兜底路径同样失效）。修法：`onChange` 改用传入的 `newValue` 参数解析 + 实体容器 ZStack 替换 Group。定位过程三段式（防再踩的排障范式）：线上会话存档 JSON 证明 `card` 信封数据正常 → 隔离复现实验抓到 `onChange FIRED` 但 `resolveIfNeeded` 被 guard 拦截（action 内读到旧值 count=0）→ 修复对照实验验证渲染成功
- MKMapView 标注视图未注册崩溃（打开 AI 窗即崩，EXC_BREAKPOINT / SIGTRAP，`_crashOnException` 布局期）：macOS 上 `dequeueReusableAnnotationView(withIdentifier:for:)` 必须先 `mapView.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier:)`，否则标注首次显示（区域变化触发 `viewFor` 回调）抛 `NSInvalidArgumentException` 直接崩溃；此雷在富卡片渲染修复前从未执行过该代码路径故未暴露。修法：`makeNSView` 注册标注视图类 + identifier 提为 Coordinator 共用常量。定位：崩溃报告堆栈全 AppKit 无异常文本（`asi` 为空、Release 二进制 strip 符号）→ 将地图卡视图 + 主题令牌编译成独立 harness 喂真实 payload 稳定复现 SIGTRAP → lldb `-E objc` 异常断点拿到精确 reason
- AI 窗冷启动偶现顶栏（图钉 + 拖动热区）整体坠至窗口垂直中央、拖顶部拖不动反而拖中部能动：根因是空会话布局塌缩——`SessionMessageList` 在 `messages.isEmpty` 时渲染 `EmptyView`（空态欢迎页/引导页由外层 overlay 承担不撑布局），冷启动恢复出的常驻会话集合全空时 `messageList` ZStack 高度塌缩为 0，`mainColumn` 的 VStack 内容仅剩 28pt 顶栏、在 `maxHeight` 撑满的 frame 内被垂直居中——图钉与 `WindowDragHandle` 拖动热区随顶栏同步错位到窗口中线（水平仍贴右缘），故「拖中部（真热区所在）能动、拖顶部空区拖不动」；任一常驻会话有消息时贪婪 ScrollView 撑满高度即恢复正常，故平时不可见、冷启动全空时偶现。修法：`messageList` ZStack 加 `.frame(maxWidth: .infinity, maxHeight: .infinity)`，列表容器恒占顶栏以下全部剩余高度，顶栏恒定钉在顶部
- 发送消息后不自动跳到底部（在上方阅读历史时发送，视图停在原地）：三重叠加——① 消息数变化的贴底跟随被 `guard isActive, isPinned` 拦截（用户上滚解除跟随后发送即不跳）；② 消息数组 diff 判定失效：`send()` 同一 runloop 连续 append 用户消息与助手占位，SwiftUI 合并帧后 `onChange(of: messages.count)` 触发时 `messages.last` 已是占位、role 判定不命中；③ 最终的 `proxy.scrollTo(bottomAnchorID)` 在「视口远离底部 + 新行刚插入」场景下对 LazyVStack 尾部锚点无声失败（前两版修调用时序均实测无效，坐实该路径不可靠）。修法 = 三层：发送事件信号（`AIChatState.scrollJumpRequests` 按会话发布时间戳，视图层 `onChange` 无条件置 pinned 并跳底）→ NSScrollView 直滚桥（`NSScrollBridgeView` 零尺寸 NSView 挂在 ScrollView 内容树内部、经 `enclosingScrollView` 捕获本会话底层 NSScrollView 弱引用存入 `SessionScrollRelay`，`scrollToBottom` 直接设置 clip view 偏移——与用户滚轮同一条 AppKit 路径零竞态，桥未就绪回退 proxy 路径）→ 下一 runloop 无动画补滚兜底；`messages.count` 的 user 分支保留为非合并帧路径兜底
- 流式落定（思考完成后最终渲染）内容闪现后整片白屏（历史气泡一并消失、token 计数正常，切会话才恢复）：两处防御——① 常驻集合兜底：`residentSessionIds` 若在 sessions 扇出中被误删当前会话，ZStack 所有层 `opacity=0` 即整片白、而侧栏选中（读 `currentSessionId`）与 token（输入坞 overlay）照常显示，现每次扇出后恒定保证 currentSessionId 常驻（幂等 LRU 补齐）；② 落定替换禁动画：`.done`/`.aborted` 的 `AssistantMarkdownView` 从流式视图结构性替换时加 `.transaction { $0.animation = nil }`，阻断 messageList 的 `.animation(value: messages.count)` 与行级 transition 在替换瞬间传入的隐式动画，防 CA 事务竞态把内容层卡在近零透明度（与既有白屏防线同族）
- 会话加载后侧栏出现两条同时高亮的选中行：`load()` 按 updatedAt 降序排序后按 id 去重（保留最新）——磁盘上存在重复 id 会话文件时 ForEach 身份域冲突会同时命中两行选中态；仅加载期收敛，运行时 mutate 路径不变
- 重启恢复草稿后输入框 placeholder 与草稿文字重影（双层文字叠绘）：`inputEmpty` @State 初值固定 true，而首挂载无变化事件可同步它——`onChange(of: inputText)` 不响应初始值，`updateNSView` 程序化回写（`textView.string = text`）生效但同期写 `isInputEmpty` 属「视图更新周期内修改 state」被 SwiftUI 丢弃（AppKit 层生效、SwiftUI 层不生效即重影）。修法 = placeholder 显隐与 `dockQuiet` 安静态判据改为 `inputEmpty && state.inputText.isEmpty` 双通道取与——派生条件首帧求值即正确、零时序依赖；IME 组字期防重影语义保留（组字文本经 setMarkedText 回调实时同步 `inputEmpty` 通道）

### Fixed

- web_search 冷启动后首次使用弹钥匙串密码授权：Tavily Key 存储从 Keychain 改为文件（`~/Library/Application Support/QuickShow/tavily_apikey`，0600 权限、原子写、读取时顺手收紧过宽权限），与 LLM API Key 同方案。根因：本地开发频繁重编译导致签名变化，Keychain 条目 ACL 每次读取都弹密码授权（`kSecAttrAccessibleWhenUnlocked` 只管设备锁屏、解决不了 ACL 问题，「先删后建」只在写入时有效）。首次读取时一次性迁移旧 Keychain 条目（可能弹最后一次授权，用户拒绝则静默走环境变量）→ 落盘 → 删除条目，此后零 Keychain 调用；`QUICKSHOW_TAVILY_API_KEY` 环境变量兜底保留；保存/清除密钥时顺手清理遗留 Keychain 条目
- 空态判据单帧空白：空态 overlay 判据直读 store 真源（原经 `state.messages` 的 CombineLatest + removeDuplicates 异步扇出，切换瞬间与 ZStack 直读差一帧出现「ZStack 已空、overlay 仍判非空」）
- 状态扇出收敛：`$sessions` → `messages` 映射后按值去重（其他会话流式冲刷不再令当前会话视图无效扇出）；会话 id 集合 + removeDuplicates 检测删除，流式冲刷不重复触发

### Performance

- 代码块 hover 性能架构重构（状态半径原则，AI 窗）：根因——hover 一个 17pt 复制按钮的显隐触发**整个代码块 body 重算**，`Text(highlighted)`（大段 AttributedString，构造需解析整段 runs，成本高一个数量级）是 body 内联属性每次全量重建；滚动中指针不动、内容在指针下移动，AppKit 对每个代码块 tracking 区域派发 enter/exit 风暴 × 全块重算 = 掉帧（录屏 87 帧逐帧分析证实：3 次单帧冻结 + 94~98px 追赶跳变，每次精确伴随新代码块复制按钮渐显；鼠标在空白区滚动无 hover 目标故丝滑）。修法 = `CodeBlockText` 独立子视图：高亮 `@State` / 高亮 task / `Text` 渲染全部内聚，父级 hover 变化被 SwiftUI 子视图值 diff 短路——大段高亮文本永不重建，hover 重算半径从整块压缩到 header 一行（语言标签 + 小按钮）；高亮 task id 由字符串拼接改 Equatable struct（内容 / 语言 / 外观三维键控）
- 会话秒开专项（AI 窗，对齐微信「只渲染视口 + 布局查表」模型，任意数量 / 体量 / 打开时间的会话切换即开）：**首帧块数视口自适应**（按视口高度 8~16 块起步、批大小 12、16ms/批摊销推进，首帧成本与屏幕大小挂钩、与会话体量彻底解耦）；**全局 `MathLayoutCache`**（段落高度 + 块级公式高度两张 LRU 4096 表、线程安全、内容 hash+宽度+外观+字号键控）——跨会话切换 / 跨 LRU 逐出重建 / 跨重启免重测量，公式占位首帧即锁定真实高度零跳变；`MarkdownASTCache` 64 条/60 万字符 FIFO → 256 条/400 万字符 LRU（多会话切换不互相驱逐）；常驻会话 LRU 上限 4 → 12（≤12 会话切换零重建纯 opacity 直切）
- 数学公式渲染全链路异步化（AI 窗）：块级公式 `AsyncMathBlockView`（占位 → 后台光栅化 → 直换回填）；行内公式两段式（锁内快速查缓存 → 命中同步装配 NSTextAttachment / 未命中等宽 LaTeX 占位 + 批量 `rasterizeAsync` 回填）；超长消息分批渐进渲染；`MathRasterizer` 统一 `renderLock` 串行化 + `inFlight` 飞行去重（预热与按需共用）+ 预热让路（utility 队列逐公式 1.5ms 释放锁）+ 失败负缓存 + LRU 512 位图缓存；选中会话后台预热全部公式（收集移出主线程、会话签名去重）；主线程首帧 / 切换路径不再存在未命中缓存的同步 SwiftMath 光栅化
- 会话消息分组缓存（`MessageGroupingCache`）：`groupMessages` 每次 body O(n) 全量分组 → messages 引用相同（COW 同缓冲区）即复用分组结果，O(1)
- AI 工具调用并行执行（同一轮回复内，AI 窗）：原 `for ... await` 严格串行（3 个 `web_search` 逐个排队）改为分段执行——**连续的 parallelSafe 工具聚批用 `withTaskGroup` 并发执行**，serial 工具逐个串行。新增 `ToolExecutionPolicy`（`AIToolRegistry`）：`parallelSafe` / `serial`，协议默认 `serial`（保守，未知工具名查询亦返回 serial）。逐工具标注：
  - **parallelSafe（8 个纯读、无共享可变状态）**：`web_search`、`fetch_url`、`read_file`、`read_clipboard`、`list_running_apps`、`get_env`、`list_env`、`get_quickshow_state`
  - **serial（6 个有副作用或共享状态，绝不并行）**：`run_shell`（任意副作用）、`write_file`（写文件 + 危险确认弹窗）、`write_clipboard`（全局剪贴板互相覆盖）、`set_env`（UserDefaults 非原子读改写、并发丢更新）、`open_app`（启动进程副作用）、`get_system_status`（`SystemStatusProvider.shared` 有可变采样缓存 prevCpuInfo/prevBytes 等，并发数据竞争风险）
  - 顺序与安全保证：工具结果与 `wireMessages` 严格按 `completedCalls` 原始顺序回填（Chat Completions 协议 tool 结果顺序不变）；批内子任务只执行不触碰 MainActor 状态，store/UI 更新全部回主线程串行落定；abort 语义与旧实现等价（中止时每条 tool_call 都有失败占位配对结果）；危险确认弹窗（`write_file`/`run_shell` 为 serial）天然串行不重叠；`AIToolExecutor` 与各工具 execute 逻辑零改动

## [1.12.0] - 2026-10-02

### Added

- 数学公式渲染全覆盖（AI 窗，SwiftMath 1.7.3 vendoring + 内核补丁）：
  - **vendoring**：SwiftMath 从 SPM 远程依赖改为 vendored 静态库（`Vendor/SwiftMath`；`project.yml` 新增静态库 target、`mathFonts.bundle` 以 folder reference 打进 App 资源、字体加载 `Bundle.module` 双路径定位——SPM 构建与 xcodebuild 直编均可用）——换取内核级补丁能力
  - **内核补丁① CJK 混排**：`atom(forCharacter:)` 放行 CJK 字符（上游对 ASCII 0x21–0x7E 外字符静默丢弃，导致 `\text{中文}` 渲染成 0×0 空白）；排版层 `addDisplayLine` 对行内 CJK 区间回退系统 PingFang SC 字体（Latin Modern Math 无汉字字形，不回退则空白），与数学字体分区混排
  - **内核补丁② 字号阶梯**：`MTMathStyle` 新增 `fontSizeScale`，命令表收录 `\tiny`~`\Huge` 七档（0.5 / 0.9 / 1.0 / 1.2 / 1.44 / 1.728 / 2.074，LaTeX 10pt 档位比例）；排版器按行消费缩放（`.style` 分支区分字号命令与样式命令，前者不扰动行样式），花括号分组天然隔离作用域；转译层移除七档去壳映射，命令直达内核原生渲染
  - **内核补丁③ 符号表补录 12 个上游缺失符号**：角括号 `\ulcorner`/`\urcorner`/`\llcorner`/`\lrcorner`（⌜⌝⌞⌟）、`\gtrless`/`\lessgtr`（≷≶）、`\lesssim`/`\gtrsim`（≲≳）、`\S`/`\P`/`\dag`/`\ddag`（§¶†‡）——沿用上游自身的 Unicode 值 + 字体字形模式（如 `partial`→U+1D715），全部经墨迹校验（Latin Modern Math 字形覆盖确认）；单个命令缺失即整式回退源码，这是实测「渲染失败案例」的主要来源
  - **转译层（`MathLatexTranspiler`）扩充约 60 条命令映射**：否定关系族（`\nsubseteq`/`\nleq`/`\nsubset` 等裸命令与 `\not` 前缀 → `\lnot` 构造）、`\therefore`/`\because`（`\atop` 三点构造）、`\leqslant`/`\geqslant`/`\preceq`/`\succeq`/`\vdash`（拼接构造）、框圈运算符（`\boxplus`→`\oplus`、`\boxtimes`→`\otimes`、`\circledast`→`\odot`、`\triangledown`→`\nabla`、`\Join`/`\ltimes`/`\rtimes`→`\times`）、钩箭头/弯箭头/双羽箭头族→方向等价的基础箭头、`\mathring`（`\circ` 置顶构造）、`\bmod`/`\mod`→`\mathrm{mod}`、`\dddot`→`\ddot`、`\varkappa`/`\digamma`、`\label`/`\require` 删除、`\genfrac` 六参→`\frac`/`\binom`（定界/线宽/样式降级、分子分母保留）、`\kern` 维度整段删除（`\mkern` 仅为 SwiftMath 序列化输出格式、解析器不收输入——认知纠偏归档）等
  - **验证方法归档**：本地 SPM 测试包（mttest，路径依赖 vendored 包）逐条渲染 + 尺寸 + 像素墨迹三重校验（「图片非 nil」检查会被 0×0 空图骗过，必须查尺寸与墨迹）；用户完整公式手册 213 条（块级 + 行内去重）全部通过、历史会话 435 块零崩溃零渲染失败、七档字号高度 4×3→16×13 单调递增。排障乌龙归档（防再踩）：APFS 大小写不敏感，测试文件 `large.tex` 与 `Large.tex` 是同一文件、后写覆盖前写，「两对档位塌缩」是同一文件测两遍的假象。全 4 会话 699 条去重公式全量扫荡（补齐 `\(...\)`/`\[...\]` 定界符提取盲区——用户新会话的公式正是方括号定界）残余 7 个失败全为已知项：6 个提取正则跨代码域 / 控制字符损坏的伪公式 + CD 交换图环境（已知限制，真实输出罕见，整式回退源码可读）

### Changed

- AI 窗流式输出贴底跟随（`AIChatView`）：消息区底部 sentinel 锚定内容绝对末端（124pt 输入坞留白 + 1pt 锚点）、流式期间自动贴底、用户滚轮上翻暂停跟随 / 回底自动恢复（新增 `AIChatScrollWheelMonitor`，NSEvent 局部 `.scrollWheel` 监听，macOS 13 兼容）、消息数变化强制回底——长输出不再被输入坞遮挡，玻璃穿透效果不变

### Fixed

- App 启动即崩（恢复含 `\textcolor` 公式的会话时）：SwiftMath `MTTypesetter` `.textcolor` display 分支数组越界陷阱（fatal 不可捕获）——转译层把 `\textcolor{c}{X}` 改写为 `{\color{c} X}` 规避，渲染语义等价
- AI 窗整窗玻璃方角残影（拖动 / 缩放后方形玻璃从圆角缺口露出）：WindowServer 在方形窗口矩形上合成 behind-window 材质，重栅格化后方形玻璃从 `cornerRadius` 缺口处露出灰色方角——新增 `GlassClipContainerView` 窗口级圆角裁剪容器（`layer.masksToBounds` + CAShapeLayer 路径 mask，玻璃经其裁剪后再作 contentView）+ 窗口 `didMove`/`didResize` 后 `invalidateShadow()`（透明窗口系统阴影由不透明像素推导、拖动后不自动重算，保留方形轮廓与残影叠加成「四个方角」）；主面板 glass 同步补 `clipsToBounds = true` 材质渲染层面圆角基础项
- AI 窗冷启动白屏（主内容区消息行卡近零透明度、白屏 + 幽灵残影，切会话重渲染才恢复）：根因是 0.08s 窗口级淡入动画与 SwiftUI 首帧建树的 CA 事务提交在同一时间窗竞态。三层防线：**A** 首建面板满 alpha 直接上屏、不播窗口级淡入（`isFreshlyBuilt` 区分首建 / 复用，复用热路径内容已就绪、保留淡入）；**B** 上屏前 `layoutSubtreeIfNeeded()` 强制完成建树与布局，不让离屏半建状态上屏后与渲染事务竞态；**C** 首载装载态 `isInitialHistoryLoad`——期间消息入场过渡降 `.identity`、列表 count 动画禁用（无 CA 动画可被窗口上屏竞态卡在近零透明度），首帧布局完成后的下一 runloop 解除，此后流式新消息恢复入场淡入。附带：操作行渲染条件收紧（`showsActionRow`——仅落定终态 `done`/`aborted` 的助手消息渲染操作行；流式 / 发送中不提供半截内容的复制入口，`failed` 有独立重试卡片）

## [1.11.0] - 2026-10-02

### Changed

- 设置窗整窗 Liquid Glass（对齐 macOS 27 系统设置「底玻璃、纸实底」观感）：titled 标准窗口保留系统 chrome（交通灯/系统圆角/窗口阴影），titlebar 透明一体化（交通灯坐在玻璃上，系统设置同款无标题条呈现）；26+ `NSGlassEffectView` 作 contentView 承载设置内容（`.regular` 样式、不设自绘圆角——窗口形状由 titled 系统管理），窗口背景 clear；设置窗惰性创建、创建即上屏（无挂起期问题）；**不设 `sizingOptions=[]`**——那是两窗「PreferenceKey 测量链死锁」的规避手段，设置窗固定尺寸、无测量链、无动画，不需要禁 hosting 尺寸协商；sidebar 材质与 grouped 表单卡片交给系统组件自适应（26 上即系统设置的渲染语言：双层明度分区 + 实底表单卡片）

### Fixed

- 设置窗详情区常驻宽体滚动条（~20pt 高亮、thumb 冻结不随滚动、永不淡出）：
  - 根因（视图树/layer dump + Apple 官方文档交叉定位）：macOS 接鼠标时系统**强制常显**滚动指示条，`.scrollIndicators(.hidden)` 被系统忽略——官方文档明确仅 `.never` 可覆盖（"Use `never` to indicate a stronger preference that can override this behavior"）；thumb 冻结因指示条挂在 SwiftUI 自动包装的 `HostingScrollView`（内容溢出视口时创建）上、内容实际在内层滚动
  - 修法：detail 详情区显式 `ScrollView` 接管滚动（消除自动包装）+ `.scrollIndicators(.never, axes: .vertical)`；`LegacyScrollerSweeper`（NSViewRepresentable 遍历窗口树关闭 AppKit 桥接层的 legacy 垂直 scroller / 隐藏独立 NSScroller）作防御性兜底保留
  - 调试记录（防再踩）：macOS 接鼠标时滚动条常显是系统语义而非 bug；overlay 指示条在 Tahoe 上由 `NSScrollerImp` + CALayer 绘制，不挂 `verticalScroller` 属性（遍历 NSView 子树找不到）；unified log 的 `NSLog`/`os_log(info)` 在本机均查不到（`log show` 需 `--info`，且最终也未命中——文件直写 dump 才是可靠诊断通道）

## [1.10.0] - 2026-10-02

### Changed

- 整窗 Liquid Glass 推广到主面板（两窗统一，26+）：`NSGlassEffectView` 同款装载移植到 `PanelManager`；玻璃组装时机学 AI 窗——**首次 show 时组装、与上屏零间隔**（组装→alpha 0→orderFront→fade 与 `AIWindowManager.makePanel`→show 完全同序），不留「启动期装载、长期 orderOut 挂起」的空窗期；后续呼出复用已挂载玻璃。当年死锁根因（PreferenceKey 测量链）已由 60Hz 轮询时钟绕过，主面板大量 Button 内容下未复现
- 两窗内容层背景统一走新增共享 `LiquidPanelBackground` modifier（26+ 透明透玻璃 / <26 铺 ultraThinMaterial），替代各视图散落的 if/else 分支；`PanelView` 背景换用同款
- AI 窗侧栏融入玻璃：`chatSidebarBase` 不透明度 0.95→0.35 轻纱层（分区靠深浅差而非实色）——旧实色是「整窗无玻璃」时代的压底设计，真玻璃上即窗中窗割裂；玻璃折射从侧栏透出，选中/hover 微胶囊语言在玻璃上自然成立
- AI 窗 ⌘B 侧栏动效同步：侧栏从 `if` 插拔（瞬间占位挤窄主区、窗口渐宽再弹回的跳变卡顿）改为**常驻 + 宽度 0↔216pt 动画**（内层内容恒宽不重排，外层与窗口 `setFrame` 同曲线同时长伸缩，`.leading` 锚定左缘展开）；`withAnimation` 曲线 easeOut→easeInOut 与窗口侧严格一致；分割线随侧栏同步收拢

### Fixed

- 主面板玻璃完全不渲染（背景全透明、桌面零模糊穿透、仅底边倒计时微光条残留）：根因是 1.10.0 开发期装载分支编辑残留——`panel.contentView = hostingView` 在玻璃分支之后无条件执行，把刚组装进窗口的玻璃踢出窗口层级（玻璃对象存在但从未上屏，backdrop 采样零执行）；删除残留行 + 组装时机迁移后修复。期间两轮错误假设（「挂起期握手未完成」→ show 时重挂 contentView；「重挂时机撞上 alphaValue=0」）均被该 bug 掩盖，最终以两窗装载代码逐行比对定位
- 主面板 fade-in 期间的玻璃渲染路径随组装时机迁移一并覆盖（fade 起步 alpha 0 不再影响首次组装后的采样握手）

## [1.9.1] - 2026-10-02

### Changed

- AI 窗恢复整窗 Liquid Glass（用户反馈「与系统聚焦面板质感差距大」；经截图逐像素比对诊断，根因是 1.8.0 移除整窗 `NSGlassEffectView` 后 `ultraThinMaterial` 在深色模式下 tint 过重近乎实心，backdrop 折射/透底/受光边缘全失效，走不到系统 Liquid Glass 渲染管线）：
  - 26+ 恢复 `NSGlassEffectView` 整窗玻璃（`.regular` 样式 + 26pt 连续曲率圆角）作 `panel.contentView`；当年移除主因（NSGlassEffectView+NSHostingView+Button 测量死锁）按社区成熟规避落地：① `sizingOptions=[]` 禁 hosting 反推窗口尺寸；② 玻璃组装全程零时长 `NSAnimationContext`（玻璃隐式动画会打断 SwiftUI 建树 → AttributeGraph 崩溃）；③ 先组装、最后挂 contentView
  - 内容层背景 26+ 透明化（内容「印」在玻璃上，系统 Spotlight 语义），手绘方向性 rim light 移除（玻璃自带 specular 受光边缘，叠加出双边缘）；`<26` 降级路径不变（ultraThinMaterial + rim）
  - 新增 `OSFeatures.liquidGlass` 运行时能力开关，SwiftUI 视图层与 AppKit 窗口层共用同一判断源
- AI 窗拖动吸附改「松手落位」交互：拖动全程窗口自由跟随鼠标，吸附检测只驱动窗口级目标区域预览（预览矩形 = 松手落点，严格一致），松手命中才以短动画（`Motion.windowResize`）落位；替换原逐帧吸附（中途锚点重置与中心线/半屏叠加冲突）——预览层去掉中心线，只画目标区域圆角轮廓

### Fixed

- 数学公式位图明暗翻转钉死：`MathBlockView`/`MarkdownBlockView` 追加 `@Environment(\.colorScheme)` 驱动 `updateNSView` 重调（SwiftUI 不追踪 `NSApp.effectiveAppearance`，外观切换后旧位图不换），经缓存 key（含颜色分量）自动取对应明暗位图；新增 `MathRasterizer.appearance(for:)` 把 colorScheme 映射到固定 `NSAppearance` 取色

## [1.9.0] - 2026-10-02

### Added

- AI 思考过程（reasoning）展示：
  - 数据链路：`ChatMessage` 新增 `reasoning` 字段（旧会话 JSON `decodeIfPresent` 兼容，缺失按 nil 恢复）；服务层双协议解析思考增量——Chat Completions 的 `delta.reasoning_content`（DeepSeek 风格）/ `delta.reasoning`（兼容端点）与 Responses 的 `response.reasoning_text.delta` / `response.reasoning_summary_text.delta` 事件，统一汇入既有 `AIStreamEvent` 流式事件通道（新增 `.reasoning(String)` 分支，未另起通道）；State 层经 `pendingReasoning` 合帧缓冲沿 ~50ms 冲刷路径累积到当前助手消息（只 mutate 单条、不改 id，保持 `.equatable()` 跳行性能纪律），落定/中止后保留不清理
  - UI（`ReasoningDisclosureView`）：流式中在正文上方呈现折叠摘要行（SF Symbol 图标 + 思考文本单行截断 + 展开箭头，contentTertiary 11pt），点击 toggle 展开为限高 160pt 内部滚动区（11.5pt contentSecondaryStrong）；摘要行随增量实时更新（250ms 门控节流，与流式 Markdown 同款时间门），落定后折叠行保留、默认收起
- 消息落定入场动画：0.16s 淡入 + 2pt 上移（复用 `Motion.contentFade`）

### Changed

- AI 窗视觉重构（用户反馈「窗口低廉、不像 Liquid Glass」；经截图逐像素诊断 + HIG Materials / WWDC25-219 规范交叉定位，根因是层级而非参数）：
  - **输入坞浮岛化**：从「消息列表 + 输入区」VStack 上下拼接改为 `overlay(.bottom)` 底部悬浮，消息滚动时从玻璃卡底下穿过（真 blur-through）——修复 glass-on-glass 反模式（`.glassEffect` 输入卡压在整窗 `ultraThinMaterial` 基面上，CABackdropLayer 采样不到窗口内真实内容、只能二次磨砂已磨砂层，退化成发灰塑料块）；玻璃折射 / specular 高光 / 自适应明度随真实内容流自动成立（HIG「玻璃浮在内容之上」的正确层级）。列表底部 `chatDockClearance=124` 留白保证末条消息可滚至坞上
  - **窗口方向性 rim light**：顶缘白 70% → 侧缘 15% → 底缘白 5% 的渐变内描边 + 底缘 1pt 黑 8% 重边（`rimTop/Side/Bottom/DarkEdgeOpacity` 令牌），替换均匀 1px 灰线——受光边缘给出玻璃厚度感，「密封袋压边」塑料感消除
  - **双层阴影系统**（新 `Theme.Shadow` 令牌）：接触影 r3/y2/12% + 环境影 r16/y12/8%，替换单层 `black 0.28 / r10 / y3` 贴身影；输入卡聚焦态（`isKeyWindow` 驱动）accent rim 提亮 35%，材质对状态有响应
  - **控件语言统一微胶囊**：⊕ / 模型 chip / 剪贴板按钮统一实底（surfaceTrack 系）+ 0.5pt 白 rim（亮 40% / 暗 20%）+ hover 提亮，告别裸细线图标；「清空会话」入口迁入 ⊕ 菜单（trash 图标）
  - **用户气泡琥珀实底**：`chatUserBubble` 令牌（亮暖纸 #F6EEDF / 暗深琥珀 #362C14 系 92%），去描边、圆角 12→18——形感靠实底 + 大圆角，半透明琥珀水感块 + 描边语言移除
  - **间距三级节奏**：轮次组距 26→36（`chatGroupGap`）/ 组内 8→10，行 < 段 < 轮的嵌套节拍，轮次边界凭空隙可辨
  - **减负**：删底部快捷键提示行（「⏎ 发送 · ⇧⏎ 换行 · ⌘B 会话 · ⌘K 清空 · ESC 关闭」）与其上羽化分割线及左侧「清空」按钮——提示全部由各控件 `.help()` tooltip 承担；删用户消息的复制操作行（操作行仅留 AI 回复，hover 提亮逻辑不变）；输入内边距 9pt→18pt（`textContainerInset` 与 placeholder 同步）
  - **流式指示器光标化**：删「▌ 生成中…」呼吸整行；无正文无 reasoning 时 = 闪烁块状光标（`Motion.caretBlink` 0.55s）+「思考中…」弱化阶段词；有正文增量后光标跟随文尾（块尾位，未侵入 Markdown 内联）
  - 发送键改琥珀实心圆 + 深色箭头（黑 0.72）——全图最强图底反转（学 Claude App 主操作语言）；流式红停止态不变
- 版本号真源 project.yml 1.8.0 → 1.9.0（xcodegen 重写产物）

### Fixed

- 发送按钮禁用态与输入卡底对比度实测 1.04:1 近隐形（用户截图逐像素确认）：禁用底改黑 14%（亮）/ 白 18%（暗）实底（`chatSendDisabledFill`），保持可辨的 disabled 语义同时 ≥1.2:1 对比

## [1.8.0] - 2026-10-02

### Added

- AI 对话窗口交互升级：
  - 钉住常驻置顶：右上角图钉按钮（状态持久化 `ai.pinned`），钉住时失焦不隐藏、保持置顶；ESC / 热键关窗语义不变。根因修复：NSPanel 浮动面板 `hidesOnDeactivate` 默认 true，应用失活时 AppKit 直接 orderOut 绕过钉住门控——显式置 false 后钉住真正生效
  - 窗口自由移动与缩放（新文件 `AIChatWindowControls.swift`）：顶部拖动条自定义逐帧拖动，磁吸对齐——屏幕中心线（辅助线）、左右缘半屏、顶边全高（预览轮廓），20/30pt 磁滞防抖；四边 5pt + 四角 12pt 八向热区缩放（480×560 下限）；位置/大小跨重启记忆（`ai.windowFrame`，换屏校验失效自动回居中）；侧栏 ⌘B 展宽改保锚点缩放不再居中重排
  - 流式完成通知（新文件 `AICompletionNotifier.swift`）：响应自然完成（排除中止/失败）且窗口不可见或非焦点时发系统通知（会话标题 + 回复纯文本摘要 ~80 字），点击唤出对话窗；首次使用时请求权限，被拒后静默
- 数学公式转译层（`MathLatexTranspiler`，渲染前把 SwiftMath 1.7.3 实测不支持的命令自动转译，独立 harness 逐条验证）：`\dfrac`/`\tfrac`/`\cfrac`→`\frac`、`\iint`/`\iiint`→`\!` 紧凑积分、单列 `cases` 自动补列、`\substack`→`\atop` 堆叠、`\pmod{X}`→`\;(\text{mod}~X)`、`\:`→`\,`；后续新失败命令可继续扩充映射表
- Markdown 水平分隔线：`---`/`***`/`___` 渲染为通栏细线（此前被当段落文本显示为连字符短线）
- 流式期间实时渲染：流式输出走 250ms 节流增量 Markdown/公式渲染（重解析 ≤4Hz），落定后全量渲染收尾（此前流式期间纯文本、落定才整体渲染）

### Changed

- Liquid Glass 官方分层重构（按 HIG Materials「glass 只属功能层，内容层必须标准材质」）：移除主面板与 AI 窗的整窗 `NSGlassEffectView`（官方点名的反模式，观感如磨砂塑料）；内容层统一 `ultraThinMaterial`；新增 `GlassSurface` modifier（26+ `.glassEffect` / <26 材质+描边，分层语义跨版本一致）用于功能面（AI 窗输入坞）；两窗 contentView 统一 `PanelHostingConfigurator` 圆角裁剪；26+ 与 <26 路径同构
- 视觉协调（用户反馈驱动）：AI 窗顶部拖动条改纯透明热区（恢复一体观感，拖动/吸附功能不变）；两窗图钉按钮统一克制语言（accent 着色无底衬、hover 轻圆底）；主面板底部状态栏恢复整合观感（与顶部日期徽章同层级同明度）；AI 窗材质层级收敛为两级（基面 + 输入坞唯一浮层）
- 构建脚本：`restart.sh` Release 构建加 `CODE_SIGN_STYLE=Manual`——SPM 包产物默认 Automatic 签名风格强制要求开发团队 Team，自签证书无 Team 时 Release 编译失败

### Fixed

- 主面板顶部日期徽章被点击后成为 first responder，系统围绕按钮 bounds 绘制蓝色键盘焦点环（圆角与徽章胶囊形状不贴合，视觉脏点）：`PanelView` 根部全局 `focusEffectDisabled`（macOS 14+ 对整棵视图树传播，macOS 13 透传），面板内所有按钮一并免疫；键盘交互本由 `FloatingPanel.sendEvent` 自行拦截分发，零功能损失
- 中文输入法组字时 placeholder「问点什么…」不消失且与组字文本重叠：`setMarkedText`/`unmarkText` 回调驱动占位符显隐（组字期间 `textDidChange` 不触发，绑定不感知组字态）
- 中文输入首键拼音闪失（上项修复引入的回归）：组字期间 `updateNSView` 的程序化回写会摧毁组字文本——双防线修复：`hasMarkedText()` 门控拦截回写 + 组字文本实时同步进绑定；组字中流式 token 到达引发的重渲染亦不再打断输入

## [1.7.0] - 2026-10-02

### Added

- AI 对话数学公式渲染（LaTeX 真排版，接入 SwiftMath 1.7.3——纯 Swift + CoreText 数学排版库，项目首个 SPM 依赖，无 WebView/JS）：
  - 解析层：`MarkdownParser` 新增行内 `math` token 与块级 `mathBlock`，支持 `$…$`（行内）与 `$$…$$` / `\(…\)` / `\[…\]`（块级，单行与跨行均支持，未闭合收剩余全部行与围栏代码块同策略）；行内 `$…$` 带货币保护启发式（开 `$` 后非空白、闭 `$` 前非空白且后非数字/`$`，「$5 和 $10」不误判）；公式内容整段切片不递归解析，内部 `\frac` 等不会二次转义
  - 渲染层（新文件 `QuickShow/Views/AIChatMathViews.swift`）：公式经 `MathImage.asImage()` 光栅化为 NSImage，静态缓存 key 含 latex + 字号 + 已解析 sRGB 四色分量 + 显示/行内模式（亮暗两套位图独立，暗色不黑底黑字）；行内公式 NSTextAttachment 按 `LayoutInfo.descent` 精确基线对齐嵌入文本流；块级公式 NSImageView 居中（display 模式 14pt）；解析失败降级等宽原始源码显示
  - 分流策略：`MarkdownInlineText` 统一入口替换 8 处 `Text(MarkdownInline.render(...))` 调用点，递归检测公式（含粗体/斜体/链接内嵌）；无公式 100% 走原 AttributedString 路径（视觉零回归），含公式段落改走 `NSTextField(labelWithAttributedString:)` 路径，`MarkdownInlineNS` 镜像原行内排版语义（等宽代码 / 加粗提亮 labelColor / accent 链接下划线 / 引号归一）
  - 不直接使用 `MTMathUILabel` 进视图树（规避 macOS 1.7.3 intrinsicContentSize 哨兵值 (-1,-1) 与 Auto Layout 裁剪/重叠问题 issue #73），统一走图片路径

### Changed

- 版本号真源 project.yml 1.5.1 → 1.7.0：追平 1.6.0 / 1.6.1 两版遗留的 CHANGELOG 版本漂移

## [1.6.1] - 2026-10-02

### Changed

- AI 对话窗口界面重做（对标 DeepSeek / Claude Code 对话排版，落成 macOS Liquid Glass 形态）：
  - 背景材质：消息区弃用 94% 不透明 `chatBase` 实心底板，改 `.ultraThinMaterial` 材质分层——窗口级 `NSGlassEffectView` 玻璃真正透出（与主面板同款模式），明暗随壁纸经 `effectiveAppearance` 自动翻转；输入坞改为浮起玻璃卡（材质底 + 0.5pt `chatStrokeStrong` 描边 + 轻投影），与消息区留 16pt 浮动缝隙；阅读列限宽 600pt 居中，窗口加宽时两侧透玻璃（消息列与输入坞同宽对齐）
  - 助手消息去气泡：markdown 正文直接铺在材质上左对齐、无内边距（用户消息琥珀气泡与工具卡片容器语言保留），层级全靠字号 / 字重 / 留白表达
  - 排版体系：正文行距 lineSpacing 3→6（13pt 等效行高约 1.7）；标题三级 h1 18 bold / h2 16 semibold / h3 14 semibold 纯白（h1 底部分隔线减弱为 `cardStroke`），正文与列表降档 primary 0.80 与加粗纯白拉开两档；块间距节奏重排——标题前 26/20/16、标题后 8 成组、内容块（段落/列表/引用/表格/代码块）之间 16，列表项间 8 / 嵌套子项间 6
  - 直引号显示层归一：markdown text token 与流式纯文本中成对 `"…"` 转中文引号「」（行内代码 / 代码块 / 链接 URL 不转换，未配对单引号保留原样；流式与定稿共用同一转换，杜绝落定瞬间跳变）
  - 消息操作行：hover 渐显的浮动跨骑 pill 改为消息下方常驻弱显示行——13pt medium hierarchical 图标、26×26 命中区、静止 38% / 悬停 85% 提亮并叠 8% 圆角底；复制对勾反馈与重新生成（仅最后一条落定回复，`canRegenerate`）逻辑不变
  - placeholder 减负：「问点什么…（⏎ 发送 · ⇧⏎ 换行 · ESC 关闭）」→「问点什么…」，快捷键提示合并至底部常驻条（⏎ 发送 · ⇧⏎ 换行 · ⌘B 会话 · ⌘K 清空 · ESC 关闭）
  - 删除对话区 / 输入区之间的羽化分隔线（输入坞改浮卡后多余，空隙归入浮动缝隙）；列表底部 padding 18→4，消除操作图标下方空洞堆积

### Fixed

- API Key 存储放弃 Keychain 改纯文本文件（`~/Library/Application Support/QuickShow/apikey`，目录 0700 / 文件 0600、临时文件原子写、读取前权限自动收紧）：本地开发频繁重编译导致签名变化，Keychain 条目 ACL 每次读取都弹密码授权（v1.5.1 的删除重建策略对开发期签名漂移无效）；首读时自动从旧 Keychain 条目一次性迁移（旧条目同时清理），`QUICKSHOW_AI_API_KEY` 环境变量只读兜底不变；设置页 API Key 存储说明文案同步更新

## [1.6.0] - 2026-10-01

### Added

- AI 工具调用体系（模型可调用本地工具并以结果多轮续写，从"纯聊天"升级为"能动手"）：
  - `QuickShow/AI/Tools/`：`AITool` 协议（name / description / JSON Schema / isDangerous）+ 注册表（`ai.tools.enabled` 持久化开关，键缺失默认除 `run_shell` 外全部启用）+ 执行器（危险工具 NSAlert 确认（sheet 附着 AI 窗、无窗降级 runModal）、30 秒超时竞速、结果统一 `{"ok":...}` JSON 包装、拒绝落 `denied`）
  - 14 个内置工具：`read_clipboard` / `write_clipboard`、`get_system_status`（CPU/内存/电池/网络/磁盘，包 SystemStatusProvider 公开只读 API，支持 section 过滤）、`list_running_apps` / `open_app`、`read_file` / `write_file`（`ai.tools.fileWhitelist` 目录白名单，标准化+软链解析前缀匹配防 `../` 逃逸，读取 200KB 上限）、`get_env` / `set_env` / `list_env`（`ai.envVars` 自定义存储优先，进程环境只读兜底；`list_env` 仅返回变量名不泄露值）、`get_quickshow_state`（窗口可见性扫描 + UserDefaults 偏好快照）、`run_shell`（Process 合并输出截断 32KB，默认关闭）
  - 联网工具：`web_search`（Tavily REST，Bearer 鉴权，15 秒超时，返回 answer + results[]；Key 存 Keychain `tavilyApiKey`，`QUICKSHOW_TAVILY_API_KEY` 环境变量只读兜底，未配置返回可读指引）；`fetch_url`（URLSession + 重定向上限 5 次 + 20 秒超时，仅 text/html 与 text/plain；手写 HTML 提取：去注释/脚本/样式 → 去标签 → 通用实体解码 → 折叠空白 + `<title>` 提取；charset 声明支持 UTF-8/GBK/GB18030/Big5/Latin-1，正文 64KB 截断；零第三方依赖）
  - 协议层（双协议）：Chat Completions 顶层 `tools` 数组与 `delta.tool_calls[]` 按 index 合帧累积；Responses 顶层 `tools` 与 `output_item.added(function_call)` / `function_call_arguments.delta|done` 事件解析；非流式路径同步支持；流式接口升级为 `AIStreamEvent`（text / toolCalls 两态）取代纯文本流，文本路径行为不变；工具结果回传 Chat Completions 走 assistant(tool_calls)+role:tool 消息，Responses 走 function_call / function_call_output input items；标题摘要等后台请求不带工具声明
  - 对话回路（`AIChatState.startConversationLoop`）：模型请求工具 → 记录（pending→running→done/failed/denied，经 store 消息更新链路实时驱动 UI）→ 串行执行 → wire 格式回传续写，`AIToolExecutor.maxToolRounds`（8 轮）防死循环，超限落文本说明；中止可打断全回路（轮前/工具前/工具后三处检查，未落定调用标 failed）；重试清理尾部失败消息从原用户消息重发；历史重建将带结果的工具消息还原为合法配对请求，结果缺失退化为纯文本
  - 消息模型与 UI：`ToolCallRecord`（id/name/arguments/result/status）随会话持久化，`decodeIfPresent` 兼容旧会话文件恢复；聊天流工具卡片（一条消息一卡多工具条目，五状态徽标，参数/结果等宽渲染、失败/拒绝默认展开并自动展开一次、可读错误摘要提取、超长结果 2000 字符折叠与限高滚动）；纯工具消息不渲染空气泡
  - 设置页 AI 分区新增四小节：工具开关列表（危险徽标 + `run_shell` 红字警示，键缺失按默认值初始化写盘、翻动写完整列表）、文件访问白名单（NSOpenPanel 添加目录、逐行可删）、自定义环境变量（键值对即时写盘）、联网搜索（Tavily API Key 安全输入，掩码/替换/清除复刻主 Key 交互，仅存 Keychain）
  - AI 配置环境变量兜底：`QUICKSHOW_AI_BASE_URL` / `QUICKSHOW_AI_API_KEY` / `QUICKSHOW_AI_MODEL` 在对应配置留空时生效（env 只读不写盘，API Key 不落 Keychain，已有配置优先）

### Fixed

- 危险工具确认 sheet 抢占 key 状态时 AI 窗触发 `resignKey` 被误判「被动切走」而自动隐藏：`AIWindowManager.performHide` 对 `panel.attachedSheet != nil` 短路跳过，sheet 关闭后焦点自然回归父窗

## [1.5.1] - 2026-10-01

### Fixed

- API Key 钥匙串条目每次重启弹密码授权：旧条目在历史签名二进制下创建，ACL 未含当前稳定证书（QuickShow Development）授权，导致每次读取触发授权弹窗。`saveAPIKey` 由 `SecItemUpdate` 改为「删除重建」策略（先 `SecItemDelete` 再 `SecItemAdd`），每次保存在当前签名下重建条目使 ACL 始终与运行二进制一致；`SecItemAdd` 显式声明 `kSecAttrAccessibleWhenUnlocked`。存量条目需重新保存一次 API Key 完成迁移（迁移后不再弹窗）
- 通用设置「呼出触发方式」选择与 AI 对话窗热键冲突的选项（如 AI 窗占用任意⌥时选左右侧⌥）被静默拒绝、UI 无任何反馈，表现为「选项选不上/显示回旧值」：对齐快捷键设置页的回读校验模式（写入后回读 `HotKeyManager.shared.currentType`），不一致即红字提示「与 AI 对话窗热键冲突，已保持原设置」并指引前往「快捷键设置」调整双路热键

## [1.5.0] - 2026-10-01

### Added

- 多会话管理（对标 DeepSeek / Claude 移动端交互，翻译为 macOS 悬浮窗形态）：
  - `ChatSessionStore`：每会话独立文件（`Application Support/QuickShow/AIChats/<uuid>.json`）原子写，旧 `AIChatSession.json` 一次性迁移为首个会话（旧文件保留）；上下文截断（最近 20 轮 / 24000 字符）按会话独立计算
  - 会话侧栏（`⌘B` 显隐，窗口宽度经 `ai.sidebarVisible` 偏好联动 216pt 平滑加宽）：搜索（`⌘F` 聚焦，标题+消息全文忽略大小写）、时间分组（置顶 / 今天 / 昨天 / 过去 7 天 / 更早，组内 updatedAt 倒序）、置顶 / 行内重命名 / 删除（红色隔离）、`⌘N` 新建；`⌘K` 语义调整为清空当前会话
  - 会话标题自动生成：首轮回复完成后后台非流式调用 LLM 生成 ≤12 字中文标题，失败静默降级为首条用户消息截断
- 消息级操作：hover 浮动操作条——任意消息复制（对勾轻反馈）、最后一条助手回复重新生成（截断重发）
- 图片附件（vision）：输入区 `⊕`（剪贴板导入 / 文件选择）、`⌘V` 粘贴（图优先于文本）、拖入（NSTextView 子类拖放拦截 + onDrop 兜底）；NSImage→JPEG base64（原图+缩略图等比压缩）；气泡内缩略图点击放大覆盖层（暗化遮罩，点击/ESC 关闭）；Chat Completions `image_url` 与 Responses `input_image` 双协议通路
- 块级 Markdown 完整渲染：`MarkdownParser` 纯函数 AST（h1–h3 / 有序无序列表含一层嵌套 / 表格 / 引用块 / 代码块 + 行内粗体/斜体/行内代码/链接）；流式期间纯文本+呼吸指示，落定后整条分区渲染；表格斑马纹+表头实线+列距加大，标题三级字号梯度，代码块 hover 复制
- 模型两层管理：
  - 「我的模型」（编辑/排序/设默认，AI 窗模型 chip 只显示这里）+「可用模型」候选池（只读、搜索过滤、`+` 加入、一键清空）；`从 API 拉取`（GET `/models`）只合并进候选池去重，不再直接灌进编辑列表；几百候选经 `ScrollView+LazyVStack` 轻量行虚拟化保持流畅
  - 键：`ai.modelList`（首项默认）/ `ai.selectedModel` / `ai.availableModels`；旧 `ai.model` 首读迁移；存量列表 >1 条时一次性迁移（全部进池、我的模型收缩为当前选中）
  - AI 窗输入区模型胶囊（>1 个模型时显示），切换对下一轮生效
- 空态欢迎页：已配置无消息时居中 Logo + 引导语 + 剪贴板快捷附加

### Changed

- 视觉层次重做（解决背景穿透 / 无层级 / 数据墙）：主区与侧栏高不透明稳定底板（94–95%，消除 vibrancy 穿透与残影）；用户消息右对齐琥珀气泡、助手消息亮一档底板+描边，连续同角色消息成组（组内 8 / 组间 26）；三级排版、间距分组节奏（标题前 18/14/10 梯度）；输入卡底色拉开+描边，发送键三态（可用 accent 实心圆 / 流式红底方块 / 禁用灰）；全窗强调色收敛单一通道；`DesignTokens` 新增 AI 窗专用 token 7 个（chatBase / chatSidebarBase / chatAssistantBubble / chatInputCard / chatStrokeStrong / chatTableHeader / chatTableRowAlternate，明暗自适应）
- `AIChatState` 重构为 `ChatSessionStore` 门面，`messages` 经 Combine 从 store 同步；设置页「AI 服务」Model 单字段替换为模型两层编辑区
- 请求体编码升级 `MessageContent` 枚举（text / parts）并显式携带 `stream` 参数

### Fixed

- 设置页候选池「+」按钮被常显滚动条遮挡：隐藏滚动指示器 + 行尾/底部安全边距，末行完整可见
- 流式响应回归（Wave 重构引入的性能退化，网络层经 diff 排除）：
  - 发送路径主线程 3 次全量会话 JSON 编码+写盘（带图 base64 时 50–200ms 叠加首 token 延迟）→ 全部 `persist: false`，落盘移至首 token 合帧时一次
  - 每 token 全量 `@Published` 扇出（50–200 次/秒视图失效）→ 50ms 合帧冲刷（≤20 次/秒），中止 / 失败 / 正常结束三路强制 flush 不丢尾部内容
  - `modelList` / `availableModels` 计算属性每次访问反序列化整个 JSON → `@MainActor` 串行内存缓存
  - 流尾 `settle(persist:)` 与 `store.persist` 双写盘去重（单点落盘）

## [1.4.0] - 2026-10-01

### Added

- AI 对话窗口：独立窄长居中 NSPanel（约 560×680 pt，随主面板三档尺寸偏好），双击 `⌥⌥`（可配置）或主面板 `I` 键唤出；`ESC` 两阶段语义（流式生成中先中止、非生成中毫秒级关窗还焦点）；文本聚焦时全键放行（复用 1.3.0 firstResponder 放行机制，中文输入法组字安全）
- OpenAI 兼容流式客户端（零依赖）：`URLSession.bytes` 手写 SSE 按行解析、`⌘`+`K` 清空、120 秒首字看门狗超时、abort 立即停止渲染；错误（401/429/网络/超时）在对话流内呈现并支持重试，不弹系统弹窗
- API 协议双支持：Chat Completions（`/chat/completions`，通用兼容）与 Responses（`/responses`，官方新协议，`instructions` 字段 + `response.output_text.delta` 事件流），设置中可选，默认前者
- Markdown 尽力渲染：行内粗体/斜体/行内代码/链接（`AttributedString(markdown:)` inlineOnly）+ 围栏代码块等宽段落（行级预切分，未闭合围栏兜底）；流式期间纯文本增量 + 呼吸指示，落定后整条富渲染
- 会话历史持久化：跨关窗与跨重启保留（`Application Support/QuickShow/AIChatSession.json` 原子写，启动恢复）；上下文截断（最近 20 轮 / 24000 字符，从最旧整轮丢弃）
- 剪贴板一键附加上下文（≤8000 字符截断，字数胶囊可移除）；设置中心新增「AI 服务」分组（协议 / Base URL / API Key 掩码存取 / Model / System Prompt 可选）
- API Key 存 Keychain（service `com.dzhang.quickshow.ai`），绝不落 UserDefaults / plist；Keychain 读取失败输出诊断日志（subsystem `com.dzhang.quickshow.ai`，status 码可按 `log show` 过滤定位）
- 双路热键分流：主面板与 AI 窗双击修饰键独立注册互不抢占；TriggerType 扩为 13 案（4 任意侧 + 8 左右侧专属 + ⌘⇧T，左右交替按下视为打断）；命中集合互斥校验（任意 ⌘ 与左 ⌘ 冲突拒绝、左 ⌘ + 右 ⌘ 可共存）
- 主菜单补标准「编辑」菜单（⌘C/⌘V/⌘X/⌘A 键等效派发链路）；速查表新增 `I` 键条目

### Changed

- 快捷键设置升级：主面板 / AI 窗双路热键分组 Picker（按 ⌘/⌃/⌥/⇧ 四族 × 任意/左/右），冲突时红字即时反馈并保持原配置
- `PanelManager.hidePanel` 增加 `restoreFocus` 参数（AI 窗切换时主面板淡出不归还焦点，由 AI 窗继承同一归还目标）
- 设置页 Base URL 占位文案中性化（`Text(verbatim:)` 禁 Markdown 链接着色，灰色 prompt 与其他字段观感一致）

### Fixed

- AI 输入框粘贴失效：轻量 App 无 Edit 菜单导致文本系统标准编辑键等效缺失——输入框子类显式接住 ⌘V/⌘C/⌘X/⌘A + 主菜单补「编辑」菜单双保险
- 版本号被误回退为 1.0 的事故：本次提交前核对并 bump 至 1.4.0

### Performance

- 流式更新只 mutate 最后一条消息 content（Identifiable 稳定 id + LazyVStack + `.equatable()` 历史行跳过），滚动节流 0.12s，无全列表重排
- AI 窗懒创建（首次唤出才构建 NSHostingView，待机零开销）；关窗无残留 URLSession/定时器，App 待机 CPU 仍为 0.0%

## [1.3.0] - 2026-10-01

### Added

- 日历模块：`G` 键任意状态直达整面板日历视图（一瞥 / 看板均可进入，面板动画展开至日历档；退出按 `G` / `Tab` 平滑回到来源状态；日历态暂停 3 秒自动淡出）
  - 月 / 周 / 日三视图：`1 / 2 / 3` 键切换，`← / →` 翻页（日历态优先翻页，退出后恢复媒体切歌语义）
  - 农历月次与月名、干支纪年 + 生肖（正月初一为年界）、传统节日、24 节气（太阳视黄经天文近似 + 二分迭代反求，分钟级精度，纯本地零依赖）
  - 今日日程列表 + 点击详情 + 一键入会复用（腾讯会议 / Zoom / Google Meet / 飞书）；自建轻量编辑表单（新建 / 编辑 / 删除，EKEventStore 保存，不依赖 EventKitUI）
  - 临近提醒：下一场日程不足 5 分钟时，一瞥态底栏高亮倒计时胶囊（秒级 tick 本地计算）
- PanelContext 统一面板视图路由架构：独立功能 = 独立全面板视图 + 键位注册表 + 来源状态快照恢复，新组件接入仅需 4 处声明；AppState / PanelManager / PanelView 状态机全部迁移到统一管线
- 全局可读性体系：字号阶梯整体上调一档（正文 12pt 体系）；字体族统一为 DesignTokens `text()` / `mono()`（正文 SF Pro、数字时间等宽 SF Mono），Settings 散落字号全部收敛令牌；文本色三档重校（contentSecondaryStrong 0.65 ≈7:1 / contentTertiary 0.55 ≈4.7:1 / idleText 0.45 装饰专用），亮玻璃实测系统 `.secondary` ≈3.9:1、`.tertiary` ≈2.3:1 不达标弃用
- 日历专用字号令牌四档（calendarDay 13.5 semibold / calendarLunar 10 / calendarWeekday 11 / calendarTitle 15）；今日高亮对比 2:1 → 8:1；事件点 3px → 4px 实色

### Changed

- 日历视图占满整个面板：顶栏时钟 / 底栏微标隐藏，垂直空间全给日历（standard 档日程列表区高度约翻倍）
- restart.sh：编译失败不再静默吞错（打印错误摘要与完整日志路径）、自动执行 xcodegen 生成工程（新增源文件即时参与编译）、清理误导性 pnpm 提示

### Fixed

- 编辑表单键盘冲突：文本输入聚焦时全局键拦截放行第一响应者——`G` / `Tab` / `⏎` / 空格 / `1/2/3` 等正常输入不再被劫持，草稿不再静默丢失；ESC 两阶段语义（先结束编辑、再关闭面板）
- `⌘G` 等带修饰键组合不再误触日历切换（contextHotkeys 查表要求修饰键纯净）
- dismiss 后日历网格 / 日程缓存残留导致再次进入首帧闪现旧月份
- exitContext 来源快照缺失防御兜底（避免面板卡死日历态仅剩 ESC）
- 速查表回调重复赋值死代码清理；日历切换胶囊未选中态弃用色改为 contentSecondaryStrong

### Performance

- 日历数据 EventKit 按日查询 + 缓存模型后台队列预生成（进入 / 翻页 / 切换 / 保存 / 跨天触发），秒级 tick 零新增轮询；pinned 常驻时每分钟静默保鲜紧邻日程

## [1.2.0] - 2026-10-01

### Added

- 新建 CHANGELOG.md（Keep a Changelog 风格）并回填全部历史提交；同步修订 AGENTS.md 文档规则：README 只描述稳定产品能力，改动细节统一归档至 CHANGELOG
- Now Playing 媒体微状态：底栏感知任意播放源的当前曲目与来源应用（含 Safari/B 站等网页视频），点击微标激活来源应用；偏好设置可开关
- 媒体控制盲操键：`⏎` 播放/暂停、`←/→` 上一首/下一首、`,`/`.` 后退/快进 15 秒，对全部播放源生效；速查卡片与快捷键设置同步新增
- 展开态媒体卡片：封面、标题/艺术家/来源、进度条与已播/总时长（diff 流 + 封面解码缓存 + 秒级本地插值推进）
- 网络延迟显示：展开态网速卡片新增 TCP 握手延迟（ms），仅面板可见时低频测量
- 世界时钟：展开态日历卡底部 2~3 个可配置时区（设置三槽位，9 城市可选）
- 番茄钟统计：今日完成数与连续天数持久化展示，跨天重置、中断重计，5 分钟短休息不计入
- vendor mediaremote-adapter（BSD-3-Clause：framework + Perl 脚本 + 自检客户端）用于桥接系统 MediaRemote；关于页新增来源声明

### Changed

- 暂停态 Now Playing 由「彻底隐形」改为「弱化显示」（暂停图标 + 半透明），使 `⏎` 可直接恢复播放
- 网络延迟探测由单目标 1.1.1.1 改为四个公共 DNS 并行探测（阿里/腾讯/Cloudflare/Google），取最先握手成功者

### Fixed

- 修复 macOS 15.4+ 上 Now Playing 恒为空的问题：系统 mediaremoted 对第三方进程做私有 entitlement 校验，直接 dlopen MediaRemote 永远返回空字典（macOS 26.5.1 实测确诊：控制中心有数据而 App 拿到空字典）；改用 `/usr/bin/perl`（com.apple.perl 平台身份）加载 vendored adapter 恢复读取，内置 `test` 自检、失败自动降级隐形且不重试
- 修复国内网络下延迟恒显「—」：1.1.1.1:443 常被墙，单目标探测必然失败
- 修复 App 经 SIGTERM（如开发重启脚本 killall）/强退路径退出时 adapter stream 子进程孤儿化残留的问题：启动时按 bundle 内脚本路径自动清理
- 长按 ⌘ 呼出速查表增加防误触：组合修饰键一旦出现立即取消长按判定（939452f）

### Performance

- 双击呼出提速：窗口先上屏，系统状态改为后台异步补齐，显著缩短响应等待（fa63b1d）
- Now Playing 改为 adapter NDJSON 事件流（--debounce=100）：纯事件驱动零轮询，待机不占 CPU；`MRMediaRemoteGetNowPlayingApplicationBundleIdentifier` 符号在 macOS 26 缺失时按父应用 bundleID 反查优雅降级

## [1.1.0]

### Added

- 原生 Liquid Glass 材质体系与「窗口单时钟」展开动效架构（e61c435）
- DesignTokens 主题令牌系统，支持黑曜石/琥珀主题与明暗模式偏好设置（14b553e）
- 原生自适应大聚焦布局与 124pt 主角时钟，重构极致极简状态栏与 Bento 看板（d4515b9）
- 菜单栏图标显隐配置与 macOS 原生侧边栏设置中心重构，新增长按 ⌘ 速查表与快捷键设置模块（0e9c6b0）
- 系统全维度快捷微交互与智能倒计时生命周期，落地黑曜石底边框晶体消散动效，并新增 M 静音、↑↓ 调音量、Wi-Fi 点击复制 IP、A 防休眠、C 释放内存、P 番茄钟、O 打开下载目录、X 剪贴板净化、L 锁屏等快捷操作，Hover 冻结倒计时（08315f5）
- 优化快捷键与 Space 图钉常驻切换，恢复 Tab 监控看板计时，并引入 AGENTS.md 协同工作规范（744c320）
- Wi-Fi 状态与 SSID 解耦，新增硬件频段回退与定位授权支持（4499bdd）
- 以 Bento Grid 重构状态栏与展开面板，实现零截断文案与更精细的间距（42f89f5）
- 新增监控看板展开面板、平滑展开动画与启动预览（624fe26）
- 恢复一瞥倒计时底部微光进度条，由两侧向中间对称收拢（3923b84）

### Fixed

- 修复呼出淡出竞态，取消 ⌘⇧T 默认抢占并将 ps 探测异步化（9b69743）
- 修复电池插电态显示与速查表叠压问题，默认配置改为黑曜石+暗黑（178dfad）
- 支持在悬浮面板激活时通过 ⌘ + , 打开偏好设置、⌘ + Q 退出（c5f4459）
- 配置持久化本地自签名证书以保障 TCC 权限（8c56e69）

### Changed

- 版本对齐 1.1.0，关于页改为读取 bundle 版本（6e6cf60）
- README 预览更新为并排裁切与优化后的展示图（d016e79）

## [1.0.0]

### Added

- QuickShow v1.0.0 初始版本发布（36a5589）

### Changed

- 完善 README 首屏：透明图标、居中布局与展示预览（90af185）