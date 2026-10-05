// 本文件由 SettingsView.swift 拆分而来：AI 服务设置表单与接口协议选项。

import SwiftUI

// MARK: - AI 接口协议选项
/// AI 接口协议选项（rawValue 与 AIChatService.APIProtocol 保持一致："chat" / "responses"）。
/// 说明：并行实现的 AIChatService.APIProtocol 公开接口暂不可见时，本表单按同键
/// `@AppStorage("ai.apiProtocol")` 私有绑定，读写同一份 UserDefaults 原始值，后续可无痛切换到服务接口。
enum AIProtocolOption: String, CaseIterable, Identifiable {
    case chat = "chat"
    case responses = "responses"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .chat: return "Chat Completions（通用兼容）"
        case .responses: return "Responses（OpenAI 官方新协议）"
        }
    }
}

// MARK: - 6. AI 服务设置表单
struct AIServiceSettingsForm: View {
    // appState 作为设置中心的统一状态入口保留（本表单配置项均为独立键，暂不依赖其成员）
    @ObservedObject var appState: AppState
    
    // Base URL / Model / System Prompt 均存 UserDefaults，键名与 AIChatService.ConfigKey 完全一致；
    // 直接以 @AppStorage 绑定同键，既能获得 SwiftUI 响应式刷新，又与 AIChatService 读写共享同一份数据。
    @AppStorage("ai.baseURL") private var baseURL: String = ""
    @AppStorage("ai.systemPrompt") private var systemPrompt: String = ""
    // API 协议：原始值 "chat" / "responses"，键名与 AIChatService 保持一致
    @AppStorage("ai.apiProtocol") private var apiProtocolRaw: String = AIProtocolOption.chat.rawValue

    /// 模型列表（显示名 + modelId，首项为默认）。由 AIChatService 读写，本表单仅做编辑态。
    @State private var modelList: [AIModel] = []
    /// 当前选中模型的 modelId。
    @State private var selectedModelId: String = ""
    /// 候选池：端点返回的全部可用 model id（只读，供搜索挑选）。
    @State private var availableModels: [String] = []
    /// 候选池搜索关键词（本地过滤，不动持久层）。
    @State private var modelFilter: String = ""
    /// 正在从 API 拉取模型列表。
    @State private var isFetchingModels = false
    /// 拉取失败的行内中文提示。
    @State private var fetchError: String?
    
    /// 已存 API Key（仅用于掩码展示，绝不持久化到 UserDefaults）
    @State private var storedKey: String = ""
    /// 新输入的 API Key（仅内存态，保存成功后清空）
    @State private var apiKeyInput: String = ""
    
