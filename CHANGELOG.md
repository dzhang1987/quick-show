# Changelog

本项目所有显著变更记录于此。格式参考 Keep a Changelog，版本号遵循语义化版本。

## [Unreleased]

### Added

- **输入坞消息排队与中途插入体系完整升级（`QueuedMessagesPanel` / `AIChatState+Queue.swift` / `SettingsStore.swift` / `AIChatInputFields.swift`）**：
  - **全新一体化可折叠排队面板（`QueuedMessagesPanel`）**：彻底替换原有平铺的分散小胶囊，单条排队时直接展示完整卡片，多条排队时自动收拢为占位极简的折叠控制栏（`排队消息 (N) · 将按顺序自动处理`）；
  - **就地独立编辑与一键提权机制**：每条排队消息均独立具备 `[-> 立即插入]`（由追加一键提拔为即时插队干预）、`[✏️ 就地编辑]`（原地展开行内编辑框，保存即生效，绝不回填污染或冲掉主输入框当前草稿）、`[🗑️ 移除]` 能力；
  - **用户偏好配置化与对称快捷键体系**：在 AI 设置面板新增「生成中敲击 Return 键」行为偏好（追加为下一轮任务 / 立即插入当前任务）；确立对称快捷键机制，`Return ⏎` 触发默认偏好，`⌘ Return ⌘⏎` 触发相反动作，`⇧ Return ⇧⏎` 保留软换行；
  - **交互心智与词汇全面去学术化**：彻底淘汰生硬晦涩的“转向”与“追问”术语，全面重构为通俗自然的“**插入**”与“**追加**”；用户消息气泡弱标记同步更名为“中途插入”；
  - **抗透字磨砂实底视觉治理**：将输入坞生长区内的排队面板与并发专家任务监控托盘（`SubagentTaskTray`）统一接入 `Theme.Colors.chatNavFloatFill`（95% 高不透明度磨砂实底）与 `chatStrokeStrong` 边框，彻底消除底层 Markdown 正文文字穿透重叠造成的视觉干扰。

- **聊天区统一自适应限高滚动容器（`AdaptiveScrollBox`）与两档高度阶梯规范（`DesignTokens.swift` / `AIChatLayoutSupport.swift`）**：
  - **两档通用高度阶梯**：在 `Theme.Layout` 确立主交付内容级（`chatBlockMaxHeight = 380`，约 20 行）与次级元信息级（`chatMetaBlockMaxHeight = 180`，约 10 行）两档设计阶梯，统一管理长内容展示；
  - **泛型统一自适应容器**：封装 `AdaptiveScrollBox`，内置内容几何尺寸动态测量；内容低于限高时 shrink-to-fit 精准贴合零留白，超出限高时严格锁死并开启平滑内滚动。

- **大模型供应商多授权方式抽象与行为策略化自治架构（`AIAuthMethod` / `BiometricImportAuthMethod` / `InteractiveBrowserAuthMethod` / `StandardAPIKeyAuthMethod` / `OAuthLoopbackServer`）**：
  - **授权方式一等公民抽象**：将 API Key、Touch ID 本地导入、浏览器外部授权（OAuth PKCE 与 Device Flow）抽象为统一面向接口的协议族，支持单一模型供应商 1 对多聚合多套授权方案；
  - **服务商能力统一聚合（`LLMProvider`）**：由 `LLMProvider` 统一收拢通信推理与所支持的 `supportedAuthMethods` 矩阵，彻底消除此前平行冗余的双轨制映射；
  - **本地轻量级 OAuth 回环服务器与密码学套件（`OAuthLoopbackServer` / `OAuthCrypto`）**：原生实现支持 S256 PKCE 随机校验码生成的本地轻量 HTTP 回环监听与安全回调；
  - **多厂商专属授权策略落地**：包含 Antigravity Google PKCE 与触控 ID 免密导入、Qoder Device Flow 与触控 ID 导入、DashScope 与 OpenAI 环境变量静默探测与存量迁移。

- **并发竞速与混沌压力测试套件（`AgentFunctionalTests.swift`）**：
  - 新增 `Suite 8` 包含 30 轮微秒级极限竞速轰击（0 误杀）、20 任务并发扇出与成果精确比对、超时熔断边界精准判定、10 任务级联中断风暴（零内存悬挂），自动化测试套件总断言数增至 97 项，保持 100% PASS。

- **多智能体并发调度与协作体系（`LaunchSubagentsTool` / `AgentCoordinator` / `AgentTaskRegistry` / `SubagentTaskTray`）**：
  - **原子调度工具收敛（`launch_subagents`）**：收敛旧版分散的 `launch_agent`、`await_agents`、`delegate_to_agent` 三工具为单一批处理并发调度工具 `launch_subagents`，支持编排中枢向多个垂类专家下发专项任务，底层真并发并行执行并一次性归并返回成果；
  - **6 大垂类智能体矩阵与最小权限隔离**：确立编排中枢（Orchestrator）、视觉感知（Observer）、代码专家（Coder）、深度推理（Oracle）、知识检索（Librarian）、系统管家（Concierge）6 大垂类智能体矩阵，实行严格的工具白名单隔离；
  - **本地任务与大产物持久化中枢（`AgentTaskRegistry`）**：建立 `~/.quickshow/agent_tasks.json` 本地持久化注册表，全生命周期跟踪各子任务状态；大产物与分析报告自动隔离写入 `~/.quickshow/artifacts/<sessionId>/<taskId>/` 目录，防止上下文膨胀；
  - **输入框上方浮动任务托盘（`SubagentTaskTray`）**：主 Agent 并发调度期间，在输入坞生长区实时浮动展开各专家的实时活动动效与执行进度（告别假死感），支持一键点击直达对应子会话；
  - **智能 Steering 转向路由引擎（A+B 方案）**：用户在主会话中途追加输入时，支持 `@librarian` / `@coder` 显式前缀或语义自动识别分流，将指令实时穿透注入正在运行的子任务 Tool Loop，并在输入框上方呈现轻反馈通知。

### Changed

- **窗口与卡片全层级圆角系统全面对齐 macOS 系统浮层标准（`DesignTokens.swift` / `AIChatQuickSwitcher.swift`）**：
  - **外框对齐控制中心标准（18pt）**：将 `Theme.Radius.panel` 由 26pt 收敛为 18pt（严格对齐 macOS 控制中心与系统浮窗的连续平滑曲率），消灭过大倒角的臃肿感；
  - **嵌套层级同心圆角平滑递减**：速查表 `cheatSheet` 24 → 16pt，Bento 监控大卡 `card` 16 → 12pt，速查组卡 `groupCard` 12 → 10pt，内层微卡 `insetCard` 10 → 8pt，用户消息气泡 `userBubble` 18 → 14pt；
  - **快速切换器收敛**：`AIChatQuickSwitcher` 移除硬编码 16pt 圆角与样式，接入统一 `GlassSurface` 与 `Theme.Radius.card` 令牌体系。

- **子智能体硬超时熔断上限提升至 5 分钟与长连接对齐（`AgentCoordinator.swift` / `AntigravityCloudCodeAdapter.swift`）**：
  - **强类型策略常量收敛**：定义 `AgentCoordinator.defaultSubagentTimeoutSeconds = 300`（5 分钟），收敛消除分散的裸写魔法数字；
  - **网络长连接对齐**：将 `AntigravityCloudCodeAdapter` SSE 长连接资源的 `timeoutIntervalForResource` 同步由 180 秒提升至 300 秒，为长文本思考、全网深度检索与复杂多轮工具调用留足充裕缓冲。

- **Markdown 列表与表格排版呼吸感精修（`MarkdownListRenderer.swift` / `MarkdownTableView.swift`）**：
  - **列表条目边界强化**：TextKit 文本流路径条目间距 10 → 14pt（原与行距 6pt 仅差 4pt，条目边界视觉上粘连难辨），带子列表的条目间距 6 → 8pt；SwiftUI Widget 路径条目间距 lg(8) → xxl(12)；
  - **表格数据行呼吸感**：数据行垂直内边距 md(6) → xl(10)、表头 md → lg(8)，单元格文本新增 3pt 行距，长文本细节列不再顶格挤压。

- **三大长内容组件统一收敛接入 `AdaptiveScrollBox`（`MarkdownCodeBlock.swift` / `AIToolCardView.swift` / `MarkdownTableView.swift`）**：
  - **代码块（`MarkdownCodeBlock.swift`）**：接入双向自适应滚动，超长代码（如 Rust / Python / Swift 等源码）限制在约 20 行（380pt）内垂直滚动并保留横向长行不折行特性，短代码紧凑贴合，删除内部重复手写的高度测量逻辑；
  - **工具调用结果（`AIToolCardView.swift`）**：`ToolCallResultBlock` 接入自适应容器，彻底消除短 JSON（如 `{"ok":true}`）由于盲目撑满 180pt 产生的 150pt 浅色留白，长结果在 180pt（或展开 260pt）内滚动；
  - **数据表格（`MarkdownTableView.swift`）**：数据行接入自适应容器，短表紧凑无空隙，超长表在 380pt 内滚动并自然呈现表头常驻置顶（Sticky Header）交互。

- **`AIAuthManager` 门面调度与纯数据驱动设置面板（`AIAuthManager.swift` / `AIServiceSettingsForm.swift`）**：
  - 彻底移除 `AIAuthManager` 内部私有字典与硬编码，统一由 `LLMProviderRegistry` 暴露的 `supportedAuthMethods` 动态调度探测与鉴权；
  - 设置界面消灭所有针对厂商类型的 hardcoded 判断，纯数据驱动自适应渲染已绑定卡片、触控 ID 导入按钮、浏览器登录按钮及 API Key 输入框；
  - 全项目 Key 统一收归 `~/Library/Application Support/QuickShow/keys/<name>.key`（POSIX 0600 访问控制），业务配置迁移为专属 json 存储（`providers.json` / `agents.json`）。

- **思考过程卡片全功能 Markdown 排版与流式跟随展示（`AIChatMessageRow.swift` / `DesignTokens.swift`）**：
  - **默认展开与自适应贴合**：思考过程默认展开（约 10 行 180pt 限高滚动区，内容少时自适应贴合不留空，超出时内滚）；落定后保持展开，可随时手动点击收起为单行摘要；
  - **流式输出贴底跟随滚动**：流式生成思考增量时随最新输出实时平滑滚动贴底展示；
  - **专有 ReasoningMarkdownView 渲染**：支持段落、列表、代码块（带语言标签与横向滚动及一键复制）、引用、数学公式、表格等全块级 Markdown 排版，同时屏蔽重型 WebView 预览以降低开销；
  - **隐藏垂直滚动条优化**：关闭限高区域内滚动条显示（`showsIndicators: false`），去除突兀的深灰色滑块，保持内凹卡片轻量精致视觉，同时完整保留手势滚动能力与贴底定位；
  - **优雅视觉分层**：轻量内凹卡片背景、0.5pt 细描边、左侧引导细竖线与 11.5pt 字号次级色阶，层级清晰克制。

- **Qoder Provider 原生工具调用链路打通与流式累积重构（`QoderProvider.swift` / `AIToolRegistry.swift` / `AIServiceSettingsForm.swift`）**：
  - 彻底废除请求体 `"tools": []` 硬编码，根据当前 Agent 授权权限动态序列化 Schema；
  - 适配 Qoder 流式工具分片传输规范，引入 `ChatToolCallAccumulator` 累积分片并在完成时产出完整 `tool_calls`；
  - 偏好设置面板新增“可用工具授权”区域，支持显示各 Agent 授权工具数、一键恢复推荐及逐项开关。

### Fixed

- **彻底根治并发任务胶囊与排队卡片在鼠标悬停时因底色替换诱发的正文透字严重干扰（`SubagentTaskTray.swift` / `AIChatStatusViews.swift`）**：
  - **悬停态透明度劣化根因消除**：彻底废除原组件在 hover 触发时直接将背景实底替换为仅含 10% 不透明度的 `Theme.Colors.iconHoverBg` 的错误逻辑；
  - **双层 100% 物理实底常驻垫底**：为并发子任务胶囊（`SubagentTaskCapsule`）、排队面板（`QueuedMessagesPanel`）及轻提示全线引入 `Color(nsColor: .windowBackgroundColor)` + `Theme.Colors.chatNavFloatFill` 物理阻断层，确保无论静止还是悬停，底层文字透光率严格为 0%；
  - **悬停交互高光解耦**：将 hover 高亮解耦为实底基座之上的微光叠加层与边框提亮（`accent.opacity(0.4)`），既保留灵动的视觉反馈，又彻底隔绝背景穿透。

- **AI 对话窗会话侧栏向左物理抽屉展开与主窗零抖动、零重排、零闪烁架构重构（`AIWindowManager.swift` / `AIChatView.swift` / `AIChatMessageList.swift`）**：
  - **绝对右边缘锚定（Right-Anchored）**：彻底修复旧逻辑在非贴屏幕最右侧时“左缘不动、向右扩展”的缺陷；无论窗口处于屏幕何处，展开与收拢侧栏时窗口的 `maxX` 严格锁定不变，物理 frame 仅向左平滑延伸与向右收缩；
  - **主聊天区强定宽与高优先级保护（Anti-Compression Lock）**：在展开/收拢过渡期间，动态测量并锁定当前主列的实际物理宽度（绝不硬编码任何具体数字，纯动态自适应），彻底消除了 WindowServer 跨进程加宽延迟导致主聊天区被瞬间压窄、随后弹回导致的二次折行与上下抖动；
  - **虚拟化防白屏安全守卫（Ironclad Defense）**：在 `SessionMessageList.updateRowFrames` 建立状态防御壁垒——当因窗口尺寸突变、侧栏过渡导致底层 `ScrollView` 坐标空间单帧重测而异常计算出空集合时，坚决不抹空可见行集合，强制保持上一帧真实可见内容，彻底杜绝所有行突变为空白占位块诱发的白屏；
  - **物理揭示（Hardware-level Reveal）与纯净动效解耦**：过渡期内侧栏保持其自身完整设计宽度，随着窗口左边缘向左物理位移而自然被揭开，避免内部二次尺寸挤压，并移除破坏子树坐标系的动态 `.fixedSize`；
  - **顶栏展开按钮常驻保活与防跳变闪烁**：顶栏左侧展开按钮由 `if !sidebarVisible` 条件插拔重构为常驻视图树，仅以 `opacity` 柔和渐变显隐，彻底根除了由于重新挂载导致 `chatReadingColumn` 在首帧因 `containerWidth == 0` 从 18pt 窄档跳变至 28pt 宽档的全屏闪烁；
  - **收拢动效同步淡出与无感交接**：收起动画触发瞬间，侧栏与微光分割线同步启动平滑淡出与收拢，与 AppKit 0.18s 节奏完全对齐，彻底消除完成回调时的突变切断闪烁。

