# QuickShow MCP 与 Agent Skills 支持 · 产品技术方案

> 状态：**方案讨论稿（未实施）**。关键边界已于 2026-11-03 与用户确认（见 §2）。
> 基线版本：1.13.0。开工前请先读 `AGENTS.md` 与本文件 §12「开放问题」。
> 规范基准：MCP `2025-11-25`（兼容 `2025-06-18`）；Agent Skills 开放标准（agentskills.io）。

> 本轮优化已确认采用「最小闭环」：只修订方案，不实施代码；M1 支持文本/结构化工具结果，多模态独立后置。§12 中尚未确认的产品默认值仍保留为开放问题。

---

## 1. 背景与第一性原理

### 1.1 现状与瓶颈

QuickShow AI 对话窗当前具备完整的原生工具链（23 个内置工具）、多 Provider 分发总线（`LLMProviderRegistry`）、单/多 Agent 协同与三级风险权限治理。但能力边界是**封闭**的：

1. **工具天花板**：新增任何外部能力（GitHub、数据库、浏览器自动化、内部系统 API……）都必须写 Swift 内置工具并发版，无法复用社区生态；
2. **知识注入原始**：专业流程知识只能塞进 Agent 的 systemPrompt，常驻占用上下文、无法按需加载、无法沉淀复用；
3. **生态孤岛**：用户已在 Claude Code / opencode / Cursor 中积累的 MCP 配置与 Skills 资产，QuickShow 一概无法继承。

### 1.2 本质拆解

- **MCP 解决「能做什么」**：一条标准化的外部能力总线。QuickShow 作为 MCP Host/Client，把任意 MCP Server 的 tools / resources / prompts 接入现有对话回路。
- **Skills 解决「怎么做好」**：渐进式披露的知识包。目录常驻只有 name + description（每技能 ~50–100 tokens），命中任务才加载完整指令，指令引用的脚本/资料再按需读取。

两者正交互补：Skill 指令可以指挥模型调用 MCP 工具；MCP prompts 与 Skills 共享同一个 `/` 命令入口。

### 1.3 QuickShow 哲学约束（设计硬边界）

| 哲学 | 对本方案的约束 |
|---|---|
| 极致轻量（待机低开销） | MCP 进程**默认按需拉起 + 闲置回收**，无连接时无 MCP 自身子进程与轮询；CPU 以采样验证而非绝对值保证 |
| 零打断 · 心流优先 | 只读能力免审直通；审批复用现有输入坞抽屉（⏎ / ⌘⏎ / ESC），不新增弹窗形态 |
| 全键盘盲操 | Skills 与 MCP prompts 走 `/` 命令面板，方向键 + ⏎ 选中，手不离主键盘区 |
| 纯原生零依赖 | MCP 协议栈与 YAML frontmatter 解析全部手写 Swift（Foundation/URLSession/Process），不引入任何 SPM/npm 依赖。用户配置的 Server 进程（npx/uvx 等）是**外部程序**，QuickShow 只负责拉起并讲 JSON-RPC，自身构建链零污染 |
| 确定性安全防线 | Server 的 annotations、Skill 的 allowed-tools 一律视为**不可信提示**，不能自我授权；风险裁决权在宿主规则引擎 |
| SOLID / OCP | 先完成注册表、执行上下文与 Provider schema 适配等必要改造；此后新增 Server 无需修改调用方，不承诺首次接入零改造 |

---

## 2. 已确认边界（用户拍板，勿擅改）

| # | 决策点 | 结论 |
|---|---|---|
| 1 | MCP 角色 | **仅客户端**：连接外部 MCP Server；不把 QuickShow 暴露为 MCP Server |
| 2 | 传输方式 | **stdio + Streamable HTTP** 都支持；Server 启动命令由用户配置（可含 npx/uvx），QuickShow 自身保持纯 Swift 零依赖 |
| 3 | Skill 格式 | **兼容 Agent Skills 开放标准**：SKILL.md + YAML frontmatter + scripts/references/assets 目录约定 |
| 4 | Skill 能力 | **指令 + 脚本**（脚本经现有 run_shell 风险审批链路执行）；**自动 + 手动**触发（模型按需 load_skill + 用户 `/名称` 显式调用） |

---

## 3. 产品方案

### 3.1 用户故事

1. 用户在设置中添加 GitHub MCP Server，明确授权启动程序并发现工具后，对话中直接说「看看我仓库最近的 PR」，模型调用 GitHub MCP 工具完成；未知风险操作弹抽屉确认；
2. 用户把 Claude Code 里攒的 `pdf-processing` 技能目录放进 `~/.agents/skills/`，QuickShow 自动发现；问「帮我合并这几个 PDF」时模型自动加载技能指令并按指令执行脚本，脚本执行前走既有审批；
3. 用户输入 `/` 唤出命令面板，模糊搜索技能与 MCP prompts，⏎ 注入；
4. 用户一键导入 Claude Desktop / Cursor 的 MCP 配置，无需逐个重填；
5. 没有在途任务、订阅或常驻设置时，闲置回收 MCP 子进程，恢复无 MCP 进程与轮询的待机状态。

### 3.2 功能清单与优先级

| 优先级 | 功能 |
|---|---|
| P0（M1） | stdio MCP 客户端：启动授权、发现缓存、文本/结构化结果桥接、执行期权限、风险审批、启停管理、工具级开关、tools/listChanged |
| P0（M2） | Skills：目录发现、frontmatter 解析、目录注入、`load_skill` 自动激活、`/名称` 手动激活、脚本审批执行、设置管理页 |
| P1（M3） | Streamable HTTP 传输 + OAuth 2.1；MCP resources 读取；MCP prompts 接入 `/` 面板；elicitation 映射提问抽屉；Claude/Cursor 配置导入 |
| P2（M4） | 资源/prompts listChanged 与资源订阅；roots（工作区目录）；闲置回收精细化；Last-Event-ID 断线续传；技能目录导入导出；多模态工具结果独立评估 |

### 3.3 交互设计

**设置中心**（`AIServiceSettingsForm` 现有四个子页保持不变，在「工具与权限」子页内新增两个分组，避免顶层导航膨胀）：

- **MCP 服务**：Server 列表卡片（名称 / 传输类型 / 状态灯 / 工具数 / 启用开关）；添加表单（stdio：命令 + 参数 + 环境变量 + 工作目录；HTTP：URL + 认证）；展开查看工具清单并逐个开关；「查看日志」（stderr 尾部）；「导入 Claude Desktop / Cursor 配置」（M3）。首次「连接并发现工具」前展示可执行路径、完整参数、工作目录与 env 键名（敏感值打码），由用户明确授权运行。该授权**不勾选「信任只读标注」**；本地程序具有当前用户权限，不受工具调用审批的沙箱隔离。
- **技能**：已发现技能列表（名称 / 描述摘要 / 来源路径 / 校验状态 / 启用开关）；「添加技能目录…」；「打开技能目录」；校验失败的技能灰显并附原因（frontmatter 缺字段、name 非法等）。

**对话窗**：

