# Changelog

本项目所有显著变更记录于此。格式参考 Keep a Changelog，版本号遵循语义化版本。

## [Unreleased]

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