- **快速会话切换器滚轮误滚动底层会话窗口与全局穿透几何模型重构（`ChatScrollCoordinator.swift` / `AIChatView.swift`）**：
  - **根本性几何收敛**：移除原实现中将阅读列高度偷懒扩大为全窗口高度（`height: contentView.bounds.height`）的粗暴模型，彻底将输入坞滚轮穿透的判定矩形收敛至输入坞底部的真实物理几何区域（`y: 0 ..< dockEffectiveHeight`）；
  - **实测高度动态同频**：在 `AIChatView` 挂载及高度变化时，将输入坞实测高度 `dockTotalHeight` 实时单向同步给 `scrollCoordinator.dockHeight`；
  - **零特化与响应链归权**：彻底消除对特定弹窗的黑名单打补丁逻辑，快速切换面板等中上部悬浮层（y 远在输入坞物理区域之外）天然放行，滚轮事件由其内部 `ScrollView` 原生平滑响应，底层消息列表不再被意外劫持。

- **彻底根治子智能体并发调度取消异常导致任务被误杀为超时失败的缺陷（`AgentCoordinator.swift` / `ChatSessionStore.swift`）**：
  - **竞速取消根因消除**：在 `AgentCoordinator.awaitSingleAgent` 结构化并发 TaskGroup 中，捕获 `Task.sleep` 抛出的 `CancellationError`，杜绝 `try?` 吞咽取消异常导致正常提前完成的子任务被唤醒的超时分支强行覆写为 `.failed` 并展示橙色感叹号；
  - **双重防御性状态守卫**：在超时落定执行分支内判断会话是否已完成（`.completed`），绝不篡改已正常落定的成果；
  - **存量误报数据自动自愈**：在 `ChatSessionStore.load()` 中增加自动纠偏逻辑，自动识别因该缺陷被误判为超时的已完成会话，启动时一键修复为 `.completed`（恢复绿色对勾）。

- **彻底修复落定助手消息中操作栏（复制与重新生成按钮）错误插入正文段落中间错位排版缺陷（`AIChatMessageRow.swift` / `MarkdownCodeBlock.swift`）**：
  - **根本成因根除（First-Principles Root Cause）**：
    1. 跨层级布局脱节：原 `ChatMessageRow` 将 `ChatMessageActionRow` 放在外层 `VStack` 作为 `HStack { content }` 的兄弟视图；由于 `ChatMessageRow` 被 `.equatable()` 包装，当内部 Markdown 块产生异步尺寸变更时，外层 `VStack` 不会重求值，导致操作行滞留在第一帧旧高度处，被后续延伸的列表内容覆盖穿越；
    2. 代码块双阶段异步抖动：`MarkdownCodeBlock` 内部原本无差别挂载通用 `AdaptiveScrollBox`，其首帧测量高度初始化为 0，随后经 `GeometryReader` preference 回调跳变至真实高度（如 117pt → 197pt），诱发内部多次重排与外层布局解耦；
  - **内聚化结构重构（`AIChatMessageRow.swift`）**：
    - 按 `message.role` 原生分流：助手消息彻底消除多余外层包装，将 `actionRow` 直接下沉至 `assistantContent` 局域 `VStack` 尾部紧贴 `assistantTextPart`；在物理视图层级上建立唯一直接父子级契约，确保操作行永远严密跟随正文文尾（或工具卡片底缘），彻底杜绝中间穿越的几何可能性；
  - **代码块首帧同步高度与零抖动优化（`MarkdownCodeBlock.swift`）**：
    - 短代码块（≤18 行，95% 场景）：消除不必要的垂直 `ScrollView` 与异步 preference 测量，首帧采用纯水平滚动容器直接自适应撑开，物理高度首帧 100% 同步确定；
    - 长代码块（>18 行）：首帧直接锁定在 `chatBlockMaxHeight`（380pt）开启双向滚动；彻底消除两阶段高度跃变；
  - **输入坞上方尾部留白减半收敛（`AIChatMessageList.swift`）**：将滚到底时末条消息操作栏距离输入坞顶部的间距由原先过宽的 103pt 收敛减半至约 54pt，消除空洞感的同时确保按钮舒适露出。

- **子智能体工具调用死循环与卡在【思考中...】假死问题（`AgentCoordinator.swift` / `AIProviderService.swift` / 各 Providers）**：
  - **强制收敛总结机制（Force Synthesis）**：将子智能体最大工具调用轮数收敛至 3 轮；当达到轮次上限后，不再无休止调用工具，自动触发强制收敛生成，通过在上下文末尾注入强收敛提示并向底层 Provider 传递 `disableTools: true` 剔除所有工具声明，强迫大模型基于已有搜集到的数据直接撰写完整 Markdown 最终报告；
  - **根除悬挂流式消息（Dangling Streaming Message）**：修复原代码在每轮工具结束后预建空助手消息占位但达到上限跳出时未处理该消息状态的严重 Bug（原逻辑导致其永久停留在 `.streaming`，UI 表现为永远旋转的【思考中...】直到 180 秒超时报错）；增加统一落定兜底，确保退出时任何状态均落地为 `.done` 或 `.failed`。

- **消除主智能体（全能助理 Orchestrator）认为子智能体 Librarian 无法联网的认知幻觉（`AIAgent.swift` / `AIChatState+RequestAssembly.swift` / `LaunchSubagentsTool.swift` / `AIAgentStore.swift`）**：
  - **透出独占工具声明**：在全能助理的子智能体派发指引中，为每个专家显式注入其配备的核心工具清单（如 `[web_search, fetch_url]`），消除大模型盲猜；
  - **人设与 Schema 补全联网专长**：将 `librarian` 人设、Schema 及存量迁移描述明确为“联网资料检索与实时情报专家，专属配备 `web_search` 与 `fetch_url` 工具，负责全网搜索最新行情、新闻与文档”；
  - **协同规则明确派发指引**：在 Orchestrator 提示词中明确指出：编排中枢自身虽未挂载 `web_search`，但遇到实时股票行情、汇率、天气、新闻及公网文档时，必须通过 `launch_subagents` 派发给 `librarian` 代理检索并汇总汇报。

- **Google Antigravity OAuth 客户端凭据解耦与动态多级配置化（`AntigravityOAuthConfig.swift` / `AntigravityCloudCodeAdapter.swift` / `AntigravityOAuthSettingsSection.swift`）**：
  - **彻底拔除源码明文常量**：将 Google OAuth Client ID / Secret 从静态硬编码常量重构为 `AntigravityOAuthConfig` 动态决议策略，彻底根除代码泄露与 Git 远程推送保护拦截；
  - **多级动态配置覆盖**：支持用户自定义偏好设置（UserDefaults）、环境变量（`ANTIGRAVITY_CLIENT_ID` / `ANTIGRAVITY_CLIENT_SECRET`）、本地私有配置文件（`~/.quickshow/antigravity_oauth.json`）及底层无静态特征的安全回退；
  - **偏好设置 UI 交互支持**：在模型服务商设置页中新增“OAuth 高级配置”区域，支持企业与开发者自主绑定自建 Google Cloud 凭据，并支持一键恢复默认。

- **彻底修复 Markdown 嵌套列表在 TextKit 流式排版中换行符丢失导致子项粘连与前导圆点丢失缺陷（`MarkdownListRenderer.swift`）**：
  - **段落隔离与独立排版**：消除原先因误判叶子节点导致子列表末尾丢失换行符 `\n` 的底层缺陷，确保每个列表条目（无论处于第几层嵌套或是否为当前子列表末尾）在 TextKit 中均保留独立的换行符与完整的 `NSParagraphStyle`；
  - **上下文感知精准间距与尾部收敛**：引入 `hasNextListItem` 上下文链，精准识别多层嵌套列表中列表项与后续兄弟分支的连贯性，使大分支间的列表项恢复标准 10pt 留白；仅在整棵列表树的绝对末尾（且后无其他块）时收敛末尾多余换行符，彻底消除前导符被吞及缩进对齐错乱。

- **优化滚动协调器几何真实驱动与命中判定扩展（`ChatScrollCoordinator.swift` / `AIChatMessageList.swift`）**：
  - **扩大滚动命中投影**：将滚轮事件检测区域扩展覆盖输入坞等悬浮覆盖层（Overlay），彻底解决在输入框上方滑动无法滚动消息列表的问题；
  - **几何驱动导航与解开跟随死锁**：浏览导航（刻度轨与回底按钮）显隐完全由物理几何离底距离驱动；当用户客观远离底部时自动同步解除跟随，防止后台生成新 Token 时强制拽回视口。


- **彻底拔除 Keychain 跨应用未授权刺探与“登录钥匙串密码”弹窗骚扰（`AntigravityCloudCodeAdapter.swift` / `AIProviderStore.swift`）**：
  - **切断未授权钥匙串访问**：运行时 100% 仅访问 QuickShow 专属 0600 凭据文件，彻底拔除对系统钥匙串（`service: "gemini"`）及外部私有目录的跨进程刺探；
  - **根除 cdhash 变动弹窗**：解决重新编译后因代码签名哈希变化导致 macOS `securityd` 频繁强制索要系统登录密码的顽疾，实现一次指纹授权即永久静默落盘、重启绝对零打扰。


- **彻底修复 Gemini 模型思考过程提前假闭合截断与思考卡片打字卡顿不贴底缺陷（`GeminiProvider.swift` / `AIChatMessageRow.swift`）**：
  - **思考标签高熵隔离与防假闭合识别（`GeminiProvider.ThinkingStreamParser`）**：将原先易被大模型在元分析（思考系统角色与规则）时口语复述的 `[THINK] ... [/THINK]` 升级为高区分度标记 `<<<BEGIN_THINKING>>>` 与 `<<<END_THINKING>>>`；解析状态机支持动态绑定对应闭合标签并加入行内引用保护，若闭合标签出现在反引号（如 `` `<<<END_THINKING>>>` ``、`` `[/THINK]` ``）或引号中，判定为模型在引用规则而非协议闭合，继续安全保留在思考态中，彻底根除思考内容大面积泄漏进正文区的历史顽疾；
  - **思考组件平滑打字与动态贴底滚动（`ReasoningDisclosureView`）**：将思考卡片渲染节流由 250ms 优化为 80ms，彻底消除原先“一大段一大段蹦出”的卡顿感；在内容超出 180pt 限高进入内部滚动时，增加轻柔平滑滚动动画贴底跟随，确保思考过程随着最新增量顺畅推展。

- **彻底修复 AI Chat 会话选中文本按 `⌘ + C` 无法复制的系统级断链（`AIWindowManager.swift` / `AIChatInputFields.swift` / `MarkdownCodeBlock.swift`）**：
  - **窗口级选区优先复制与事件闭环（`AIPanel.sendEvent` / `copyActiveSelection`）**：解决在 Accessory 窗口与无边框 Panel 下，`sendEvent` 遇到 `firstResponder is NSTextView` 直接放行导致 ⌘C 沦为普通文本按键并被 `keyDown` 静默丢弃的底层缺陷；在 `sendEvent`、`keyDown` 与 `performKeyEquivalent` 三层捕获 `⌘C`，若第一响应者或当前窗口视图树中存在持有非空选区的 `NSTextView` / `SelectionTextField` 节点，毫秒级直接触发拷贝；
  - **输入框盲目拦截解除（`ChatInputNSTextView.performKeyEquivalent`）**：将输入框对 `⌘C` 与 `⌘X` 的消费条件严格限制为 `selectedRange.length > 0`；自身无选区时主动放行给窗口层，杜绝输入框持焦状态下吞噬外部会话划选复制事件；
  - **代码块局部划选复制支持（`MarkdownCodeBlock.swift`）**：为 `CodeBlockText` 正文容器追加 `.textSelection(.enabled)`，支持鼠标自由框选局部代码片段并按 `⌘C` 复制。

- **修复系统通知激活与单实例中继冲突引起的误开一瞥面板（`SingleInstanceGuard.swift` / `QuickShowApp.swift` / `AICompletionNotifier.swift`）**：
  - **通知点击防抖拦截**：记录用户点击通知的时间戳，在通知响应 2.0 秒内阻断由 LaunchServices 伴随拉起次级实例引起的误开一瞥面板；
  - **前台会话状态保护**：当 AI 对话窗口正处于可见状态时，严禁后台盲目广播打断正在进行的会话；
  - **中继安全时延缩短**：将次级实例安全兜底定时器从 0.6 秒优化至 0.25 秒，提升唤醒即时响应体验；
  - **启动阶段预热升级**：在应用启动时尽早预热 `AIProviderStore` 与 `AIAgentStore`，确保存量配置无感平滑升级。

- **修复多智能体协作阻塞死锁与流式停滞假死缺陷（`AgentCoordinator.swift` / `AIChatService+Streaming.swift` / `AIAgentStore.swift`）**：
  - **`awaitAgents` 并发等待与 180s 严格超时熔断**：改用 `withTaskGroup` 并发调度等待所有子任务，彻底消除形参超时未实现的无限挂起死锁问题，超时自动熔断并释放 Continuation 与后台 Task；
  - **流式首帧精准判定与 60s 静默停滞看门狗**：排除首帧纯 `.usage` 导致 Watchdog 提前自杀的误判，仅实质内容（文本/思考/工具）到达时确认首帧，并新增 60 秒传输停滞看门狗，防范远端网络挂起导致的流永久假死；
  - **存量智能体自动合并与中文别名语义路由**：启动时自动比对并补齐存量缺失的 `concierge`（系统管家）角色，并在任务派发中增加对“系统专家/运维/进程”等常见中文别名的精准语义映射，绝对杜绝子任务错误回退至编排中枢自身的递归调度；
  - **级联中止与协作状态协同清理**：主会话取消或 ESC 双击中止时穿透联动取消该会话下属所有运行中的子任务，彻底消除状态残留。
- **修复子智能体流式断流与工具调用丢弃缺陷（`AgentCoordinator.swift`）**：
  - 为子智能体流式执行内核注入完整的 Agentic Tool Loop（多轮 ReAct 回路，上限 6 轮），解决此前收到 `tool_calls` 事件时直接 `break` 忽略、导致工具从未执行且中枢死循环重试 4 次的问题；
- **修复自动化测试套件主线程死锁问题（`QuickShowApp.swift`）**：
  - 命令行测试分支 `--test-agent-suite` 改用 `CFRunLoopRun()` 替代 `semaphore.wait()`，彻底消除主线程与 `@MainActor` 的互锁。

- **东亚注音文本（Ruby Annotation `<ruby>/<rt>`）全生命周期解析与诗词/散文双轨原生排版（`MarkdownAST.swift` / `MarkdownParser+HTML.swift` / `MarkdownRubyView.swift` / `MarkdownInlineNS.swift`）**：
  - **规范级东亚多区域注音解析**：在 `MarkdownParser+HTML` 中完整支持 `<ruby>`、`<rt>`、`<rp>` 标签解析，根据字符集与属性智能识别注音方位（普通话拼音与日文假名置于汉字正上方 `.over`、台湾注音符号 ㄅㄆㄇㄈ 置于字符右侧同行 `.right`、显式 `ruby-position="under"` 置于字符正下方 `.under`）；
  - **诗词对仗等宽网格排版（`PoetryRubyGridView`）**：针对三言至八言古诗律绝（如《静夜思》），建立 38pt 黄金基准列宽网格，拼音与底字严格纵向居中对齐，标点紧随尾字右侧，跨联跨节严密对齐；严格限定单行 3~8 字、无句内停顿逗号且各行字数规整，防止文赋散文误入网格；
  - **散文流式 CoreText 原生排版（`RubyProseRepresentable`）**：针对大段文赋长句与散文混排（如《赤壁赋》），接入 Apple 原生 `CTRubyAnnotation` 流式自然折行；配置 `lineSpacing = 11` 与 `minimumLineHeight = 26` 出版级行距，彻底消除上一行汉字底端对下一行拼音顶部的垂直重叠碰撞，并在视口上下保留安全边距防止声调被边缘截断。

