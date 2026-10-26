# QuickShow 智能工具权限治理体系架构设计方案

## 1. 概述与核心诉求

### 1.1 背景与现状痛点
在桌面级 AI Agent（如 Antigravity、Claude Code、Cursor 等）的演进过程中，工具调用的权限管控往往陷入两个极端的**死板困境**：
1. **模式化一刀切陷阱（All-or-Nothing Fallacy）**：
   - 传统方案提供粗暴的全局 4 档开关（`Request Review` / `Default` / `Auto` / `Turbo`）；
   - `Request Review`：对 `pwd`、`ls`、`git status`、`cat` 等最无害的只读感知也要频繁弹窗确认，引发**审查疲劳（Alert Fatigue）**，用户最终麻木连按回车；
   - `Turbo`：系统彻底不设防（`Run all commands without restrictions`），一旦 Agent 误跑 `rm -rf`、覆盖未提交代码或修改系统根配置，毫无挽回机会；
   - `Default`：用户根本不知道系统定义的“Sensitive（敏感）”边界在哪里，属于不可预测的黑盒；
   - `Auto (Preview)`：让大模型自己判断是否执行，本质上是**让嫌疑人自审**，极易被 Prompt 注入或幻觉击穿。
2. **机械僵化的精确哈希记忆（Exact String Matching）**：
   - 目前 QuickShow 的 `rememberSessionAllowed` 仅按 `toolName + "|" + argumentsJSON` 完全字符串哈希记忆；
   - 用户刚刚批准了 `git diff src/A.swift`，模型下一步跑 `git diff src/B.swift` 时又被拦截，哪怕点了一万次“总是允许”，由于参数变了一个字母就依然不断被打扰。
3. **脱离上下文与空间边界（Lack of Scoping & Reversibility）**：
   - 忽视了“在当前工作区写文件”与“在 `~/.zshrc` / `/System` 写文件”的巨大差异；
   - 将所有安全全押在**事前审批**上，忽视了**事后追溯与回滚（Undo）**。

### 1.2 结合 QuickShow 定位的第一性原理
QuickShow 的核心定位是：
> **“专为全屏沉浸与极简工作流打造的 macOS 原生极速信息悬浮窗，零打断 · 即看即走 · 全键盘盲操 · 极致轻量。”**

在全屏沉浸的工作流中，权限体系的设计必须满足三大第一性准则：
- **心流优先（Zero Flow-Breaking）**：只读与系统感知 100% 自动无感秒级放行，绝不打断键盘敲击节奏；
- **精准防御（Deterministic Guardrails）**：宿主真实环境下，破坏性高危操作硬门禁守底，绝不盲目 Turbo 裸奔；
- **有备无患（Reversibility over Bureaucracy）**：“事后能一秒撤销，事前就不必如临大敌”，引入轻量快照与撤销机制。

---

## 2. 核心架构设计（SOLID & Strategy Architecture）

```
                    ┌────────────────────────────────────────┐
                    │       AIToolExecutor (工具调度中枢)     │
                    └───────────────────┬────────────────────┘
                                        │ 1. 评估风险
                                        ▼
                    ┌────────────────────────────────────────┐
                    │      ToolRiskClassifier (风险分类器)    │
                    │   (开放策略链: Shell / File / Default)  │
                    └───────────────────┬────────────────────┘
                                        │ 产出: ToolRiskLevel
                                        │ (.readOnly / .scopedMutation / .destructive)
                                        ▼
┌──────────────────┐ 命中规则 ┌────────────────────────────────────────┐
│  Tier 0: 只读感知 ├─────────┤   ToolPermissionPolicyEngine (规则引擎) │
│ (100% 免审直通)   │         │ (前缀通配 / 目录作用域 / 会话规则)      │
└──────────────────┘         └───────────────────┬────────────────────┘
                                                 │ 未授权 / 高危
                                                 ▼
┌────────────────────────────────────────┐ 未命中 ┌────────────────────────────────────────┐
│   Tier 2: 破坏性硬门禁 (Hard Gate)     │◀───────┤   Tier 1: 受控变更 (Scoped Mutation)   │
│   (强制弹窗拦截，不可通过前缀静默跳过)    │        │   (抽屉提供: ⏎ 单次 / ⌘⏎ 规则记忆)     │
└────────────────────────────────────────┘        └───────────────────┬────────────────────┘
                                                                      │ 执行成功
                                                                      ▼
                                                  ┌────────────────────────────────────────┐
                                                  │   UndoSnapshotManager (撤销快照引擎)    │
                                                  │   (写入前内存备份 -> 提供一键 Undo)    │
                                                  └────────────────────────────────────────┘
```

---

## 3. 详细子系统设计

### 3.1 操作语义与多级风险系统（ToolRiskLevel）

彻底弃用单一布尔值 `tool.isDangerous`，引入强类型风险等级：