    var body: some View {
        Form {
            Section {
                Picker("API 协议", selection: apiProtocolBinding) {
                    ForEach(AIProtocolOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } header: {
                Text("API 协议")
            } footer: {
                Text("Chat Completions 兼容大多数 OpenAI 兼容端点（中转 / Ollama / vLLM 等）；Responses 为 OpenAI 官方新协议，仅官方端点支持。选择 Responses 时 Base URL 填官方地址。")
            }
            
            Section {
                // 占位文案用中性描述且以 verbatim 传入，避免 URL 被 Markdown 自动识别成蓝色链接；
                // prompt 压成 contentTertiary 灰，与其他字段（如「输入 API Key」）的占位观感一致。
                TextField("Base URL", text: $baseURL, prompt: Text(verbatim: "例如 api.openai.com/v1").foregroundColor(Theme.Colors.contentTertiary))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Base URL")
            } footer: {
                // verbatim 纯文本：footer 中的示例地址不做 Markdown 链接着色，保持普通灰白说明文字。
                Text(verbatim: "OpenAI 兼容端点的根地址，程序会自动用所选协议拼接请求路径。官方端点填 https://api.openai.com/v1；本地 Ollama / vLLM 填 http://localhost:端口/v1。")
            }
            
            Section {
                if storedKey.isEmpty {
                    SecureField("输入 API Key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                } else {
                    HStack {
                        Text("已存储 ····\(maskedKeySuffix)")
                            .font(.system(size: Theme.Typography.body))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("清除") { clearAPIKey() }
                            .font(.system(size: Theme.Typography.body))
                    }
                    SecureField("输入新的 API Key 以替换", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                }
                
                if !trimmedAPIKeyInput.isEmpty {
                    HStack {
                        Spacer()
                        Button("保存 API Key") { saveAPIKey() }
                            .font(.system(size: Theme.Typography.body, weight: .medium))
                    }
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("API Key 以仅当前用户可读的文件权限存储在本机应用支持目录，不写入 UserDefaults，不随 iCloud 同步。")
            }
            
            Section {
                if modelList.isEmpty {
                    Text("尚未配置模型，请添加一项，或从下方「可用模型」中添加。")
                        .font(.system(size: Theme.Typography.body))
                        .foregroundColor(.secondary)
                } else {
                    // 默认模型（新会话）：仅作为未绑定会话模型的默认值；已绑定模型的会话不受影响
                    Picker("默认模型（新会话）", selection: selectedModelBinding) {
                        ForEach(modelList) { item in
                            Text(item.name.isEmpty ? item.modelId : item.name).tag(item.modelId)
                        }
                    }

                    ForEach(Array(modelList.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("显示名", text: nameBinding(at: index))
                                    .textFieldStyle(.roundedBorder)
                                TextField("模型 ID", text: modelIdBinding(at: index))
                                    .textFieldStyle(.roundedBorder)
                                if index == 0 {
                                    Text("默认")
                                        .font(.system(size: Theme.Typography.mini, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            // 上下文窗口（tokens）：留空 = 使用默认 512k；仅接受正整数。
                            TextField("上下文窗口（tokens，留空=512k）", text: contextWindowBinding(at: index))
                                .textFieldStyle(.roundedBorder)
                            HStack(spacing: 10) {
                                Button("上移") { moveModel(from: index, to: index - 1) }
                                    .disabled(index == 0)
                                Button("下移") { moveModel(from: index, to: index + 1) }
                                    .disabled(index == modelList.count - 1)
                                Button("设为默认") { setDefaultModel(at: index) }
                                    .disabled(index == 0)
                                Button("删除", role: .destructive) { removeModel(at: index) }
                                Spacer(minLength: 0)
                                if selectedModelId == item.modelId {
                                    Text("当前使用")
                                        .font(.system(size: Theme.Typography.mini))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .font(.system(size: Theme.Typography.body))
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }

                    Button("添加模型") { addModel() }
                        .font(.system(size: Theme.Typography.body))
                }
            } header: {
                Text("我的模型")
            } footer: {
                Text("列表首项为默认模型；AI 窗的模型切换菜单只显示这里（我的模型）的条目。图片输入需端点与模型支持 vision。")
            }

            Section {
                // 候选池：只读、可搜索、可挑选加入「我的模型」；几百条也保持流畅。
                TextField("搜索模型 ID", text: $modelFilter)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Text(modelFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "共 \(availableModels.count) 个"
                         : "匹配 \(filteredAvailableModels.count) / \(availableModels.count)")
                        .font(.system(size: Theme.Typography.footnote))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Button("从 API 拉取") { fetchModelsFromAPI() }
                        .font(.system(size: Theme.Typography.body, weight: .medium))
                        .disabled(isFetchingModels)
                    if isFetchingModels {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let fetchError {
                    Text(fetchError)
                        .font(.system(size: Theme.Typography.body))
                        .foregroundColor(Theme.Colors.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if availableModels.isEmpty {
                    Text("候选池为空，点击「从 API 拉取」获取端点可用模型。")
                        .font(.system(size: Theme.Typography.body))
                        .foregroundColor(.secondary)
                } else {
                    // 固定高度 + LazyVStack：只渲染可视行，几百条滚动不卡；行内严禁 TextField。
                    // 滚动条隐藏：默认叠加式滚动条会压住行尾的「+」按钮，内容已有搜索过滤，无需滚动条存在感。
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredAvailableModels, id: \.self) { modelId in
                                HStack(spacing: 8) {
                                    Text(modelId)
                                        .font(.system(size: Theme.Typography.body))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundColor(isModelAdded(modelId) ? .secondary : .primary)
                                    Spacer(minLength: 0)
                                    if isModelAdded(modelId) {
                                        Text("已添加")
                                            .font(.system(size: Theme.Typography.mini))
                                            .foregroundColor(.secondary)
                                    } else {
                                        Button {
                                            addModelFromPool(modelId)
                                        } label: {
                                            Image(systemName: "plus.circle")
                                                .font(.system(size: Theme.Typography.body))
                                        }
                                        .buttonStyle(.borderless)
                                        .help("加入我的模型")
                                    }
                                }
                                .padding(.vertical, 1)
                                // 行尾让出安全边距：确保「+」按钮不被列表右缘裁切
                                .padding(.trailing, 6)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 末行完整可见：底部留出滚动余量
                        .padding(.bottom, 4)
                    }
                    .scrollIndicators(.never, axes: .vertical)
                    .frame(height: 220)

                    if !filteredAvailableModels.isEmpty || !modelFilter.isEmpty {
                        Button("清空候选池", role: .destructive) { clearAvailableModels() }
                            .font(.system(size: Theme.Typography.footnote))
                    }
                }
            } header: {
                Text("可用模型")
            } footer: {
                Text("端点返回的全部模型候选，仅供挑选；点击 + 加入「我的模型」。候选池清空不影响我的模型。")
            }
            
            Section {
                TextField("留空则不发送 system 消息", text: $systemPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
            } header: {
                Text("System Prompt（可选）")
            } footer: {
                Text("可选的角色设定 / 前置指令，留空则不发送 system 消息。")
            }

            // AI 工具配置：开关 / 联网搜索 Key / 文件访问白名单 / 自定义环境变量
            //（开关与白名单、环境变量即改即生效，后端每次请求直读 UserDefaults；Key 仅存 Keychain）
            AIToolsSettingsSection()
            AIWebSearchSettingsSection()
            AIFileWhitelistSettingsSection()
            AIEnvVarsSettingsSection()

            Section {
                HStack {
                    Text("打开 AI 对话窗")
                    Spacer()
                    KeyBadge(key: "双击 ⌥ / I")
                }
            } header: {
                Text("使用")
            } footer: {
                Text("全局双击 ⌥⌥ 随时唤出 / 关闭 AI 对话窗（热键可在「快捷键设置」中更改）；主面板激活时按 I 键亦可进入。")
            }
        }
        .onAppear {
            loadStoredKey()
            loadModelList()
        }
    }
    
    /// API 协议绑定：原始值字符串与枚举互转，默认 Chat Completions
    private var apiProtocolBinding: Binding<AIProtocolOption> {
        Binding(
            get: { AIProtocolOption(rawValue: apiProtocolRaw) ?? .chat },
            set: { apiProtocolRaw = $0.rawValue }
        )
    }
    
    /// 已存 key 的末 4 位掩码文本
    private var maskedKeySuffix: String {
        String(storedKey.suffix(4))
    }
    
    private var trimmedAPIKeyInput: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// API Key 读取走 AIChatService 公开接口（@MainActor），用 MainActor Task 包裹，
    /// 避免在非隔离的 View 上下文中直接调用产生隔离告警。
    private func loadStoredKey() {
        Task { @MainActor in
            storedKey = AIChatService.shared.apiKey ?? ""
        }
    }
    
    private func saveAPIKey() {
        let key = trimmedAPIKeyInput
        guard !key.isEmpty else { return }
        Task { @MainActor in
            AIChatService.shared.saveAPIKey(key)
            storedKey = key
            apiKeyInput = ""
        }
    }
    
    private func clearAPIKey() {
        Task { @MainActor in
            AIChatService.shared.clearAPIKey()
            storedKey = ""
            apiKeyInput = ""
        }
    }

    // MARK: - 模型列表编辑

    /// 当前模型绑定：写回服务层，对下一轮请求生效。
    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { selectedModelId },
            set: { newValue in
                selectedModelId = newValue
                persistModelList()
            }
        )
    }

    private func nameBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { index < modelList.count ? modelList[index].name : "" },
            set: { newValue in
                guard index < modelList.count else { return }
                modelList[index].name = newValue
                persistModelList()
            }
        )
    }

    private func modelIdBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { index < modelList.count ? modelList[index].modelId : "" },
            set: { newValue in
                guard index < modelList.count else { return }
                let oldValue = modelList[index].modelId
                modelList[index].modelId = newValue
                if selectedModelId == oldValue {
                    selectedModelId = newValue
                }
                persistModelList()
            }
        )
    }

    /// 上下文窗口（tokens）绑定：空串写回 nil（= 默认 512k）；仅接受正整数，非法输入忽略。
    private func contextWindowBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard index < modelList.count, let value = modelList[index].contextWindow else { return "" }
                return String(value)
            },
            set: { newValue in
                guard index < modelList.count else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    modelList[index].contextWindow = nil
                } else if let value = Int(trimmed), value > 0 {
                    modelList[index].contextWindow = value
                } else {
                    return // 非法输入不写回
                }
                persistModelList()
            }
        )
    }

    private func loadModelList() {
        Task { @MainActor in
            modelList = AIChatService.shared.modelList
            selectedModelId = AIChatService.shared.selectedModel
            availableModels = AIChatService.shared.availableModels
        }
    }

    private func persistModelList() {
        let snapshot = modelList
        let selected = selectedModelId
        Task { @MainActor in
            var list = snapshot
            // 清理空 modelId 项，避免写入无效条目
            list.removeAll { $0.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            AIChatService.shared.modelList = list
            // 仅当选中项仍在列表中才写回，否则交由 setter 的校正逻辑兜底。
            if list.contains(where: { $0.modelId == selected }) {
                AIChatService.shared.selectedModel = selected
            }
        }
    }

    private func persistAvailableModels() {
        let snapshot = availableModels
        Task { @MainActor in
            AIChatService.shared.availableModels = snapshot
        }
    }

    private func addModel() {
        modelList.append(AIModel(name: "", modelId: ""))
        persistModelList()
    }

    private func removeModel(at index: Int) {
        guard index < modelList.count else { return }
        let removed = modelList.remove(at: index)
        if selectedModelId == removed.modelId, let first = modelList.first {
            selectedModelId = first.modelId
        }
        persistModelList()
    }

    private func moveModel(from index: Int, to target: Int) {
        guard modelList.indices.contains(index), modelList.indices.contains(target) else { return }
        modelList.swapAt(index, target)
        persistModelList()
    }

    /// 设为默认：移到首项并切换为当前模型。
    private func setDefaultModel(at index: Int) {
        guard modelList.indices.contains(index) else { return }
        let item = modelList.remove(at: index)
        modelList.insert(item, at: 0)
        selectedModelId = item.modelId
        persistModelList()
    }

    // MARK: - 候选池

    /// 本地过滤（忽略大小写，匹配 modelId），不动持久层。
    private var filteredAvailableModels: [String] {
        let keyword = modelFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return availableModels }
        return availableModels.filter { $0.lowercased().contains(keyword) }
    }

    private func isModelAdded(_ modelId: String) -> Bool {
        modelList.contains { $0.modelId == modelId }
    }

    /// 从候选池加入「我的模型」（显示名默认 = modelId）。
    private func addModelFromPool(_ modelId: String) {
        guard !isModelAdded(modelId) else { return }
        modelList.append(AIModel(name: modelId, modelId: modelId))
        persistModelList()
    }

    /// 清空候选池（条目都是拉来的，无需确认；不影响我的模型）。
    private func clearAvailableModels() {
        availableModels = []
        modelFilter = ""
        persistAvailableModels()
    }

    /// 从 API 拉取模型：结果只合并进候选池（去重），绝不直接进「我的模型」。
    private func fetchModelsFromAPI() {
        isFetchingModels = true
        fetchError = nil
        Task { @MainActor in
            do {
                let ids = try await AIChatService.shared.fetchModels()
                var existing = Set(availableModels)
                for id in ids where !existing.contains(id) {
                    availableModels.append(id)
                    existing.insert(id)
                }
                if availableModels.isEmpty {
                    fetchError = "接口未返回任何模型。"
                }
                persistAvailableModels()
            } catch {
                fetchError = error.localizedDescription
            }
            isFetchingModels = false
        }
    }
}
