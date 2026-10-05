// 本文件由 SettingsView.swift 拆分而来：AI 工具配置各小节。

import SwiftUI
import AppKit

// MARK: - AI 工具配置小节
//
// 三个配置均直接读写 UserDefaults，后端（AIToolRegistry / BuiltInTools）每次请求 / 执行时直读，
// 无需通知机制即可即改即生效。本区只做编辑态 + 持久化，不做运行态刷新。

/// 「工具」小节：内置工具按类别分组（剪贴板/系统状态/文件/环境变量/联网/地图），
/// 每行开关 = 中文展示名主标题 + 蛇形名次要等宽小字 + 危险徽标 + 中文简述。
/// 持久化语义：UserDefaults 键 "ai.tools.enabled" 为启用的工具名数组；
/// 键缺失 = 默认启用（除 run_shell 外全部）——首次进入先按默认值初始化写入，再展示；
/// 用户翻动任一开关时写入完整启用列表（按注册表顺序）。
/// 分组纯为渲染层重组，不碰持久化：落盘仍是蛇形名数组，与协议层零耦合。
struct AIToolsSettingsSection: View {
    /// 全部已注册工具（注册表顺序，含默认关闭的 run_shell；persistEnabled 落盘顺序的真源）。
    @State private var tools: [AITool] = []
    /// 分组视图数据（固定组序，组内注册序）。
    @State private var groups: [(category: ToolCategory, tools: [AITool])] = []
    /// 当前启用的工具名集合（编辑态真源，任何变更即刻写盘）。
    @State private var enabledNames: Set<String> = []

    var body: some View {
        Section {
            ForEach(Array(groups.enumerated()), id: \.element.category) { index, group in
                // 组标题：类别中文名（footnote 半重次级色，与工具描述同族但不混——靠字重拉开层级）
                Text(group.category.label)
                    .font(.system(size: Theme.Typography.footnote, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.top, index > 0 ? Theme.Spacing.xxl : 0)
                ForEach(group.tools, id: \.name) { tool in
                    toolRow(tool)
                }
            }
        } header: {
            Text("工具")
        } footer: {
            Text("按类别分组展示；灰色等宽小字是模型调用的工具标识。关闭后 AI 将无法调用对应工具，下一轮对话起生效；危险工具执行前仍会逐个弹窗确认。")
        }
        .onAppear { loadToolsIfNeeded() }
    }

    /// 单个工具行：开关（展示名 + 徽标 + 右侧蛇形名）+ 简述 + run_shell 红字警告。
    private func toolRow(_ tool: AITool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: enabledBinding(for: tool.name)) {
                HStack(spacing: 6) {
                    // 中文展示名主标题（正文常规字族，中文不走等宽）
                    Text(tool.displayName)
                        .font(.system(size: Theme.Typography.body))
                    if tool.isDangerous {
                        dangerousBadge
                    }
                    Spacer(minLength: 4)
                    // 蛇形名降为右侧次要等宽小字（与协议层/日志对照用，不抢主标题）
                    Text(tool.name)
                        .font(.system(size: Theme.Typography.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Text(tool.description)
                .font(.system(size: Theme.Typography.footnote))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if tool.name == "run_shell" {
                Text("允许 AI 执行任意 shell 命令，有安全风险")
                    .font(.system(size: Theme.Typography.footnote))
                    .foregroundColor(Theme.Colors.statusWarning)
            }
        }
        .padding(.vertical, 2)
    }

    /// 「危险」徽标：警示红小胶囊。
    private var dangerousBadge: some View {
        Text("危险")
            .font(.system(size: Theme.Typography.micro, weight: .semibold))
            .foregroundColor(Theme.Colors.statusWarning)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.statusWarning.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
                    .stroke(Theme.Colors.statusWarning.opacity(0.28), lineWidth: 0.5)
            )
    }

    private func enabledBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { enabledNames.contains(name) },
            set: { newValue in
                if newValue {
                    enabledNames.insert(name)
                } else {
                    enabledNames.remove(name)
                }
                persistEnabled()
            }
        )
    }

    /// 首次进入：键缺失时按默认值（除 run_shell 外全部启用）初始化并写入，再展示。
    private func loadToolsIfNeeded() {
        let registry = AIToolRegistry.shared
        tools = registry.allTools()
        groups = registry.toolsGroupedByCategory()
        let defaults = UserDefaults.standard
        if let stored = defaults.stringArray(forKey: AIToolRegistry.enabledToolsKey) {
            enabledNames = Set(stored)
        } else {
            let defaultEnabled = registry.enabledTools().map { $0.name }
            enabledNames = Set(defaultEnabled)
            defaults.set(defaultEnabled, forKey: AIToolRegistry.enabledToolsKey)
        }
    }

    /// 写完整启用列表（按注册表顺序，保证落盘内容稳定可读）。
    private func persistEnabled() {
        let ordered = tools.map(\.name).filter { enabledNames.contains($0) }
        UserDefaults.standard.set(ordered, forKey: AIToolRegistry.enabledToolsKey)
    }
}

/// 「文件访问白名单」小节：目录路径列表（NSOpenPanel 选目录添加，逐行可删）。
/// 持久化：UserDefaults 键 "ai.tools.fileWhitelist"（[String] 目录路径数组）。
struct AIFileWhitelistSettingsSection: View {
    /// UserDefaults 键（与 BuiltInTools 中的白名单键保持一致）。
    private let whitelistKey = "ai.tools.fileWhitelist"

    @State private var paths: [String] = []

