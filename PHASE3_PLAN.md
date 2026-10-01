# QuickShow Phase 3 · AI 对话窗口实施计划

> 本文档为自包含实施计划，供新会话直接开工使用。开工前请先读 `AGENTS.md`（项目协同规范）与本文件「开放问题」一节（需与用户确认后再动手）。

---

## 0. 项目背景（新会话必读）

- **QuickShow**：macOS 原生悬浮信息悬浮窗，纯 Swift + AppKit + SwiftUI，**零外部依赖**（绝不引入 npm/SPM 第三方生态），构建用 xcodebuild + XcodeGen，产物 `./build_release`。
- 核心哲学：**零打断 · 即看即走 · 全键盘盲操 · 极致轻量**。待机 CPU 0.0%，ESC 毫秒级归还焦点。
- 当前版本 **1.3.0**（commit 39db80b）：一瞥态状态栏 + Bento 监控看板（Tab）+ **整面板日历视图（G 键，PanelContext 路由）** + Now Playing（vendored mediaremote-adapter 桥接）。
- 最低支持 macOS 13.0（注意：禁止使用 macOS 14+ 独占 API，如 `Calendar.Component.isLeapMonth` 枚举组件——用 `DateComponents` 老属性替代的先例见 `LunarCalendar.swift`）。
- 修改代码后必须执行 `./scripts/restart.sh`（已内置：自动 xcodegen + 编译失败大声报错 + 杀旧进程拉新二进制）。

### 关键架构接入点（Phase 3 直接相关）

| 文件 | 机制 | Phase 3 接入方式 |
|---|---|---|
| `Core/HotKeyManager.swift` | CGEventTap 监听 flagsChanged 做双击修饰键判定；当前四选一（⌘⌃⌥⇧）作为主面板全局 Toggle | **需扩展：双修饰键分流**——主热键与 AI 窗热键各自独立注册（AI 默认双击 ⌥⌥），互不抢占 |
| `Core/PanelManager.swift` | 主面板 NSPanel 生命周期、`onKeyDownAction` 键位分发（`(NSEvent) -> Bool`）、`targetSize` 尺寸动画、焦点毫秒级归还 | I 键（keyCode 34）case 接入：面板激活时按 I 打开 AI 窗 |
| `Utilities/FloatingPanel.swift` | key window NSPanel、`sendEvent` 拦截（ESC/全局键）、**firstResponder 为 NSTextView 时放行**（文本输入不被全局键劫持——1.3.0 修复的高危项） | AI 窗参考/复用同款面板基类；**AI 输入框聚焦时全部按键必须放行**，此机制必须继承 |
| `Core/AppState.swift` | `PanelContext` 枚举（glance/dashboard/calendar）+ `contextHotkeys` 注册表 + `enterContext/exitContext` 来源态恢复管线 | AI 窗是**独立窗口**，不进 PanelContext 路由；I 键动作直接调 AIWindowManager |
| `Utilities/DesignTokens.swift` | 字号阶梯（正文 SF Pro `text()` / 数字等宽 `mono()`）、文本色三档（`contentSecondaryStrong` 0.65 / `contentTertiary` 0.55 / `idleText` 0.45 装饰专用）、间距/圆角/玻璃材质令牌、黑曜石/琥珀双主题 | AI 窗全部视觉走既有令牌；新字号档位按需新增（如对话正文档） |
| `Views/SettingsView.swift` | macOS 系统侧边栏式设置中心（通用/一瞥底栏/监控看板/快捷键/关于） | 新增「AI 服务」设置分组 |
| `Utilities/ScreenHelper.swift` | `PanelLayoutMetrics` 三档尺寸（standard/comfort/legacy）+ 屏幕居中计算 | AI 窗尺寸建议复用三档偏好体系 |

### 已占用键位表（防冲突，I 键已预留）

主面板已占用：双击修饰键（呼出）、长按 ⌘ / `?`（速查表）、`Tab`、`Space`、`G`、`1/2/3`（日历内）、`←/→`、`⏎`、`,/.`（媒体）、`M`、`↑/↓`、`A`、`C`、`P`、`O`、`X`、`L`、`D`、`ESC`。
**预留待用：`I`（keyCode 34，AI 窗入口）**。AI 窗内部键位由 Phase 3 自行设计（见 §2）。