- **Markdown 扩展语法支持：GitHub 风格提示卡片（Alerts）、`<details>/<summary>` 交互折叠块与 `<kbd>` 键盘按键（`MarkdownAST.swift` / `MarkdownParser.swift` / `MarkdownParser+HTML.swift` / `MarkdownBlocks.swift`）**：
  - **GitHub 风格提示卡片（GFM Alerts）**：在 `MarkdownParser` 引用块解析中新增 `parseAlertHeader` 识别首行 `> [!NOTE]` / `> [!TIP]` / `> [!IMPORTANT]` / `> [!WARNING]` / `> [!CAUTION]`（大小写不敏感），剥离标记行后递归解析块级正文；新增 `MarkdownAlertView` 组件，配备五种语义专属配色（蓝 / 绿 / 紫 / 橙 / 红）、SF Symbol 图标、语义标题栏与左侧 3pt 语义色竖条及半透明衬底卡片；
  - **`<details>` / `<summary>` 原生可折叠卡片**：在 `MarkdownParser+HTML` 中新增 `parseDetailsInner` 与 `isDetailsOpen`，自动提取 `<summary>` 行内标题（并剥离冗余手写 `▶`/`▼` 前缀）与内部块级正文，支持 `open` 默认展开属性；新增 `MarkdownDetailsView` 交互卡片，支持点击标题栏平滑旋转 chevron 展开/收起详细内容；
  - **`<kbd>` 键盘按键标签**：将行内 `<kbd>` 从普通 `<code>` 中解耦为独立 `.kbd(String)` token，在 SwiftUI（`MarkdownInline`）与 AppKit（`MarkdownInlineNS`）双路径中统一渲染为加粗等宽键帽样式。

- **离线 Mermaid 矢量图表原生渲染支持（`MermaidBlockView` / `MermaidWebView` / `AIMermaidSettingsSection`）**：
  - **离线单文件运行环境与 WKUserScript 预注入（`MermaidScriptLoader`）**：将精简稳定版 `mermaid.min.js`（升级至 v11.12.0）打包进 App Bundle 资源，通过 `WKUserScript` 在 Document 启动时单例全局注入，彻底规避 WebKit 本地文件跨域沙箱与 `Script error.` 拦截，零外网依赖，毫秒级快速冷启，保持 QuickShow 纯净隐私安全；
  - **内置外观风格（`look`）与主题（`theme`）双入口配置**：支持全局偏好设置面板（`AIMermaidSettingsSection`）与图表卡片 Header 右上角悬停胶囊按钮（与「代码 / 复制」视觉统一，采用原生 `NSMenu.popUp`）随时切换 3 种官方外观（规整 `classic` / 新锐 `neo` / 手绘 `handDrawn`）与 12 套主题（自动毛玻璃、官方经典五色及 Neo / Redux 新生代六色），切换后所有图表卡片实时联动重绘；
  - **无感滚动穿透与事件链（`NonScrollingWKWebView`）**：重写 AppKit 滚轮响应逻辑，将垂直滚轮手势自然透传给外层聊天会话 `NSScrollView`，滚轮划过图表卡片极致顺滑无卡顿，水平滑动手势保留用于超宽图表横向平移；
  - **图表 / 源码 双模切换与复制**：卡片 Header 右上角集成「图表 / 代码」一键切换，默认展示自适应矢量图表，可随时无缝切回等宽高亮源码，并提供一键复制源码及轻反馈；
  - **自适应高度与深浅色无缝融合**：基于双向 JS Bridge 实时测量 SVG 渲染真实高度动态撑开视图，支持 QuickShow 明暗主题联动与透明磨砂卡片质感，消除白屏与底色突兀；
  - **ZStack 双层常驻监听架构与流式容错**：底层 `MermaidWebView` 始终在线监听代码变动，AI 流式输出语法未闭合时平滑呈现上层等宽高亮代码，闭合瞬间无缝切换为矢量图表并动态撑开真实高度；内置 60ms 渲染防抖降低高频打字 CPU 开销。

- **AI 会话混合排版架构与跨文本块连续拖选（`MarkdownTextFlow` / `AssistantMarkdownView`）**：
  - **分段单文本流（Segmented Text Flow）**：将常规连续内容（标题、段落、有序/无序列表）在数据层合并为统一 `AttributedString` 由单个文本组件排版，彻底突破 SwiftUI 原生多 View 嵌套下选区被截断的限制，支持鼠标从正文一路跨越多个列表项及小标题自由连续划选与复制；
  - **富交互岛屿（Widget Islands）100% 完整保留**：代码块（独立语言标签、右上角悬浮复制代码按钮、横向独立滚动、语法高亮）、Markdown 表格、KaTeX 数学公式等富组件保持为独立 SwiftUI 容器，交互与排版不受任何破坏；
  - **视图树性能大幅飞跃**：单条长消息的 SwiftUI View 实例数从 300~800 个锐减 90% 以上，消除长消息首帧挂载布局与快速滚动卡顿。

### Changed

- **多智能体层级导航、任务闭环同步与流式工具首帧预显（`SubagentTopNavBar.swift` / `AgentCoordinator.swift` / `AIChatWireModels.swift` / `AIChatState+Streaming.swift` / `AIChatKeyMonitor.swift` / `ChatSessionStore.swift`）**：
  - **子智能体原生极简顶栏（`SubagentTopNavBar`）**：子会话顶部常驻极简原生导航条，提供返回主会话（`⌘↑`）、当前专家图标与子任务语义短标题，并支持原生下拉菜单在同级专家会话间无缝跳转；
  - **全键盘多维导航系统（`AIChatKeyMonitor` / `AIChatView`）**：支持 `⌘↑`（返回主 Agent）、`⌘↓`（钻入首个子 Agent）、`⌘←` / `⌘→`（同级子 Agent 快速轮切），并在子会话输入框为空时支持 `ESC` 快捷返回主会话；
  - **跨专家协同与成果闭环同步（`AgentCoordinator.syncChildOutputToParent`）**：支持在子会话中通过 `@main` / `@主会话` 或按钮将专家的核心产物与结论沉淀并结构化回传至主协调器，形成完整闭环；
  - **流式工具调用首帧即时预显（`toolCallDispatched`）**：在流式累积器首次捕获到有效工具名称时即刻派发通知，实时挂载 pending 状态卡片（提示“正在组织调度参数…”），彻底消除大模型生成复杂 JSON 参数过程中的界面假死感；
  - **子任务语义短标题智能提取（`ChatSessionStore.summarizeTitle`）**：清洗 Markdown 与“请帮我/搜索一下”等冗余动词前缀，智能切分核心谓宾短语，为同级子任务提炼紧凑高辨识度标题。

- **会话侧栏可拖拽微光分割线与记忆持久化（`AIChatLayoutSupport.swift` / `AIChatSidebarView.swift` / `AIChatView.swift` / `AIWindowManager.swift` / `DesignTokens.swift`）**：
  - **原生 AppKit 事件热区与防抖拖拽（`SidebarDividerHandleNSView`）**：基于原生 `resetCursorRects` 注册水平双向箭头光标（`resizeLeftRight`），精准捕获拖拽手势并支持 160pt ~ 360pt 弹性区间调节，双击立即复位至默认 216pt；
  - **微光羽化分割线视觉表现（`SidebarDivider`）**：采用 0.5pt 两端渐隐微光羽化细线与居中 8pt 交互热区融合，视觉轻盈克制；
  - **侧栏宽度记忆与窗口尺寸平滑联动**：持久化用户自定义的侧栏宽度，展开/收起侧栏时窗口宽度增减自适应对齐当前设定宽度；
  - **侧栏折叠按钮布局对齐**：侧栏顶部新增收起按钮与主区标题栏等高齐平，主区在侧栏收起态下显露展开按钮并严格与阅读列左基准线对齐。

- **Qoder 国际版官方模型全量对齐与动态迁移（`AIProvider.swift` / `QoderProvider.swift` / `AIProviderStore.swift` / `AIAgent.swift` / `AIAgentStore.swift`）**：
  - **18 个全量官方模型 1:1 对齐**：严格对齐当前 `qodercli --list-models` 及官方后端 catalog-v6 目录，补齐 6 个新增模型（`Fast`、`Sonus`、`Cantus`、`Qwen3.8-Flash`、`GLM-5.3`、`GLM-5.3-Flash`）；
  - **清理已下线与过时模型**：彻底下线官方已退役的 `qoder/lite`，升级 `qoder/qmodel_preview` 为正式 `qoder/qmodel_38max`，升级 `Kimi-K2.7-Code` 为 `Kimi-K2.8-Preview`，升级 `qoder/gm51model` (GLM 5.1/5.2) 为 `qoder/gmodel` (GLM-5.3)；
  - **本地持久化平滑热更新**：在 `AIProviderStore.loadProviders()` 与 `AIAgentStore.loadAgents()` 中注入平滑迁移逻辑，自动将用户本地缓存的已废弃 Qoder 模型无感置换为最新版本，避免用户手动清空配置。

- **AI 服务商设置协议只读收敛与模型能力池 Bento 紧凑重构（`AIServiceSettingsForm.swift` / `QuickShowApp.swift`）**：
  - **原生预设协议只读收敛**：针对 Qoder / Antigravity 等原生深度适配的服务商，移除易产生误导的可编辑协议 Picker 下拉框，转为优雅的只读信息展示；通信协议及 API 子协议切换仅在自定义第三方端点（`openAICompatible`）下开放；
  - **模型能力池 Bento 紧凑卡片重构**：彻底废弃此前在 macOS Form 下被粗暴截断标签（`上下文 (to...`）与数十行巨大输入框生硬堆叠的排版，重构为 44pt 紧凑 Bento 条目流；
  - **即点即切能力胶囊与紧凑数值**：模型上下文规格采用紧凑格式化呈现（如 `180K`、`600K`、`1M`）；“视觉看图”与“深度思考”采用交互式高亮胶囊（青色视觉 / 紫色思考），点击即可毫秒级无感切换，免去展开编辑；
  - **能力胶囊文案对齐与防折行加固**：彻底消除狭窄宽度下胶囊内文字被挤成上下两行的排版缺陷；开启与关闭态统一保持恒定 2 字（青色 `视觉` / 弱灰 `视觉`，紫色 `思考` / 弱灰 `思考`），通过 `.fixedSize()` 与 `.layoutPriority(1)` 锁死尺寸优先级，左侧名称自适应省略；
  - **折叠式参数微调抽屉与快捷操作**：卡片右侧集成轻量级上移、下移、删除与展开按钮；点击展开按钮平滑滑出精细编辑抽屉（支持修改底层路由 Key 与精确 Token 阈值），顶部常驻“恢复官方推荐”一键还原能力；
  - **偏好设置窗口黄金尺寸升级**：将设置窗口默认尺寸从偏窄的 `720×500` 适度优化放宽至 macOS 现代标准 `780×540`（最小限制 `720×490`），彻底赋予各设置面板通透的横向呼吸感；
  - **设置面板全局去技术黑话与文案用户化净化（`AIServiceSettingsForm` / `AISettingsSections` / `SettingsGeneralForms` / `SettingsShortcutsForm`）**：
    - 消除顶部选项卡多余的“配置分类”表单标签（`.labelsHidden()`），恢复极简对称；
    - 全面剔除各页面 footer 与字段中混杂的内部架构方案性自嗨描述（如“A+B 多模态调度”、“暴露 Schema”、“0600 权限”、“底层路由 Key”等研发术语），替换为专业、克制、面向真实用户的简洁功能引导。

- **AI 对话新建会话交互与草稿生命周期重构（`ChatSessionStore.swift` / `AIChatState.swift` / `AIChatSidebarView.swift` / `AIChatView.swift`）**：
  - **惰性会话与防重复新建（`newSession`）**：按下 `⌘N` 或点击「新对话」时进入「新会话草稿待命态」，不向会话列表插入条目，不写磁盘文件；若当前已处于草稿态，重复按 `⌘N` 直接保持并重新聚焦输入框，杜绝反复生成无内容空会话；
  - **独立新会话草稿记忆与消费转正**：在草稿态输入内容未发送时切换至其他会话，草稿独立持久化至后台（`newSessionDraft`），再次进入新对话自动恢复；当且仅当发送首条消息时，正式实例化会话并持久化，同时原子清空新会话草稿，彻底杜绝首条消息回写泄露到下一次新会话；
  - **历史遗留空会话自动清理**：启动加载时自动扫描并移除历史残留的无消息主会话，彻底清爽侧栏历史。

- **AI 对话语义标题提炼与截断机制重构（`AIChatState+Notifications.swift` / `AIChatState+Streaming.swift` / `ChatSessionStore.swift`）**：
  - **首条用户输入直击意图**：废除过去必须等待助手回复且拼接大段助修正文的迟钝机制，发送首条消息后立即以用户的提问内容为唯一输入源启动后台轻量摘要请求，单次闭环提炼核心主题；
  - **消除暴力字符截断**：彻底废除写死的 `prefix(12)` 机械字符截断，完整保留模型生成的精炼短句，仅在异常超长时平滑追加省略号；
  - **临时标题语义优化**：临时标题由机械截断前 20 字符优化为优先截取完整第一句，避免词句被拦腰截断。

- **Markdown Mermaid 渲染器前端资源（HTML/CSS/JS）全面独立化与模块化解耦（`QuickShow/Resources/Mermaid/` 与 `MermaidTemplateProvider.swift`）**：
  - **前端资产独立与多语言原生支持**：将原先在 Swift 源码中硬编码定义的近 1300 行前端代码彻底抽离为 4 个独立资源文件，获得完整的 HTML/CSS/JavaScript 语法高亮、Prettier 格式化与独立调试能力：
    - `mermaid_template.html`：HTML 容器骨架与插槽占位；
    - `mermaid_base.css`：容器重置、居中布局与隐藏原生错误指示器的基底样式；
    - `mermaid_normalizer.js`：涵盖 10 余种子图语法的词法预归一化正则管线；
    - `mermaid_bridge.js`：WebKit 消息桥、深浅色毛玻璃对比度样式动态生成与尺寸监听调度；
  - **运行期零额外 I/O 与单例缓存（`MermaidTemplateProvider`）**：将 `MermaidTemplateProvider.swift` 从近 1000 行大幅缩减至 90 行纯装配逻辑，在应用启动/首次调用时从 Bundle 一次性读取并拼装缓存，彻底避免每次卡片渲染重复读盘；
  - **冗余代码清理**：移除中间包装类 `MermaidNormalizerScript.swift`，保持 Swift 源码目录高度纯净。

