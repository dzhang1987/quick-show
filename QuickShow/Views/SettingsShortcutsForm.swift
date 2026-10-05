// 本文件由 SettingsView.swift 拆分而来：快捷键设置表单。

import SwiftUI

// MARK: - 4. 快捷键设置表单 (Shortcuts)
struct ShortcutsSettingsForm: View {
    @ObservedObject var appState: AppState
    
    /// 热键互斥被拒时的即时提示（所选未实际生效时出现，红色小字）
    @State private var conflictNotice: String?
    
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: Theme.Typography.title, weight: .bold))
                        .foregroundColor(.orange)
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("长按 Command (⌘) 速查特性")
                            .font(.system(size: Theme.Typography.badge, weight: .semibold))
                        Text("在悬浮面板激活时，只需按住 ⌘ 键约 0.35 秒或敲击「?」键，屏幕将浮现半透明速查表；手指松开 ⌘ 自动收起。")
                            .font(.system(size: Theme.Typography.callout))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            
            Section {
                Picker("主面板呼出 / 关闭", selection: mainTriggerBinding) {
                    triggerOptions()
                }
                Picker("AI 对话窗呼出 / 关闭", selection: aiTriggerBinding) {
                    triggerOptions()
                }
                HStack {
                    Text("备用全局组合键呼出")
                    Spacer()
                    KeyBadge(key: "⌘ ⇧ T")
                }
                HStack {
                    Text("主面板激活时打开 AI 对话窗")
                    Spacer()
                    KeyBadge(key: "I")
                }
            } header: {
                Text("全局唤醒")
            } footer: {
                if let conflictNotice = conflictNotice {
                    Text(conflictNotice)
                        .font(.system(size: Theme.Typography.label))
                        .foregroundColor(.red)
                } else {
                    Text("主面板与 AI 对话窗热键各自独立、并行生效；两者命中键冲突时后设置者被拒绝并保持原设置（左⌘ + 右⌘ 可共存，任意⌘ + 左⌘ 冲突）。")
                }
            }
            
            Section {
                HStack {
                    Text("展开 / 收起监控看板")
                    Spacer()
                    KeyBadge(key: "Tab")
                }
                HStack {
                    Text("切换图钉常驻 (Pin / Unpin)")
                    Spacer()
                    KeyBadge(key: "Space")
                }
                HStack {
                    Text("打开偏好设置窗口")
                    Spacer()
                    KeyBadge(key: "⌘ ,")
                }
                HStack {
                    Text("彻底退出应用")
                    Spacer()
                    KeyBadge(key: "⌘ Q")
                }
                HStack {
                    Text("关闭 / 退出悬浮面板")
                    Spacer()
                    KeyBadge(key: "ESC")
                }
            } header: {
                Text("基础交互控制")
            }
            
            Section {
                HStack {
                    Text("切换日历视图 (任意状态直达)")
                    Spacer()
                    KeyBadge(key: "G")
                }
                HStack {
                    Text("日历 月 / 周 / 日 视图切换")
                    Spacer()
                    KeyBadge(key: "1 / 2 / 3")
                }
                HStack {
                    Text("日历翻页 (日历视图内优先于媒体切歌)")
                    Spacer()
                    KeyBadge(key: "← / →")
                }
            } header: {
                Text("日历视图")
            } footer: {
                Text("任意状态按 G 直达日历视图（含农历、节气、当日日程）；再按 G 或 Tab 回到进入前状态（一瞥进入回一瞥，看板进入回看板）。")
            }
            
            Section {
                HStack {
                    Text("一键切换静音 / 取消静音")
                    Spacer()
                    KeyBadge(key: "M")
                }
                HStack {
                    Text("微调系统主音量 (步进 ±5%)")
                    Spacer()
                    KeyBadge(key: "↑ / ↓")
                }
                HStack {
                    Text("咖啡因防休眠开关 (阻止息屏)")
                    Spacer()
                    KeyBadge(key: "A")
                }
                HStack {
                    Text("一键优化整理系统内存 (释放缓存)")
                    Spacer()
                    KeyBadge(key: "C")
                }
                HStack {
                    Text("极简番茄钟 播放 / 暂停")
                    Spacer()
                    KeyBadge(key: "P")
                }
                HStack {
                    Text("在访达中瞬间打开「下载目录」")
                    Spacer()
                    KeyBadge(key: "O")
                }
                HStack {
                    Text("剪贴板格式净化 (转为纯文本)")
                    Spacer()
                    KeyBadge(key: "X")
                }
                HStack {
                    Text("全屏立即锁屏离座")
                    Spacer()
                    KeyBadge(key: "L")
                }
                HStack {
                    Text("打开系统专注 / 勿扰模式偏好")
                    Spacer()
                    KeyBadge(key: "D")
                }
                HStack {
                    Text("切换快捷键速查卡片浮层")
                    Spacer()
                    KeyBadge(key: "?")
                }
            } header: {
                Text("单键盲操与效率")
            }
            
            Section {
                HStack {
                    Text("媒体播放 / 暂停切换")
                    Spacer()
                    KeyBadge(key: "⏎")
                }
                HStack {
                    Text("上一首 / 下一首")
                    Spacer()
                    KeyBadge(key: "← / →")
                }
                HStack {
                    Text("快退 / 快进 15 秒")
                    Spacer()
                    KeyBadge(key: ", / .")
                }
            } header: {
                Text("媒体控制")
            } footer: {
                Text("仅在系统存在媒体会话（音乐 / 视频 / 播客等，含网页播放源）时生效，无会话时按键无副作用。")
            }
        }
    }
    
    // MARK: 热键绑定与选项
    
    /// 主面板热键绑定：写入后读取 HotKeyManager 实际生效值，被互斥拒绝则即时回退并提示。
    private var mainTriggerBinding: Binding<TriggerType> {
        Binding(
            get: { appState.triggerType },
            set: { newValue in
                appState.triggerType = newValue
                // 互斥兜底在 AppState setter：被拒绝时实际生效值仍为旧值，与所选不同
                if HotKeyManager.shared.currentType != newValue {
                    conflictNotice = "与 AI 对话窗热键冲突，已保持原设置"
                } else {
                    conflictNotice = nil
                }
            }
        )
    }
    
    /// AI 对话窗热键绑定：同上，读取 aiTriggerType 实际生效值做即时校验。
    private var aiTriggerBinding: Binding<TriggerType> {
        Binding(
            get: { appState.aiTriggerType },
            set: { newValue in
                appState.aiTriggerType = newValue
                if HotKeyManager.shared.aiTriggerType != newValue {
                    conflictNotice = "与主面板热键冲突，已保持原设置"
                } else {
                    conflictNotice = nil
                }
            }
        )
    }
    
    /// 13 案触发类型选项：按 ⌘ / ⌃ / ⌥ / ⇧ 四族分组（每族 任意侧 / 左 / 右），外加组合键分组。
    @ViewBuilder
    private func triggerOptions() -> some View {
        Section("双击 ⌘（Command）") {
            Text("双击 ⌘（任意侧）").tag(TriggerType.doubleCmd)
            Text("双击左⌘").tag(TriggerType.doubleLeftCmd)
            Text("双击右⌘").tag(TriggerType.doubleRightCmd)
        }
        Section("双击 ⌃（Control）") {
            Text("双击 ⌃（任意侧）").tag(TriggerType.doubleCtrl)
            Text("双击左⌃").tag(TriggerType.doubleLeftCtrl)
            Text("双击右⌃").tag(TriggerType.doubleRightCtrl)
        }
        Section("双击 ⌥（Option）") {
            Text("双击 ⌥（任意侧）").tag(TriggerType.doubleOpt)
            Text("双击左⌥").tag(TriggerType.doubleLeftOpt)
            Text("双击右⌥").tag(TriggerType.doubleRightOpt)
        }
        Section("双击 ⇧（Shift）") {
            Text("双击 ⇧（任意侧）").tag(TriggerType.doubleShift)
            Text("双击左⇧").tag(TriggerType.doubleLeftShift)
            Text("双击右⇧").tag(TriggerType.doubleRightShift)
        }
        Section("组合键") {
            Text("⌘⇧T 组合键").tag(TriggerType.hotKeyCmdShiftT)
        }
    }
}