- 工具卡片左上角来源徽标：`内置` / `MCP·<server>` / `技能`，一眼区分能力出处；
- 输入 `/` 唤出命令面板（复用 `AtMentionQuotePopupView` 的弹出与键 nav 模式）：技能与 MCP prompts 混排、模糊过滤、↑↓ 选择、⏎ 注入、ESC 收起；
- 技能激活后输入坞上方显示轻量胶囊 `⚡ 技能: pdf-processing`（可点击移除 = 取消激活）；
- 审批抽屉对 MCP 工具展示：Server 名 + 工具名 + 参数摘要 + 风险等级；记忆放行的建议作用域为「本会话允许该工具」；对技能脚本展示技能来源与建议放行范围；
- 安全微标（Security Badge）计数纳入 MCP 会话规则。

**键盘协议**：全部沿用现有纪律（⏎ 单次放行 / ⌘⏎ 记忆放行 / ESC 拒绝；ESC 全局紧急退出不受任何新增抽屉影响）。

### 3.4 轻量纪律（性能红线）

1. **发现与执行分离**：首次经授权连接、initialize、分页发现并缓存目录，发现结束且无在途请求即关闭；无缓存的 Server 不凭空声明工具，提示先连接发现。后续仅声明缓存工具不拉起进程，真正调用时才重连（§5.3）；
2. **闲置回收**：默认 10 分钟无活动且在途请求、待审批、elicitation、订阅均为零时关闭，回到 idle；单次到期任务代替轮询，关闭后撤销计时任务。「常驻」可豁免，订阅与常驻有明确资源成本；
3. **退出清理**：正常退出在应用终止协调阶段等待有界清理，不依赖 `willTerminate` 中临时发起异步任务。对子进程组 SIGTERM → 宽限 → SIGKILL；仅清理本次启动且仍归属自身的进程组，不宣称可保证 App 崩溃或强杀后的清理；
4. **上下文预算**：请求发送前统一执行硬预算（§9），被排除的能力同时从该请求执行允许集中移除，并给出原因；设置页提示不是预算执行机制。

---

## 4. 总体架构

### 4.1 架构总览

```
                        ┌─────────────────────────────────────────────┐
                        │  AIChatState+RequestAssembly (system 段组装) │
                        │  + 技能目录段 + 已激活技能正文段             │
                        └──────────────────────┬──────────────────────┘
                                               │
 ┌──────────────────────────┐   ┌──────────────▼───────────────────────────┐
 │ SkillStore (发现/解析)    │   │ AIToolRegistry.tools(for:mode:)          │
 │  ~/.quickshow/skills      │   │ ★ 工具声明汇聚点（全部工具型 Provider）  │
 │  ~/.agents/skills         │   │  = 内置工具 + Σ AIToolSource.tools()     │
 │  ~/.claude/skills (兼容)  │   └────────────────────────────────────────┘
 │  + 用户自定义目录         │          │                       │
 └───────────┬──────────────┘   ┌──────▼─────────┐   ┌─────────▼──────────────┐
             │ load_skill       │ 内置 AITool[]   │   │ MCPToolSource           │
 ┌───────────▼──────────────┐   │ (23 个，不动)   │   │  → MCPToolBridge: AITool │
 │ LoadSkillTool (内置工具)  │   └──────┬─────────┘   └─────────┬──────────────┘
 │ SlashCommandRegistry      │          │                       │
 │  (/技能 + /MCP prompts)   │   ┌──────▼───────────────────────▼───────────┐
 └──────────────────────────┘   │ AIToolExecutor（上下文校验 + 超时钩子）   │
                                │ ToolRiskClassifier ← MCPRiskEvaluator(新增)│
                                │ ToolPermissionPolicyEngine / ShadowGuard  │
                                └──────────────────────┬───────────────────┘
                                                       │ MCPToolBridge.execute
                                ┌──────────────────────▼───────────────────┐
                                │ MCPServerManager（注册/生命周期/状态机）    │
                                │  ┌────────────┐      ┌────────────────┐  │
                                │  │ MCPClient  │      │ MCPClient      │  │
                                │  │ JSON-RPC   │      │ JSON-RPC       │  │
                                │  │ + 生命周期  │      │ + 生命周期      │  │
                                │  └─────┬──────┘      └───────┬────────┘  │
                                │  ┌─────▼──────┐      ┌───────▼────────┐  │
                                │  │StdioTransp │      │HTTPTransport   │  │
                                │  │Process/Pipe│      │URLSession/SSE  │  │
                                │  └─────┬──────┘      └───────┬────────┘  │
                                └────────┼─────────────────────┼───────────┘
                                         ▼                     ▼
                                   MCP Server 子进程      远程 MCP 服务
```

### 4.2 核心改造：注册表复合化（OCP 落地点）

现状：`AIToolRegistry` 持有实例工具数组，`tools(for:mode:)` 汇聚 OpenAI / Qoder / Antigravity 三条工具声明链路；执行器另走 `tool(named:)` 与 `enabledTools()`，当前不校验 Agent 白名单。复合化必须覆盖声明、查询、分组与执行校验，不能只改一个入口。

改造（对扩展开放、对修改关闭）：

```swift
/// 动态工具源协议：任何外部能力体系（MCP、未来的插件）实现此协议即可汇入对话回路，
/// 完成首期必要改造后，新增工具源不要求调用方逐个适配 Server。
protocol AIToolSource: AnyObject {
    /// 当前可用的工具快照（已按各自启用配置过滤）
    func availableTools() -> [AITool]
}

final class AIToolRegistry {
    private let builtinTools: [AITool]          // 现有 23 个，原样保留
    private var toolSources: [AIToolSource] = [] // 新增：MCPToolSource 等

    func register(source: AIToolSource) { ... }

    func allTools() -> [AITool] { builtinTools + toolSources.flatMap { $0.availableTools() } }
    // enabledTools() / tools(for:mode:) / tool(named:) / executionPolicy(for:)
    // 全部改为基于 allTools() 复合集；内置工具的 UserDefaults 启用语义原样不变，
    // 外部工具的启用由各自 Source 内部裁决（MCP：Server 级 + 工具级开关）。
}
```

要点：

- **内置启用集零迁移**：`ai.tools.enabled` 仍只存内置蛇形名；必须同步修改 `AISettingsSections` 的读取/写回和 `toolsGroupedByCategory()`，MCP 开关只写 Source 配置，不能依赖命名空间自动隔离；M2 为存量启用配置增加 `load_skill` 的一次性兼容，之后尊重用户禁用；
- **Agent 白名单扩展**：保留 `AIAgent.resolvedTools` 的角色默认回退语义，统一由 `ToolNameMatcher` 支持 `mcp__github__*`，不引入没有对应工具实体的 `skill__*`。工具声明最终集合 = 全局启用 ∩ 当前 Agent 权限 ∩ 当前模式 ∩ Provider 可表示集合 ∩ 预算允许集合；
- **执行期强校验**：每个模型请求生成不可变 `ToolRequestSnapshot`，包含会话/Agent/运行 ID、允许工具与定义版本，主 Agent 和子 Agent 都传入执行器。执行前校验快照成员关系，再检查当前禁用、配置版本、风险与授权；审批后实际调用前再次校验，撤权即时生效。缺少上下文默认拒绝，不以全局启用代替 Agent 权限；
- **设置分组**：`ToolCategory` 新增 `.mcp`、`.skills` 两个 case（`allCases` 自动进入设置页分组序）；MCP 分组内按 Server 二次分组展示。