- **Markdown 渲染系统模块化与面向协议架构重构（`QuickShow/Views/Markdown/` 全链路）**：
  - **开闭原则（OCP）与协议化注册（`MarkdownBlockRenderer` / `MarkdownBlockRegistry`）**：
    - 确立「AST 解析 → 智能排版流切分（TextFlow vs. Widget）→ 注册表动态分发 → 原生 TextKit / SwiftUI 视图」清晰架构流水线；
    - 引入 `MarkdownBlockRenderer` 契约协议（统一调度优先级、排版能力、间距节奏、文本流拼接与组件渲染）与 `MarkdownBlockRegistry` 集中注册表，彻底废除核心视图内庞大的硬编码 `switch-case`，未来扩展新块类型主流程零修改；
  - **千行大文件解耦与职责单一化**：
    - `MermaidWebView.swift`（原 1555 行）彻底解耦为轻量 AppKit 宿主（188 行）、`MermaidModels`（外观/主题配置）、`MermaidScriptLoader`（单例脚本缓存）、`MermaidNormalizerScript`（语法预归一化）与 `MermaidTemplateProvider`（HTML/CSS 模板）；
    - `MathLatexTranspiler.swift`（原 818 行）重构为 Pipeline 流水线（括号平衡匹配、符号清洗、环境转换与列收敛、带参命令重构、流水线宿主），对外保留 `MathLatexTranspiler` 兼容门面；
    - `MarkdownBlocks.swift`（原 475 行）拆解为 12 个单一职责的独立 Renderer 与 View 组件，由门面视图 `MarkdownBlockView`（28 行）统一代理；
    - `MarkdownTextFlow.swift`（原 504 行）拆解为 `MarkdownDisplaySegment`、`MarkdownBlockSegmenter`、`MarkdownTextFlowBuilder` 与 `NativeTextFlowView`，排版流切分完全由渲染器 `capabilities` 契约驱动；
    - 行内渲染拆解为纯 TextKit 路径 `MarkdownInlineNS`、纯 SwiftUI 路径 `MarkdownInline`、统一门面 `MarkdownInlineText` 与 AST 属性检测 `InlineToken+Inspection`。
  - **代码与资产零污染规范落地**：
    - 渲染子系统源码统一收敛至 `QuickShow/Views/Markdown/` 子目录，单文件平均体量控制在 25 ~ 200 行，首帧自适应分批、落定态防抖全量渲染与 TextKit 精密排版 100% 保持零退化；架构设计文档归档至 `docs/MARKDOWN_REFACTOR_DESIGN.md`；
    - 将行内注音与图片组件（`MarkdownRubyView`、`MarkdownImageView`）、表格组件（`MarkdownTableView`）以及数学公式光栅化/缓存体系（`MathRasterizer`、`MathViews`、`AsyncMathBlockView`、`MathLayoutCache`、`MathLatexCollector`）全量物理归位至 `Markdown/` 对应子目录，`QuickShow/Views/` 顶层目录彻底纯净化。

- **单文本流升级为 AppKit 原生 TextKit 宿主架构（`NativeTextFlowView` / `NonScrollingTextView`）**：
  - **TextKit 底层系统级排版穿透**：彻底攻克 SwiftUI `Text(AttributedString)` 静默丢弃 `NSParagraphStyle` 的系统级缺陷，重构为基于原生 `NSTextView` 的 `NativeTextFlowView`；
  - **真·悬挂缩进与两列精密对齐**：完整支持 `headIndent` 悬挂缩进（折行文字垂直对齐至汉字首字）与 `NSTextTab` 制表对齐，彻底消除列表多行折行顶格在标号圆点下方的缺陷；
  - **点级精确间距（消除硬拼空行）**：彻底剔除双换行 `\n\n` 物理空行拼接，段间距统一由 TextKit `paragraphSpacing` 驱动——列表项间距精准 10pt 呼吸留白、正文段落间距 14pt、步出列表 16pt、标题后收紧 8pt；
  - **无感滚动穿透与原生选区链**：重写 `scrollWheel(with:)` 将垂直滚轮自然透传给外层会话 `NSScrollView`，保留 macOS 原生连续多选（跨小标题、段落、多层列表一拖到底）、双击选词、三击整段及原生上下文菜单能力；
  - **`sizeThatFits` 动态测量撑开**：实现 `sizeThatFits` 依提案宽度自适应重排计算真实像素高度，杜绝窗口缩放与流式生成时的布局抖动。

- **Markdown 引用块（Blockquote）竖线与卡片垂直无限拉伸 Bug 根治（`MarkdownBlocks.swift`）**：
  - 针对原实现中左侧竖条使用无高度约束的 `RoundedRectangle` Shape 导致在 SwiftUI 容器中贪婪占用垂直空间、致使文字悬空且卡片底部产生大片虚白的问题，重构为基于文本内容尺寸驱动的 `.overlay(alignment: .leading)`，引述线高度与内容精确 1:1 贴合；
- **Markdown 块级数学公式（Math Block）夸张留白修复（`MathViews.swift`）**：
  - 针对 `MathBlockView` 封装的 `NSImageView` 因缺少 `sizeThatFits` 在垂直方向被分配过多 Proposed Height、导致公式上下各留出数百像素空白的缺陷，重构为纯 SwiftUI `Image(nsImage: raster.image)` 并显式锚定为光栅化实际逻辑点高度，公式恢复紧凑优雅的居中展现；
- **Markdown 图片加载失败卡片排版轻量化与请求头增强（`MarkdownImageView.swift`）**：
  - 移除 `failureView` 强加的通栏 `maxWidth: .infinity`，改为自适应紧凑卡片并补充 `photo` 状态图标，避免在列表项缩进中形成臃肿 Banner；
  - `loadRemote` 补齐现代浏览器标准 `User-Agent` 与 `Accept` 请求头，降低图床防盗链被误拒概率。
- **`⌘ + C` 复制快捷键失效修复（`AIPanel.performKeyEquivalent`）**：
  - 针对 QuickShow 运行于 `NSApp.setActivationPolicy(.accessory)` 下系统不自动派发主菜单 Key Equivalent 的底层机制，在 `AIPanel` 窗口层补齐 `performKeyEquivalent(with:)`；
  - 子视图未消费时自动转交 `NSApp.mainMenu`，并针对 `⌘C`（复制）、`⌘A`（全选）直接向当前响应者链派发 `copy:` / `selectAll:` 动作，彻底解决聊天消息划选后只能依赖右键菜单复制的 P0 痛点。
- **输入坞全区域点击即聚焦光标（Click-to-Focus 兜底）**：
  - 在 `AIChatInputDock` 输入区域添加全框点击手势与 `aiChatRefocusInput` 聚焦通知，点到输入框上下左右任何空白内边距边缘，100% 瞬间激活光标，根除光标难获取与反复点击问题；
  - 消除内层重复挂载 `textSelection` 导致的双重选区层冲突，恢复窗口失焦与聚焦的毫秒级轻量响应。


- Antigravity 官方云端网关原生 HTTP SSE 直连架构（`AntigravityCloudCodeAdapter` / `GeminiProvider` / `AIAuthManager`）：
  - **彻底剥离本地 CLI 5.5 秒冷启动开销**：从第一性原理直连 Google Cloud Code PA 内部服务端点 (`daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse`)，首字上屏时间 (TTFT) 从原来的 10 秒骤降至 1.2~1.8 秒，提速超 5~7 倍；
  - **官方原生结构化思考流承接**：服务端 SSE 事件流直接下发 `candidate.parts.thought == true` 字段，无需任何客户端打标或模型输出的 `[THINK]` 标签清洗，实现纯净且实时的思考流折叠展开卡片；
  - **系统钥匙串 (macOS Keychain) 凭据真源与 401 自动检测自愈**：
    - 优先自 macOS 钥匙串（`svce: "gemini"`, `acct: "antigravity"`）提取活跃 OAuth Token，彻底根除读取静态过期凭据的问题；
    - 结合系统钥匙串后台实时续期机制，当遇到 HTTP 401 时自动重新捕获更新后的最新 Token 并秒级重试，实现零密钥硬编码的纯净直连自愈能力；
  - **服务端模型映射表修正**：精确映射 `gemini-3.8-flash` / `gemini-3.7-flash` 为 `gemini-3.6-flash-high`，映射 `gemini-3.1-pro` 为 `gemini-pro-agent`，杜绝因非法模型参数触发 HTTP 400 INVALID_ARGUMENT；
  - **双轨无缝平滑容错兜底**：直连通道若遇到严重断网等不可抗力，自动无感 fallback 唤起本地 `agy` CLI 进程兜底执行，保证用户体验稳健无故障。

### Fixed

- **大段注音长文排版横向越界爆屏与标点堆叠修复（`MarkdownRubyView.swift`）**：
  - 收紧诗词网格识别判准，单行超过 8 字或包含句内逗号分割的长文赋/散文 100% 自动分流至 CoreText 原生折行；修复标点遍历累加逻辑，彻底根除行末产生 `，，。` 的缺陷。

- **修复 SwiftUI 行内渲染字体覆盖导致加粗/斜体/行内代码失效及 `***粗斜体***` 解析错位（`MarkdownInline.swift` / `MarkdownInlineNS.swift` / `MarkdownParser+Inline.swift`）**：
  - **消除整段 `result.font` 事后覆盖**：重构 `MarkdownInline.render`，改为按叶子 token 上下文（`size` / `baseWeight` / `isBold` / `isItalic`）直接计算并赋予精确字体，解决此前 `result.font = Theme.Typography.text(size)` 抹平 `.code` 等宽字体以及 `.bold`/`.italic` 缺失字重与斜体样式导致引用块、Alert、表格内行内格式失效的问题；
  - **支持三符号 `***text***` / `___text___` 粗斜体语法与 trait 叠加**：在 `MarkdownParser.parseInlines` 中增加 `findClosingTriple` 三符号优先匹配（解析为 `.bold([.italic(...)])`），避免被双符号 `**` 抢先截断留置孤立星号；并在 `MarkdownInlineNS` 的 `.bold` 分支中保留外层已有的 `.italic` 字体特征。

- **Markdown 混合排版与行内公式引发的 AppKit 300 次布局死循环与主线程死机根治（`MarkdownTextFlow.swift` / `MathViews.swift` / `AIChatMessageList.swift` / `MermaidWebView.swift`）**：
  - **排查与根因**：采样与系统日志定证，当会话同时包含单文本流（`NativeTextFlowView`）、行内数学公式（`MathParagraphView`）与多张 Mermaid 图表时，主线程陷入 `-layoutSubtreeIfNeeded has continued for 300 iterations because -updateConstraints and/or -layout has kept the layout or constraints dirty` 死循环，导致 CPU 100% 满载与内存暴涨无响应；
  - **`NativeTextFlowView` 离屏测量与禁止视图自改 `frame`**：将 `NonScrollingTextView.isVerticallyResizable` 设为 `false`，禁止 TextKit 在 `ensureLayout` 期间私自调用 `setFrameSize:` 篡改视图树 `frame` 冒泡标记父级 `NSHostingView` dirty；引入不挂载任何 `NSView` 的纯离屏 TextKit 测量栈（`measureStorage` / `measureLayoutManager` / `measureContainer`）与 `Coordinator` 宽高缓存，确保 `sizeThatFits` 测量全程零视图树副作用、同宽度下 $O(1)$ 命中返回；
  - **`MathParagraphView` 移除布局周期内的约束失效调用**：移除 `updateNSView` 与异步回填 `rebuildFlush` 中触发 AppKit 约束树反复 dirty 的 `field.invalidateIntrinsicContentSize()`（尺寸完全由 `sizeThatFits` 独立负责），并新增输入签名（内容 Hash、深浅色、字号、字重与稳定态）短路守卫与富文本相等性检查；
  - **消除列宽探测与图表高度回调抖动**：将 `AIChatMessageList.updateRowFrames` 的列宽探测从无序字典随机首项 `frames.values.first?.width` 改为确定性的 `frames.values.map(\.width).max()`；在 `MermaidWebView` 接收高度回调处增加 $\ge 1\text{pt}$ 差值守卫，过滤同值重复状态写回。

- **亮色模式下正文文本颜色异常变白根治（`MarkdownInlineNS.swift` / `MarkdownTextFlow.swift`）**：
  - **排查与根因**：排查定位 AppKit 动态语义色（Catalog Color，如 `NSColor.labelColor`）在调用 `.withAlphaComponent(...)` 时会丢失外观动态响应能力并在调用瞬间的暗色上下文下被静态光栅化为固化 sRGB 白色（`RGBA(1, 1, 1, 0.8)`）的底层机制，导致普通正文与列表在亮色模式毛玻璃卡片上呈现为近乎不可见的隐形白字；
  - **动态外观自适应提供器（`adaptiveLabel`）**：封装基于 `NSColor(name: nil, dynamicProvider:)` 的动态颜色构造器，依据当前宿主视图的 `effectiveAppearance` 正确分流深色（白字透明度）与浅色（黑字透明度），使正文与列表项在亮色模式下自然呈现高对比度深色文本；
  - **全链路外观联动与即时重绘**：将行内代码背景色、高亮底色与链接强调色同步升级为动态闭包提供，并在 `NonScrollingTextView` 中重写 `viewDidChangeEffectiveAppearance()`，确保系统或设置切换深浅模式时文字样式毫秒级无缝联动刷新。

