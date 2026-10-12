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
    @ObservedObject private var authManager = AIAuthManager.shared

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
            Section {
                TextField("显示名称", text: providerNameBinding(for: provider.id))
                    .textFieldStyle(.roundedBorder)

                Picker("通信协议类型", selection: providerTypeBinding(for: provider.id)) {
                    ForEach(AIProviderType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }

                if provider.type == .openAICompatible {
                    Picker("API 子协议", selection: providerProtocolBinding(for: provider.id)) {
                        ForEach(AIProtocolOption.allCases) { opt in
                            Text(opt.displayName).tag(opt)
                        }
                    }
                }

                Toggle("启用此服务商", isOn: providerEnabledBinding(for: provider.id))
            } header: {
                Text("基本配置")
            }

            Section {
                TextField("Base URL", text: providerBaseURLBinding(for: provider.id), prompt: Text(providerURLPlaceholder(for: provider.type)))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("端点地址 (Base URL)")
            } footer: {
                Text(providerURLFooter(for: provider.type))
            }

            Section {
                let storedKey = providerStore.apiKey(for: provider.id) ?? ""
                let accountInfo = providerStore.accountInfo(for: provider.id)
                let authState = authManager.state(for: provider.id)
                let detected = authManager.detectedAccount(for: provider.id)

                // A. 针对支持浏览器/本机探测的服务商 (Qoder / Antigravity)
                if provider.type == .qoderNative || provider.type == .antigravityNative {
                    if !storedKey.isEmpty {
                        // 已认证授权状态卡片
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Theme.Colors.statusGood)
                                Text("已完成认证授权")
                                    .font(.system(size: Theme.Typography.body, weight: .semibold))
                                Spacer()
                                Button("退出登录 / 清除") {
                                    authManager.logout(for: provider.id)
                                    apiKeyInput = ""
                                }
                                .font(.system(size: Theme.Typography.footnote))
                                .foregroundColor(Theme.Colors.statusWarning)
                            }

                            if let acc = accountInfo {
                                HStack(spacing: 8) {
                                    Image(systemName: "person.crop.circle")
                                        .foregroundColor(.secondary)
                                    Text(acc.displayName)
                                        .font(.system(size: Theme.Typography.body))
                                    if !acc.email.isEmpty {
                                        Text("(\(acc.email))")
                                            .font(.system(size: Theme.Typography.footnote))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(acc.authMethod == "browser" ? "浏览器授权" : (acc.authMethod == "auto_detect" ? "本机导入" : "手动凭据"))
                                        .font(.system(size: Theme.Typography.micro))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .cornerRadius(4)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        // 未授权状态：快捷操作组 (浏览器登录 / 本机检测导入)
                        VStack(alignment: .leading, spacing: 10) {
                            if case .authorizing(let msg) = authState {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(msg)
                                        .font(.system(size: Theme.Typography.body))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Button("取消") {
                                        authManager.cancelAuth(for: provider.id)
                                    }
                                    .font(.system(size: Theme.Typography.footnote))
                                }
                                .padding(.vertical, 4)
                            } else {
                                HStack(spacing: 10) {
                                    Button {
                                        authManager.startBrowserAuth(for: provider.id)
                                    } label: {
                                        Label("🌐 浏览器登录授权", systemImage: "globe")
                                            .font(.system(size: Theme.Typography.body, weight: .medium))
                                    }
                                    .buttonStyle(.borderedProminent)

                                    if let local = detected {
                                        Button {
                                            authManager.importDetectedAccount(for: provider.id)
                                        } label: {
                                            Label("⚡️ 导入本机账号 (\(local.displayName))", systemImage: "bolt.fill")
                                                .font(.system(size: Theme.Typography.body))
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }

                                if case .failed(let err) = authState {
                                    Text(err)
                                        .font(.system(size: Theme.Typography.footnote))
                                        .foregroundColor(Theme.Colors.statusWarning)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    Divider().padding(.vertical, 2)
                }

                // B. 方式 ①：手动填入 API Key / Token (通用保底)
                VStack(alignment: .leading, spacing: 6) {
                    if !storedKey.isEmpty {
                        HStack {
                            Text("已保存凭据 ····\(String(storedKey.suffix(4)))")
                                .font(.system(size: Theme.Typography.footnote))
                                .foregroundColor(.secondary)
                            Spacer()
                            if provider.type != .qoderNative && provider.type != .antigravityNative {
                                Button("清除") {
                                    providerStore.clearAPIKey(for: provider.id)
                                    apiKeyInput = ""
                                }
                                .font(.system(size: Theme.Typography.footnote))
                            }
                        }
                        SecureField("输入新的密钥以替换", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(apiKeyPlaceholder(for: provider.type), text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedKey.isEmpty {
                        HStack {
                            Spacer()
                            Button("保存手动密钥") {
                                providerStore.setAPIKey(trimmedKey, for: provider.id)
                                let acc = ProviderAccountInfo(
                                    displayName: "手动凭据",
                                    email: "",
                                    avatarURL: nil,
                                    authMethod: "manual",
                                    authorizedAt: Date(),
                                    refreshToken: nil
                                )
                                providerStore.saveAccountInfo(acc, for: provider.id)
                                apiKeyInput = ""
                            }
                            .font(.system(size: Theme.Typography.body, weight: .medium))
                        }
                    }
                }
            } header: {
                Text("认证与授权 (浏览器 / 本机 / API Key)")
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
                    ForEach(provider.models) { model in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("显示名", text: modelNameBinding(providerId: provider.id, modelId: model.id))
                                    .textFieldStyle(.roundedBorder)
                                TextField("模型 ID", text: modelIdBinding(providerId: provider.id, modelId: model.id))
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack(spacing: 12) {
                                TextField("上下文 (tokens)", text: modelContextBinding(providerId: provider.id, modelId: model.id))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 160)

                                Toggle(isOn: modelVisionBinding(providerId: provider.id, modelId: model.id)) {
                                    Label("支持视觉", systemImage: "eye.fill")
                                        .font(.system(size: Theme.Typography.footnote))
                                }
                                .toggleStyle(.checkbox)
                                .help("开启后，该模型可直接接收并解析图片。若关闭，用户发送图片时系统将自动委派视觉担当 (Observer) 先行分析")

                                Toggle(isOn: modelThinkingBinding(providerId: provider.id, modelId: model.id)) {
                                    Label("支持思考", systemImage: "brain.head.profile")
                                        .font(.system(size: Theme.Typography.footnote))
                                }
                                .toggleStyle(.checkbox)
                            }

                            HStack(spacing: 10) {
                                let mIndex = provider.models.firstIndex(where: { $0.id == model.id }) ?? 0
                                Button("上移") { moveModel(providerId: provider.id, modelId: model.id, direction: -1) }
                                    .disabled(mIndex == 0)
                                Button("下移") { moveModel(providerId: provider.id, modelId: model.id, direction: 1) }
                                    .disabled(mIndex == provider.models.count - 1)
                                Button("删除", role: .destructive) { removeModel(providerId: provider.id, modelId: model.id) }
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
                        addNewModel(providerId: provider.id)
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
                                                addModelFromAvailable(providerId: provider.id, modelId: mid)
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
            Section {
                TextField("智能体名称", text: agentNameBinding(for: agent.id))
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
                            var copy = agent
                            copy.iconName = sym
                            agentStore.saveAgent(copy)
                        } label: {
                            Image(systemName: sym)
                                .font(.system(size: 12))
                                .padding(4)
                        }
                        .buttonStyle(.borderless)
                    }

                    TextField("SF Symbol 名", text: agentIconBinding(for: agent.id))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                }

                TextField("职责描述", text: agentDescBinding(for: agent.id))
                    .textFieldStyle(.roundedBorder)

                Toggle("启用此智能体", isOn: agentEnabledBinding(for: agent.id))
            } header: {
                Text("角色档案")
            }

            Section {
                Picker("绑定服务商", selection: agentProviderBinding(for: agent.id)) {
                    ForEach(providerStore.providers.filter { $0.isEnabled }) { p in
                        Text(p.name).tag(p.id)
                    }
                }

                let boundProvider = providerStore.provider(for: agent.providerId)
                let models = boundProvider?.models ?? []

                Picker("绑定模型", selection: agentModelBinding(for: agent.id)) {
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

                Picker("默认思考强度", selection: agentThinkingBinding(for: agent.id)) {
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
                Toggle("设为全局视觉感知担当 (Visual Observer)", isOn: agentVisualDelegateBinding(for: agent.id))

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
                TextField("特化角色提示词，留空继承全局", text: agentSystemPromptBinding(for: agent.id), axis: .vertical)
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
            return "支持三方认证方式：① 浏览器登录授权（自动唤起网页并在确认后无感绑定）；② 自动检测本机 Qoder CLI 已登录账号一键导入；③ 手动填入 PAT 令牌 (以 pt- 开头)。"
        case .antigravityNative:
            return "支持三方认证方式：① 浏览器登录授权（Google OAuth 2.0 PKCE 标准流）；② 自动检测本机 Gemini / gcloud 凭据一键导入；③ 手动填入 Google AI Studio API Key。"
        default:
            return "API Key 以仅当前用户可读的文件权限 (0600) 存储在本机应用支持目录，绝不随云端同步。"
        }
    }

    // MARK: - Provider Bindings

    private func providerNameBinding(for providerId: String) -> Binding<String> {
        Binding(
            get: { providerStore.provider(for: providerId)?.name ?? "" },
            set: {
                guard var p = providerStore.provider(for: providerId) else { return }
                p.name = $0
                providerStore.saveProvider(p)
            }
        )
    }

    private func providerTypeBinding(for providerId: String) -> Binding<AIProviderType> {
        Binding(
            get: { providerStore.provider(for: providerId)?.type ?? .openAICompatible },
            set: {
                guard var p = providerStore.provider(for: providerId) else { return }
                p.type = $0
                providerStore.saveProvider(p)
            }
        )
    }

    private func providerProtocolBinding(for providerId: String) -> Binding<AIProtocolOption> {
        Binding(
            get: { providerStore.provider(for: providerId)?.apiProtocol ?? .chat },
            set: {
                guard var p = providerStore.provider(for: providerId) else { return }
                p.apiProtocol = $0
                providerStore.saveProvider(p)
            }
        )
    }

    private func providerEnabledBinding(for providerId: String) -> Binding<Bool> {
        Binding(
            get: { providerStore.provider(for: providerId)?.isEnabled ?? false },
            set: {
                guard var p = providerStore.provider(for: providerId) else { return }
                p.isEnabled = $0
                providerStore.saveProvider(p)
            }
        )
    }

    private func providerBaseURLBinding(for providerId: String) -> Binding<String> {
        Binding(
            get: { providerStore.provider(for: providerId)?.baseURL ?? "" },
            set: {
                guard var p = providerStore.provider(for: providerId) else { return }
                p.baseURL = $0
                providerStore.saveProvider(p)
            }
        )
    }

    // MARK: - Model Bindings

    private func modelNameBinding(providerId: String, modelId: String) -> Binding<String> {
        Binding(
            get: {
                providerStore.provider(for: providerId)?.models.first(where: { $0.id == modelId })?.name ?? ""
            },
            set: { newName in
                guard var p = providerStore.provider(for: providerId),
                      let idx = p.models.firstIndex(where: { $0.id == modelId }) else { return }
                p.models[idx].name = newName
                providerStore.saveProvider(p)
            }
        )
    }

    private func modelIdBinding(providerId: String, modelId: String) -> Binding<String> {
        Binding(
            get: {
                providerStore.provider(for: providerId)?.models.first(where: { $0.id == modelId })?.id ?? ""
            },
            set: { newId in
                guard var p = providerStore.provider(for: providerId),
                      let idx = p.models.firstIndex(where: { $0.id == modelId }) else { return }
                p.models[idx].id = newId
                providerStore.saveProvider(p)
            }
        )
    }

    private func modelContextBinding(providerId: String, modelId: String) -> Binding<String> {
        Binding(
            get: {
                if let model = providerStore.provider(for: providerId)?.models.first(where: { $0.id == modelId }) {
                    return String(model.contextWindow)
                }
                return "128000"
            },
            set: { str in
                guard var p = providerStore.provider(for: providerId),
                      let idx = p.models.firstIndex(where: { $0.id == modelId }),
                      let val = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)), val > 0 else { return }
                p.models[idx].contextWindow = val
                providerStore.saveProvider(p)
            }
        )
    }

    private func modelVisionBinding(providerId: String, modelId: String) -> Binding<Bool> {
        Binding(
            get: {
                providerStore.provider(for: providerId)?.models.first(where: { $0.id == modelId })?.supportsVision ?? false
            },
            set: { isVision in
                guard var p = providerStore.provider(for: providerId),
                      let idx = p.models.firstIndex(where: { $0.id == modelId }) else { return }
                p.models[idx].supportsVision = isVision
                providerStore.saveProvider(p)
            }
        )
    }

    private func modelThinkingBinding(providerId: String, modelId: String) -> Binding<Bool> {
        Binding(
            get: {
                providerStore.provider(for: providerId)?.models.first(where: { $0.id == modelId })?.supportsThinking ?? false
            },
            set: { isThinking in
                guard var p = providerStore.provider(for: providerId),
                      let idx = p.models.firstIndex(where: { $0.id == modelId }) else { return }
                p.models[idx].supportsThinking = isThinking
                providerStore.saveProvider(p)
            }
        )
    }

    private func addNewModel(providerId: String) {
        guard var p = providerStore.provider(for: providerId) else { return }
        let newModelId = "model-\(UUID().uuidString.prefix(4).lowercased())"
        p.models.append(AIModelSpec(id: newModelId, name: "新模型", contextWindow: 524288, supportsVision: false, supportsThinking: false))
        providerStore.saveProvider(p)
    }

    private func addModelFromAvailable(providerId: String, modelId: String) {
        guard var p = providerStore.provider(for: providerId) else { return }
        guard !p.models.contains(where: { $0.id == modelId }) else { return }
        let isVision = modelId.contains("vl") || modelId.contains("flash") || modelId.contains("4o")
        let isThinking = modelId.contains("glm") || modelId.contains("k3") || modelId.contains("r1") || modelId.contains("o1") || modelId.contains("o3")
        p.models.append(AIModelSpec(id: modelId, name: modelId, contextWindow: 524288, supportsVision: isVision, supportsThinking: isThinking))
        providerStore.saveProvider(p)
    }

    private func removeModel(providerId: String, modelId: String) {
        guard var p = providerStore.provider(for: providerId) else { return }
        p.models.removeAll(where: { $0.id == modelId })
        providerStore.saveProvider(p)
    }

    private func moveModel(providerId: String, modelId: String, direction: Int) {
        guard var p = providerStore.provider(for: providerId),
              let idx = p.models.firstIndex(where: { $0.id == modelId }) else { return }
        let targetIdx = idx + direction
        guard targetIdx >= 0, targetIdx < p.models.count else { return }
        p.models.swapAt(idx, targetIdx)
        providerStore.saveProvider(p)
    }

    // MARK: - Agent Bindings

    private func agentNameBinding(for agentId: String) -> Binding<String> {
        Binding(
            get: { agentStore.agent(for: agentId)?.name ?? "" },
            set: {
                guard var a = agentStore.agent(for: agentId) else { return }
                a.name = $0
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentIconBinding(for agentId: String) -> Binding<String> {
        Binding(
            get: { agentStore.agent(for: agentId)?.iconName ?? "sparkles" },
            set: {
                guard var a = agentStore.agent(for: agentId) else { return }
                a.iconName = $0
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentDescBinding(for agentId: String) -> Binding<String> {
        Binding(
            get: { agentStore.agent(for: agentId)?.description ?? "" },
            set: {
                guard var a = agentStore.agent(for: agentId) else { return }
                a.description = $0
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentEnabledBinding(for agentId: String) -> Binding<Bool> {
        Binding(
            get: { agentStore.agent(for: agentId)?.isEnabled ?? false },
            set: {
                guard var a = agentStore.agent(for: agentId) else { return }
                a.isEnabled = $0
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentProviderBinding(for agentId: String) -> Binding<String> {
        Binding(
            get: { agentStore.agent(for: agentId)?.providerId ?? "" },
            set: { newProviderId in
                guard var a = agentStore.agent(for: agentId) else { return }
                a.providerId = newProviderId
                if let p = providerStore.provider(for: newProviderId), let firstModel = p.models.first {
                    a.modelId = firstModel.id
                }
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentModelBinding(for agentId: String) -> Binding<String> {
        Binding(
            get: { agentStore.agent(for: agentId)?.modelId ?? "" },
            set: {
                guard var a = agentStore.agent(for: agentId) else { return }
                a.modelId = $0
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentThinkingBinding(for agentId: String) -> Binding<ThinkingLevel?> {
        Binding(
            get: { agentStore.agent(for: agentId)?.thinkingLevel },
            set: {
                guard var a = agentStore.agent(for: agentId) else { return }
                a.thinkingLevel = $0
                agentStore.saveAgent(a)
            }
        )
    }

    private func agentVisualDelegateBinding(for agentId: String) -> Binding<Bool> {
        Binding(
            get: { agentStore.agent(for: agentId)?.isVisualDelegate ?? false },
            set: { isDelegate in
                guard var a = agentStore.agent(for: agentId) else { return }
                if isDelegate {
                    agentStore.setVisualDelegate(agentId: a.id)
                } else {
                    a.isVisualDelegate = false
                    agentStore.saveAgent(a)
                }
            }
        )
    }

    private func agentSystemPromptBinding(for agentId: String) -> Binding<String> {
        Binding(
            get: { agentStore.agent(for: agentId)?.systemPrompt ?? "" },
            set: {
                guard var a = agentStore.agent(for: agentId) else { return }
                a.systemPrompt = $0
                agentStore.saveAgent(a)
            }
        )
    }
}