### 4.3 新增模块文件树

```
QuickShow/AI/
├── MCP/
│   ├── MCPProtocolModels.swift      # JSON-RPC 信封、生命周期/工具/资源/提示词 Codable 模型
│   ├── MCPTransport.swift           # 传输协议 + 帧解析公共件
│   ├── StdioTransport.swift         # Process + Pipe + 换行分帧 + stderr 日志
│   ├── StreamableHTTPTransport.swift# URLSession POST/GET/DELETE + SSE + 会话头（M3）
│   ├── MCPClient.swift              # 单 Server 会话：请求/响应配对、握手、能力、通知分发（actor）
│   ├── MCPServerManager.swift       # 注册中心 + 状态机 + 按需拉起/闲置回收/退出清理
│   ├── MCPServerConfigStore.swift   # 配置持久化（JSON + Keychain 凭据）
│   ├── MCPToolBridge.swift          # 远程工具 → AITool 适配器
│   ├── MCPToolSource.swift          # AIToolSource 实现（已授权、版本匹配的缓存目录）
│   ├── MCPToolCatalogStore.swift    # 目录缓存、定义摘要与配置版本绑定
│   ├── MCPToolNameCodec.swift       # 稳定命名空间与双向映射
│   └── MCPAuthCoordinator.swift     # OAuth 2.1 授权流（M3，复用 OAuthLoopbackServer 模式）
├── Skills/
│   ├── SkillModels.swift            # Skill 实体 + frontmatter 模型 + 校验规则
│   ├── SkillFrontmatterParser.swift # 零依赖受限 YAML 解析（宽容校验）
│   ├── SkillStore.swift             # 多目录发现 / 目录缓存 / 热重载（FSEvents 或手动刷新）
│   ├── LoadSkillTool.swift          # 内置工具 load_skill（渐进披露第 2 层）
│   ├── SkillActivationManager.swift # 会话级激活态（去重/LRU/正文注入数据源）
│   └── SlashCommandRegistry.swift   # / 命令注册中心（SkillSource + MCPPromptSource 可插拔）
└── Tools/
    ├── MCPRiskEvaluator.swift       # MCP 工具风险评估策略（挂入 ToolRiskClassifier 策略链）
    ├── ToolRequestSnapshot.swift    # 请求工具快照与执行权限上下文
    ├── ToolSchemaAdapter.swift      # 按 Provider 能力校验/无损适配 schema
    └── ContextBudgetPolicy.swift    # 请求预算与确定性能力选择策略

QuickShow/Views/
├── MCPServerSettingsSection.swift   # 设置：MCP 服务分组
├── SkillSettingsSection.swift       # 设置：技能分组
└── SlashCommandPopupView.swift      # 输入坞 / 命令面板
```

---

## 5. MCP 客户端技术方案

### 5.1 协议版本策略

- 首选 `2025-11-25`，兼容集 `["2025-06-18", "2025-11-25"]`；
- `initialize` 携带客户端最高版本；Server 回以其支持的版本：在兼容集内 → 接受并按该版本行为；不在 → 断开并给出可读错误（「Server 协议版本 X 不受支持」），不做猜测式降级；
- `structuredContent` 从 2025-06-18 起支持；2025-11-25 的 icons 为可选展示能力，不阻塞首期。tasks（实验性）、sampling 工具调用等不声明、不实现；协议版本与各能力分别门控。

### 5.2 分层与协议

```swift
/// 传输层：只负责字节进出，不懂 JSON-RPC 语义
protocol MCPTransport: AnyObject {
    var incoming: AsyncStream<Data> { get }   // 每条元素 = 一条完整 JSON-RPC 消息
    func send(_ message: Data) async throws
    func close() async
}
```

- `MCPClient`（actor，每 Server 一个）：宿主请求 id 自增，兼容服务端字符串/数字 id；请求/响应/通知按信封分类，不混用双向请求 id 表。未知请求返回 JSON-RPC 方法错误，未知通知忽略；不因客户端未声明能力就假定服务端必然守规。未决 continuation 在响应、超时、取消与断连竞态下恰好收尾一次；
- `MCPServerManager`（@MainActor ObservableObject）：配置真源、状态机、UI 绑定、进程监督。

### 5.3 生命周期

```
idle → connecting → initializing → discovering → ready
 ↑          └────────失败───────────────┴────────→ failed
 └──────── stopping ← 发现完成/闲置/手动断开 ───── ready
disabled：禁用时终止连接与在途请求，不参与自动重连
```

1. `initialize`（protocolVersion / capabilities / clientInfo{name:"QuickShow", version}）→ 记录 Server capabilities 与 serverInfo；
2. 发送 `notifications/initialized`；
3. 按能力拉取 `tools/list`（cursor 分页循环直至无 nextCursor）；
4. 运行期：`ping` 可选；ESC 仅对当前会话/运行拥有的未决请求发送 `notifications/cancelled`，取消本地等待不代表远端操作已回滚，不关闭其他会话共用连接；initialize 不发送取消通知，取消握手改为关闭连接；
5. 能力声明：M1 为空；M3 仅开启 form elicitation；roots 在 M4，sampling/tasks 始终不声明。

**工具发现与缓存（M1）**：显式发现后原子保存工具目录、原名映射、schema/annotations/description 摘要、协议版本与配置修订号。缓存不是授权来源；无缓存、配置不匹配或发现失败时不发布该 Server 工具。调用缓存工具时通过 single-flight 合并同 Server 并发连接，重新发现后比对定义；变化则拒绝本次旧快照调用、撤销相关会话规则，并从下一模型请求发布新定义，不把旧参数静默送入新工具。

**热更新与重试（M1）**：收到 tools/listChanged 合并刷新；每次重连也重新发现，覆盖不支持通知的 Server。分页设页数/条数上限并检测 cursor 循环，刷新失败不发布半份目录。连接建立可指数退避至多 3 次；配置/版本/授权错误不自动重试。连接恢复与 `tools/call` 重放分离：已发送但结果未知的调用返回「结果未知」，不自动重放；重新连接、HTTP 会话恢复均不意味着重试写操作。

**共享连接纪律**：每个未决请求绑定会话、Agent、运行与配置版本；服务端 elicitation 只能路由到可确定的所属调用，归属不明则拒绝。单 Server 默认串行，显式信任只读标注只影响风险，不自动证明 Server 支持并发；初期全部 serial。闲置检测按所有请求/审批/交互引用计数，重连不会延续旧的远端订阅状态。

### 5.4 传输实现细节

**stdio（M1）**

