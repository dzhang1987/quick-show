# OpenCode 接入 Qoder 国际版 —— Agent 安装手册

> **本文档面向执行安装的 AI Agent。** 按步骤顺序执行，每步带验证命令与预期输出；验证不过不要进入下一步，按「失败处理速查」排查。步骤 3（认证）需要人工配合，到该步骤必须停下等用户，不要代替用户操作。
> 实测基准：OpenCode 1.18.35 · opencode-qoder v0.2.1 · 2026-10-11

---

## 0. 目标与关键约束

**目标**：让本机 OpenCode 能直接调用 Qoder 国际版（qoder.com）的后端模型（Auto/Ultimate/GLM/Kimi/DeepSeek 等 14 个），并配置 oh-my-opencode-slim 的 qoder preset。

```
OpenCode ──► 插件 provider: qoder ──► PAT/job token 自动交换 + COSY 签名 + SSE 解析 ──► api3.qoder.sh
```

**关键约束（先读，避免走弯路）**：

1. Qoder 后端**不是 OpenAI 兼容接口**（私有 COSY 签名 + 私有 SSE），把 `@ai-sdk/openai-compatible` 直指 `api2/api3.qoder.sh` 会 403。唯一正确路径是装 `opencode-qoder` 插件。
2. **不要手写 `provider` 配置块**——插件自动注册 provider、npm 包、baseURL 和全部模型。
3. **不要安装 qoder-proxy / 任何 spawn qodercli 的代理方案**（无原生工具调用、usage 恒为 0、每请求起子进程）。
4. **不要手动编辑 `auth.json`**——凭据由 `/connect` 流程或环境变量管理。
5. 本插件只支持**国际版**（\*.qoder.sh）。用户要接中国版（gateway.qoder.com.cn）时停止并报告，方案不同。

## 1. 前置检查

```bash
opencode --version          # 预期：1.18+（低于则先升级）
ls ~/.config/opencode/opencode.json   # 预期：存在。不存在则创建：
```

不存在时创建最小配置：

```bash
mkdir -p ~/.config/opencode
cat > ~/.config/opencode/opencode.json <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": []
}
EOF
```

**幂等检查**（已配置则跳过步骤 2）：

```bash
rg -c '"opencode-qoder"' ~/.config/opencode/opencode.json
# 输出 ≥1 → 插件已装，直接去步骤 3
# 无输出 → 继续步骤 2
```

## 2. 安装插件

配置文件可能禁止 edit 工具直接改 `~/.config/opencode/**`，用 node 原子写最可靠：

```bash
node -e '
const fs = require("fs");
const p = process.env.HOME + "/.config/opencode/opencode.json";
const j = JSON.parse(fs.readFileSync(p, "utf8"));
j.plugin ??= [];
if (!j.plugin.includes("opencode-qoder")) j.plugin.push("opencode-qoder");
const tmp = p + ".tmp";
fs.writeFileSync(tmp, JSON.stringify(j, null, 2) + "\n");
JSON.parse(fs.readFileSync(tmp, "utf8"));   // 写前校验
fs.renameSync(tmp, p);
console.log("plugin:", JSON.stringify(j.plugin));
'
```

**验证**（会自动从 npm 拉取插件，首次可能要几十秒）：

```bash
opencode models | grep qoder
```

预期输出 14 个模型：

```
qoder/auto  qoder/dfmodel  qoder/dmodel  qoder/efficient  qoder/gm51model
qoder/kmodel  qoder/kmodel_latest  qoder/lite  qoder/mmodel  qoder/performance
qoder/qmodel  qoder/qmodel_latest  qoder/qmodel_preview  qoder/ultimate
```

- ✅ 列出 → 进入步骤 3
- ❌ 无输出 / 报错 → 见失败处理 #1、#2

## 3. 认证（⚠️ 停下：此步必须用户人工完成）

Agent 无法代替用户做浏览器授权。先检查是否已有凭据：

```bash
# 检查已有凭据（满足任一即可跳过本步骤）
node -e 'const a=JSON.parse(require("fs").readFileSync(process.env.HOME+"/.local/share/opencode/auth.json","utf8"));console.log("stored:", Object.keys(a).includes("qoder"))' 2>/dev/null
echo "env: ${QODER_PERSONAL_ACCESS_TOKEN:+set}"
```