- **Mermaid 全量 25+ 种图表语法预归一化、跨主题对比度与渲染尺寸根治（`MermaidWebView.swift` / `mermaid.min.js`）**：
  - **全量图表中文、特殊字符与无引号语法预归一化（`normalizeMermaidSource` + 词法器补齐）**：
    - 排查定位 Mermaid 18 个 Jison 词法器与 7 个 Langium 语法对未加引号文本与语法结构的严苛限制（如 `requirementDiagram` 的 `unqString` 规则显式禁止连字符 `-`，导致 `id: REQ-101` 直接词法报错；`xychart-beta` 未加引号标题含 `%`/`/` 报错且吞空格；`packet-beta` 位段描述、`pie` 切片名、`treemap-beta` 节点名、`erDiagram` 第 4 列注释强制要求双引号；`radar-beta` 强制要求纯 ASCII 标识符；C4 图表中 `Container`/`System` 不允许后接 `{ ... }`，而 `Deployment_Node`/`Node` 强制要求后接非空 `{ ... }` 且不进入可连线形状表 `Yl`；`mindmap` 子节点裸文本以 `mindmap` 开头时被规则 1 抢先误判为图表头关键字）；
    - 从 `mermaid.min.js` 词法器底层扩充 `\u0080-\uFFFF` Unicode 范围，并在 `MermaidWebView` 渲染前引入无损语法预归一化层 `normalizeMermaidSource`，自动为 `requirementDiagram`、`xychart-beta`、`packet-beta`、`radar-beta`、`erDiagram`、`pie`、`gitGraph`、`treemap-beta` 中未加引号的属性值、标题、注释及中文维度补齐双引号或合法 ID 映射；针对 C4 系列图表自动将后接 `{` 的 `Container`/`System` 映射为对应 `*_Boundary`、将不带 `{ ... }` 的叶子级 `Deployment_Node`/`Node` 归正为可被 `Rel` 连线的 `Container` 叶子形状；针对 `mindmap` 以 `mindmap\b` 开头的缩进子节点注入零宽空格 `\u200B` 避开关键字抢占并保留原生无框样式；
  - **全量 25+ 种图表暗黑/亮色 × 3 种外观 × 12 套主题对比度统一治理（`initMermaid` / `updateCanvasContrastCSS`）**：
    - 排查定位当传入 `background: 'transparent'` 时，Mermaid 内部 `invert('transparent')` 会计算出 `rgba(255, 255, 255, 0)` 全透明色并赋给 `lineColor` / `relationColor` / `transitionColor`，导致所有连线隐形；彻底移除 `background: 'transparent'` 并显式接管跨主题画布连线与文字色值；
    - 建立双层 CSS 与 `themeVariables` 对比度保护体系：针对 `mindmap`（脑图暗色节点与分支连线）、`c4`（硬编码 `#444444` 关系线与浅灰外部系统块）、`gitGraph`（翻转标签底色与 `cScaleLabel`）、`sankey-beta`（`mix-blend-mode: multiply` 连线消失与 SVG `<text>` 缺少 `fill`）、`architecture-beta`、`kanban`、`block-beta`、`packet-beta`、`treeView-beta`、`radar-beta`、`xychart-beta`、`quadrantChart`、`timeline`、`gantt`、`journey`、`pie` 等全部图表消除暗色画布黑字/黑线与亮色节点白字问题；
    - 针对 `handDrawn`（Rough.js 手绘斜线填充 `fill="none"`）在暗色毛玻璃画布搭配浅色主题时透出暗底导致深色字模糊的问题，在 `normalizeDiagram` 中为手绘闭合边框路径注入 `0.82` 同色系半透明实心衬底，兼顾手绘质感与文字锐利度；
  - **`ResizeObserver` 实时高度同步（根治 `erDiagram` 等图表底部截断）**：解决原实现仅在 `mermaid.render` 完成单帧测量一次 `svgEl.getBoundingClientRect().height` 且漏算 `#container` 上下 12px 内边距的缺陷——当容器首帧处于较窄宽度完成测量后展开至完整宽度时，内部 `<svg width="100%">` 等比放大而外层 SwiftUI `renderedHeight` 锁死在旧高度导致底部节点被裁切；引入 `ResizeObserver` 监听 `document.body`、`#container` 与 `<svg>` 实时上报精确容器高度，并在 `clientWidth < 10` 时延后至布局就绪再渲染；
  - **根治用户旅程图（`journey`）与 C4 架构图（`c4`）巨幅留白与标题偏置**：在 `normalizeDiagram` 中将 C4 顶层标题相对图形实际几何中心居中归位，并依据 `getBBox()` 实际几何边界收紧 `journey` 与 `c4` 的 `viewBox`、移除硬编码 `height` 属性，使其严格按真实宽高比紧凑展示；
  - **消除小图暴力放大畸变**：彻底移除 Web 模板中 `svg { max-width: 100% !important; }` 的破坏性样式覆盖，恢复 Mermaid 原生内联 `style="max-width: 自然宽"` 保护，彻底解决流程图（`flowchart TB`）、方块图（`block-beta`）、实体关系图（`erDiagram`）等窄图被强行拉扯放大 2~4 倍且高度暴增至数千像素的严重缺陷；
  - **根治时序图（`sequenceDiagram`）泳道竖线穿刺顶部参与者方框**：排查定位 Mermaid 底层生命线起笔于顶部方框内 `y=5` 处、依赖不透明实色背景遮盖的历史实现缺陷；在 SVG 渲染流水线中新增几何规范化裁剪（`normalizeDiagram`），自动将垂直生命线起点截断在顶部参与者底边（$bottomY = y + height$），即使在 macOS 深度毛玻璃半透明体系下亦能呈现规整干净的专业时序图；
  - **根治实体关系图（`erDiagram`）鱼尾终端点闭合树叶畸变与穿透遮挡表头**：排查定位 Mermaid 原生将 `ONE_OR_MORE`（`|{`）与 `ZERO_OR_MORE`（`o{`）四个 `<marker>` 绘制为闭合树叶曲线并将 `refX` 设在中心点、导致后半截 18px 曲线深入实体框内部且依赖不透明背景遮挡的缺陷；将 `mermaid.min.js` 中的鱼尾 `<marker>` 路径重构为标准开放式三叉曲线，并在 `normalizeDiagram` 中通过 `userSpaceOnUse` 坐标系 `<mask>` 将所有 `rect.er.entityBox` 实体矩形内部从 `path.er.relationshipLine` 图层中精准镂空，确保任意角度入射的鱼尾三叉严丝合缝止步于实体框外边缘。

- **多轮历史上下文角色严格归一化合并（根治 MALFORMED_FUNCTION_CALL 断流）**：
  - 排查定位多轮对话中若存在截断产生的空回复，会导致 `contents` 中产生连续的 `user` 角色，触发 Google Gemini 服务端上下文状态机崩溃并报 `MALFORMED_FUNCTION_CALL`，导致正文输出为空并被提前掐断；
  - 引入连续相同角色 `parts` 自动合并与首轮 `user` 校验机制，确保上下文绝对合规，彻底根除思考后正文丢失断流的问题。
- **SSE 流式数据块空行防御性跳过**：
  - 修正原 `guard !rawJSON.isEmpty, rawJSON != "[DONE]" else { break }` 误将 SSE 心跳空行当做结束标志 break 的严重逻辑缺陷，仅在明确收到 `[DONE]` 时退出，空行正常 continue 等待，杜绝流式提前截断。
- **直连网络通道专用隔离**：
  - 建立专用的 `directSession`，独立管理连接池与请求超时，杜绝与系统全局会话的连接复用冲突。

- 触控 ID (Touch ID) 优先的生物识别本机静默导入体系（`AIAuthManager` / `AIServiceSettingsForm`）：
  - **原生 Touch ID 授权闭环**：接入 Apple 原生 `LocalAuthentication` 框架，点击「触控 ID 导入」优先唤起系统生物识别面板（呼吸灯与指纹提示），轻触指纹秒级通过验证，无 Touch ID 设备自动优雅降级为系统解锁密码，彻底消除每次输入钥匙串密码的繁琐体验；
  - **真正的零浏览器静默导入**：彻底切断导入流程中回退唤起网页浏览器的逻辑，全程在 macOS 系统安全与原生 UI 闭环完成，不再产生“导入账号却弹浏览器”的体验割裂；
  - **Antigravity 原生 CLI 流式驱动引擎（`GeminiProvider` / `AIProvider` / `AIProviderStore`）**：
    - 针对 Antigravity 本机凭据与 Google OAuth 架构，引入基于原生 Antigravity CLI (`agy`) 的子进程流式交互引擎，直接利用本地已登录凭据与官方网关通道，彻底解决传统 Google AI Studio 端点 (`generativelanguage.googleapis.com`) 报 `HTTP 401 / Scope 不足` 的致命缺陷；
    - 基于异步 NDJSON 流解析器提取 `step_update.text_delta` 与 `usage.input_tokens`，实现毫秒级流式打字机吐字与上下文感知；
    - **启动与工作空间轻量化**：自动指派临时专用独立沙箱工作空间，配合 `--disable-slash-commands` 与 `PYTHONUNBUFFERED`，彻底杜绝 CLI 扫描用户主目录大量文件和 git 历史的开销；
    - **Pro 会员全套官方旗舰模型矩阵升级**：全面接入官方支持的 Pro 会员核心模型（`gemini-3.1-pro-high`、`claude-sonnet-4-6`、`claude-opus-4-6-thinking`、`gemini-3.8-flash-high`、`gemini-3.8-flash-medium`、`gpt-oss-120b-medium` 等），并在 `loadProviders` 时自动补齐同步；
    - 双轨平滑兼容：若用户手动输入传统 Google AI Studio API Key (`AIzaSy...`) 则无缝 fallback 到云端 HTTP 直连。
  - **Antigravity 本机凭据深度感知**：直接探测并读取 `~/.gemini/jetski-standalone-oauth-token`，解析 OAuth Access Token (`ya29...`)、Refresh Token 与从 JWT/本地账号配置解析的真实邮箱，指纹确认后无感注入与持久化；
  - **Qoder 本机凭据与 UID 联动**：自动感知 Qoder CLI / 客户端全局状态与本地已有 Device Token，指纹确认后一键完成真实 UID 绑定与就绪激活；
  - **UI 职责与操作边界清晰化**：设置面板按钮直观区分「🌐 浏览器登录授权」与「触控 ID 导入」，状态卡片标明「触控 ID 导入」身份来源，取消或失败即地清晰提示，操作边界彻底清晰。
- Qoder 与 Antigravity 三模认证与无感授权体系（`AIAuthManager` / `OAuthLoopbackServer` / `AIProviderStore` / `AIServiceSettingsForm`）：
  - **三位一体认证架构**：同时支持「① 直接填入 API Key / PAT 凭据」、「② 自动探测并导入本机已登录账号」、「③ 网页端浏览器登录授权」，彻底消除手动复制长串密钥的心智负担；
  - **Qoder 官方 Device Flow 浏览器授权**：纯原生 Swift 实现基于官方 Device Flow（S256 PKCE + Nonce + Machine ID）的浏览器授权通道，打开 `qoder.com/device/selectAccounts` 并在后台异步轮询 `deviceToken/poll`，用户在网页端点击确认后自动回传 Token 并换取用户信息完成绑定，无本地端口依赖，零代理/TUN模式冲突；
  - **Google OAuth 2.0 PKCE 桌面端流（Antigravity）**：使用 Apple 原生 `Network.framework` 的 `NWListener` 监听临时本地回环随机端口，生成高熵 S256 PKCE 凭据，唤起系统默认浏览器完成 Google 账号登录授权，捕获回调后自动换取 Access Token 与 Refresh Token，展示原生美观的授权成功 HTML 反馈页并即时销毁监听器；
  - **本机凭据智能感知与一键导入**：自动探测 Mac 本机已安装并登录的 `qodercli`（解析 `status -o json` 用户名与邮箱）、本机环境变量 `GEMINI_API_KEY` / `GOOGLE_API_KEY` 及 `gcloud` 账号，检测到即在界面高亮提供一键导入；
  - **偏好设置授权卡片与生命周期管理**：提供已授权账号卡片（展示用户名、邮箱、授权来源标签与退出登录操作），未授权态支持进度加载提示与随时取消，保留折叠/就地手动输入框作为高级自定义中转兜底。
- 大模型多供应商原生驱动与统一 Provider 架构（`LLMProvider` / `LLMProviderRegistry` / `OpenAIProvider` / `QoderProvider` / `GeminiProvider`）：
  - **统一行业标准协议分层**：基于行业通用 Provider + Model 第一性原理，抽象 `protocol LLMProvider` 通用能力接口与 `LLMProviderRegistry` 动态分发总线，业务调用层彻底消除巨型分支；
  - **Qoder 国际版原生网关纯原生接入**：纯原生 Swift 完整实现 PAT 换取短效 JobToken、动态 UserInfo 查询与 COSY 签名请求头（RSA PKCS1 报文加密 + MD5 校验 + AES-128-CBC 对称加密 + 自定义 Base64 字典重排与块置换），预设官方 14 款模型，彻底摆脱外部桥接依赖；
  - **Google Gemini / Antigravity 原生协议适配**：原生支持 Gemini 图文 payload 组装与 SSE 流式事件解析；
  - **OpenAI 兼容端点双协议支持**：支持 OpenAI 官方、阿里云百炼、DeepSeek、Ollama 等端点的 Chat Completions 与 Responses 双协议。
- 多智能体团队协作与中枢编排体系（`AIAgentStore` / `DelegateToAgentTool` / `oh-my-opencode-slim` 模式）：
  - **预设多智能体团队**：内置通用助手（Generalist，编排中枢）、系统架构师（Architect）、全能工程师（Engineer）、感知观察者（Observer，视觉担当）、快速探索者（Explorer）等专业角色，每个智能体具备独立专属 Provider、模型绑定、提示词人设与思考档位；
  - **多智能体异步并发调度与任务总线（`AgentCoordinator` / `LaunchAgentTool` / `AwaitAgentsTool`）**：
    - 引入基于 Swift Concurrency 的后台调度中枢 `AgentCoordinator`，支持中枢通过 `launch_agent` 默认异步并发启动多个子智能体，立即返回 `task_id` 并在后台独立流式会话中并行执行，彻底消除串行阻塞；
    - 引入 `await_agents(task_ids)` 工具，支持在后续规划依赖子任务产出时原子挂起并同步聚合等待多个子智能体成果；
  - **全连接智能体间点对点通信（`SendMessageTool`）**：所有智能体相互之间均可调用 `send_message` 进行点对点直接通信、跨领域咨询或中间数据移交，无需中枢二次传话；
  - **独立子会话与侧边栏树状缩进切换（`ChatSessionStore` / `AIChatSidebarView` / `AIToolCardView`）**：
    - 每次委派均自动创建具有 `parentSessionId` 关联的独立持久化会话，主会话保持聚焦不跳转；
    - 侧边栏主会话支持折叠/展开，展开后以树状层级缩进展示所有子会话（呈现拐角连接线、智能体专属图标、呼吸中/完成/失败状态指示）；
    - 工具调用卡片提供 `[查看子会话 ↗]` 快捷按钮，支持一键切换至对应子会话查看完整流式生成；
  - **全模态媒体协议扩展（`ChatAttachment` / `AttachmentKind`）**：淘汰单一特化的 `include_images` 参数，全面升级为通用的 `include_attachments`（双向兼容），媒体容器抽象为通用的 `ChatAttachment`（涵盖图片、音频、视频、文档），为未来全模态扩展奠定统一底座；
  - **子智能体中枢委派工具（`delegate_to_agent`）**：保留一键复合委派工具，自动创建子会话并同步等待结果回传；
  - **多模态视觉感知自动接力**：当用户向不支持视觉的纯文本/代码模型发送图片时，视觉担当（Observer）自动先行提取图片结构化要素（OCR、布局、报错信息）并接力注入上下文，纯文本模型无需改动即可精准回答图片内容；
  - **输入坞智能体与模型矩阵切换**（`AIChatInputDock`）：输入坞常驻 Chip 升级为「智能体团队」➔「所属模型池」➔「思考强度」三级上下文菜单，并直观标注视觉专长（👁️）；
  - **偏好设置智能体管理面板**（`AIServiceSettingsForm`）：提供可视化智能体团队增删改查、跨 Provider/模型自由指派与视觉担当开关。