- `Foundation.Process` + 三个 `Pipe`；**参数数组直传，绝不经过 `/bin/sh -c` 插值**；命令解析：绝对路径直接用，裸命令名按 PATH 查找（找不到 → 配置页可读报错）；
- 分帧：stdout 增量按 `\n` 切分，每行一条 JSON-RPC（规范要求消息内不得含嵌入换行）；容忍空行；非法 JSON 行记日志丢弃；
- stderr 全量视为日志（规范允许任意级别日志），滚动缓存尾部 200 行供设置页查看，**不**把 stderr 输出当作错误条件；
- 环境策略：最小基础 env（PATH/HOME/LANG/TMPDIR）+ 用户显式配置的 env；**绝不继承/透传 QuickShow 的 LLM API Key**；
- cwd 默认 `$HOME`，可配置；
- 进程退出监听（`terminationHandler`）→ 状态机流转 + 未决请求全部以失败收尾。
- 进程监督须覆盖独立进程组中的启动器及其后代；脱离进程组的 daemon 不受保证，配置说明要求 Server 前台运行。原生进程组启动方案在 M1 验证，不得误杀其他同名程序。
- 分帧前限制消息/未完成行字节数，异步排空 stdout/stderr；日志同时限制行数与总字节数并脱敏，超限协议输入关闭连接，避免无限行或无界缓冲耗尽内存。

**Streamable HTTP（M3）**

- 单一 MCP endpoint；每条客户端消息 = 一次 POST，`Accept: application/json, text/event-stream`；响应为 JSON 或 SSE 两种形态都支持（SSE 解析复用 `AIChatService+Streaming` 的手写解析模式）；
- 握手响应携带 `Mcp-Session-Id` → 后续请求必带；后续请求带 `MCP-Protocol-Version: <协商版本>` 头；
- 会话失效（404 + 旧 session）→ 自动重新 initialize 一次；401 → 触发 OAuth 流（§5.9）；
- 可选 GET 打开服务端通知流（405 视为 Server 不支持，正常降级）；关闭时 DELETE 终止会话（405 容忍）；
- 断线 ≠ 取消：取消必须显式 `notifications/cancelled`；`Last-Event-ID` 续传为 P2；
- 安全：非 loopback 地址强制 HTTPS；凭据按 Server 隔离存储。
- 正确接受通知/响应 POST 的 202 无正文；SSE 支持分块 UTF-8、CRLF、多行 data 与注释，不直接假定 LLM 流解析器已兼容。取消/EOF/错误必须关闭本地任务并收尾请求。
- 重定向不自动跨 origin 携带 Authorization；发现元数据地址也需校验 scheme、目标与跳转，远程 Server 不得借发现过程静默访问本机/内网。重初始化后由调用层判断是否允许重发，遵守 §5.3 的结果未知规则。

### 5.5 工具桥接（MCPToolBridge）

每个远程工具适配为一个 `AITool`：

| AITool 字段 | 映射 |
|---|---|
| `name` | `mcp__<serverId>__<toolName>`，经 `MCPToolNameCodec` 编码为 `[a-zA-Z0-9_-]`，总长 ≤64；创建时限制 serverId 长度并完整保留来源前缀，只截断工具段并加原名短哈希，确保 Server 通配授权不串来源；维护稳定双向映射，碰撞拒绝注册并告警 |
| `displayName` | `<Server 名> · <工具原名>` |
| `category` | `.mcp` |
| `description` | Server 提供的 description（截断上限 1024 字符）+ 前缀来源标注 |
| `parametersSchema` | 保存原始 `inputSchema`，作为服务端契约；声明前由 `ToolSchemaAdapter` 校验当前 Provider 支持性 |
| `effectiveParametersSchema` | 不混入内置 `description` 动作意图参数；经统一编码入口应用 Provider 的无损适配。无法表示的 schema 禁止向该 Provider 声明，并展示原因，不删除约束伪造兼容；动作意图由参数摘要呈现 |
| `isDangerous` | 不由此布尔裁决，统一走 `MCPRiskEvaluator`（§5.6） |
| `executionPolicy` | M1–M3 默认 `.serial`，Server 并发能力需后续独立验证，不从只读标注推导 |
| `execute` | `tools/call` → 结果映射；执行器新增受策略上限约束的超时钩子（默认 30s，最高 120s），取消联动 MCPClient。M3 等待 elicitation 时暂停执行计时，交互结束恢复；取消不等于撤销 |

**结果映射**（→ 执行器统一的 `{"ok":...}` 包装）：

- M1–M3 仅文本/结构化结果：text → 文本拼接；嵌入文本资源保留正文和 URI，resource_link 保留名称/URI；image/audio/二进制资源返回类型与「当前不支持」占位，不把 base64 塞入文本，不自动下载 URI；
- `structuredContent` 存在 → 作为 `data`，同时保留文本、警告及资源指针，不因优先结构化而丢失其他内容；
- `isError == true` → `{"ok":false,"error":<文本>}`（工具执行错误，模型可自我纠正，符合规范语义）；
- 总文本上限 32,000 字符，超限截断并附「[结果已截断]」标记。
- 截断须保留合法 JSON 包装；结构化数据超预算时返回截断状态与有限预览，不切断 JSON 字节串。多模态另立改造项，覆盖 wire 模型、持久化、Provider 编码与体积预算后才承诺模型可见。
- 2025-11-25 schema 默认方言为 JSON Schema 2020-12；适配测试覆盖 `$ref`/`$defs`/组合类型、嵌套与 strict 限制。不支持工具调用的 Provider 不获得虚假工具能力。

### 5.6 风险映射（MCPRiskEvaluator，挂入 ToolRiskClassifier 策略链）

第一性原理：**Server 的 annotations 是自我声明，等同于嫌疑人自审，只能作提示不能作授权**。

```swift
final class MCPRiskEvaluator: ToolRiskEvaluator {
    func canEvaluate(toolName: String) -> Bool { toolName.hasPrefix("mcp__") }
    func evaluateRisk(tool: AITool, arguments: [String: Any]) -> ToolRiskLevel {
        // 1. destructiveHint == true → .destructive（硬门禁，不可被规则绕过）
        // 2. Server 被用户标记为「信任」且 readOnlyHint == true 且 destructiveHint != true
        //    → .readOnly（免审直通）
        // 3. 其余一律 .scopedMutation(suggestedScope: .toolName(name: tool.name))
        //    → 抽屉审批，⌘⏎ 可记忆「本会话允许该工具」
    }
}
```

- 策略链顺序：`ShellSemantic → File → MCPRisk → Default`（MCP 评估器以命名空间前缀命中，与内置工具零交集）；
- 信任只读标注是 **Server 级独立显式设置**，默认关闭，与允许启动进程分开；这表示用户委托相信该来源，不是宿主验证了实际副作用。遗漏 destructiveHint 不等于确定安全；未知调用仍可能有破坏性，不能声称硬门禁能识别所有远端危险行为；
- `.tool(name:)` 规则可复用，但 MCP 规则额外绑定配置修订号与工具定义摘要；变更定义、传输目标、命令/参数/env/cwd/认证或撤销信任时失效。缺少 destructiveHint 不按只读处理，显式 destructive 永不进入记忆放行；
- ShadowGuard 当前仅审查 shell；M1–M3 不扩展到未知 MCP 语义，不将模型审查作为安全证明。

### 5.7 Resources 与 Prompts（M3）