---

## 1. 需求规格（已与用户锁定，勿擅改）

1. **独立窄长居中窗口**：AI 对话窗是独立 NSWindow/NSPanel，**不是**主面板内的 PanelContext 视图。
2. **唤出方式（两者并存）**：
   - 全局：默认**双击 ⌥⌥（Option）**唤出/关闭 AI 窗（热键可在设置中更换，与主面板热键体系分流互不冲突）；
   - 主面板：面板激活时按 **`I`** 进入 AI 窗。
3. **OpenAI 兼容协议**：仅三项配置——**Base URL + API Key + Model**。适配任意 OpenAI 兼容端点（官方 / 中转 / 本地 Ollama / vLLM 等）。
4. **纯对话（窗口内多轮）**：单会话上下文连续对话，无分支无历史列表。**历史跨关窗保留（2026-10-01 用户确认）**：关窗后再次唤出仍显示上次对话；持久化到 Application Support 下的 JSON 文件（App 重启后恢复）；`⌘K` 清空重新开始。截断策略照 §4.4。
5. **一键附加剪贴板上下文**：输入区一键把当前剪贴板文本作为附加上下文发送。
6. **SSE 流式**：回复打字机式逐 token 流式渲染。**回复按 Markdown 尽力渲染（2026-10-01 用户确认）**：行内元素（粗体/斜体/行内代码/链接）用 `AttributedString(markdown:)`；围栏代码块（``` ```）按行级预切分为等宽字体段落（附背景色）；标题/列表做前缀样式轻渲染。流式期间以纯文本增量渲染，落定后再整体重渲染为富文本。
7. **ESC 毫秒级还焦点**：AI 窗 ESC 关窗并瞬间把键盘焦点归还原应用（与主面板同款焦点纪律）。
8. **零依赖**：URLSession 手写 SSE 解析、Security framework 手写 Keychain，不用任何第三方 SDK。

---

## 2. 交互与键位设计

### AI 窗口
- **形态**：窄长居中（建议 standard 档约 **560 × 680 pt**，comfort/legacy 档按比例缩减——具体数值实施时按内容密度拿捏并支持三档偏好）；非激活即隐藏，不抢 Dock、不进 ⌘Tab（LSUIElement 应用属性天然满足）。
- **材质与主题**：与主面板同款玻璃材质 + 黑曜石/琥珀主题 + 明暗自适应，全部走 DesignTokens。

### 键位（AI 窗内，全部盲操）
| 键 | 行为 |
|---|---|
| `ESC` | ① 流式生成中：先中止生成（abort 请求）；② 非生成中：毫秒级关窗还焦点 |
| `⏎` | 发送消息（输入框聚焦时为换行语义由实现决定，见下方「输入框键盘语义」） |
| `⇧⏎` | 输入框内换行 |
| `⌘V` / 剪贴板按钮 | 粘贴 / 一键附加剪贴板上下文（附加后在输入区显示「已附加剪贴板 N 字」胶囊，可移除） |
| `⌘K`（建议） | 清空当前会话重新开始 |

**输入框键盘语义（硬性要求）**：输入框聚焦时所有按键放行给第一响应者（复用 FloatingPanel 的 `firstResponder is NSTextView` 放行机制）——这是 1.3.0 刚修复的高危问题（全局键拦截劫持文本输入导致丢草稿），AI 窗绝不能重蹈覆辙。ESC 在输入框聚焦时按上述两阶段语义优先（先中止/后关窗），不进入文本编辑的 cancelOperation。

### 焦点纪律
- AI 窗是 key window（可打字），关窗瞬间 resign 并把焦点毫秒级归还原应用——参考 PanelManager 现有 focus 归还实现。
- 主面板与 AI 窗互斥可见性策略：按 I 进入 AI 窗时主面板淡出（建议）；AI 窗关闭后不自动回主面板（还焦点给原应用）。

---

