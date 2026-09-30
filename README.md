<div align="center">

  <img src="assets/icon.png" width="128" height="128" alt="QuickShow App Icon" />

  # QuickShow

  <p>
    <b>专为全屏沉浸与极简工作流打造的 macOS 原生极速信息悬浮窗。</b><br>
    零打断 · 即看即走 · 全键盘盲操 · 极致轻量
  </p>

  <p>
    <a href="https://github.com/dzhang1987/quick-show"><img src="https://img.shields.io/badge/macOS-13.0%2B-blue?logo=apple" alt="macOS 13.0+" /></a>
    <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9-orange?logo=swift" alt="Swift 5.9" /></a>
    <img src="https://img.shields.io/badge/Dependencies-0-brightgreen" alt="Zero Dependencies" />
    <img src="https://img.shields.io/badge/Architecture-AppKit%20%2B%20SwiftUI-purple" alt="AppKit + SwiftUI" />
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="MIT License" /></a>
  </p>

  <br />

  <img src="assets/preview.png" width="850" alt="QuickShow Showcase Preview" />

</div>

<br />

---

## 💡 为什么需要 QuickShow？

在 macOS 上进行全屏写代码、沉浸写作或全屏观看视频时，系统的菜单栏通常处于**自动隐藏**状态。当你想看一眼当前时间和电池状态时，往往需要用鼠标滑到屏幕顶端等待菜单栏笨拙地下落，这极大地打断了专注心流。

**QuickShow** 正是为此而生：
- 随时随地，**双击两下修饰键（默认双击 `⌘ Command`）**，黑曜石悬浮窗瞬间在屏幕正中央平滑浮现；
- 抬眼一瞥，自动在 3 秒后淡出；或者轻按 **`ESC`**，瞬间隐形并将键盘焦点毫秒级交还原应用；
- 整个过程手不离主键盘区，丝滑跟手，零心流打断。

---

## ✨ 核心特性

- ⚡️ **极致轻量与极速响应**：
  - 纯原生 Swift + AppKit 构建，零外部依赖，极速秒级唤醒；
  - 后台待机时 CPU 占用严格为 0.0%，面板关闭自动深度释放内存；
  - 极简常驻后台设计，完全不占用系统资源。
- 🖥️ **专为全屏体验设计**：
  - 覆盖于全屏应用和各种桌面空间之上，不抢夺全屏工作区；
  - **多屏幕自适应**：智能检测光标所在的当前活跃屏幕并在正中央居中展现。
- ⌨️ **多维盲操热键（支持偏好设置随心切换）**：
  - **双击 Command (⌘ ⌘)** [默认推荐]：全局一键呼出 / 关闭悬浮窗（极简 Toggle 开关）；
  - **双击 Control / Option / Shift**：全屏终端与开发者的防冲突替代方案；
  - **经典组合键 (⌘ + Shift + T)**：双重保险快捷键；
  - **ESC 键退出**：底层同步捕获，退出瞬间立即归还系统焦点，绝无粘滞卡顿；
  - **Space 键常驻切换**：按空格键在「常驻固定」与「一瞥倒计时」之间丝滑切换；
  - **智能防误触**：连续敲击修饰键途中如果按下了普通键（如 ⌘+C），自动取消唤醒判定。
- 🥷 **Dock 程序坞彻底隐形**：
  - 作为系统附属工具运行，程序坞**完全不占图标**，不打扰 ⌘ + Tab 任务切换。
- 🔋 **系统微状态感知与快捷微交互 (一瞥底栏 380 × 168 pt)**：
  - **精准状态平铺**：电池电量、动态充放电提示与低电量警告，字号与间距精心微调，排版清晰规整；
  - **音频与音量控制**：按 **`M` 键**或点击音量微标一键静音/恢复，键盘 **`↑` / `↓`** 步进 5% 平滑调音；
  - **网络状态感知**：实时感知 Wi-Fi 连接与硬件频段，点击 Wi-Fi 图标瞬间将当前局域网 IP 复制至剪贴板；
  - **咖啡因防休眠 (Keep-Awake)**：点击咖啡杯微标或按 **`A` 键**即可阻止系统息屏休眠；
  - **外设与专注模式感知**：自动感知外设蓝牙电量（如 AirPods），系统勿扰模式开启时优雅高亮专注胶囊；
  - **智能倒计时生命周期**：鼠标悬停（Hover）时自动冻结倒计时，移出后平滑继续；高光折射微光随倒计时向内收敛，直观感知剩余展示时间。
- 📊 **Bento Grid 监控看板 (按 `Tab` 键展开 430 × 286 pt)**：
  - **性能与网络概览**：实时展示 CPU、内存负载曲线及当前 Top 高占用进程；支持按 **`C` 键**一键释放 inactive 内存缓存；双击卡片直达系统「活动监视器」；实时上下行网速动态更新；
  - **效率、日程与直达**：内置极简番茄钟（按 **`P` 键**启停，轻点时间快速轮换 25m/45m/5m 预设）；智能识别日程中的腾讯会议、Zoom、Google Meet 链接并高亮微胶囊「一键入会」；感知主磁盘剩余空间，按 **`O` 键**秒开「下载目录」。