都没有凭据时，**把下面的话原样给用户，然后停下等待用户完成**（不要轮询、不要代填）：

> 请完成 OpenCode 的 Qoder 认证（二选一，约 1 分钟）：
>
> **方式 A（推荐）**：重启 OpenCode → 输入 `/connect qoder` → 选 **Browser Login** → 浏览器里点一下授权（已登录 qoder.com 的话一键完成）
>
> **方式 B（PAT）**：到 https://qoder.com/account/integrations 生成 `pt-...` 令牌 → `/connect qoder` → 选 Personal Access Token → 粘贴；或在 shell 里 `export QODER_PERSONAL_ACCESS_TOKEN="pt-..."`

用户说完成后，用步骤 4 的冒烟测试实际验证（不要只看文件存在就下结论）。

注意：`/connect` 存储的凭据优先于环境变量；两种方式不要混用，换方式前先 `/disconnect qoder`。

## 4. 冒烟测试

```bash
opencode run -m qoder/lite "请只回复两个字符: pong"
```

- ✅ 输出包含 pong → 认证与推理链路全通，进入步骤 5
- ❌ 401/403/"Login expired" → 认证没成功，回到步骤 3
- ❌ 超时/网络错 → 见失败处理 #4

（`lite` 是免费模型，适合冒烟；不要用付费模型做测试。）

## 5. oh-my-opencode-slim 配置（用户要求时才做）

前提：`~/.config/opencode/oh-my-opencode-slim.json` 存在且 `plugin` 数组含 `oh-my-opencode-slim`。不存在则跳过并告知用户未装 slim。

幂等合并（不覆盖已有 preset，不动其他 preset）：

```bash
node -e '
const fs = require("fs");
const p = process.env.HOME + "/.config/opencode/oh-my-opencode-slim.json";
const j = JSON.parse(fs.readFileSync(p, "utf8"));
if (j.presets?.qoder) { console.log("qoder preset 已存在，跳过"); process.exit(0); }
j.presets ??= {};
j.presets.qoder = {
  orchestrator: { model: "qoder/gm51model", skills: ["*"], mcps: ["*", "!context7"] },
  oracle:       { model: "qoder/kmodel_latest", skills: ["simplify"], mcps: [] },
  librarian:    { model: "qoder/dfmodel", skills: [], mcps: ["context7", "gh_grep"] },
  explorer:     { model: "qoder/dfmodel", skills: [], mcps: [] },
  designer:     { model: "qoder/kmodel", skills: [], mcps: [] },
  fixer:        { model: "qoder/dfmodel", skills: [], mcps: [] },
  observer:     { model: "qoder/qmodel" }
};
j.preset = "qoder";
const tmp = p + ".tmp";
fs.writeFileSync(tmp, JSON.stringify(j, null, 2) + "\n");
JSON.parse(fs.readFileSync(tmp, "utf8"));
fs.renameSync(tmp, p);
console.log("active preset:", j.preset);
'
```

选型逻辑（用户问起时解释）：编排 0.6x（GLM）、评审 Kimi-K3、检索/执行 0.1x（DeepSeek-Flash）、designer 代码特化（Kimi-K2.7-Code）、observer 视觉（Qwen-Plus）。**不写 variant 字段**——插件模型不暴露档位。切回旧 preset 只需把 `"preset"` 改回原名。

## 6. 交付汇报模板

完成后向用户汇报：

```
✅ opencode-qoder 插件已装，14 个 qoder/* 模型可用
✅ 认证方式：<Browser Login / PAT / 已有凭据>
✅ 冒烟测试通过：qoder/lite
✅ slim preset：qoder 已激活（或：用户不需要）
ℹ️ 改动文件：~/.config/opencode/opencode.json、（可选）oh-my-opencode-slim.json
ℹ️ 当前运行中的 OpenCode 会话仍是旧模型，重启后生效
```

## 7. 失败处理速查

