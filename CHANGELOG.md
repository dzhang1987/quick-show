# Changelog

本项目所有显著变更记录于此。格式参考 Keep a Changelog，版本号遵循语义化版本。

## [Unreleased]

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