- 💎 **黑曜石液态玻璃美学**：
  - 26pt 连续曲率高精圆角，严格裁切，四周零溢出边缘；
  - 深色黑曜石晶体背景，在任何壁纸与全屏窗口下均呈现超高对比度与通透质感；
  - SF Pro 现代排版搭配视网膜级柔和投影，浑然天成。

---

## ⌨️ 常用快捷键一览

| 按键 / 操作 | 功能描述 |
| :--- | :--- |
| **双击 `⌘ Command`** | 快速显示 / 关闭 QuickShow 悬浮窗（全局 Toggle 开关） |
| **长按 `⌘ Command` (0.35s)** | 屏幕浮现全键盘盲操速查卡片（CheatSheet），**手指松开自动淡出收起** ⚡️ |
| **`?` 键** | 一键打开 / 收起快捷键速查卡片 ❓ |
| **`Tab` 键** | 展开 / 收起详细监控看板（展开暂停倒计时，收起恢复倒计时） |
| **`Space 空格键`** | 切换常驻图钉（在常驻模式与一瞥倒计时模式之间切换） |
| **`M` 键** | 一键切换系统静音 / 取消静音 🔈 |
| **`↑ / ↓` 方向键** | 微调系统主音量（步进 ±5%） |
| **`A` 键** | 开启 / 关闭咖啡因防休眠模式（阻止屏幕息屏） ☕️ |
| **`C` 键** | 一键优化整理系统内存（释放 inactive 内存缓存） ⚡️ |
| **`P` 键** | 番茄钟一键播放 / 暂停 🍅 |
| **`O` 键** | 在访达中瞬间打开「下载目录」 💾 |
| **`X` 键** | 剪贴板格式净化（剔除富文本，转为纯文本） 📋 |
| **`L` 键** | 全屏立即锁屏离座 🔒 |
| **`D` 键** | 打开系统专注 / 勿扰模式偏好设置 🌙 |
| **`ESC` 键** | 瞬间关闭悬浮面板（若速查表打开则优先关闭速查表），毫秒级交还焦点 ⚡️ |
| **`⌘ + Shift + T`** | 备用组合键触发 |
| **`⌘ + ,`** | 打开偏好设置窗口 |
| **`⌘ + Q`** | 彻底退出 QuickShow |

---

## ⚙️ 偏好设置指南 (Preferences)

QuickShow 采用标准的 **macOS 现代系统侧边栏式设置中心 (System Settings Style)**，界面规整、专业典雅。在面板激活时按 **`⌘ ,`** 或点击底栏/菜单栏设置图标即可进入。

### 1. ⚙️ 通用设置 (General)
- **呼出触发方式**：
  - **双击 Command (⌘ ⌘)** *(推荐)*：两只大拇指敲击两下极速唤起/收起，全屏沉浸零打断；
  - **双击 Control (⌃ ⌃)** / **双击 Option (⌥ ⌥)** / **双击 Shift (⇧ ⇧)**：避免与终端或特定 IDE 快捷键冲突的替代选项；
  - **经典组合键 (⌘ + Shift + T)**：传统组合按键方案。
- **在系统菜单栏显示图标**：支持开启/关闭右上角系统状态栏 Sparkles 图标（默认展示）。
  > 💡 **提示**：隐藏菜单栏图标后，QuickShow 保持完全隐形后台运行。您仍可随时通过双击修饰键唤起面板，在面板激活时按 **`⌘ ,`** 随时重新打开偏好设置。
- **开机自动启动**：基于 macOS 原生 `SMAppService`，开机免手动拉起。
- **打开应用时默认展示一次**：应用初次拉起或重启时，在屏幕中央展示一次一瞥面板。
- **一瞥模式显示时长**：滑块支持 1.5 秒 ~ 10.0 秒自由微调（步进 0.5 秒，默认 3.0 秒）。鼠标悬停在悬浮窗上时会自动冻结倒计时。
- **时间格式**：支持切换 24 小时制与是否展示秒数 (`HH:mm:ss`)。

### 2. 💡 一瞥底栏微状态 (Status Bar)
悬浮面板底部默认展示的轻量感知微标，即看即走，各微标均支持一键快捷交互：
- **电池状态**：显示电量数值与充放电雷电标识，低电量自动红色预警；点击直达系统电池设置；
- **Wi-Fi 连接与 SSID**：点击一键复制当前局域网 IP 至剪贴板（按住 Option 点击打开网络设置）；
  - *定位权限授权*：macOS 要求获取定位权限方可读取真实 Wi-Fi 名称 (SSID)，未授权时将优雅降级显示频段（如 5G/2.4G）；