- **Resources**：不逐资源生成工具（避免工具爆炸）。注入一份资源目录摘要进 system 段（上限 2000 tokens，含 URI + 名称 + 描述），配一个内置工具 `read_mcp_resource(server, uri)` 按需读取；该通用工具除名称权限外还须检查目标 Server 的启用、授权与当前 Agent 可访问范围，不得绕过 Server 隔离。`resources/templates/list` 一并列入目录；订阅与 updated 通知为 P2；
- **Prompts**：`prompts/list` 结果注册为 `/` 命令（`MCPPromptSource`）；按声明收集必需 arguments 后调用 `prompts/get`，所有返回角色/文本均作为外部模板预览，用户确认后发送；不伪造成模型已说过的话，不提升为宿主 system 指令。不支持的非文本块明确占位，命令用来源命名空间消歧；
- **Elicitation**（M3）：仅声明 `elicitation: {form: {}}`，映射到现有提问抽屉；覆盖字符串、数字/整数、布尔、单选/多选和带标题枚举，并在发送前校验。ESC/关闭 → `cancel`，显式拒绝 → `decline`，确认 → `accept`；不声明 URL 模式，收到不支持模式返回 `-32602`。表单不用于收集密码、token 等敏感凭据；明确来源并限制请求频率；
- **Sampling**：不实现（Server 借用宿主模型涉及费用与注入风险，长期保持不声明；如未来需要，必须逐次审批）；
- **Roots**（P2）：若用户配置了工作区目录，声明 roots 能力并应答 `roots/list`。

### 5.8 配置模型与持久化

```swift
struct MCPServerConfig: Codable, Identifiable {
    var id: String                  // 创建后不可编辑的稳定 slug，用于命名空间与 Keychain
    var name: String                // 展示名
    var isEnabled: Bool
    var transport: Transport        // .stdio(command, args, env, cwd) / .http(url, headers)
    var autoConnect: Bool           // true=启用即连；false=默认，按需拉起
    var keepAlive: Bool             // 常驻豁免闲置回收
    var revision: Int               // 安全相关配置变更时递增，失效缓存与既有规则
    var launchApproval: String?     // 已确认的启动配置摘要；不匹配则重新确认
    var trust: TrustLevel           // 默认未信任；独立选择信任 readOnlyHint
    var toolOverrides: [String: Bool]  // 工具级开关（缺省 = 启用）
    var timeoutSeconds: Int         // 默认 30
    var idleShutdownMinutes: Int    // 默认 10
}
```

- 非敏感配置：`~/Library/Application Support/QuickShow/MCPServers.json`（与 `AIChats/` 同级，沿用 ChatSessionStore 的存储模式）；
- 敏感值（env 中标记为 secret 的值、HTTP Authorization 头、OAuth tokens）：Keychain（service `cn.chiproad.QuickShow.mcp`，account `<serverId>/<key>`），JSON 中只存引用；
- 工具热更新：收到 `notifications/tools/list_changed` → 重新 `tools/list` → 刷新 Source 快照（下一轮请求生效）。
- 目录缓存独立存入 `MCPCatalogs/<serverId>.json`，不含凭据和工具结果，不因缓存存在自动授予权限。写入采用原子替换；导入配置先预览差异，全部按未授权/未信任处理，禁止导入后自动运行。
- 密钥默认进 Keychain；日志/错误/导出均脱敏。显示名可改，稳定 ID 不改；删除 Server 时撤销会话规则并清理对应缓存与凭据。

### 5.9 OAuth 2.1（M3，远程 Server 认证）

只复用现有 loopback 回调与浏览器授权基础设施，不照搬特定 Provider 的固定端点、client ID 或 scope：

1. 401 → 拉取 Protected Resource Metadata（RFC 9728，`WWW-Authenticate` 或 `.well-known` 回退）定位授权服务器；
2. 授权服务器元数据发现（含 OIDC Discovery 回退）；
3. 注册顺序：已有预注册信息 → AS 声明支持时使用 CIMD → 有 `registration_endpoint` 时使用 DCR → 用户手填预注册信息。CIMD 需要 QuickShow 的公开 HTTPS metadata 文档，托管地址与允许的 loopback redirect 尚未确定，列为 M3 开工门槛；不可用时不伪造地址；
4. PKCE 授权码流：校验 AS metadata 的 `code_challenge_methods_supported`，缺失或无 S256 则停止；使用 S256、随机且校验匹配的 state、有界回调等待与系统浏览器，取消时清理监听；
5. 授权请求和 token 请求均必须携带 RFC 8707 `resource`（目标 MCP Server 的 canonical URI），不以 Keychain 按 Server 分组替代 audience 绑定；scope 优先取 401 challenge，缺失按 PRM 规则回退；403 insufficient_scope 按有界 step-up 处理；
6. token 按 Server/resource/授权服务器及客户端身份隔离存 Keychain，串行合并 refresh，不跨 origin/其他 Server/模型传递。只向目标资源发送为其签发的 token，不复用 QuickShow 的 LLM 凭据。

---

## 6. SKILL 技术方案

### 6.1 格式兼容（Agent Skills 开放标准）

```
skill-name/
├── SKILL.md          # 必需：YAML frontmatter + Markdown 指令正文
├── scripts/          # 可选：可执行脚本
├── references/       # 可选：参考文档
└── assets/           # 可选：模板与资源
```

frontmatter 字段（规范约束）：

| 字段 | 必需 | 约束 | QuickShow 处理 |
|---|---|---|---|
| `name` | 是 | 1–64 字符，小写字母/数字/连字符，不以连字符开头结尾，无连续 `--`，与父目录名一致 | 按下述校验策略展示错误/警告，不静默改名 |
| `description` | 是 | 非空、≤1024 字符，说明做什么、何时用 | 目录段注入，供模型判断任务匹配 |
| `license` | 否 | 许可证名或文件引用 | 设置页展示 |
| `compatibility` | 否 | ≤500 字符，环境要求 | 设置页展示；不满足时仅提示不阻断 |
| `metadata` | 否 | string→string 映射 | 透传展示 |
| `allowed-tools` | 否 | 空格分隔的预批准工具串（实验性） | 只展示声明与兼容诊断，不批量授权（§6.6） |

### 6.2 发现与解析

**扫描目录**（优先级从高到低，同名技能高优先级覆盖低优先级并在设置页标注来源）：

1. `~/.quickshow/skills/`（QuickShow 原生位置）
2. `~/.agents/skills/`（跨客户端互操作约定）
3. `~/.claude/skills/`（务实兼容存量生态；设置页可关，默认开——见开放问题）
4. 用户在设置页添加的自定义目录

扫描规则：目录下**含 `SKILL.md` 的一级子目录**即一个技能；启动时扫描 + 设置页「刷新」按钮 + FSEvents 监听热重载（P2）。项目级 `.agents/skills` 依赖工作区目录概念，随 roots 一并放 P2。

**零依赖 frontmatter 解析**：不引入 YAML 库，但简单字段不代表只需逐行切分。实现有明确语法边界的解析器，兼容常见标准技能，不宣称完整 YAML 实现：