| # | 症状 | 原因 | 处理 |
|---|---|---|---|
| 1 | `opencode models` 无 qoder | npm 拉取失败 / registry 不通 | 检查 npm registry（国内可设 npmmirror）；重跑 `opencode models` |
| 2 | models 报 plugin 加载错 | 配置 JSON 写坏 | 用步骤 2 的 node 脚本重写；`node -e 'JSON.parse(...)'` 校验 |
| 3 | 403 / "Login expired" | 凭据过期或端点路由变更 | `/disconnect qoder` → 重新 `/connect qoder`；PAT 重新生成 |
| 4 | 请求超时 | 本机到 \*.qoder.sh 网络不通 | `curl -sI https://api3.qoder.sh` 测试；让用户检查代理（HTTPS_PROXY） |
| 5 | 模型列表比 Qoder CLI 少 | 插件静态注册滞后 | 正常现象（家族别名自动路由最新版）；急需新模型可在 `provider.qoder.models` 手动补，插件会合并 |
| 6 | 改配置不生效 | 启动时加载 | 重启 OpenCode |
| 7 | 想接中国版 | 本插件只支持国际版 | 停止，报告用户：需换支持 CN 的方案 |

## 8. 禁止事项

- ❌ 手写 `provider.qoder` 配置块（插件自动注册，写了反而可能冲突）
- ❌ 手动编辑 `~/.local/share/opencode/auth.json`
- ❌ 安装/使用 qoder-proxy 及任何 spawn qodercli 的代理
- ❌ 把 PAT/token 写入文档、日志或回显给用户以外的任何地方
- ❌ 用付费模型（auto/ultimate 等）做冒烟测试

## 附录 A：模型清单（选型参考）

倍率为 Qoder 官方（auto = 1.0x）：

| 模型 ID | 后端 | 倍率 | 上下文 | 视觉 | 备注 |
|---|---|---|---|---|---|
| `auto` | Auto（智能路由） | 1.0x | 180K | ✅ | 默认主力 |
| `ultimate` | Ultimate | 1.6x | 1M | ✅ | effort 档位 |
| `performance` | Performance | 1.1x | 1M | ✅ | effort 档位 |
| `efficient` | Efficient | 0.3x | 180K | ✅ | 低价快速 |
| `lite` | Lite | **免费** | 180K | ❌ | 纯文本 |
| `qmodel_latest` | Qwen-Max | 0.2x | 1M | ✅ | 家族别名自动更新 |
| `qmodel` | Qwen-Plus | 0.1x | 1M | ✅ | |
| `qmodel_preview` | Qwen 预览 | — | 1M | ✅ | |
| `dmodel` | DeepSeek-V4-Pro | 0.5x | 1M | ✅ | effort 档位 |
| `dfmodel` | DeepSeek-Flash | 0.1x | 1M | ✅ | effort 档位 |
| `gm51model` | GLM（当前 5.3） | 0.6x | 1M | ✅ | effort 档位 |
| `kmodel_latest` | Kimi-K3 | ~0.3x | 1M | ✅ | |
| `kmodel` | Kimi-K2.7-Code | 0.3x | 256K | ✅ | 代码特化 |
| `mmodel` | MiniMax-M3 | 0.2x | 1M | ✅ | |

## 附录 B：旧 qoder-proxy 残留清理（仅当目标机器存在旧方案时执行）

```bash
# 检测：7890 端口有 qoder-proxy 进程？
lsof -nP -iTCP:7890 -sTCP:LISTEN
```

存在旧方案时依次：停进程（`kill <PID>`）→ 删 `opencode.json` 里指向 `127.0.0.1:7890` 的 provider → 删 `auth.json` 里遗留的旧 qoder 键（保留其他 provider）→ 删 `~/Projects/qoder-proxy` 目录与 `opencode.json.bak-qoder-*` 备份（需用户确认）。改 `auth.json` 前备份，只删明确属于旧方案的键。

## 参考

- 插件源码：<https://github.com/Moorad/opencode-qoder>（npm: `opencode-qoder`）
- 协议参考实现：<https://github.com/simonsmh/pi-provider-qoder>
- Qoder CLI 文档：<https://docs.qoder.com/cli/overview> · PAT 页：<https://qoder.com/account/integrations>
