// AIServiceSettingsForm: AI 服务设置中心，支持多服务商管理、多智能体团队编排与工具扩展配置。

import SwiftUI

// MARK: - AI 接口协议选项
enum AIProtocolOption: String, Codable, CaseIterable, Identifiable {
    case chat = "chat"
    case responses = "responses"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chat: return String(localized: "Chat Completions（通用兼容）")
        case .responses: return String(localized: "Responses（OpenAI 官方新协议）")
        }
    }
}

// MARK: - 设置子页面枚举
enum AIServiceSubTab: String, CaseIterable, Identifiable {
    case providers = "服务商"
    case agents = "智能体团队"
    case tools = "工具与扩展"

    var id: String { rawValue }
}

// MARK: - AI 服务设置主表单
struct AIServiceSettingsForm: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var providerStore = AIProviderStore.shared
    @ObservedObject private var agentStore = AIAgentStore.shared

    @State private var selectedSubTab: AIServiceSubTab = .providers

    // 当前选中的服务商 API Key 编辑态缓存
    @State private var apiKeyInput: String = ""
    @State private var isFetchingModels: Bool = false
    @State private var fetchError: String?

    // 候选模型池搜索过滤
    @State private var availableModels: [String] = []
    @State private var modelFilter: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 顶部子页面导航
            Picker("配置分类", selection: $selectedSubTab) {
                ForEach(AIServiceSubTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Form {
                switch selectedSubTab {
                case .providers:
                    providersFormSection
                case .agents:
                    agentsFormSection
                case .tools:
                    toolsFormSection
                }
            }
        }
    }

    // MARK: ================== 1. 服务商管理 ==================

    @ViewBuilder
    private var providersFormSection: some View {
        // 服务商选择与预设添加
        Section {
            HStack(spacing: 12) {
                Picker("选择服务商", selection: $providerStore.selectedProviderId) {
                    ForEach(providerStore.providers) { p in
                        HStack {
                            Text(p.name)
                            if !p.isEnabled {
                                Text("(已停用)").foregroundColor(.secondary)
                            }
                        }
                        .tag(p.id)
                    }
                }

                Menu {
                    Button("添加 阿里云百炼 (DashScope)") {
                        addPresetProvider(AIProvider.alibabaPreset())
                    }
                    Button("添加 OpenAI 官方") {
                        addPresetProvider(AIProvider.openAIPreset())
                    }
                    Button("添加 Qoder 国际版") {
                        addPresetProvider(AIProvider.qoderPreset())
                    }
                    Button("添加 Antigravity (Gemini)") {
                        addPresetProvider(AIProvider.antigravityPreset())
                    }
                    Divider()
                    Button("添加 自定义端点") {
                        addCustomProvider()
                    }
                } label: {
                    Label("添加服务商", systemImage: "plus")
                        .font(.system(size: Theme.Typography.body))
                }
            }
        } header: {
            Text("服务商列表")
        } footer: {
            Text("支持配置主流服务商（阿里云百炼、OpenAI、Qoder、Antigravity），密钥独立安全隔离存储。")
        }

        if let provider = currentProvider {
            let providerIndex = providerStore.providers.firstIndex(where: { $0.id == provider.id }) ?? 0

            Section {
                TextField("显示名称", text: providerNameBinding(at: providerIndex))
                    .textFieldStyle(.roundedBorder)

                Picker("通信协议类型", selection: providerTypeBinding(at: providerIndex)) {
                    ForEach(AIProviderType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }

                if provider.type == .openAICompatible {
                    Picker("API 子协议", selection: providerProtocolBinding(at: providerIndex)) {
                        ForEach(AIProtocolOption.allCases) { opt in
                            Text(opt.displayName).tag(opt)
                        }
                    }
                }

                Toggle("启用此服务商", isOn: providerEnabledBinding(at: providerIndex))
            } header: {
                Text("基本配置")
            }

            Section {
                TextField("Base URL", text: providerBaseURLBinding(at: providerIndex), prompt: Text(providerURLPlaceholder(for: provider.type)))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("端点地址 (Base URL)")
            } footer: {
                Text(providerURLFooter(for: provider.type))
            }

            Section {
                let storedKey = providerStore.apiKey(for: provider.id) ?? ""
                if storedKey.isEmpty {
                    SecureField(apiKeyPlaceholder(for: provider.type), text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                } else {
                    HStack {
                        Text("已安全存储 ····\(String(storedKey.suffix(4)))")
                            .font(.system(size: Theme.Typography.body))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("清除") {
                            providerStore.clearAPIKey(for: provider.id)
                            apiKeyInput = ""
                        }
                        .font(.system(size: Theme.Typography.body))
                    }
                    SecureField("输入新的密钥以替换", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                }

                let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedKey.isEmpty {
                    HStack {
                        Spacer()
                        Button("保存密钥") {
                            providerStore.setAPIKey(trimmedKey, for: provider.id)
                            apiKeyInput = ""
                        }
                        .font(.system(size: Theme.Typography.body, weight: .medium))
                    }
                }
            } header: {
                Text("认证密钥 (API Key / Token)")
            } footer: {
                Text(apiKeyFooter(for: provider.type))
            }

            // 模型池管理
            Section {
                if provider.models.isEmpty {
                    Text("尚未配置模型，请点击下方「添加模型」或「从 API 拉取」。")
                        .font(.system(size: Theme.Typography.body))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(provider.models.enumerated()), id: \.element.id) { mIndex, model in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("显示名", text: modelNameBinding(pIndex: providerIndex, mIndex: mIndex))
                                    .textFieldStyle(.roundedBorder)
                                TextField("模型 ID", text: modelIdBinding(pIndex: providerIndex, mIndex: mIndex))
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack(spacing: 12) {
                                TextField("上下文 (tokens)", text: modelContextBinding(pIndex: providerIndex, mIndex: mIndex))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 160)

                                Toggle(isOn: modelVisionBinding(pIndex: providerIndex, mIndex: mIndex)) {
                                    Label("支持视觉", systemImage: "eye.fill")
                                        .font(.system(size: Theme.Typography.footnote))
                                }
                                .toggleStyle(.checkbox)
                                .help("开启后，该模型可直接接收并解析图片。若关闭，用户发送图片时系统将自动委派视觉担当 (Observer) 先行分析")

                                Toggle(isOn: modelThinkingBinding(pIndex: providerIndex, mIndex: mIndex)) {
                                    Label("支持思考", systemImage: "brain.head.profile")
                                        .font(.system(size: Theme.Typography.footnote))
                                }
                                .toggleStyle(.checkbox)
                            }

                            HStack(spacing: 10) {
                                Button("上移") { moveModel(pIndex: providerIndex, from: mIndex, to: mIndex - 1) }
                                    .disabled(mIndex == 0)
                                Button("下移") { moveModel(pIndex: providerIndex, from: mIndex, to: mIndex + 1) }
                                    .disabled(mIndex == provider.models.count - 1)
                                Button("删除", role: .destructive) { removeModel(pIndex: providerIndex, at: mIndex) }
                                Spacer()
                            }
                            .font(.system(size: Theme.Typography.footnote))
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }

                HStack {
                    Button("添加模型") {
                        addNewModel(pIndex: providerIndex)
                    }
                    Spacer()
                    if provider.type == .openAICompatible {
                        Button("从 API 拉取模型") {
                            fetchModelsForProvider(provider)
                        }
                        .disabled(isFetchingModels)
                        if isFetchingModels {
                            ProgressView().controlSize(.small)
                        }
                    }
                }

                if let fetchError {
                    Text(fetchError)
                        .font(.system(size: Theme.Typography.footnote))
                        .foregroundColor(Theme.Colors.statusWarning)
                }

                if !availableModels.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("在拉取的候选中搜索...", text: $modelFilter)
                            .textFieldStyle(.roundedBorder)

                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(filteredAvailableModels, id: \.self) { mid in
                                    HStack {
                                        Text(mid)
                                            .font(.system(size: Theme.Typography.footnote, design: .monospaced))
                                        Spacer()
                                        if provider.models.contains(where: { $0.id == mid }) {
                                            Text("已添加").font(.system(size: Theme.Typography.micro)).foregroundColor(.secondary)
                                        } else {
                                            Button {
                                                addModelFromAvailable(pIndex: providerIndex, modelId: mid)
                                            } label: {
                                                Image(systemName: "plus.circle")
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        .frame(height: 120)

                        Button("清空拉取的候选列表") {
                            availableModels = []
                        }
                        .font(.system(size: Theme.Typography.micro))
                    }
                    .padding(.top, 4)
                }
            } header: {
                Text("模型能力池")
            } footer: {
                Text("「支持视觉」是 A+B 多模态调度的核心开关：若当前模型未勾选支持视觉，带有图片的消息将自动交由视觉感知 (Observer) Agent 代理看图，提取 OCR 与结构化信息后再注入主对话。")
            }

            if providerStore.providers.count > 1 {
                Section {
                    Button("删除此服务商", role: .destructive) {
                        providerStore.deleteProvider(id: provider.id)
                    }
                }
            }
        }
    }

    // MARK: ================== 2. 智能体管理 ==================

    @ViewBuilder
    private var agentsFormSection: some View {
        Section {
            HStack(spacing: 12) {
                Picker("选择智能体", selection: $agentStore.activeAgentId) {
                    ForEach(agentStore.agents) { a in
                        HStack {
                            Image(systemName: a.iconName)
                            Text(a.name)
                            if a.isVisualDelegate {
                                Text("[视觉担当]").foregroundColor(.secondary)
                            }
                        }
                        .tag(a.id)
                    }
                }

                Menu {
                    Button("添加新智能体") {
                        addNewAgent()
                    }
                    Divider()
                    Button("重置为官方默认团队 (Orchestrator, Observer, Coder, Oracle, Librarian)") {
                        agentStore.resetToDefaults()
                    }
                } label: {
                    Label("智能体操作", systemImage: "ellipsis.circle")
                        .font(.system(size: Theme.Typography.body))
                }
            }
        } header: {
            Text("当前激活智能体")
        } footer: {
            Text("智能体可在输入底栏点击胶囊随时切换，支持为不同任务配置专属人设、服务商、模型与思考强度。")
        }

        if let agent = currentAgent {
            let agentIndex = agentStore.agents.firstIndex(where: { $0.id == agent.id }) ?? 0

            Section {
                TextField("智能体名称", text: agentNameBinding(at: agentIndex))
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Text("图标:")
                        .font(.system(size: Theme.Typography.body))
                    Image(systemName: agent.iconName)
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(6)

                    // 预置常用图标按钮组
                    ForEach(["sparkles", "eye.fill", "curlybraces", "brain.head.profile", "books.vertical.fill", "bolt.fill"], id: \.self) { sym in
                        Button {
                            var copy = agentStore.agents[agentIndex]
                            copy.iconName = sym
                            agentStore.saveAgent(copy)
                        } label: {
                            Image(systemName: sym)
                                .font(.system(size: 12))
                                .padding(4)
                        }
                        .buttonStyle(.borderless)
                    }

                    TextField("SF Symbol 名", text: agentIconBinding(at: agentIndex))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                }

                TextField("职责描述", text: agentDescBinding(at: agentIndex))
                    .textFieldStyle(.roundedBorder)

                Toggle("启用此智能体", isOn: agentEnabledBinding(at: agentIndex))
            } header: {
                Text("角色档案")
            }

            Section {
                Picker("绑定服务商", selection: agentProviderBinding(at: agentIndex)) {
                    ForEach(providerStore.providers.filter { $0.isEnabled }) { p in
                        Text(p.name).tag(p.id)
                    }
                }

                let boundProvider = providerStore.provider(for: agent.providerId)
                let models = boundProvider?.models ?? []

                Picker("绑定模型", selection: agentModelBinding(at: agentIndex)) {
                    if models.isEmpty {
                        Text("无可用模型（请先在服务商中配置）").tag("")
                    } else {
                        ForEach(models) { m in
                            HStack {
                                Text(m.name)
                                if m.supportsVision {
                                    Text("[视觉]").foregroundColor(.cyan)
                                }
                                if m.supportsThinking {
                                    Text("[思考]").foregroundColor(.indigo)
                                }
                            }
                            .tag(m.id)
                        }
                    }
                }

                Picker("默认思考强度", selection: agentThinkingBinding(at: agentIndex)) {
                    Text("无 (None)").tag(ThinkingLevel?.none)
                    Text("低 (Low)").tag(ThinkingLevel?.some(.low))
                    Text("中 (Medium)").tag(ThinkingLevel?.some(.medium))
                    Text("高 (High)").tag(ThinkingLevel?.some(.high))
                }
            } header: {
                Text("模型路由绑定")
            } footer: {
                Text("为该智能体指定后端算力提供商与模型规格。")
            }

            Section {
                Toggle("设为全局视觉感知担当 (Visual Observer)", isOn: agentVisualDelegateBinding(at: agentIndex))

                let boundModel = providerStore.modelSpec(providerId: agent.providerId, modelId: agent.modelId)
                if boundModel?.supportsVision == false {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Theme.Colors.statusWarning)
                        Text("提示：当前绑定的模型未标记「支持视觉」，请确保绑定的模型具备多模态能力以承担视觉解析职责。")
                            .font(.system(size: Theme.Typography.footnote))
                            .foregroundColor(Theme.Colors.statusWarning)
                    }
                }
            } header: {
                Text("多模态协作机制")
            } footer: {
                Text("🌟 混合双模设计：当你在与不支持看图的模型对话时，若附带了图片，系统将自动无感调度本视觉担当 Agent 提取图像结构、OCR 文字与视觉关键要素，再将多模态语义注入主对话，解决纯文本模型无法理解图像的痛点！")
            }

            Section {
                TextField("特化角色提示词，留空继承全局", text: agentSystemPromptBinding(at: agentIndex), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4...8)
            } header: {
                Text("特化 System Prompt")
            } footer: {
                Text("为该智能体定制的系统设定、思维规范与工程职责。")
            }

            if agentStore.agents.count > 1 {
                Section {
                    Button("删除此智能体", role: .destructive) {
                        agentStore.deleteAgent(id: agent.id)
                    }
                }
            }
        }
    }

    // MARK: ================== 3. 工具与扩展 ==================

    @ViewBuilder
    private var toolsFormSection: some View {
        AIToolsSettingsSection()
        AIWebSearchSettingsSection()
        AIFileWhitelistSettingsSection()
        AIEnvVarsSettingsSection()

        Section {
            HStack {
                Text("打开 AI 对话窗")
                Spacer()
                KeyBadge(key: String(localized: "双击 ⌥ / I"))
            }
        } header: {
            Text("使用说明")
        } footer: {
            Text("全局双击 ⌥⌥ 随时唤出 / 关闭 AI 对话窗；在输入底栏点击智能体胶囊可一键切换当前角色。")
        }
    }

    // MARK: - 辅助计算属性与方法

    private var currentProvider: AIProvider? {
        providerStore.provider(for: providerStore.selectedProviderId) ?? providerStore.providers.first
    }

    private var currentAgent: AIAgent? {
        agentStore.agent(for: agentStore.activeAgentId) ?? agentStore.agents.first
    }

    private var filteredAvailableModels: [String] {
        let kw = modelFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return availableModels }
        return availableModels.filter { $0.lowercased().contains(kw) }
    }

    private func addPresetProvider(_ preset: AIProvider) {
        var newP = preset
        newP.id = "\(preset.id)-\(UUID().uuidString.prefix(4).lowercased())"
        newP.name = "\(preset.name) (副本)"
        providerStore.saveProvider(newP)
        providerStore.selectedProviderId = newP.id
    }

    private func addCustomProvider() {
        let newP = AIProvider(
            id: "custom-\(UUID().uuidString.prefix(4).lowercased())",
            name: "自定义端点",
            type: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            apiProtocol: .chat,
            isEnabled: true,
            models: [
                AIModelSpec(id: "default-model", name: "默认模型", contextWindow: 524288, supportsVision: true, supportsThinking: false)
            ]
        )
        providerStore.saveProvider(newP)
        providerStore.selectedProviderId = newP.id
    }

    private func addNewAgent() {
        let newA = AIAgent(
            id: "agent-\(UUID().uuidString.prefix(4).lowercased())",
            name: "新智能体",
            iconName: "sparkles",
            description: "自定义职责描述",
            systemPrompt: "你是一个专业的 AI 助手。",
            providerId: providerStore.selectedProviderId,
            modelId: currentProvider?.models.first?.id ?? "glm-5.3",
            thinkingLevel: nil,
            isEnabled: true,
            isVisualDelegate: false
        )
        agentStore.saveAgent(newA)
        agentStore.activeAgentId = newA.id
    }

    private func fetchModelsForProvider(_ provider: AIProvider) {
        isFetchingModels = true
        fetchError = nil
        Task { @MainActor in
            do {
                let ids = try await AIChatService.shared.fetchModels(for: provider)
                var set = Set(availableModels)
                for id in ids where !set.contains(id) {
                    availableModels.append(id)
                    set.insert(id)
                }
                if availableModels.isEmpty {
                    fetchError = "接口未返回任何模型。"
                }
            } catch {
                fetchError = error.localizedDescription
            }
            isFetchingModels = false
        }
    }

    private func providerURLPlaceholder(for type: AIProviderType) -> String {
        switch type {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .qoderNative: return "https://api3.qoder.sh"
        case .antigravityNative: return "https://generativelanguage.googleapis.com/v1beta"
        case .nativeBridge: return "http://127.0.0.1:8080/v1"
        }
    }

    private func providerURLFooter(for type: AIProviderType) -> String {
        switch type {
        case .openAICompatible:
            return "OpenAI 兼容端点的根地址，程序会自动用所选协议拼接请求路径。官方填 https://api.openai.com/v1；本地 Ollama/vLLM 填 http://localhost:端口/v1。"
        case .qoderNative:
            return "Qoder 官方地址为 https://api3.qoder.sh；若使用本地桥接代理，请填入本地 http://127.0.0.1:端口/v1。"
        case .antigravityNative:
            return "Gemini 官方地址为 https://generativelanguage.googleapis.com/v1beta；直连 Google AI 端点。"
        case .nativeBridge:
            return "本地独立代理端点根地址，程序将直连该地址并不做二次加解密。"
        }
    }

    private func apiKeyPlaceholder(for type: AIProviderType) -> String {
        switch type {
        case .openAICompatible: return "输入 Bearer API Key"
        case .qoderNative: return "输入 Qoder PAT 访问令牌 (pt-...)"
        case .antigravityNative: return "输入 Google AI Studio API Key 或 OAuth Token"
        case .nativeBridge: return "输入本地代理鉴权密钥 (如有)"
        }
    }

    private func apiKeyFooter(for type: AIProviderType) -> String {
        switch type {
        case .qoderNative:
            return "支持直接输入 PAT 令牌 (以 pt- 开头)，应用将在本地自动完成 JobToken 兑换与 COSY 签名，密钥仅保存在本机。"
        case .antigravityNative:
            return "支持 Google AI Studio 获取的 API Key，或以 ya29. 开头的 Google Cloud OAuth 临时访问令牌。"
        default:
            return "API Key 以仅当前用户可读的文件权限 (0600) 存储在本机应用支持目录，绝不随云端同步。"
        }
    }

    // MARK: - Provider Bindings

    private func providerNameBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { providerStore.providers[index].name },
            set: {
                var p = providerStore.providers[index]
                p.name = $0
                providerStore.saveProvider(p)
            }
        )
    }

    private func providerTypeBinding(at index: Int) -> Binding<AIProviderType> {
        Binding(
            get: { providerStore.providers[index].type },
            set: {
                var p = providerStore.providers[index]
                p.type = $0
                providerStore.saveProvider(p)
            }
        )
    }

    private func providerProtocolBinding(at index: Int) -> Binding<AIProtocolOption> {
        Binding(
            get: { providerStore.providers[index].apiProtocol },
            set: {
                var p = providerStore.providers[index]
                p.apiProtocol = $0
                providerStore.saveProvider(p)
            }
        )
    }

    private func providerEnabledBinding(at index: Int) -> Binding<Bool> {
        Binding(
            get: { providerStore.providers[index].isEnabled },
            set: {
                var p = providerStore.providers[index]
                p.isEnabled = $0
                providerStore.saveProvider(p)
            }
        )
    }

    private func providerBaseURLBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { providerStore.providers[index].baseURL },
            set: {
                var p = providerStore.providers[index]
                p.baseURL = $0
                providerStore.saveProvider(p)
            }
        )
    }

    // MARK: - Model Bindings

    private func modelNameBinding(pIndex: Int, mIndex: Int) -> Binding<String> {
        Binding(
            get: { providerStore.providers[pIndex].models[mIndex].name },
            set: {
                var p = providerStore.providers[pIndex]
                p.models[mIndex].name = $0
                providerStore.saveProvider(p)
            }
        )
    }

    private func modelIdBinding(pIndex: Int, mIndex: Int) -> Binding<String> {
        Binding(
            get: { providerStore.providers[pIndex].models[mIndex].id },
            set: {
                var p = providerStore.providers[pIndex]
                p.models[mIndex].id = $0
                providerStore.saveProvider(p)
            }
        )
    }

    private func modelContextBinding(pIndex: Int, mIndex: Int) -> Binding<String> {
        Binding(
            get: { String(providerStore.providers[pIndex].models[mIndex].contextWindow) },
            set: {
                if let val = Int($0.trimmingCharacters(in: .whitespacesAndNewlines)), val > 0 {
                    var p = providerStore.providers[pIndex]
                    p.models[mIndex].contextWindow = val
                    providerStore.saveProvider(p)
                }
            }
        )
    }

    private func modelVisionBinding(pIndex: Int, mIndex: Int) -> Binding<Bool> {
        Binding(
            get: { providerStore.providers[pIndex].models[mIndex].supportsVision },
            set: {
                var p = providerStore.providers[pIndex]
                p.models[mIndex].supportsVision = $0
                providerStore.saveProvider(p)
            }
        )
    }

    private func modelThinkingBinding(pIndex: Int, mIndex: Int) -> Binding<Bool> {
        Binding(
            get: { providerStore.providers[pIndex].models[mIndex].supportsThinking },
            set: {
                var p = providerStore.providers[pIndex]
                p.models[mIndex].supportsThinking = $0
                providerStore.saveProvider(p)
            }
        )
    }

    private func addNewModel(pIndex: Int) {
        var p = providerStore.providers[pIndex]
        p.models.append(AIModelSpec(id: "new-model", name: "新模型", contextWindow: 524288, supportsVision: false, supportsThinking: false))
        providerStore.saveProvider(p)
    }

    private func addModelFromAvailable(pIndex: Int, modelId: String) {
        var p = providerStore.providers[pIndex]
        guard !p.models.contains(where: { $0.id == modelId }) else { return }
        let isVision = modelId.contains("vl") || modelId.contains("flash") || modelId.contains("4o")
        let isThinking = modelId.contains("glm") || modelId.contains("k3") || modelId.contains("r1") || modelId.contains("o1") || modelId.contains("o3")
        p.models.append(AIModelSpec(id: modelId, name: modelId, contextWindow: 524288, supportsVision: isVision, supportsThinking: isThinking))
        providerStore.saveProvider(p)
    }

    private func removeModel(pIndex: Int, at mIndex: Int) {
        var p = providerStore.providers[pIndex]
        guard mIndex < p.models.count else { return }
        p.models.remove(at: mIndex)
        providerStore.saveProvider(p)
    }

    private func moveModel(pIndex: Int, from: Int, to: Int) {
        var p = providerStore.providers[pIndex]
        guard p.models.indices.contains(from), p.models.indices.contains(to) else { return }
        p.models.swapAt(from, to)
        providerStore.saveProvider(p)
    }

    // MARK: - Agent Bindings

    private func agentNameBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { agentStore.agents[index].name },
            set: {
                var a = agentStore.agents[index]
                a.name = $0
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentIconBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { agentStore.agents[index].iconName },
            set: {
                var a = agentStore.agents[index]
                a.iconName = $0
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentDescBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { agentStore.agents[index].description },
            set: {
                var a = agentStore.agents[index]
                a.description = $0
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentEnabledBinding(at index: Int) -> Binding<Bool> {
        Binding(
            get: { agentStore.agents[index].isEnabled },
            set: {
                var a = agentStore.agents[index]
                a.isEnabled = $0
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentProviderBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { agentStore.agents[index].providerId },
            set: { newProviderId in
                var a = agentStore.agents[index]
                a.providerId = newProviderId
                if let p = providerStore.provider(for: newProviderId), let firstModel = p.models.first {
                    a.modelId = firstModel.id
                }
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentModelBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { agentStore.agents[index].modelId },
            set: {
                var a = agentStore.agents[index]
                a.modelId = $0
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentThinkingBinding(at index: Int) -> Binding<ThinkingLevel?> {
        Binding(
            get: { agentStore.agents[index].thinkingLevel },
            set: {
                var a = agentStore.agents[index]
                a.thinkingLevel = $0
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentVisualDelegateBinding(at index: Int) -> Binding<Bool> {
        Binding(
            get: { agentStore.agents[index].isVisualDelegate },
            set: { isDelegate in
                if isDelegate {
                    agentStore.setVisualDelegate(agentId: agentStore.agents[index].id)
                } else {
                    var a = agentStore.agents[index]
                    a.isVisualDelegate = false
                    agentStore.saveAgent(a)
                }
            }
        )
    }

    private func agentSystemPromptBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { agentStore.agents[index].systemPrompt },
            set: {
                var a = agentStore.agents[index]
                a.systemPrompt = $0
                agentStore.saveAgent(a)
            }
        )
    }
}