- 支持 UTF-8/BOM、LF/CRLF、独立行 `---` 边界、普通标量、单/双引号及转义、多行引号字符串、`|`/`>` 块标量及 `+/-` 尾换行规则、缩进和引号感知行内注释；metadata 解析 string→string 映射，不做隐式数字/布尔转换；
- 未知可选扩展字段可跳过并警告；缺必需字段、重复关键字段、必需字段语法不支持/解析失败、非法 name 字符或无法唯一定位技能时 invalid。name 超长、目录名不一致等可明确警告并加载，但以独立来源 ID 标识，不静默覆盖另一技能。该策略区分格式规范与客户端宽容策略，不把解析错误当成功；
- 不解析任意 YAML tag、alias/anchor 或执行构造；给出具体位置与原因，禁止悄悄丢失 description。SKILL.md 读取设字节硬上限（§9），正文 5000 tokens 是作者建议，不替代请求硬预算。

### 6.3 渐进式披露（三层加载）

| 层 | 内容 | 时机 | 成本 |
|---|---|---|---|
| 1 目录 | name + description | 请求组装时，工具循环沿用有效快照 | ~50–100 tokens/技能 |
| 2 指令 | SKILL.md 完整正文 + 附带文件清单 | 激活时 | 建议 <5000 tokens，受实际硬预算约束 |
| 3 资源 | scripts/references/assets 具体文件 | 指令引用时 | 按需（read_file） |

**目录段**（`AIChatState+RequestAssembly` 新增 systemParts 段）：

```
可用技能目录（任务匹配时先调用 load_skill 加载完整指令，再按指令行动）：
- pdf-processing：合并/拆分/填表 PDF。当用户需要处理 PDF 文件时使用。
- ...
```

预算：最多 30 个已启用技能 / 2500 tokens；按稳定的名称与来源 ID 顺序逐项装入，不切断单项内容，超限可在设置页或 `/` 面板手动选择，不影响发现列表。无可用技能时不注入该段（零成本）。

**激活链路（模型驱动）**：内置工具 `load_skill(name)`（category `.skills`，纯读知识 → `.readOnly` 免审）：

1. 基于执行上下文校验来源 ID、技能启用状态、当前会话/Agent 可用性与文件版本；同名歧义要求选择来源，不由模型猜；
2. 预算预检成功后返回完整正文、技能目录绝对路径与有界文件清单（第 3 层指针），再原子记录激活态；预检同时覆盖完整工具返回的字符上限与本轮 token 预算，必要时缩减附件清单，正文仍装不下则返回原因，不截断指令冒充完整加载；
3. 当前工具循环立即靠工具结果获得指令；后续请求依靠激活态重建正文。两者的短暂重叠计入总预算，不能宣称「从未落入聊天消息」；
4. 重复激活同一版本可返回「已加载」；内容未在当前有效上下文时需补回，不能只因持久化名单存在就省略正文。

**激活链路（用户驱动）**：`/pdf-processing` → 命令面板选中 → 执行与工具激活相同的来源/版本/预算校验，再记录激活态（不经过工具调用），输入坞显示激活胶囊。命令名与 MCP prompts、保留命令 `unload` 冲突时使用来源限定名。

### 6.4 激活态与上下文管理

- `ChatSession` 新增可选 `activatedSkills: [SkillActivation]?`（来源 ID、展示名、正文摘要、最近使用顺序）；同步修改自定义 CodingKeys、初始化与 decodeIfPresent，旧会话文件无需迁移。只存名字无法防止目录覆盖后悄悄换技能；
- **每个用户请求/子 Agent 任务初始化时的技能快照**由共享组装器生成；当前工具循环不重建整份 system，同轮新激活通过工具结果生效，下一次用户请求再同步激活段。压缩或显式重建请求时恢复当前仍激活且版本有效的正文；每次模型发送仍独立执行预算与权限快照检查；
- 并发激活最多 3 个且受正文总预算约束；新增激活时按 LRU 淘汰，仍装不下则拒绝新激活并说明原因。淘汰只停止未来重复注入，不能从模型已见的工具结果/历史中抹除指令，不是安全撤权；
- 用户点胶囊移除 / 输入 `/unload <name>` → 取消激活；
- 多 Agent 模式：扩展 `launch_subagents` schema 与 `AgentCoordinator`，显式携带可用技能来源 ID、独立激活态与执行上下文；默认不继承主会话激活态，不反写主会话。明确当前子 Agent 仅 3 个工具轮，load_skill 消耗一轮，优先允许派发时携带已选技能，避免加载即耗尽执行轮次；
- 刷新/恢复会话时核对来源与摘要；正文变化或同名来源替换后停止自动重注入，提示重新激活。禁用技能同时从目录和未来激活快照移除；它不自动撤销之前经用户授予的独立工具权限，权限需单独撤销。

### 6.5 脚本执行

- 技能指令中的脚本以相对路径书写；`load_skill` 返回技能目录绝对路径，模型据此构造命令（如 `python3 ~/.agents/skills/pdf-processing/scripts/fill_form.py ...`）；
- 执行一律走现有 `run_shell` → `ShellSemanticRiskEvaluator` → 权限策略/审批链，**不为技能脚本开任何旁路**。当前 run_shell 没有 Undo，任意脚本可能执行不可逆动作，禁止承诺通用回滚；现有文件覆盖快照仅适用于对应内置文件写入工具；
- `run_shell` 当前默认禁用：技能带脚本而 run_shell 未启用时，`load_skill` 结果附注「脚本执行需先在设置中启用 run_shell」，指令类技能不受影响。

### 6.6 allowed-tools 的安全处理

规范语义是「技能预批准工具」，但技能文件与 Server annotations 同属**不可信内容**——允许文件自我授权等于让嫌疑人自审。QuickShow 的处理：

- M2 只展示声明与兼容诊断，不批量授权：`Bash(git:*)`、`Read` 等客户端专有工具名/参数约束不能直接映射为整个 `run_shell` 或 `read_file`；未知声明原样显示为不支持；
- ⌘⏎ 仍仅记忆**当前调用经宿主产生的准确作用域**，不是放行技能列出的全部工具。不能无损表达的参数约束不降级为更宽规则；破坏性硬门禁保持不变；
- 如未来支持批量授权，须另行设计强类型映射与逐项确认，不属于 M2。allowed-tools 不改变全局开关、Agent 白名单与请求执行允许集。

### 6.7 技能安全边界

1. **加载即可见**：任何激活都在 UI 留痕（胶囊 + 工具卡片），绝无静默注入；
2. **加载路径边界**：枚举/读取技能文件时校验真实路径的目录组件（非字符串前缀），拒绝越界符号链接并防检查后替换；限制文件数、深度与字节数。这只保护宿主的技能加载器，不是通用 read_file/run_shell 的进程沙箱；
3. **不自动执行**：加载技能绝不触发任何脚本，执行必须经模型发起工具调用 + 宿主审批；
4. **内容标记**：目录描述和正文均视为外部内容，采用转义/长度边界明确的序列化结构，不仅靠可伪造的文本分隔符。宿主明确不得覆盖其策略与当前用户指令；来源标记和提示词不能消灭注入风险，真正授权仍由执行期检查决定；
5. **目录信任**：自定义目录添加时展示路径确认；扫描不跟随目录符号链接出界。

---

## 7. 权限与安全治理汇总