## 3. 架构设计（模块拆解）

新增文件（全部接入 project.yml 的既有源目录，xcodegen 自动纳入）：

```
QuickShow/
├── AI/                                  # 新目录（或并入 Utilities，二选一，建议独立目录）
│   ├── AIChatService.swift              # OpenAI 兼容 SSE 客户端 + Keychain 存取 + 配置模型
│   └── AIChatState.swift                # 会话状态：messages、流式状态、发送/中止/附加剪贴板
├── Core/
│   └── AIWindowManager.swift            # AI 窗口生命周期：窄长 NSPanel、居中、焦点纪律、ESC
└── Views/
    └── AIChatView.swift                 # 对话 UI：消息列表、流式渲染、输入区、剪贴板胶囊
```

修改文件：
- `HotKeyManager.swift`：双修饰键分流注册（主热键 + AI 热键独立）
- `PanelManager.swift`：I 键 case（34）→ AIWindowManager.toggle
- `SettingsView.swift`：「AI 服务」设置分组
- `AppState.swift`：最小接入（I 键动作转发的粘合点，勿把 AI 逻辑塞进 AppState——该文件已 1200+ 行）

### 数据流

```
AIChatView (SwiftUI) ──观察──> AIChatState (@Published) <──回调/Task── AIChatService
                                   │                            │
                                   │                     URLSession SSE 流
                                   │                     Keychain (apiKey)
                                   └── AIWindowManager 提供窗口环境
```

- **AIChatService**（无 UI 状态）：`send(messages:) -> AsyncThrowingStream<String>`、`abort()`、`apiKey` Keychain 读写（service `com.dzhang.quickshow.ai`，account `apiKey`）、Base URL/Model 存 UserDefaults。
- **AIChatState**：`messages: [ChatMessage]`（role/content/状态）、`isStreaming`、`streamingText`、`clipboardAttachment: String?`；发送 = 追加用户消息 + 创建流式任务增量更新；中止 = task.cancel() 并把半截回复落定。
- **渲染性能**：流式期间只更新最后一条消息的 content（SwiftUI diff 单行更新），历史消息不可变数组，禁止全列表重排。

---

## 4. 技术方案细节

### 4.1 OpenAI 兼容协议（SSE）

```http
POST {baseURL}/chat/completions
Headers: Authorization: Bearer {apiKey}
         Content-Type: application/json
Body: {
  "model": "{model}",
  "messages": [{"role":"system"|"user"|"assistant","content":"..."}],
  "stream": true
}
```

- Base URL 语义：用户填根地址（如 `https://api.openai.com/v1`），代码拼 `/chat/completions`；容错处理尾部斜杠。设置项说明文案写清楚。
- **SSE 解析**（零依赖手写）：`URLSession.shared.bytes(for:)` async sequence，按行读取；`data: {...}` 行解析 `choices[0].delta.content` 增量 append；`data: [DONE]` 结束；忽略 `:` 注释行/心跳行。JSON 用 `JSONSerialization` 或 `Codable`（建议 Codable，delta 结构体）。
- **中止**：持有当前 `URLSessionTask`（或 Task<Task> 双层取消：外层 Task.cancel() 触发 bytes sequence 抛 `CancellationError`），abort 必须立即停止渲染。
- **错误处理**：HTTP 非 2xx 读 body 展示错误信息（如 401 key 无效 / 429 限流）；网络超时（建议 120s 无首 token 判定超时）；错误以一条错误态消息呈现在对话流内（含重试按钮或提示重发），不弹系统弹窗。
- **首 token 延迟**：连接建立后立即在对话流显示「生成中…」呼吸态。

### 4.2 Keychain（零依赖 Security framework）

- `SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate`，kSecClassGenericPassword，service `com.dzhang.quickshow.ai`，account `apiKey`。
- **硬性要求：API Key 绝不落 UserDefaults / plist**（会被 Time Machine 与 iCloud 备份明文带走）。设置界面 API Key 输入框用安全输入样式，已存 key 显示掩码。
- Base URL / Model 是非敏感配置，存 UserDefaults（`ai.baseURL` / `ai.model`，附合理默认值如空串 + 占位提示）。