- 居中快速会话切换与全局搜索面板（Quick Switcher，`⌘P` / 侧栏收起时 `⌘F`，`AIChatQuickSwitcher` / `ChatSessionStore` / `AIChatKeyMonitor` / `AIChatLayoutSupport`）：
  - **即搜即切**：无需展开 216pt 侧边栏，按 `⌘P` 随时在对话框正上方唤出居中悬浮切换面板，支持实时全文检索标题与历史消息上下文摘要片段；
  - **全键盘流畅盲操**：支持 `↑` / `↓` / `Tab` / `Shift+Tab` 列表循环导航，`⏎` 回车切入对应会话；空搜索态默认预选次近会话，连敲即切；
  - **高亮会话快捷删除**：选中任意会话按 `⌃D` (Ctrl + D) 或 `⌘⌫` 直接删除会话，自动校正选中项并保持平滑滚动。
- 统一 ESC 响应者栈协调架构（`EscapePolicyCenter` / `EscapeRespondable` / `AIChatView` / `AIChatKeyMonitor`）：
  - **纯 LIFO 栈模型（栈底为 Chat 窗口）**：彻底拔除各处堆叠的硬编码 if-else 分支，将 Chat 主窗口登记为永久栈底，所有上层组件（快速切换面板、图片放大、就地编辑、行内重命名、交互抽屉）通过声明式修饰符 `.escapeResponder` 动态入栈/出栈；
  - **彻底消除穿透关窗**：ESC 统一由栈顶优先消费；仅当所有上层组件完全退栈、栈顶回落至根窗口时，才触发关窗或中止生成；
  - **模态输入阻断**：提供 `isModalActive` 守卫，模态浮层在场时输入坞底层严格阻断按键与制表符派发，根治 `Tab` 切换列表导致输入坞键入制表符的问题。

- AI 交互抽屉（`ask_user` 提问与危险工具授权）后台时效性系统通知与全生命周期自愈（`AICompletionNotifier` / `ChatInteractionCenter` / `AIWindowManager`）：
  - **交互挂起后台提醒**：AI 在执行 `ask_user` 或危险工具授权等交互工具时，若检测到 AI 对话窗处于非前台活跃状态（未钉住隐藏或失焦），立即向系统派发 `.timeSensitive` 时效性系统通知（含问题题干/操作摘要及提示音），解决用户切到其他应用后因不知晓 AI 提问而导致流程死锁卡住的问题；
  - **窗口失焦自动补发**：当交互抽屉弹出时窗口虽在前台、但用户随后切走至其他应用（`onResignKey`）时，自动补发后台待办通知；
  - **一键直达与状态自愈**：用户点击通知横幅立即平滑唤出 AI 窗口并切至对应会话，抽屉即刻处于就绪交互态；当用户在抽屉中完成作答提交、确认授权或取消抽屉后，自动从系统通知中心撤销对应待办通知，保持通知中心清爽。

- AI 对话 ESC 终止大模型响应二次确认守卫与分层状态机（Double-ESC Guard 与方案 B 抽屉协同急停，`AIChatState` / `AIWindowManager` / `AIChatKeyMonitor` / `AIChatView`）：
  - **分层优先级状态机**：严格确立 P0 输入法组字放行 → P1 图片放大覆盖层关闭 → P2 消息就地编辑退出 → P3 侧栏标题重命名退出 → P4 交互抽屉在场取消 → P5 纯流式双击急停守卫 → P6 空闲关窗还焦点的确定性链路；
  - **抽屉协同急停（方案 B）**：在交互抽屉（`ask_user` / 权限确认）在场时按 ESC，立即安全拒绝/取消抽屉并连带彻底中止大模型本次流式生成，回填待注入队列，消息落定为 `.aborted`，窗口稳稳保持打开；
  - **抑制期防穿透断路器**：抽屉取消后原子开启 0.5 秒抑制保护期（`suppressAbortConfirmationUntil`），流式生成退出期或抑制期内任何按键事件由系统静默消费吸收，彻底消除了由于异步取消间隙导致的「误弹二次确认 Toast」或「意外关闭隐藏窗口」两大严重体验问题；
  - **GCD 代次令牌调度与全生命周期保洁**：废除依赖 RunLoop 模式易假死的 `Timer`，改用全生命周期安全的 `DispatchQueue.main.asyncAfter` + 自增代次令牌（`abortConfirmationGeneration`），保证 1.5 秒必定准时自动淡出；在窗口隐藏（`performHide`）、重新展示（`show`）、视图卸载（`onDisappear`）、流式收尾（`finishStream`）、切换/清空会话中全方位清除残留状态，开窗绝无幽灵悬挂。
- 消息就地编辑态全局状态提升（`AIChatState.editingMessageId` / `ChatMessageRow` / `ChatMessageList`）：将原消息行内私有 `@State` 编辑态提升至全局，使窗口层与本地按键监听能够在编辑气泡在场时准确捕获 ESC 并优先退出编辑态，避免按键穿透误触关窗。
- 完整国际化（简体中文源语言 + English，界面语言跟随系统自动切换）：新建 String Catalog（`Localizable.xcstrings`，582 条 key，zh-Hans 源 / en 翻译，经 project.yml `developmentLanguage: zh-Hans` 声明，构建产物生成 `zh-Hans.lproj` / `en.lproj`）——SwiftUI 字面量（`Text`/`Label` 等 ~271 处）经 `LocalizedStringKey` 零代码改动自动查找 catalog；dynamic 类（三元表达式、枚举 `displayName`、自定义视图 String 参数）与 AppKit 类（`NSMenuItem`/`NSMenu`/toast/`panel.title` 等共 ~360 处、约 50 个文件，4 条并行 lane 改造）显式包裹 `String(localized:)`，插值文案经编译器格式串机制（`%lld`/`%@`）与 catalog 逐条对账；`Text(verbatim:)` 2 处改 `String(localized:)` 恢复本地化。范围决策（用户确认）：AI 工具 displayName / 类别 / 地图卡文案（UI 可见）翻译；发给 LLM 的工具 description / JSON schema / 系统提示词 / 工具执行错误（~180 处）与农历 / 天干地支 / 节气数据表保持中文；语言策略为跟随系统（无应用内切换）
- 输入框撤销 / 重做支持（AI 窗主输入框与就地编辑框，快捷键 `⌘Z` / `⇧⌘Z`）：主菜单 Edit 菜单补入「撤销 / 重做」菜单项——`allowsUndo` 虽一直开启，但 AppKit 文本系统的 ⌘Z 键等效派发依赖主菜单存在对应 keyEquivalent 的菜单项，缺失即死键（与早年 ⌘V 粘贴失效同因）；`ChatInputNSTextView.performKeyEquivalent` 与 ⌘V/⌘C 同模式显式接住 ⌘Z/⇧⌘Z 双保险（`canUndo` / `canRedo` 为 false 时不消费、放行给系统）；就地编辑框（`ChatInlineEditTextView`）补上遗漏的 `allowsUndo = true`，与主输入框共享同一 NSTextView 子类的快捷键处理

### Removed

- 剪贴板附加上下文功能整链移除（用户决策：真实 agent 产品无此交互惯例，附加文本作提问背景的场景由直接粘贴进输入框覆盖）：
  - **数据层**（`AIChatState` 及其 extensions）：`clipboardAttachment` 状态、`attachClipboard()` / `removeClipboardAttachment()`、8000 字符截断上限（`clipboardLimit`）、`composeUserContent(input:clipboard:)` 的 `<<<剪贴板开始/结束>>>` 拼接协议；`send()` / `enqueueSteering()` / `editAndResendLast()` / `clearDraft()` 中的剪贴板参与与清空同步移除（发送门控判据回归「文本或图片」）
  - **UI 层**：输入坞剪贴板附加钮（低频工具组中「剪贴板」一枚）、生长区「已附加剪贴板 N 字」胶囊（`ClipboardAttachmentCapsule` 整组件删除）、空态欢迎页「附加剪贴板内容」快捷入口（`WelcomeView` 瘦身为纯引导页）；`AIChatView` 的 `hasClipboardText` 状态与 `attachClipboard()` 出口删除，`refreshClipboardAvailability` 收敛为仅刷新图片可用态（hover / 窗口激活刷新路径保留，继续服务 ⊕ 菜单「剪贴板导入」可用态）
  - **保留项**（与「作为上下文」无关的剪贴板能力）：⌘V 粘贴图片 / ⊕ 菜单「剪贴板导入」图片附件、`X` 键剪贴板纯文本化、AI 工具 `read_clipboard` / `write_clipboard`（LLM 主动调用语义，非上下文注入）、复制消息 / 导出对话到剪贴板

### Changed

- Antigravity 模型列表纯净化与思考强度正交收敛（`AIProvider` / `AIProviderStore` / `GeminiProvider`）：
  - **模型列表纯净化**：彻底移除模型选择下拉菜单中冗余的思考强度后缀项（`-high`、`-medium`、`-low`、`-thinking`），模型列表仅展示标准清晰的模型本体（Gemini 3.1 Pro、Gemini 3.8 Flash、Gemini 3.7 Flash、Claude Opus 4.6、Claude Sonnet 4.6、GPT-OSS 120B）；
  - **思考强度正交映射**：思考档位由输入坞生成 chip 统一调度，底层根据用户选取的档位（Low / Medium / High / Off）动态映射至官方合规的后缀模型（如 Gemini 3.8 Flash + Low 映射至 `gemini-3.8-flash-low`，High 映射至 `gemini-3.8-flash-high`），并彻底移除命令行 `--effort` 参数，彻底根除 `conflicts with --effort=low` 等参数冲突崩溃；
  - **旧数据自动去重迁移**：`AIProviderStore.loadProviders` 启动时自动探测并清洗旧配置中带旧后缀的冗余模型，保持列表纯净。
- 快速会话切换器（Quick Switcher）视觉质感重塑与加权搜索相关性升级（`AIChatQuickSwitcher` / `ChatSessionStore` / `AIChatView`）：
  - **通透毛玻璃体与顶级光影重构**：废除 95% 不透明度的硬质底板（`chatNavFloatFill`），全面接入原生 `.regularMaterial` 磨砂玻璃体搭配柔光底层（`surfaceCard`），使底层聊天内容自然呈现优雅的景深模糊与高光折射；外框升级为 Directional Rim Light（顶部微白受光边、侧边微弱边、底部阴影重边）与双层立体阴影（贴身接触影 8pt + 纵深漫反射环境影 32pt），彻底消除实色塑料廉价感；
  - **结构去切片化与轻盈 Footer（方案 A）**：移除粗暴分割线，改用两端对称羽化渐隐的微光光线；剥离底部按键提示条沉重的全幅灰底，将其转为与面板底板浑然一体的轻巧微胶囊提示；调优遮罩层为轻透的 0.12 不透明度；
  - **黄金比例收敛（对齐输入坞最小宽度）**：弹窗宽度由 476pt 收敛至 410pt，精准对齐输入坞基准最小宽度（404~410pt），彻底消除弹窗比底座输入坞还宽的视觉倒挂，两侧留出充足的透光呼吸边，悬浮层次更为小巧协调；
  - **消息文本纯净化（Markdown 标记剥离）**：新增 `cleanPlainText` 纯文本清洗管线，在会话列表预览与引文摘要中自动滤除标题井号、粗斜体星号、任务复选框、表格线、代码反引号等原始语法符号，呈现自然流畅的人类自然语言正文；
  - **相关性梯度加权排序**：重构会话检索算法，建立「标题完全匹配 (100) / 前缀命中 (80) > 标题包含 (60) > 正文命中 (30)」加权评分模型，彻底终结单纯按时间倒序导致正文偶发词压过标题精准命中的反直觉问题；同梯队内部按活跃时间倒序；
  - **检索关键词视觉高亮**：对标题与正文引文切片中命中的关键词应用 Accent 强调色与 Semibold 加粗渲染，命中点清晰醒目。
- 阅读列边距收敛（`DesignTokens.swift` / `AIChatLayoutSupport.swift`）：退役 `chatTickRailLane` 额外内缩（归零），刻度轨（10~19pt）完全容纳于标准 18pt 边距内，消除双侧额外 28pt 对称留白，使对话流内容列与输入坞自然舒展。
- 文档体系净化与持久规则明确（`README.md` / `AGENTS.md`）：系统性净化 README.md，剥离内部架构机制与微观 UI 瞬态描述，修正历史滞后的 API Key 存储与构建路径说明，收敛代码结构树为稳定模块概览；于 AGENTS.md 确立 README 极度克制更新红线与 CHANGELOG 严格分工。
- 构建产物目录收敛为统一单根 `./build`（`scripts/restart.sh` / `AGENTS.md`）：废弃并移除历史冗余的 `./build_release` 根目录，构建中间数据与 Release 最终产物统一收敛至 `./build`（Release 产物位于 `./build/Build/Products/Release/QuickShow.app`），彻底消除多根目录导致的磁盘缓存冗余以及 macOS LaunchServices 扫描多路径注册冲突。

### Fixed

- Antigravity 思考流正文 `[/THINK]` 标签残留泄露与流式状态机容错（`GeminiProvider` / `AIChatState+Streaming`）：
  - **正文流式标签自洁**：流式状态机 `ThinkingStreamParser` 新增孤立闭合标签吞噬机制与正文流 `cleanTextDelta` 净化层，针对大模型在思考内部复述提示词标签引发的提早闭合边界场景，自动吸收孤立的 `[/THINK]` 或 `<think>` 标签，彻底根除正文开头泄露技术标签的问题；
  - **思考流式活性即时激活**：`AIChatState+Streaming` 在收到思考增量（`reasoningChunk`）时立即将消息状态翻转为 `.streaming`，激活呼吸灯与流式更新节拍。
- Qoder 模型切换全线报错与浏览器凭据网关鉴权根治（`AIChatService+Streaming` / `AIChatService+Completion` / `AIChatState` / `AIProviderStore` / `QoderNativeSigner` / `QoderProvider` / `AIAuthManager`）：
  - **跨服务商模型路由纠偏**：修复 `performStream` 与 `complete` 仅依赖当前 Agent 绑定的默认服务商（Alibaba），导致在会话中切换 Qoder 模型时误将请求发往 DashScope 触发 404/400 报错的缺陷；重构为优先按目标模型 ID 动态路由真实归属的 Provider 及独立 Key；
  - **Qoder Device Token (`dt-`) 放行与端点优先**：浏览器设备流签发的 `dt-` 令牌本身即为长期 Access Token，在 `exchangeJobToken` 中直接识别并放行 `dt-` 与 `jt-` 前缀，清洗包裹引号，杜绝误作为 PAT 提交给兑换接口遭到 400 拒绝；调整端点顺序优先请求国际版 `openapi.qoder.sh`，避开国内端点对国际凭据的 401 拦截；
  - **真实 UID 可靠解析与防 403 鉴权失效**：Qoder 推理网关严格校验 Token 与真实 UID 绑定关系；`fetchUserInfo` 与 `finishQoderAuth` 兼容提取多层结构及从 `avatar_url` 提取 UID，并持久化到本地账号存储；彻底消除因回滚至占位符 `qoder-user` 触发内层 SSE 403 `Login expired`，凭据缓存主动拦截失效 UID 条目；
  - **端点就绪与模型能力跨服务商探测**：`hasConfiguredEndpoint` 升级为依次综合会话生效模型、当前 Agent、全局选中 Provider 与全局回退判定，彻底解决用户仅授权 Qoder、但 Agent 仍指向未配 Key 的默认服务商时输入坞错误报「尚未配置 AI 服务」的阻断问题；`modelSpec(for:)` 支持跨 Provider 查询模型的视觉与思考能力；
  - **非流式补全与角色映射兼容**：对非 OpenAI 兼容服务商（Qoder / Gemini）的轻量补全（标题摘要/上下文压缩）统一重定向至流式收集逻辑并严格透传目标模型，根治请求不存在的 `chat/completions` 端点导致的 404；Qoder 请求构建将 `role: tool` 安全映射为上下文观测文本，并在授权成功时自动为新用户切入官方预设团队。