| 威胁 | 对策 |
|---|---|
| 恶意 MCP Server 工具描述注入指令 | 来源标注、请求快照与宿主执行权限；截断/提示词不能保证阻止注入 |
| annotations 自我声明骗免审 | 仅「用户信任的 Server + readOnlyHint」才降级免审；destructiveHint 升硬门禁 |
| 技能文件自我授权 | allowed-tools 只展示，⌘ 仅记忆当前宿主裁决的准确作用域，不批量放行 |
| 技能脚本破坏 | 走 run_shell 风险与权限链；无通用 Undo，语义分析不能保证识别脚本内部行为 |
| 本地 MCP 程序自主读写/联网 | 独立启动授权；与当前用户同权限，不宣称工具审批提供进程沙箱 |
| stdio 命令注入 | Process 参数数组直传，无 shell 插值；首次启用展示完整命令行确认 |
| 凭据泄露 | 最小 env + 显式配置；LLM Key 绝不透传；OAuth token 按 resource 隔离、禁透传 |
| 路径逃逸 | 技能资源路径禁闭校验；扫描不跟随出界符号链接 |
| 上下文膨胀 | 目录/工具数/结果体积多级预算（§9） |
| 远程会话劫持 | 非 loopback 强制 HTTPS；Mcp-Session-Id 严格回带；401 走标准 OAuth |
| 闲置进程驻留 | 按需执行 + 在途引用计数 + 正常退出有界进程组清理 |

与既有体系的关系：复用 `ToolRiskClassifier`、`ToolPermissionPolicyEngine` 与输入坞审批交互；增加请求执行上下文及 MCP 授权版本绑定。ShadowGuard 仍只覆盖现有 shell 场景，未知 MCP 工具不自动经模型审查放行。已知破坏性可硬拦，未知远端实现/脚本副作用不能靠声明或模型推理获得确定性证明。

---

## 8. 数据与持久化汇总

| 数据 | 位置 | 形态 |
|---|---|---|
| MCP Server 配置 | `Application Support/QuickShow/MCPServers.json` | Codable JSON |
| MCP 敏感凭据 | Keychain `cn.chiproad.QuickShow.mcp` | env secret / headers / OAuth tokens |
| MCP 启用与工具开关 | 随配置 JSON（isEnabled / toolOverrides） | — |
| MCP 目录缓存 | `Application Support/QuickShow/MCPCatalogs/<serverId>.json` | 定义与配置版本绑定，不含授权/结果 |
| 技能启用集 | UserDefaults `ai.skills.disabled`（[String] 稳定来源 ID，默认全启用） | 发现不等于激活；来源变化不继承旧激活 |
| 技能自定义目录 | UserDefaults `ai.skills.extraDirs`（[String]） | — |
| 兼容扫描开关 | UserDefaults `ai.skills.scanClaudeDir`（Bool，默认 true） | — |
| 会话激活技能 | `ChatSession.activatedSkills: [SkillActivation]?` | 来源/摘要/使用顺序，旧文件可选解码 |
| 技能本体 | 用户目录（只读消费，QuickShow 不写入） | SKILL.md 标准格式 |

---

## 9. 性能与上下文预算

| 项 | 预算 | 超限行为 |
|---|---|---|
| 技能目录段 | ≤30 技能 / ≤2500 tokens | 整项选择 + 设置页提示，不切断描述 |
| 单技能正文 | 作者建议 ≤5000 tokens；实际受总预算 | 不截断指令；装不下则拒绝激活 |
| 并发激活技能 | ≤3，正文合计 ≤8000 tokens | LRU 停止未来注入；仍超限则拒绝新增 |
| 外部工具声明 | ≤80（单 Server ≤60），名称/描述/schema 合计 ≤8000 tokens | 按稳定顺序整项选择，其余排除声明与执行允许集 |
| 单工具 schema | ≤64KiB UTF-8，限制嵌套深度/引用展开量 | 过大或无法表示则不声明，不删除字段约束 |
| 工具 description | ≤1024 字符 | 截断 |
| 资源目录段 | ≤2000 tokens | 整项选择并提示省略数量 |
| 单次工具结果 | ≤32,000 字符且受请求总预算；图片/音频暂不支持 | 合法 JSON 包装内预览与截断标记，不嵌入 base64 |
| 技能加载输入 | SKILL.md ≤1MiB，附带清单 ≤200 项/深度 ≤4 | 超大拒绝加载，清单截断有标记，不预读全部附件 |
| MCP 传输入口 | 单消息/未完成行 ≤16MiB，stderr ≤200 行且 ≤256KiB | 入口即限流限量，超限关闭协议连接；日志滚动截断 |
| 待机开销 | MCP 无连接时无自身子进程/轮询/重连计时任务 | 不以应用总 CPU 绝对 0.0% 作为不可控保证 |
| 首连开销 | 已安装 Server 的 initialize + tools/list 目标 <2s | 外部 npx/uvx 首次下载不计入；独立启动超时、可取消、不阻塞 UI |

**统一预算闸门**：`ContextBudgetPolicy` 在每次模型发送前计算系统基线、技能目录/正文、资源目录、完整工具 schema、历史及本轮工具结果，预留输出与工具返回空间。优先保留宿主约束/当前用户请求/有效工具调用配对，再选择外部声明与目录；压缩历史后仍超限则返回可操作错误，不发送已知超限请求，也不丢失必须配对的工具结果。工具循环和子 Agent 使用同一策略。

以上数值是待 §12 确认的策略初值，不散落在实现内。优先复用模型对应 token 计数；无准确 tokenizer 时使用经多语言/JSON 样本校准的保守 UTF-8 字节估算与安全余量，标明估算属性，不把字符数等同 token 数。预算选择顺序固定，已有激活优先于新目录；改变能力集合时重新生成请求快照。

---

## 10. 实施路线图

> 每个里程碑独立可编译、可回退、可发版；遵循 AGENTS.md：改码即编译重启，提交须用户明确指示。

### M1 · MCP stdio 工具接入（核心价值闭环）

- 新增：MCP 协议/stdio/客户端/管理器、配置与目录缓存、命名 codec、桥接/Source/风险策略、请求快照、schema 适配、预算策略及设置分组；
- 改造：`AIToolRegistry` 全部查询/分组入口与 `ToolNameMatcher`、`ToolCategory`、`ToolRiskClassifier`、`AIToolExecutor`（必需的执行期权限/版本校验与超时取消钩子）、主/子 Agent 请求组装与 Provider schema 编码入口、`AISettingsSections`（开关存储分离）、`AIServiceSettingsForm`、正常退出协调与进程组监督；
- **验收门槛**：冷启动无缓存时能通过显式发现建立工具目录；回收后缓存仍可声明，调用才重连且验证定义；三条工具型 Provider 对支持的 schema 可用，不支持者可见禁用；仅文本/结构化结果真实送达；全局启用但 Agent/请求未授权的调用在执行期拒绝；禁用/变更定义后旧快照与放行规则失效；tools/listChanged 同样生效；
- **安全与生命周期验收**：启动授权不自动信任只读标注；未知风险首次人工审批，⌘⏎ 只放行当前准确作用域，显式 destructive 不能记忆放行；并发连接只启动一次；ESC 不取消其他会话；取消/超时/退出竞态只收尾一次；在途/待审批不回收；正常退出启动器与同组后代无残留；结果未知写操作不重放；超大消息/schema/结果不造成无界内存或超预算请求。