```swift
/// 工具调用风险等级
enum ToolRiskLevel: Equatable {
    /// 纯感知 / 只读操作：无副作用，100% 零审批自动放行
    case readOnly
    
    /// 受控变更操作：在特定白名单目录或特定命令空间内的写入/执行，可被规则记忆放行
    case scopedMutation(suggestedScope: PermissionScopeSuggestion)
    
    /// 破坏性 / 逃逸高危操作：系统级破坏、关键配置篡改、越界提权，强制硬门禁审批，不可被通配规则静默绕过
    case destructive(reason: String)
}

/// 建议授权的作用域类型（供 UI 呈现智能快捷记忆）
enum PermissionScopeSuggestion: Equatable {
    /// 建议放行命令前缀（如 "git", "pnpm", "cargo"）
    case shellPrefix(prefix: String)
    /// 建议放行工作区目录（如当前工程根目录）
    case directoryPath(path: String)
    /// 仅单次或常规工具放行
    case toolName(name: String)
}
```

### 3.2 风险评估策略（ToolRiskEvaluator - 严格遵循 OCP）

定义评估器协议，遵循开闭原则（OCP），新增工具或特殊命令时只需增加 Evaluator，无需在调用方堆砌 `if-else`：

```swift
protocol ToolRiskEvaluator {
    /// 是否适用于当前工具调用
    func canEvaluate(toolName: String) -> Bool
    /// 计算风险等级
    func evaluateRisk(tool: AITool, arguments: [String: Any]) -> ToolRiskLevel
}
```

#### 3.2.1 Shell 语义解析器（ShellSemanticRiskEvaluator）
针对 `run_shell` 工具，通过对命令首词与子命令进行轻量语法分析，消除“将所有 shell 命令当成高危”的死板弊端：

1. **只读 Shell 启发式（降为 `.readOnly`，免审放行）**：
   - 基础命令：`pwd`、`ls`、`which`、`echo`、`whoami`、`uname`、`date`、`cat`、`head`、`tail` 等；
   - Git 只读子命令：`git status`、`git diff`、`git log`、`git branch`、`git show`、`git remote -v` 等；
   - 依赖与状态只读：`pnpm list`、`npm list`、`cargo check`、`swift --version` 等。
2. **破坏性高危 Shell 启发式（升为 `.destructive`，硬门禁拦截）**：
   - 递归破坏：`rm -rf`、`rm -r`、`srm`；
   - 提权与特权越界：`sudo`、`su`、`doas`；
   - 磁盘与系统破坏：`mkfs`、`dd`、`fdisk`、`diskutil erase`；
   - 破坏性版本回退与强推：`git reset --hard`、`git clean -fd`、`git push --force`、`git push -f`；
   - 关键环境变量与安全篡改：修改 `/etc/`、`~/.zshrc`、`~/.bash_profile`、`launchctl` 等。
3. **其余命令**：归为 `.scopedMutation`，提取首词（如 `git commit` 提取 `git`，`pnpm run build` 提取 `pnpm`）作为候选前缀建议。

#### 3.2.2 文件写入解析器（FileRiskEvaluator）
- 检查目标路径：
  - 若目标落在工程白名单目录或临时缓存内：判定为 `.scopedMutation`，建议作用域为当前工作区目录；
  - 若目标包含敏感隐藏路径（如 `.git/config`、`~/.ssh/`、`/etc/`）：升级为 `.destructive`。

---

### 3.3 规则引擎与智能记忆（ToolPermissionPolicyEngine）

彻底重构 `sessionAllowedKeys: Set<String>` 的单一哈希机制，支持结构化规则：

```swift
/// 权限授权规则
enum PermissionRule: Hashable {
    /// 本会话允许特定工具全量执行
    case tool(name: String)
    /// 本会话允许特定 Shell 命令前缀（如 "git *", "pnpm *"）
    case shellPrefix(prefix: String)
    /// 本会话允许特定根目录下的写入操作（如 "/Users/admin/Projects/quick-time"）
    case directory(path: String)
}

final class ToolPermissionPolicyEngine {
    static let shared = ToolPermissionPolicyEngine()
    
    /// 当前活跃会话的放行规则集合（纯内存，随会话切换/新建清空）
    private var sessionRules: Set<PermissionRule> = []
    
    /// 评估是否允许执行
    func evaluate(tool: AITool, arguments: [String: Any], risk: ToolRiskLevel) -> PolicyDecision {
        switch risk {
        case .readOnly:
            // 只读一律免审直通
            return .allow
            
        case .destructive(let reason):
            // 破坏性操作强制硬门禁，即使匹配了前缀规则也不放行，必须人工显式确实验证
            return .requireExplicitApproval(risk: risk, allowRuleScope: nil)
            
        case .scopedMutation(let suggestion):
            // 检查是否已被规则放行
            if isAllowedByRules(tool: tool, arguments: arguments) {
                return .allow
            }
            // 未被规则覆盖：请求抽屉审批，并附带建议的记忆规则
            return .requireExplicitApproval(risk: risk, allowRuleScope: suggestion)
        }
    }
    
    /// 记录放行规则
    func recordRule(_ rule: PermissionRule) {
        sessionRules.insert(rule)
    }
    
    /// 重置规则（切会话或清空会话时）
    func resetRules() {
        sessionRules.removeAll()
    }
}
```