### 4.3 剪贴板上下文

- 读取 `NSPasteboard.general.string(forType: .string)`；空剪贴板时按钮弱化不可点。
- 附加策略：发送时若有 `clipboardAttachment`，拼接为用户消息的前置上下文（建议格式：剪贴板内容包在明确分隔符中 + 用户问题在后），并在 UI 胶囊显示字数；超长（建议 >8000 字符）自动截断并提示。

### 4.4 会话上下文管理

- `messages` 数组直接作为请求体（含 system prompt——见开放问题 3）。
- 长对话截断：建议保留最近 N 轮（如 20 轮或按字符预算 24000 截断，从最旧整轮丢弃），防止 token 溢出。

### 4.5 窗口与热键

- AI 窗：NSPanel（borderless + 玻璃材质复刻主面板 FloatingPanel 的做法，或直接参数化复用 FloatingPanel 基类——注意 FloatingPanel 现有 ESC/全局键拦截逻辑需要按 AI 窗语义适配，别直接实例化硬套）。`canBecomeKey = true`。
- 双击 ⌥⌥ 分流：HotKeyManager 目前双击判定只有一个目标。扩展方案：双击事件回调携带「当前触发的修饰键」，主面板热键管理器与 AI 窗热键各自认领自己的修饰键（若用户把主面板也配成 ⌥⌥ 则冲突——设置里做互斥校验并提示）。AI 热键默认 ⌥⌥，可选 ⌘⌃⇧ 等其余组合（实现可先只支持默认 ⌥⌥ + 设置里四选一，互斥校验）。
- **左右修饰键区分（2026-10-01 用户确认增补）**：TriggerType 扩为 12 案——4 个「任意侧」（现状类型，双击任一侧均触发，默认值不变向后兼容）+ 8 个左右专属（doubleLeftCmd/doubleRightCmd/…Shift）。判定精确到 keyCode：左⌘54/右⌘55/左⌃59/右⌃62/左⌥58/右⌥61/左⇧56/右⇧60；左右交替按下视为打断（重置双击计时）。互斥校验按「命中 keyCode 集合是否相交」：左⌘+右⌘ 可共存，任意⌘+左⌘ 冲突拒绝。主面板与 AI 热键共用全部 12 选项；设置 UI 按四族分组、每族 左/右/任意 三选。
- I 键：PanelManager `onKeyDownAction` 加 `case 34`（注意修饰键纯净过滤，与 G 键同款——1.3.0 已建立模式）。

---

## 5. 实施步骤（分 lane，供新会话编排参考）

> 建议顺序：Lane A 先行（可独立冒烟验证）→ B/C 并行（不同文件无写冲突）→ D → 集成验收。每步完成跑 `./scripts/restart.sh` 编译验证；**每个 lane 完成后交用户实测一次**（项目惯例：小步验收）。

| Lane | 内容 | 文件 | 验证方式 |
|---|---|---|---|
| **A. 服务层** | AIChatService（SSE 解析/Keychain/协议）+ AIChatState | `AI/AIChatService.swift`、`AI/AIChatState.swift` | 编译 + 临时调试入口（或单元冒烟脚本）真实请求一次流式输出 |
| **B. 窗口与热键** | AIWindowManager + FloatingPanel 适配 + I 键 + 双击⌥⌥ 分流 | `Core/AIWindowManager.swift`、`Utilities/FloatingPanel.swift`、`Core/HotKeyManager.swift`、`Core/PanelManager.swift` | 双击⌥⌥ 唤出空窗 / I 键进入 / ESC 毫秒还焦点 |
| **C. 对话 UI** | AIChatView：消息列表、流式打字机、输入区、剪贴板胶囊、中止态 | `Views/AIChatView.swift` | 真实对话多轮、流式渲染、⌘V/胶囊、中止 |
| **D. 设置** | 「AI 服务」分组：Base URL / API Key（Keychain）/ Model | `Views/SettingsView.swift` | 配置落 Keychain 查证（不落 plist）、错 key 的错误呈现 |
| **集成验收** | 全链路 + 主题/明暗 + 三档尺寸 + 焦点纪律回归（主面板交互不受影响） | — | 按 §6 清单逐项过 |