### M2 · Skills 全链路

- 新增：`SkillModels` / `SkillFrontmatterParser` / `SkillStore` / `LoadSkillTool` / `SkillActivationManager` / `SlashCommandRegistry` / `SlashCommandPopupView` / `SkillSettingsSection`；
- 改造：`ChatSession` 自定义 Codable（+activatedSkills）、共享技能上下文组装器与主回路工具轮预算、`LaunchSubagentsTool` schema/`AgentCoordinator` 独立激活态、`ToolCategory`、注册表与存量 load_skill 启用兼容、输入坞 `/` 触发；
- **验收**：块标量/多行/引号等常见标准技能能解析，错误有具体诊断；双激活链路使用同一校验；同轮 load_skill 结果立即可用，压缩后有效激活正文可恢复；来源变化不静默替换；LRU/卸载不声称擦除历史；主子 Agent 不串激活态；禁用工具在执行期不可绕过；脚本沿现有权限链执行且不承诺 Undo；allowed-tools 不批量授权或扩大参数约束；超大技能拒绝而非静默截断。

### M3 · Streamable HTTP + 生态互通

- 新增：`StreamableHTTPTransport` / `MCPAuthCoordinator` / `read_mcp_resource` 工具 / `MCPPromptSource`；
- 能力：form elicitation 映射提问抽屉并支持交互等待；Claude Desktop / Cursor 配置安全导入；复用 M1 tools/listChanged，不重复推迟；
- **验收**：JSON/SSE/202/405/会话失效路径与 OAuth resource/PKCE/注册兜底均可测试；不跨目标泄漏凭据；远程断连不重放结果未知写操作；资源读取复用预算、执行权限和来源检查，URI 不被宿主擅自当 URL 下载；prompts 参数/角色预览正确；form elicitation 全类型可操作、ESC 返回 cancel、跨会话归属不明拒绝；导入配置不自动运行。

### M4 · 打磨与进阶

- roots / 工作区目录与项目级技能；资源/prompts listChanged、资源订阅；Last-Event-ID 续传；技能目录导入导出；FSEvents 热重载；闲置策略与监控指标打磨。
- 多模态独立立项：先明确 wire/持久化/各 Provider 真实图像输入通道，再制定二进制/上下文预算和降级矩阵；不以 data URI 文本替代视觉支持。roots 仅是提供给 Server 的目录提示，不是文件访问沙箱。

---

## 11. 测试方案

1. **单元测试**（沿用 `AI/Tests` 模式）：frontmatter 块标量/多行/转义/注释/BOM/CRLF/重复字段/不支持语法、来源消歧与 name 校验；工具名消毒/碰撞/长名称、schema Provider 矩阵、风险与启动授权独立性、权限版本失效、命名空间白名单、统一预算与合法 JSON 截断；
2. **Mock 传输集成测试**：冷发现→缓存→回收→按需连接、single-flight、握手版本、分页/cursor 循环、双向请求同 id、未知能力请求、listChanged、工具定义变化、isError、超大消息/无换行输出、取消/超时/迟到响应/退出竞态；并发会话隔离、审批中撤权、Agent 越权调用与结果未知写操作不重放必须有负向测试；
3. **真实 Server 冒烟**：固定可复现版本的 filesystem/everything/git 参考 Server（stdio），按其真实发布方式启动，不假定全部均为 npm 包；M3 以可控 HTTP/OAuth 测试 Server 覆盖 JSON/SSE/202/405/401/403/404/跨源重定向，公开端点仅作补充，不依赖其稳定性；
4. **GUI 冒烟**：按 `macos-gui-smoke-test` playbook 实测设置页添加流程、抽屉键盘协议、`/` 面板导航；
5. **性能回归**：待机 CPU 采样并记录方法/时长（无连接 / 回收后），确认无 MCP 自身子进程与轮询任务；分别记录外部安装、spawn、握手/发现耗时；全请求预算、多语言估算误差与大输入内存峰值；
6. **Skills 与多 Agent 回归**：同轮加载/重复加载/压缩恢复、LRU 与历史残留、文件内容替换、read_file 与加载器边界区分、符号链接/路径组件逃逸、子 Agent 技能隔离与轮次限制；脚本权限不会被 allowed-tools 扩大；
7. **原生进程与认证集成**：测试启动器生成后代、stderr 背压、闲置/退出进程组清理；OAuth 用本地受控授权服务器验证 resource、state、S256、取消回调、refresh 合并、预注册/CIMD/DCR/手填分支和凭据脱敏。

---

## 12. 开放问题（实施前需确认）

| # | 问题 | 建议默认 |
|---|---|---|
| 1 | `~/.claude/skills` 兼容扫描默认开还是关？ | 开（存量生态价值大，设置可关） |
| 2 | 预算数值（30 技能 / 80 工具 / 3 激活 / 10 分钟回收）是否合适？ | 先按建议值落地，全部做成可配常量收敛于策略模型 |
| 3 | 工作区目录概念（roots + 项目级技能）何时引入？ | M4，避免 M1–M3 范围膨胀 |
| 4 | Sampling（Server 借用宿主模型）是否永久不做？ | 建议永久不声明；如未来需要必须逐次审批 |
| 5 | 技能是否需要内置「创建技能」向导？ | M4 之后再议，先消费存量生态 |
| 6 | CIMD 的公开 HTTPS metadata 托管在哪里，loopback redirect 如何登记？ | M3 开工前确认；未落实时使用预注册/支持的 DCR/手填，不虚构托管地址 |

实施阶段门槛：M1 先验证原生进程组监督、三条工具型 Provider schema 支持矩阵与现有执行器取消行为，再细化代码任务。所有新增数值集中到策略模型；不为落实本讨论稿提前创建持久化配置。UI 只沿用本文已有交互方向，具体视觉与键盘事件优先级在界面实施前单独验证。

---

## 13. 参考资料

- [MCP Specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25)
- [MCP 2025-11-25 Key Changes](https://modelcontextprotocol.io/specification/2025-11-25/changelog)（icons、OAuth 增强、elicitation 增强、tasks 实验性等）
- [MCP Transports（stdio / Streamable HTTP）](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [MCP Authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)（resource、PKCE、CIMD 与注册兜底）
- [MCP Elicitation](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation)（form/URL 模式与 accept/decline/cancel）
- [One Year of MCP: November 2025 Spec Release](https://blog.modelcontextprotocol.io/posts/2025-11-25-first-mcp-anniversary/)
- [Agent Skills Specification](https://agentskills.io/specification)（目录结构、frontmatter 字段约束）
- [Agent Skills: Adding skills support](https://agentskills.io/client-implementation/adding-skills-support)（三层渐进披露、发现/激活/上下文管理指引）
- [agentskills/agentskills GitHub](https://github.com/agentskills/agentskills)
- 工程内参考：`docs/AI_TOOL_PERMISSION_ARCHITECTURE.md`（权限治理体系）、`QuickShow/AI/Tools/AIToolRegistry.swift`（注册表）、`QuickShow/AI/Tools/ToolRisk.swift`（风险策略链）