---

### 3.4 交互层与全键盘盲操协议（Keyboard-Centric UX）

为贯彻 QuickShow “手不离主键盘区”的灵魂，输入坞抽屉的操作与快捷键进行深度优化：

#### 抽屉三态按钮与快捷键绑定：
| 按钮 / 动作 | 快捷键 | 行为语义与说明 |
| :--- | :--- | :--- |
| **拒绝 (Reject)** | **`ESC`** | 拒绝本次工具调用，返回 `denied` 给模型，安全收起抽屉。 |
| **允许此前缀/目录并记忆** | **`⌘⏎` (Cmd+Enter)** | 智能提取前缀（例如 `允许 "pnpm *" 本会话放行` 或 `允许项目目录写入`），写入当前会话规则并立即执行。 |
| **仅执行单次 (Run Once)** | **`⏎` (Enter)** | 仅放行当前这次调用，不记录前缀规则。 |

#### 输入坞边缘极简安全胶囊（Security Badge）：
- 在 `AIChatView` 输入栏左下/右下侧以极简微徽章展示：`🛡️ 2 项会话规则 (git*, pnpm*)`；
- 点击微徽章可呼出极简气泡，一键查看已放行规则或点击清空还原。

---

### 3.5 事后安全网：轻量快照与撤销引擎（UndoSnapshotManager）

> **“有后悔药的放行，胜过一百次繁琐的事前弹窗。”**

借鉴 Cursor 与 Windsurf 的 Checkpoint 思想，为文件写入工具配备无感备份：
1. **执行前暂存（In-Memory Shadow Cache）**：
   - 当 `write_file` 准备覆盖写入白名单文件时，`UndoSnapshotManager` 先读取目标文件的原始内容并保留在内存字典中（若文件原先不存在，则记录标记为新建）；
   - 生成唯一的 `undoToken: UUID`，存入工具执行结果元数据。
2. **消息流内渲染撤销微标**：
   - 工具执行成功后，在对话界面的工具卡片右侧轻量浮现：`[已修改 · 撤销 / Undo]`；
   - 点击该微标或按快捷键，立即用暂存内容原子覆写回目标文件，并在消息中更新状态为 `已还原`；
   - 随会话关闭或超时（例如 30 分钟无操作）自动释放快照，保持内存极致轻量。

---

## 4. 实施与重构路线（Implementation Roadmap）

按照 SOLID 原则分阶段渐进式落地，每一步均做到可独立编译与回退：

- **阶段 1：核心风险评估模型与 Shell 启发式（Foundation）**
  - 新增 `ToolRiskLevel` 及 `ToolRiskEvaluator` 协议；
  - 实现 `ShellSemanticRiskEvaluator`，拆分出只读安全命令与破坏性黑名单；
  - 单测覆盖：覆盖 `git status`、`rm -rf`、`pnpm test` 等典型命令的定级。
- **阶段 2：策略引擎与前缀/作用域记忆（Policy Engine）**
  - 实现 `ToolPermissionPolicyEngine`，支持 `PermissionRule.shellPrefix` 与 `.directory`；
  - 改造 `ChatInteractionCenter`，将其内部的精确哈希改为委托规则引擎。
- **阶段 3：抽屉 UI 与键盘快捷键联动（UX Refinement）**
  - 改造 `ToolConfirmationDrawerContent`，动态显示建议记忆的前缀；
  - 支持 `⏎`（单次）、`⌘⏎`（记忆前缀）、`ESC`（拒绝）全键盘盲操；
  - 接入输入坞安全状态微标（Security Badge）。
- **阶段 4：写入快照与一键撤销（Undo Safety Net）**
  - 实现 `UndoSnapshotManager`；
  - `WriteFileTool` 接入前置快照捕获与结果 Token 回传；
  - `AIChatMessageList` 原生卡片接入撤销交互。

---

## 5. 预期成效评估

| 评估维度 | 优化前现状 | 优化后体系 |
| :--- | :--- | :--- |
| **日常只读查询打扰率** | 100% 弹窗打断（`ls`, `git diff`, `pwd`） | **0% 打扰**，秒级静默无感执行 |
| **多命令交互心流** | 每次参数微变都要重复审批 | **一次放行整个命令族**（`git *`, `pnpm *`） |
| **系统安全性** | Turbo 模式下直接裸奔无防线 | **破坏性命令硬防线守护**，绝无意外删库可能 |
| **操作容错率** | 写错即覆盖，不可逆 | **支持一键秒级 Undo 还原** |
| **键盘沉浸感** | 频繁被迫用鼠标点击抽屉按钮 | **全键盘主键区盲操**（`⏎` / `⌘⏎` / `ESC`） |