- Qoder 浏览器登录授权与本机账号一键确认链路根治（`AIAuthManager` / `QoderNativeSigner` / `AIServiceSettingsForm`）：
  - **根因分析**：原实现将 Qoder Web 授权地址硬编码为不存在的 `qoder.sh` 根域名，导致唤起 Safari 时报「无法找到服务器 qoder.sh」；且当点击「导入本机账号」时，因本机 CLI 凭据由系统加密保存而回退调用该错误链接，导致两个按钮均打开失效网页；
  - **官方生产 Web 域名校正**：将授权页地址修正为官方可用的 `https://qoder.com/device/selectAccounts`，Safari 唤起后即可正常渲染官方账号授权与允许页面；
  - **双端点并发轮询容灾**：轮询 Device Token 与兑换 Job Token 时并发试探国内端点（`openapi.qoder.com.cn`）与国际端点（`openapi.qoder.sh`），只要任意一侧响应 200 即可秒级完成无感绑定，解决跨区域网络 DNS 偶发延迟；
  - **已登录账号探测直读与清晰引导**：Antigravity 探测直接解析本机 `app_storage.json` 获取真实登录账号（如 `netpicasa@gmail.com`）；Qoder 导入本机账号文案明确指引「正在唤起官方授权页确认绑定本机账号 (用户名)...」，用户点击后网页一键确认即完成全流程。
- 设置面板删除服务商崩溃根治（`AIServiceSettingsForm` / `AIProviderStore` / `AIAgentStore`）：
  - **根因分析**：设置面板原模型列表与智能体表单的 SwiftUI `Binding` 使用硬编码数组整数下标（`pIndex`、`mIndex`、`agentIndex`）；当用户点击「删除此服务商」导致数组缩短时，SwiftUI 在当前布局刷新帧内对旧 Binding 闭包求值，直接触发 `Swift runtime failure: Index out of range` 致命崩溃；
  - **按实体 ID 安全路由重构**：将所有 Provider、Model、Agent 的 Binding 生成器及辅助操作方法全面重构为基于唯一 ID（`providerId` / `modelId` / `agentId`）动态检索；若目标实体已从 Store 中移除，getter 安全返回默认值（空串/默认开关），setter 安全守卫返回，彻底消除下标越界隐患；
  - **删除动作选中迁移守卫**：`AIProviderStore.deleteProvider(id:)` 与 `AIAgentStore.deleteAgent(id:)` 在移除目标对象时，原子检查并平滑将 `selectedProviderId` 与 `activeAgentId` 迁移至第一个可用项，确保界面平滑切换不闪退。
- 快速切换器鼠标悬浮滚动与按键冲突修复（`AIChatQuickSwitcher`）：解决鼠标悬停在列表项导致滚轮与上下方向键无法驱动列表滚动的事件争抢问题，确保键鼠平滑过渡。
- 模态在场输入坞制表符泄漏与穿透修复（`ChatInputNSTextView` / `AIChatInputFields`）：在模态浮层在场期间拒收文本输入与命令派发，彻底消除 `Tab` 键选择会话时向输入坞插入多余制表符的焦点穿透缺陷。

- 单实例强保障与通知点击唤醒多实例根治（`SingleInstanceGuard` / `QuickShowApp`）：
  - **根因分析**：应用入口（`AppDelegate.main()`）先前缺失单实例互斥检测；且历史构建在 `./build`（Debug）与 `./build_release`（Release）并存时，同 Bundle ID（`cn.chiproad.QuickShow`）被 LaunchServices 同时登记。当 Release 版发送 AI 生成完成通知后，用户点击横幅，系统 LaunchServices 误激活并拉起另一路径的构建副本；无互斥锁机制使新进程常驻后台，导致双实例运行（双菜单栏图标、双快捷键抢占、双 MediaRemote 进程）；
  - **双重互斥守卫（SingleInstanceGuard）**：在 `main()` 最早期结合 `NSRunningApplication` 跨路径进程探测与 POSIX 文件排他锁（`flock`），严格保证系统内唯一主实例（Primary Instance）；
  - **次级实例极简中继（SecondaryRelayDelegate）**：任何后续被系统或用户意外拉起的次级实例，立即阻断全套 UI/状态栏/热键/后台监控初始化；通过极简代理接收通知响应（`UNUserNotificationCenterDelegate`），将 `action` 与 `sessionId` 打包后经 `DistributedNotificationCenter` 跨进程广播给唯一主实例并激活置顶主实例；配以 0.6 秒超时兜底，事件转交完毕后次级实例立即 `exit(0)` 自行终止，绝不逗留；
  - **主实例响应**：主实例收到中继广播后激活自身，按目标 `sessionId` 切换会话并在鼠标所在物理屏幕直接弹出 AI 对话窗。

- 刻度轨放大模型重构（全刻度统一放大 + 对称推开 + 当前条独立明暗梯度，`ChatTickRail` / `Theme.Layout` / `Theme.Colors`）：
  - **几何尺寸与布局统一**：废除当前条 16×3 与普通刻度 10×2 的尺寸差异，所有刻度几何基底统一为 10×2 圆头胶囊；轨体宽收敛为单一基础宽度的峰值放大宽；
  - **消除锚点钉死感**：废除当前条固定 scale 1 钉死在位的旧机制，所有刻度统一参与余弦钟形权重放大与位移推开，绕轨体几何中心平滑对称生长，彻底消除光标掠过时当前条孤立静止的生硬割裂感；
  - **当前条独立明暗梯度**：当前条保留 accent 色彩区分，并引入专属明暗梯度（静止 0.65、波峰 1.00、波谷 0.40），大小与明暗流动与普通刻度节奏完全同源，保持高辨识度的同时实现极致丝滑。
- 实心操作按钮亮暗双模式配色自适应与高对比度重构（`ThemePalette` / `AIChatInputDock`）：为 `ThemePalette` 及 `Theme.Colors` 新增 `actionButtonFill` 和 `actionButtonForeground` 语义通道；琥珀暖色（Amber）主题暗色模式取高明度暖金（#F5B942 系）搭配深褐黑标，亮色模式取暖金琥珀橙（#BF5700 系）搭配纯白标（对比度达 4.8:1，告别发暗泥褐色）；默认标准主题暗色亮青配黑标、亮色深青蓝配白标；AI 聊天输入坞发送按钮适配该通道，确保在亮暗各模式及不同主题下图标对比度均稳居 4.5:1 以上。
- AI 窗口多显示器独立位置记忆与多屏协同（`ScreenHelper` / `AIWindowManager`）：
  - **硬件级显示器持久识别**：`NSScreen.persistentDisplayIdentifier` 优先从 CoreGraphics 获取 EDID 派生的物理 UUID（`CGDisplayCreateUUIDFromDisplayID`），跨系统重启与外接屏幕拔插绝对稳定；
  - **同屏记忆位置，跨屏黄金分割居中**：`AIWindowManager` 实现多显示器相对坐标独立存档（`screenWindowFramesKey`）；当鼠标在哪个屏幕呼出时即在该屏幕恢复该屏幕专属的相对位置与尺寸；首次在未存档新屏幕唤出时继承最近偏好尺寸（`lastWindowSizeKey`）并居中弹出；拖动/缩放防抖落盘，无缝兼容旧单屏存档平滑迁移。
- 模型选择与思考强度合并为单一「生成 chip」入口（输入坞工具行，用户多轮实测反馈驱动）：原模型 chip + 思考 chip 两个下拉合并为一个——chip 常驻 brain 图标 + 模型名（单模型时模型名无信息量，退化为「思考」二字），点击弹原生 NSMenu 双分组（「模型」组仅多模型时出现 /「思考强度」组含默认·关·低·中·高，选中项 `NSMenuItem.state` 系统原生勾选，「关」档保留 canDisableThinking 门控）；思考档位被手动覆盖时模型名后挂三根递增信号条（点亮根数 = 档位：低 1 / 中 2 / 高 3，「关」三根全熄灭留暗轮廓），默认态（跟随模型）不显示、整 chip 轻提亮示「已覆盖」；工具行视觉同步弱化统一：chip 字号 11→10、默认色降 idleText 灰（覆盖态轻提亮 contentTertiary）、⊕ 附件钮静止色 iconRest(0.60)→contentTertiary(0.55) 与 chip 同层、原 chevron.up.chevron.down 双箭头图标换为 brain 语义图标并前置
- 窗口档位体系调整（低分屏适配，用户截图反馈驱动）：
  - **`.auto` 选档改「容得下就选最大」级联**（`ScreenHelper`）：取代旧「宽 ≥1600 或高 ≥1000」阈值——旧阈值把 1280~1512 宽的屏幕一律压进舒适档（内容宽仅 240pt，而监控卡行内容最小需 ~285pt 横向预算，天然溢出变形）；现为屏幕能容纳该档展开窗（窗高 + 垂直居中上移 centerLift 26 + 上下系统边距 46×2）即从标准档逐级向下试探选定，1280×720 只要能容纳标准档（740×520）即用标准档，不再被误降档
  - **舒适/极简档高度修正**（`Theme.Layout`）：舒适展开 460→512、极简紧凑 230→258、极简展开 400→494——旧值为全局字号上调前的陈旧账目，内容实高超窗高后被根帧 `.frame(maxWidth: .infinity, maxHeight: .infinity)` 默认 .center 对齐**双向居中裁剪**（顶日期徽章、底监控卡同裁）；新值按标准档 520 的同账同余量修正（垂直账本逐项核算：徽章 ~34 + 时钟 窗宽×0.183 + 呼吸 + 状态栏 ~35 + 监控占位 259.5）
- 展开监控卡「数字大、单位小一档」视觉层级（用户反馈驱动）：网速 KB/s、延迟 ms、CPU% / 内存% 的单位统一降为 caption、数字保持 callout 不变——吞吐串经 `splitSpeedUnit` 拆「值␣单位」两段后 Text 拼接（`formatNetworkSpeed` 恒为两段格式），部件级 font 优先于容器级、异字号拼接基线自动对齐；窄档下单位缩小同步省横向预算，与低分屏变形修复同向
- 浏览导航（刻度轨 + 回底钮）浮现门槛：显隐与贴底跟随 pin 解耦（用户实测反馈「上滚一点点就出现，太敏感」）——pin 解除必须「用户上滚立即生效」（滚动卡死根治根基，不可动），显隐此前直接绑 `isPinned` 导致 1pt 上滚即冒 UI；现在由 coordinator 新增显隐真源按**离底距离**独立判定（`Theme.Layout.chatNavRevealDistance` = 120pt，DesignTokens 单源）：上滚一点点（门槛内）跟随照常暂停但 UI 不浮现，越过门槛淡入、滚回门槛内淡出、点回底钮/发送跳底立即隐藏、快照恢复远位置正常显示；判定挂点：`setPinned`（pin 翻转恒隐藏）/ `attach`（重挂载即重估）/ bounds 与 document frame 两通知 handler 的 defer（覆盖全部 return 路径、pin 写入后读最终态、嵌套通知幂等）；`bind` 扩展 `onNavVisibilityChange` 双回调并注册时立即同步镜像（重挂载不等首次滚动），视图层 `isNavVisible` @State 替换两处 overlay 的 `!isPinned` 判定、淡入淡出动画（0.15s）随之切换；`distanceFromBottom` 与 `isAtBottom` 几何同源（flipped = maxOffset - origin.y，内容不满一屏恒 0）
- 输入区布局对称化 + 输入框固定行高（AI 窗视觉调整，用户实测反馈驱动）：
  - **阅读列左右边距对称**：`ChatReadingColumn` 修饰器的刻度轨让位通道从「仅右缘 28pt」改为「左右双侧各 28pt」——内容列（消息列 / 输入坞 / 回底钮 / 顶栏图钉共用）左右边距恒等（窄窗 46 / 宽窗 56），整列居中不再左偏（实测右侧曾为左侧 2.6 倍）；刻度轨本体挂在阅读列之外的 ScrollView overlay 上仍贴窗口右缘，不受修饰器位移影响
  - **主输入框固定 3 行高**：`chatInputHeight` 44 → 72（3 × 13pt 行高 ≈ 16 + 垂直内边距 12 × 2），常驻容纳 3 行文字，超出内部滚动；`hasVerticalScroller = false` 隐藏滚动条（滚轮滚动行为不变）；坞高兜底 `chatDockHeightFallback` 88 → 116（72 + 工具行 ≈32 + 底缝 12）
  - **ask_user 自由输入条固定 2 行高**：`freeInputMinHeight`/`freeInputMaxHeight`（22/60 生长区间）收敛为单一 `freeInputHeight = 38`（2 × 12pt 行高 ≈ 14.8 + TextEditor 垂直内边距 ≈ 7 + 防裁切余量 1），`.scrollIndicators(.never)` 隐藏滚动条（超出 2 行仍可滚轮内部滚动）

### Fixed

- AI 生成完成通知点击精准打开 AI Chat 窗口与 Reopen 解耦根治（`QuickShowApp` / `AICompletionNotifier` / `AIChatState+Notifications`）：
  - **会话精准导流**：通知载荷中携带 `sessionId`，用户在系统通知横幅点击后自动切换至对应会话，并在鼠标当前所在的物理屏幕直接呼出 AI Chat 窗口；
  - **Reopen 误触主面板根除**：揭示系统点击通知横幅激活应用时的跨进程 XPC 异步机制（第一阶段即时派发 reopen，第二阶段约 300~600ms 跨进程 XPC 送达通知点击响应）。QuickShow 作为无 Dock 图标的常驻辅助应用（`LSUIElement`），在 `applicationShouldHandleReopen` 中彻底解除对主面板的误触呼出，将通知唤醒 100% 专职收口至 `UNUserNotificationCenterDelegate`，彻底消除了主面板与 AI 窗口同时弹出的时序竞争。