- **蓝牙外设电量**：感知 AirPods 及外接键鼠电量，电量低于 20% 醒目告警；
- **音频输出与音量**：展示当前系统主音量；点击一键切换静音/恢复；
- **专注 / 勿扰模式**：当系统开启「勿扰模式」或特定「专注模式」时，优雅点亮紫色微胶囊。

### 3. 📊 监控看板 (Dashboard · 按 Tab 键展开)
敲击 `Tab` 键即可在极简一瞥与 Bento Grid 双列监控看板间无缝切换：
- **CPU & 内存系统负载条**：实时直观的负载百分比及占用最高的进程；点击微按钮一键整理清理闲置内存，双击卡片直达「活动监视器」；
- **实时网络吞吐速率**：动态监测并显示当前系统的瞬时上传与下载网速；
- **极简专注番茄钟**：内置 25 分钟标准番茄钟，按 `P` 键快速启停，轻点时间预设轮换；
- **下一场日历日程会议**：智能感知即将到来的日程，一键识别腾讯会议、Zoom、Google Meet 链接并高亮微胶囊「一键入会」（需授权日历读取权限）。

### 4. ⌨️ 快捷键设置 (Shortcuts)
- **独立快捷键配置与速查中心**：系统化查看与管理所有按键（唤醒热键、基础交互、单键盲操功能）；
- **长按 Command 速查特性**：支持在悬浮面板激活时按住 `⌘` 约 0.35s 浮现速查表，松开手指瞬间淡出收起，零记忆负担。

### 5. ℹ️ 关于 (About)
展示原生应用大图标、版本号 1.1.0、架构说明、内存状态及开源许可证。

---

## 📂 项目结构

```
quick-show/
├── project.yml                          # XcodeGen 自动化工程规范配置
├── QuickShow.xcodeproj                  # 自动生成的 Xcode 项目
├── assets/                              # README 展示素材（超清图标、预览图）
│   ├── icon.png                         # 原生透明 Squircle 图标
│   └── preview.png                      # 双模式（一瞥 / 展开）左右对照产品展示图
├── scripts/
│   ├── restart.sh                       # 自动重新编译并重启 QuickShow 实例的轻量脚本
│   └── setup_codesign.sh                # 本地自签名代码签名证书初始化脚本（保证权限持久化）
├── QuickShow/
│   ├── QuickShowApp.swift               # 原生 AppDelegate 入口与 NSStatusItem 状态栏管理
│   ├── Info.plist                       # LSUIElement 常驻、日历与定位权限配置
│   ├── Assets.xcassets/                 # 1024x1024 原生超清 AppIcon
│   ├── Core/
│   │   ├── AppState.swift               # 全局响应式状态驱动（核心微状态、扩展看板、番茄钟、偏好设置）
│   │   ├── HotKeyManager.swift          # 双击修饰键与 Carbon 快捷键双模管理器
│   │   └── PanelManager.swift           # 悬浮窗生命周期、平滑展开/收起与焦点毫秒级管理
│   ├── Utilities/
│   │   ├── FloatingPanel.swift          # 具备 Key Window 焦点的全屏穿透透明 NSPanel (支持 ESC/Space/Tab)
│   │   ├── ScreenHelper.swift           # 鼠标活跃屏幕居中几何计算
│   │   └── SystemStatusProvider.swift   # 系统状态与传感器原生采集
│   └── Views/
│       ├── PanelView.swift              # 黑曜石毛玻璃主容器 (极简 / 展开自适应)
│       ├── TimeDisplayView.swift        # 饱满高对比度的大字时钟与日期徽章
│       ├── StatusBarView.swift          # 底部微状态栏（电池、WiFi、蓝牙、音频、勿扰、图钉、Tab键）
│       ├── ExpandedMonitoringView.swift # 展开监控看板 (CPU/内存负载、网速、日历日程、番茄钟)
│       └── SettingsView.swift           # 偏好设置界面（快捷键切换、状态项开关、日历与定位授权等）
├── AGENTS.md                            # 项目持久开发规则与协同工作规范
└── README.md
```

---

## 🛠️ 构建与运行

### 环境要求
- macOS 13.0 (Ventura) 或更高版本
- Xcode 15.0+ 
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### 0. 配置代码签名证书（初次开发运行一次即可）
为了使日历与定位等系统隐私权限在本地重新编译后保持永久有效（避免系统因二进制签名变动重复弹窗请求授权），首次构建前可执行：
```bash
./scripts/setup_codesign.sh
```

### 1. 生成工程
```bash
xcodegen generate
```

### 2. 编译 Release 生产版本（推荐）
```bash
xcodebuild -scheme QuickShow -configuration Release -derivedDataPath build_release -destination 'platform=macOS' build
```

### 3. 运行体验
```bash
open build_release/Build/Products/Release/QuickShow.app
```

### 4. 极速调试与平滑重启
修改代码后，在项目根目录运行以下脚本即可自动完成 Release 重编译并重启实例：
```bash
./scripts/restart.sh
```

---

## 📄 开源许可证

本项目采用 [MIT License](LICENSE) 开源。欢迎 Star、Fork 与提交 PR！