    var body: some View {
        Section {
            if paths.isEmpty {
                Text("尚未添加目录，AI 将无法读写本地文件。")
                    .font(.system(size: Theme.Typography.body))
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: Theme.Typography.body))
                            .foregroundColor(.secondary)
                        Text(path)
                            .font(.system(size: Theme.Typography.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            removePath(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: Theme.Typography.body))
                        }
                        .buttonStyle(.borderless)
                        .help("移除该目录")
                    }
                }
            }
            Button("添加目录…") { chooseDirectories() }
                .font(.system(size: Theme.Typography.body))
        } header: {
            Text("文件访问白名单")
        } footer: {
            Text("AI 的 read_file / write_file 仅可访问白名单目录内文件。")
        }
        .onAppear { paths = UserDefaults.standard.stringArray(forKey: whitelistKey) ?? [] }
    }

    /// NSOpenPanel 选目录（可多选），去重后追加并即刻写盘。
    private func chooseDirectories() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.title = "选择允许 AI 访问的目录"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.path
            if !paths.contains(path) {
                paths.append(path)
            }
        }
        persist()
    }

    private func removePath(at index: Int) {
        guard paths.indices.contains(index) else { return }
        paths.remove(at: index)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(paths, forKey: whitelistKey)
    }
}

/// 「自定义环境变量」小节：键值对编辑器（增删改行）。
/// 持久化：UserDefaults 键 "ai.envVars"（[String: String] 字典，与 get_env/set_env 工具读写同一份）。
struct AIEnvVarsSettingsSection: View {
    /// UserDefaults 键（与 BuiltInTools 中的环境变量键保持一致）。
    private let envVarsKey = "ai.envVars"

    /// 编辑态行模型（允许编辑中出现暂空键；落盘时空键行跳过）。
    private struct EnvEntry: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    @State private var entries: [EnvEntry] = []

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("暂无自定义变量。")
                    .font(.system(size: Theme.Typography.body))
                    .foregroundColor(.secondary)
            } else {
                ForEach($entries) { $entry in
                    HStack(spacing: 8) {
                        TextField("变量名", text: $entry.key)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: Theme.Typography.body, design: .monospaced))
                            .frame(maxWidth: 180)
                        TextField("值", text: $entry.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: Theme.Typography.body, design: .monospaced))
                        Button(role: .destructive) {
                            removeEntry(id: entry.id)
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: Theme.Typography.body))
                        }
                        .buttonStyle(.borderless)
                        .help("删除该变量")
                    }
                    // 任一字段变更即刻写盘（后端每次执行直读 UserDefaults）
                    .onChange(of: entry) { _ in persist() }
                }
            }
            Button("添加变量") {
                entries.append(EnvEntry(key: "", value: ""))
            }
            .font(.system(size: Theme.Typography.body))
        } header: {
            Text("自定义环境变量")
        } footer: {
            Text("供 AI 的 get_env / set_env 工具读写，独立于系统环境变量。")
        }
        .onAppear { load() }
    }

    private func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    /// 读取持久化字典为有序行（按键名排序，展示稳定）。
    private func load() {
        let stored = UserDefaults.standard.dictionary(forKey: envVarsKey) as? [String: String] ?? [:]
        entries = stored.keys.sorted().map { EnvEntry(key: $0, value: stored[$0] ?? "") }
    }

    /// 写盘：跳过空键行；重名键后行覆盖前行（与字典语义一致）。
    private func persist() {
        var dict: [String: String] = [:]
        for entry in entries {
            let key = entry.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            dict[key] = entry.value
        }
        UserDefaults.standard.set(dict, forKey: envVarsKey)
    }
}

/// 「联网搜索」小节：Tavily API Key 输入。交互模式复刻上方 API Key 输入框——
/// 未存时直接输入保存；已存时显示掩码 + 替换输入框 + 清除钮；保存成功后清空输入框。
/// Key 仅存 Keychain（绝不落 UserDefaults），读写走 WebToolsConfig 契约
///（Keychain 优先，环境变量 QUICKSHOW_TAVILY_API_KEY 兜底；setTavilyAPIKey 传空串 = 删除条目）。
struct AIWebSearchSettingsSection: View {
    /// 已存 Key（仅用于掩码展示，不二次持久化）。
    @State private var storedKey: String = ""
    /// 新输入的 Key（仅内存态，保存成功后清空）。
    @State private var keyInput: String = ""

    var body: some View {
        Section {
            if storedKey.isEmpty {
                SecureField("输入 Tavily API Key", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
            } else {
                HStack {
                    Text("已存储 ····\(String(storedKey.suffix(4)))")
                        .font(.system(size: Theme.Typography.body))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("清除") { clearKey() }
                        .font(.system(size: Theme.Typography.body))
                }
                SecureField("输入新的 Key 以替换", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
            }

            if !trimmedInput.isEmpty {
                HStack {
                    Spacer()
                    Button("保存 Key") { saveKey() }
                        .font(.system(size: Theme.Typography.body, weight: .medium))
                }
            }
        } header: {
            Text("联网搜索")
        } footer: {
            Text("用于 web_search 联网搜索工具，免费注册 tavily.com 获取；支持环境变量 QUICKSHOW_TAVILY_API_KEY 兜底。")
        }
        .onAppear { loadStoredKey() }
    }

    /// 输入去空白（空串不触发保存按钮）。
    private var trimmedInput: String {
        keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadStoredKey() {
        storedKey = WebToolsConfig.tavilyAPIKey ?? ""
    }

    private func saveKey() {
        let key = trimmedInput
        guard !key.isEmpty else { return }
        WebToolsConfig.setTavilyAPIKey(key)
        storedKey = key
        keyInput = ""
    }

    private func clearKey() {
        // 契约：传空字符串即删除钥匙串条目
        WebToolsConfig.setTavilyAPIKey("")
        storedKey = ""
        keyInput = ""
    }
}