- AI 窗呼出后主输入框自动获得输入焦点（呼出即打字）——根因：`AIWindowManager.show()` 仅做 `makeKeyAndOrderFront` / `makeKey` / `NSApp.activate` 三连，全程无一步显式把主输入框设为第一响应者，焦点依赖两个脆弱兜底：① `makeNSView` 里的一次性 async 聚焦仅首次建树时执行，面板复用（第二次以后打开）路径不再走；② `windowDidBecomeKey` 观察者带「其他 NSTextView 持焦即让位」守卫，而 NSWindow 隐藏不清 firstResponder——侧栏搜索 / 重命名持焦后关窗，复开时残留 field editor 使守卫永久拦截，主输入框拿不到光标只能手动点击；修复：`show()` 在上屏 + 激活完成后于 MainActor Task 发布 `aiChatForceFocusInput` 强制聚焦通知（面板不可见 / 正在收起 / 抽屉展开中三种情况不发布——抽屉展开时焦点留给抽屉交互），`ChatInputTextView.Coordinator` 收到后无条件 `makeFirstResponder` 接管第一响应者、清掉残留 field editor 焦点；「让位」语义仅保留给窗口已可见时的交互场景（抽屉关闭归还焦点 / 重命名不抢焦），与既有 `aiChatRefocusInput`（抽屉关闭后归还，带让位）分工明确
- 日历打开链路三连修复（用户实测截图反馈驱动）：① 打开系统日历报「未设定用来打开 URL calshow:// 的应用程序」系统弹窗——根因：`openCalendarApp()` 用 `calshow://` scheme 唤起日历，而本机 LaunchServices 未注册该 scheme 的处理程序，`NSWorkspace.open` 直接弹系统报错框；修复：改按 bundle id `com.apple.iCal` 经 `NSWorkspace.urlForApplication(withBundleIdentifier:)` 解析实际安装路径后直接打开（不依赖 scheme 注册与安装路径），解析失败回退 `/System/Applications/Calendar.app` 固定路径 ② 打开的应用（系统日历 / 活动监视器）不前置到前台——根因：`NSWorkspace.open` 打开 .app 对已运行应用仅「显示」不必然激活置前；修复：新增 `openAppActivating()` 统一辅助——`NSWorkspace.openApplication(at:configuration:)` + `activates = true`，日历与活动监视器均接入，确保目标窗口来到前台 ③ 日期胶囊与日历视图标题的年份数字被千位分组（`2026` → `2,026`）——根因（独立 swift 脚本实测复现）：`String(localized:)` 的 Int 插值与 `String.localizedStringWithFormat` 均按 locale 对数字做千位分组渲染（zh_CN 分组分隔符为逗号），第一轮换汤未换药；修复：数值渲染统一改 `String(format:)`（printf 语义、永无分组），格式模板仍经 `String(localized:)` 查 xcstrings 表保留中英文翻译（英文翻译的位置参数格式 `%1$d` 实测兼容）——共 5 处：TimeDisplayView 日期胶囊 ×1 + CalendarGridViews 月/周/日视图标题与选中日信息行 ×4
- 输入坞右键菜单全英文根治（`CFBundleAllowMixedLocalizations: true` 声明于 project.yml `info.properties`——Info.plist 唯一真源，xcodegen 每次重生成会打回手改）——根因：`ChatInputNSTextView` 未自定义 `menu(for:)`，右键弹出的是 AppKit 系统标准文本菜单（剪切/拷贝/粘贴/字体/拼写/服务全套，文案由框架提供而非应用源码），AppKit 渲染系统菜单时按「应用 bundle 声明的本地化语言 ∩ 系统语言」取框架资源；项目此前零本地化声明（`developmentRegion = en`、无任何 lproj），即使系统语言为简体中文也回退英文框架资源；声明允许混合本地化后，系统菜单跟随系统语言（中文系统显示中文，英文系统显示英文），应用自身的中文硬编码文案不受影响
- 生成 chip hover 失效 / 思考信号条不显示 / 下拉菜单零选中标识三症同根根治（SwiftUI `Menu` + `.menuStyle(.borderlessButton)` 的 label 不走实时 SwiftUI 渲染管线）——症状链：chip 无 hover 反馈（label 内挂的 `.onHover` 被丢弃，悬停胶囊底与提亮从不出现）；思考档位覆盖后信号条永不显示（body 重算不落到 label 上——数据链路经排查完好：`ChatSession` 为 struct、`@Published sessions` 正常发射、`sessionConfigStamp` 刷新触发器工作，@2x 截图实测 chip 上零竖条痕迹）；macOS 26 系统菜单渲染丢弃菜单内 Button label 的 icon（12 个选项零选中标识）。修复：chip 从 SwiftUI Menu 重写为 SwiftUI Button + 点击构建 AppKit NSMenu 弹出（`popUp(positioning:at: NSEvent.mouseLocation, in: nil)`，`autoenablesItems = false`）——Button 的 label 是真 SwiftUI 视图，hover 可靠触发、body 重算实时刷新（信号条出现，用户实测确认）；选中勾改由 `NSMenuItem.state` 系统原生绘制；NSMenuItem target 弱引用问题以 `GenerationMenuAction` proxy（NSObject + @objc invoke）承接、局部数组持有至模态 popUp 结束随栈释放；排障过程中的中间方案（Picker `.inline` 单选、`.onHover` 移入 label 内部）均不奏效——label 的渲染路径不因修饰符位置或菜单内容形态而改变
- 思考过程（reasoning）流式展示冻结（开启思考发问后折叠区摘要全程停在「思考中…」不随增量滚动，思考结束后一次性突现全部思考文案，正文流式正常）——根因：`SessionMessageList` Equatable 8 字段 O(1) 签名（聚焦卡顿根治引入）只覆盖正文通道（末条 `content.count`），漏掉与正文独立流式的 reasoning 通道：纯思考期正文恒为空串、8 字段全程不变，`.equatable()` 误判相等跳过整棵子树 body 重放，思考折叠区收不到 reasoning 增量、`rendered` 停在初始空值、摘要回退「思考中…」；正文开流 content.count 变化才打开闸 → 思考内容全量突现（数据层 50ms 合帧冲刷、行级 `ChatMessageRow.Equatable`、250ms 节流与收尾对账均无辜）；修复：`==` 签名补入 `messages.last?.reasoning?.count`，与 content.count 同取舍（比长度不比全文、保持 O(1)）——纯思考期 reasoning 增长本身即打开 diff 闸，折叠区摘要按 250ms 节流滚动、收尾全量对账原样兜底，不再依赖「正文与思考同帧到达」的时序巧合
- 低分辨率（1280×720 等）主窗状态区布局变形根治（用户截图三处红框：日期徽章顶部被裁、番茄行预设胶囊压成逐字竖排、网速「9 KB/s」逐字折行 / 复制内网 IP 钮贴边遮挡）——三层独立根因逐层修复（选档错位与档高陈旧两条根因见上方 Changed，此处为第三条与防御层）：
  - **行降载改由布局真值裁决**（`PerformanceCard` / `FocusWorkCard`）：每条可降载行包一层 `ViewThatFits(in: .horizontal)` 变体阶梯（网速行 4 档 / 番茄行 4 档 / 内存行、磁盘行、头部行、工具条各 2 档），从最全到最简逐级排列，布局系统按各变体**理想宽**与实际可用宽比对、选中第一个放得下的；取代先前「窗口宽纯算术推导每卡内容宽 + 手写阈值常量」的估算机制——该机制两处阈值估错（番茄行理想 ~291pt vs 标准档可用 280pt、网速行 ~307pt vs 300pt，均被判定为「放得下」照常渲染，再被 HStack 压缩成逐字竖排与尾省略号，用户截图实证）。零魔法数字、无 @State、无 PreferenceKey 回喂（纯布局期选择，不触本宿主含 Button 的测量死锁链），`ExpandedMonitoringView` 随之不再下发 `contentWidth`；窗口 resize / 档位切换即时重估
  - **让位顺序按「可操作性」排**：动作类控件最后让位且先降级不消失（复制内网 IP 钮 文字 → 纯图标（能力与 help 提示保留）→ 整枚让位；番茄预设胶囊 常规 → 紧凑字距 → 整组让位），被动读数先走（网络延迟、番茄统计小字、蓝牙外设 chip、内存清理钮 / 磁盘下载钮 / 活动监视器入口）；被让位能力均有等价入口兜底（O 键下载目录 / C 键清理 / 双击卡片开活动监视器 / P 键番茄 / 蓝牙连接状态不受影响），窗口拉宽即自动恢复、无状态残留
  - **关键数值文本全部 `lineLimit(1)` + `layoutPriority(1)`**：作为变体阶梯之外的最后防线——即便最简变体仍溢出也只尾省略号截断，不逐字折行竖排（低分屏「9 / KB / s」的直接根因）；番茄统计小字在紧凑档由 `Theme.Layout.pomodoroStatsCompactWidth` 给宽上限，把预算让给可点的预设胶囊
  - 不依赖时序 / 缓存 / 门槛值：变体选择每次布局从真值重算，日后行内增删控件自动纳入理想宽账，构造上不再复发
- 侧栏选中态残影根治（同一时刻两行琥珀高亮，残影行刷不掉：换选中/⌘B/窗口隐显/置顶迁移/新建会话全部存活）——根因：SwiftUI「待移除副本」孤儿 CALayer。侧栏 hover 提亮/悬停清理三处 `withAnimation` 在行插拔（⌘F 搜索分支切换 / 置顶跨组迁移 / 删除）瞬间制造动画事务，事务完成回调被 50ms 流式更新或 ⌘B 双域窗口动画搅黄时，被移除行保留的副本层永久孤儿化（实证特征：命中测试透明 = 裸 layer 不参与 hitTest；绘制冻结不随 `currentSessionId` 更新；跟随列表布局；行销毁重建刷不掉。数据层经查零重复 id、零跨组重复渲染，与早前「重复 id 会话文件 → ForEach 身份冲突」事故同症不同因）；修复 = ①删除侧栏数据路径全部 `withAnimation`（hover 提亮/悬停清理变瞬时，损失仅 0.15s 文字淡变）②列表容器 `.transaction(Transaction(animation: nil))` 事务剥离——行插拔构造上不再进入任何动画事务（含外部环境事务），「待移除副本」无源，残影一族不可能再生；屏上既有残影随重启清除（孤儿层是运行进程内存）
- AI 窗聚焦/失焦卡顿根治（卡顿随会话变大而加剧，用户实测反馈驱动）：
  - **聚焦路径全量去重**（`AIChatView`）：`didBecomeKeyNotification` 过滤非 AIPanel 窗口（系统弹窗 / 其他 App 激活不再误触发整窗刷新）；`refreshEnvironment` 幂等化——值不变不写 @State，杜绝恒等写入触发全列消息 diff；剪贴板探测延迟到 runloop 闲时（聚焦瞬间不抢主线程）
  - **消息列表保活单元 Equatable 收敛**（`SessionMessageList`）：`ForEach` 加 `.equatable()`，`==` 只比 sessionId / isActive / 坞高 / 消息数 / 首尾消息 id / 末条状态与内容长度——父体重建时未变化会话整体跳过 body 重估（此前每次聚焦都重放全部 LRU 常驻会话的布局）
- 冷启动打开公式密集会话卡死 → 崩溃根治（三层连环根因，逐层独立构成性修复）：
  - **首帧全行实渲染**（`ChatScrollCoordinator.ChatVirtualRow`）：`rowHeights` 无缓存时旧实现恒实渲染——冷启动全列 N 行同时进入布局，约束求解递归深至 AppKit 异常；改为「未测量且在窗口外 = 100pt 估算占位」，实渲染仅保留给窗口内行
  - **虚拟化窗口预置**（`AIChatMessageList.seedVirtualWindowIfNeeded`）：onAppear 按快照（pinned 态 + 顶部锚点消息）预置 `virtualWindowIds`——首帧即命中视口行，geometry 反馈循环收敛前的可见闪烁消除
  - **布局期视图侧效应清零**（`MathParagraphView.sizeThatFits`）：旧实现在 SwiftUI 布局遍历内调 `invalidateIntrinsicContentSize` / `preferredMaxLayoutWidth` / `layoutSubtreeIfNeeded`——沿视图树冒泡 `setNeedsUpdateConstraints`，AppKit 在布局周期内收到约束失效即抛 NSInternalInconsistencyException（EXC_BREAKPOINT 崩溃日志帧 19-20 实证）；改为 `NSAttributedString.boundingRect` 纯文本测量（TextKit 排版计算、零视图层级触碰，布局遍历内安全）+ cell 垂直内边距常数补回；coordinator 内存缓存与 `MathLayoutCache` 全局持久缓存及稳定性判定原样保留——公式再多、行再密，这条崩溃路径构造上不可能再触发（不依赖时序、行数、门槛值）
- 会话滚动卡死回归（上述列宽变化引爆，两层根因连环修复，滚动判别根基重构）：
  - **pin 判定从「几何方向 + 容差猜测」重构为「滚轮事件来源判别」**（`ChatScrollCoordinator`）：新增 `NSEvent` 本地 `scrollWheel` 监听（只观察不消费，hit-test 与事件派发同路径路由到具体会话 + 0.15s 关联时窗）。用户上滚立即解除底部跟随——触控板容差带内的小 delta 滚动也生效，根治「上滚攒不过 18pt 容差线、被 pinned 逐帧 `scrollPinnedToBottom` 拽回」的滚动卡死；流式内容塌缩时 AppKit 的被动 clamp（bounds 通知在 `documentView.setFrame` 调用栈内同步投出且**先于** frame 通知，任何程序化遮蔽窗原理上罩不住——独立 AppKit harness 实证）不再被误判为用户输入，流式贴底跟随全程保持；底部 rubber-band 越界区回收的 movedUp 显式豁免（回弹后跟随不丢）；非用户来源的下行滚动永不改写 pin（历史「塌缩瞬移 → pin 误恢复 → 回填拽回」bug 族被构造性消灭，不再是几何守卫的妥协）。已知保守取舍：滚动条拖拽 / 键盘滚动不产生滚轮事件，不改写跟随态（回底由 ↓ 按钮 / 发送跳底覆盖）
  - **虚拟化行高缓存增加列宽维度**（`AIChatMessageList`）：`rowHeights` 新增伴随 `cachedColumnWidth`，内容列宽变化 >1pt 即清空缓存全行重测——修复列宽变化后「占位高 ≠ 实渲染高」打破虚拟化恒等式，导致的 document 高度持续抖动与全列反复重排（主线程 CPU 风暴、滚动间歇性冻住）；触发源覆盖窗口 resize / ⌘B 侧栏切换 / 冷启动首帧宽度修正
  - **阅读列 720pt 宽度断点加 1pt 死区**：吸收 ⌘B 侧栏展开的 0.5pt 主列宽度补偿，防止窗口停在 720 附近时每次侧栏开关触发 18 ↔ 28 档位翻转全列重排（视觉零变化）
  - **刻度轨密度自适应加上界钳制**（`ChatTickRail`）：pitch 计算加 `avail / n` 拟合上界 + `restHeight` 钳制——坞体增高压缩可用高度时轨体与全部槽位收进可用区，不再溢出 overlay 上下缘
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