---

## 6. 验证与验收标准

1. **编译重启**：`./scripts/restart.sh` 零错误零警告新增。
2. **唤出**：双击 ⌥⌥ 唤出/关闭 AI 窗；主面板激活时按 I 进入；两个入口互不干扰主面板原有热键（⌘⌘ 呼出主面板照常）。
3. **焦点纪律**：在 Safari/编辑器聚焦状态唤出 AI 窗 → ESC 关窗 → **焦点毫秒级回到原应用**（打字立即可用，无粘滞）。
4. **流式对话**：配置真实端点后多轮对话，回复逐 token 打字机渲染、无全列表重排卡顿。
5. **中止**：流式生成中按 ESC 立即停止渲染（半截回复保留落定）；中止后再发新消息正常。
6. **输入框键盘语义**：聚焦输入框打字（含中文输入法组字）不被任何全局键劫持；⏎ 发送、⇧⏎ 换行符合定义。
7. **剪贴板**：复制一段文本 → 一键附加 → 胶囊显示 → 发送后 AI 基于该上下文回答；空剪贴板按钮弱化。
8. **Keychain**：`security find-generic-password -s com.dzhang.quickshow.ai` 能查到 key；`defaults read` 无 key 痕迹。
9. **错误路径**：错 key（401）、断网、超时——对话流内优雅呈现错误信息，可重试，无弹窗无崩溃。
10. **视觉**：玻璃材质 + 黑曜石/琥珀主题 + 亮暗模式全部过目；字号/颜色走 DesignTokens 三档色阶（可读性纪律：正文不弱于 contentTertiary 0.55）。
11. **回归**：主面板全部键位（G/Tab/⏎/媒体组/速查表/Space Pin）与日历编辑表单键盘行为无回归。
12. **待机资源**：AI 窗关闭后无残留 URLSession/定时器；App 待机 CPU 仍为 0.0%。

---

## 7. 开放问题（已于 2026-10-01 与用户逐项确认完毕）

1. **对话历史跨关窗保留？** ✅ 确认：**保留到下次唤出**（偏离原建议）——关窗不清空，再次唤出继续上次会话；持久化 Application Support JSON，App 重启后恢复；⌘K 清空重新开始。
2. **AI 回复 Markdown 渲染级别？** ✅ 确认：**完整 Markdown 渲染**（偏离原建议）——见 §1.6 渲染策略（行内 AttributedString + 代码块等宽段落 + 标题/列表轻渲染，流式期间纯文本、落定后富渲染）。
3. **system prompt 可配置？** ✅ 确认：设置里给一个可选文本框（默认空 = 不发送 system 消息），存 UserDefaults（`ai.systemPrompt`）。
4. **AI 窗尺寸**是否跟随主面板三档尺寸偏好？ ✅ 确认：跟随（复用 PanelScaleOption）。
5. **⏎ 在输入框聚焦时**？ ✅ 确认：⏎ 发送 + ⇧⏎ 换行；ESC 两阶段语义如 §2。

---

## 8. 项目规范（摘要，全文见 AGENTS.md）

- 简体中文沟通与代码注释；修改前先读相关文件；**凡事先讨论清楚再动手**；不确定就问，不猜。
- 每次只做最小必要修改；改码后必须 `./scripts/restart.sh`（编译+重启）。
- **严禁擅自 `git commit/push`**——等用户明确指令；提交前同步 README（产品能力）/CHANGELOG（改动细节，Keep a Changelog 中文风格）。
- 键位/交互相关改动需同步：速查表（PanelView ? 面板）+ 快捷键设置分组。
- 版本号：Phase 3 完成提交时 bump 至 **1.4.0**（Info.plist `CFBundleShortVersionString`，注意历史上出现过被误回退为 1.0 的事故，提交前核对）。

---

*计划版本：v1 · 2026-10-01 · 基于会话中与用户锁定的 Phase 3 需求整理。实施中有需求变更，先与用户确认再改本文件。*
