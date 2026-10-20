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

    // 模型列表行内编辑与悬停状态
    @State private var editingModelId: String? = nil
    @State private var hoveredModelId: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 顶部子页面导航 (隐藏多余 Label，保留纯粹分段切换)
            Picker("", selection: $selectedSubTab) {
                ForEach(AIServiceSubTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
            Text("管理用于对话的 AI 模型服务商与连接配置。")
        }

        if let provider = currentProvider {
            Section {
                TextField("显示名称", text: providerNameBinding(for: provider.id))
                    .textFieldStyle(.roundedBorder)

                if isPresetProvider(provider) || provider.type == .qoderNative || provider.type == .antigravityNative {
                    HStack {
                        Text("通信协议类型")
                        Spacer()
                        Text(provider.type.displayName)
                            .font(.system(size: Theme.Typography.footnote))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Picker("通信协议类型", selection: providerTypeBinding(for: provider.id)) {
                        ForEach(AIProviderType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
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
                let methods = authManager.authMethods(for: provider)

                let browserMethods = methods.compactMap { $0 as? InteractiveBrowserAuthMethod }
                let biometricMethods = methods.compactMap { $0 as? BiometricImportAuthMethod }
                let apiKeyMethods = methods.compactMap { $0 as? StandardAPIKeyAuthMethod }
                let primaryAPIKeyMethod = apiKeyMethods.first

                // 1. 已认证授权状态卡片展示
                if !storedKey.isEmpty {
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
                                Text(formatAuthMethodTag(acc.authMethod))
                                    .font(.system(size: Theme.Typography.micro))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .cornerRadius(4)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Divider().padding(.vertical, 2)
                }

                // 2. 外部交互/免密导入方式 (浏览器登录 / 触控 ID 导入)
                if !browserMethods.isEmpty || (!biometricMethods.isEmpty && detected != nil) {
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
                                ForEach(browserMethods, id: \.displayName) { bm in
                                    Button {
                                        authManager.startBrowserAuth(for: provider, method: bm)
                                    } label: {
                                        Label(bm.displayName, systemImage: "globe")
                                            .font(.system(size: Theme.Typography.body, weight: .medium))
                                    }
                                    .buttonStyle(.borderedProminent)
                                }

                                if let local = detected, let bioMethod = biometricMethods.first {
                                    Button {
                                        authManager.importDetectedAccount(for: provider, method: bioMethod)
                                    } label: {
                                        Label("触控 ID 导入 (\(local.displayName))", systemImage: "touchid")
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

                    if primaryAPIKeyMethod != nil {
                        Divider().padding(.vertical, 2)
                    }
                }

                // 3. 手工录入 API Key / 凭据 (纯策略化驱动)
                if let keyMethod = primaryAPIKeyMethod {
                    VStack(alignment: .leading, spacing: 6) {
                        if !storedKey.isEmpty {
                            HStack {
                                Text("已保存凭据 ····\(String(storedKey.suffix(4)))")
                                    .font(.system(size: Theme.Typography.footnote))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("清除") {
                                    providerStore.clearAPIKey(for: provider.id)
                                    providerStore.clearAccountInfo(for: provider.id)
                                    apiKeyInput = ""
                                }
                                .font(.system(size: Theme.Typography.footnote))
                            }
                            SecureField("输入新的密钥以替换", text: $apiKeyInput)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField(keyMethod.placeholder, text: $apiKeyInput)
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
                }
            } header: {
                Text("认证与连接凭据")
            } footer: {
                let methods = authManager.authMethods(for: provider)
                if let keyMethod = methods.compactMap({ $0 as? StandardAPIKeyAuthMethod }).first {
                    Text(keyMethod.footerText)
                } else {
                    Text("连接凭据仅保存在本机受保护目录，绝不上云。")
                }
            }

            // Antigravity 专属：OAuth 高级配置
            if provider.id == "antigravity" {
                AntigravityOAuthSettingsSection()
            }

            // 模型能力池
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    // 顶部操作栏
                    HStack(alignment: .center, spacing: 8) {
                        Text("共 \(provider.models.count) 个模型")
                            .font(.system(size: Theme.Typography.footnote, weight: .medium))
                            .foregroundColor(.secondary)

                        Spacer()

                        if isPresetProvider(provider) {
                            Button {
                                resetToPresetModels(providerId: provider.id)
                            } label: {
                                Label("恢复官方推荐", systemImage: "arrow.counterclockwise")
                                    .font(.system(size: Theme.Typography.footnote))
                            }
                            .buttonStyle(.borderless)
                            .help("恢复为该服务商官方最新推荐的模型规格与能力列表")
                        }

                        Button {
                            addNewModel(providerId: provider.id)
                        } label: {
                            Label("添加模型", systemImage: "plus")
                                .font(.system(size: Theme.Typography.footnote))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if provider.type == .openAICompatible {
                            Button {
                                fetchModelsForProvider(provider)
                            } label: {
                                if isFetchingModels {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("拉取模型", systemImage: "arrow.down.circle")
                                        .font(.system(size: Theme.Typography.footnote))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isFetchingModels)
                        }
                    }
                    .padding(.bottom, 2)

                    if provider.models.isEmpty {
                        HStack {
                            Spacer()
                            Text("尚未配置模型，点击上方「添加模型」或「恢复官方推荐」")
                                .font(.system(size: Theme.Typography.footnote))
                                .foregroundColor(.secondary)
                                .padding(.vertical, 16)
                            Spacer()
                        }
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(8)
                    } else {
                        // 紧凑卡片列表
                        VStack(spacing: 6) {
                            ForEach(Array(provider.models.enumerated()), id: \.element.id) { index, model in
                                modelRowView(provider: provider, model: model, index: index, count: provider.models.count)
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
                }
                .padding(.vertical, 4)
            } header: {
                Text("模型能力池")
            } footer: {
                Text("开启「视觉」后模型可直接理解图片；未开启时，发送图片将由视觉助手协助分析。")
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
                                Text("[识图]").foregroundColor(.secondary)
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
                    Button("重置为官方默认团队 (全能助理、识图助理、代码专家、深度思考、资料检索、系统管家)") {
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
                    ForEach(["sparkles", "eye", "curlybraces", "brain.head.profile", "books.vertical", "macbook.and.iphone"], id: \.self) { sym in
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
                Toggle("作为图片分析助手 (Visual Observer)", isOn: agentVisualDelegateBinding(for: agent.id))

                let boundModel = providerStore.modelSpec(providerId: agent.providerId, modelId: agent.modelId)
                if boundModel?.supportsVision == false {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Theme.Colors.statusWarning)
                        Text("提示：当前绑定的模型未开启视觉支持，请选择具备多模态能力并勾选了「视觉」的模型。")
                            .font(.system(size: Theme.Typography.footnote))
                            .foregroundColor(Theme.Colors.statusWarning)
                    }
                }
            } header: {
                Text("图片辅助分析")
            } footer: {
                Text("当主对话模型不支持解析图片时，由该助手协助分析图像内容并将结果带回主会话。")
            }

            Section {
                let resolved = agent.resolvedTools
                HStack {
                    Text("当前授权工具数")
                    Spacer()
                    Text("\(resolved.count) 项")
                        .font(.system(size: Theme.Typography.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                HStack {
                    Button("恢复为角色推荐工具") {
                        var copy = agent
                        copy.enabledTools = AIAgent.defaultToolNames(for: agent.id)
                        agentStore.saveAgent(copy)
                    }
                    .font(.system(size: Theme.Typography.footnote))

                    Spacer()

                    Button("授权全部已启用工具") {
                        var copy = agent
                        copy.enabledTools = AIToolRegistry.shared.enabledTools().map(\.name)
                        agentStore.saveAgent(copy)
                    }
                    .font(.system(size: Theme.Typography.footnote))
                }

                DisclosureGroup("展开工具授权明细 (\(resolved.count) / \(AIToolRegistry.shared.allTools().count))") {
                    ForEach(AIToolRegistry.shared.allTools(), id: \.name) { tool in
                        let isGranted = resolved.contains(tool.name)
                        Toggle(isOn: Binding(
                            get: { isGranted },
                            set: { newValue in
                                var currentSet = Set(agent.resolvedTools)
                                if newValue {
                                    currentSet.insert(tool.name)
                                } else {
                                    currentSet.remove(tool.name)
                                }
                                var copy = agent
                                copy.enabledTools = Array(currentSet)
                                agentStore.saveAgent(copy)
                            }
                        )) {
                            HStack {
                                Text(tool.displayName)
                                    .font(.system(size: Theme.Typography.body))
                                Spacer()
                                Text(tool.name)
                                    .font(.system(size: Theme.Typography.micro, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            } header: {
                Text("可用工具授权")
            } footer: {
                Text("配置该智能体可调用的工具与系统能力。")
            }

            Section {
                TextField("定制人设提示词，留空则使用全局默认", text: agentSystemPromptBinding(for: agent.id), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4...8)
            } header: {
                Text("系统设定 (System Prompt)")
            } footer: {
                Text("定义该智能体的行为准则与角色设定。")
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
        AIMermaidSettingsSection()
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
        type.defaultEndpointURL
    }

    private func providerURLFooter(for type: AIProviderType) -> String {
        type.endpointDescription
    }

    private func formatAuthMethodTag(_ method: AuthMethodKind) -> String {
        method.tagDisplayName
    }

    private func formatAuthMethodTag(_ rawMethod: String) -> String {
        AuthMethodKind(rawValue: rawMethod)?.tagDisplayName ?? "手动凭据"
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
        // 从可用模型池拉取导入时赋予标准默认规格；多模态与思考链能力由用户按需在卡片中精准 toggle
        p.models.append(AIModelSpec(id: modelId, name: modelId, contextWindow: 524288, supportsVision: false, supportsThinking: false))
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

    private func toggleModelVision(providerId: String, modelId: String) {
        guard var p = providerStore.provider(for: providerId),
              let idx = p.models.firstIndex(where: { $0.id == modelId }) else { return }
        p.models[idx].supportsVision.toggle()
        providerStore.saveProvider(p)
    }

    private func toggleModelThinking(providerId: String, modelId: String) {
        guard var p = providerStore.provider(for: providerId),
              let idx = p.models.firstIndex(where: { $0.id == modelId }) else { return }
        p.models[idx].supportsThinking.toggle()
        providerStore.saveProvider(p)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let m = Double(count) / 1_000_000.0
            return m.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(m))M" : String(format: "%.1fM", m)
        } else if count >= 1_000 {
            let k = Double(count) / 1_000.0
            return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))K" : String(format: "%.0fK", k)
        } else {
            return "\(count)"
        }
    }

    private func isPresetProvider(_ provider: AIProvider) -> Bool {
        AIProvider.officialPresetModels[provider.id] != nil
    }

    private func resetToPresetModels(providerId: String) {
        guard var p = providerStore.provider(for: providerId),
              let factory = AIProvider.officialPresetModels[providerId] else { return }
        p.models = factory()
        providerStore.saveProvider(p)
    }

    @ViewBuilder
    private func modelRowView(provider: AIProvider, model: AIModelSpec, index: Int, count: Int) -> some View {
        let isEditing = (editingModelId == model.id)
        let isHovered = (hoveredModelId == model.id)

        VStack(spacing: 0) {
            // 主卡片行 (紧凑高质感条目)
            HStack(spacing: 10) {
                // 1. 左侧名称与标识 (允许弹性收缩与尾部截断)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name)
                        .font(.system(size: Theme.Typography.body, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(model.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(0)

                Spacer(minLength: 8)

                // 2. 中间能力胶囊 (锁定单行与固定尺寸，最高排版优先级，绝不折行)
                HStack(spacing: 6) {
                    // 上下文胶囊
                    Text(formatTokens(model.contextWindow))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(5)
                        .fixedSize()
                        .help("上下文窗口: \(model.contextWindow) tokens")

                    // 视觉开关胶囊 (恒定 2 字，绝不折行)
                    Button {
                        toggleModelVision(providerId: provider.id, modelId: model.id)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: model.supportsVision ? "eye.fill" : "eye.slash")
                                .font(.system(size: 10))
                            Text("视觉")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            model.supportsVision
                                ? Color.teal.opacity(0.16)
                                : Color.primary.opacity(0.05)
                        )
                        .foregroundColor(
                            model.supportsVision
                                ? Color.teal
                                : Color.secondary.opacity(0.55)
                        )
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help(model.supportsVision ? "支持视觉看图 (点击关闭)" : "仅纯文本，发图将委派 Observer 看图 (点击开启)")

                    // 思考开关胶囊 (恒定 2 字，绝不折行)
                    Button {
                        toggleModelThinking(providerId: provider.id, modelId: model.id)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 10))
                            Text("思考")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            model.supportsThinking
                                ? Color.purple.opacity(0.16)
                                : Color.primary.opacity(0.05)
                        )
                        .foregroundColor(
                            model.supportsThinking
                                ? Color.purple
                                : Color.secondary.opacity(0.55)
                        )
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help(model.supportsThinking ? "支持深度思考链 (点击关闭)" : "不输出思考过程 (点击开启)")
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

                // 3. 右侧操作按钮组 (锁定单行，尺寸收敛)
                HStack(spacing: 2) {
                    // 上移
                    Button {
                        moveModel(providerId: provider.id, modelId: model.id, direction: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(index > 0 ? Color.secondary : Color.secondary.opacity(0.2))
                    .disabled(index == 0)
                    .help("上移")

                    // 下移
                    Button {
                        moveModel(providerId: provider.id, modelId: model.id, direction: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(index < count - 1 ? Color.secondary : Color.secondary.opacity(0.2))
                    .disabled(index == count - 1)
                    .help("下移")

                    // 编辑参数展开
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if editingModelId == model.id {
                                editingModelId = nil
                            } else {
                                editingModelId = model.id
                            }
                        }
                    } label: {
                        Image(systemName: isEditing ? "xmark.circle.fill" : "slider.horizontal.3")
                            .font(.system(size: 11))
                            .frame(width: 20, height: 20)
                            .foregroundColor(isEditing ? Color.accentColor : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isEditing ? "关闭编辑" : "展开精细调整")

                    // 删除
                    Button {
                        removeModel(providerId: provider.id, modelId: model.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .frame(width: 20, height: 20)
                            .foregroundColor(Color.secondary.opacity(0.55))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("删除此模型")
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isEditing ? Color.accentColor.opacity(0.06) : (isHovered ? Color.primary.opacity(0.04) : Color.primary.opacity(0.02)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isEditing ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .onHover { h in
                withAnimation(.easeOut(duration: 0.15)) {
                    hoveredModelId = h ? model.id : nil
                }
            }

            // 行内精细编辑抽屉（展开态）
            if isEditing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("显示名称")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            TextField("显示名", text: modelNameBinding(providerId: provider.id, modelId: model.id))
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("模型标识 (Model ID)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            TextField("模型 ID", text: modelIdBinding(providerId: provider.id, modelId: model.id))
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("上下文长度 (Tokens)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            TextField("上下文", text: modelContextBinding(providerId: provider.id, modelId: model.id))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 180)
                        }

                        Spacer()

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                editingModelId = nil
                            }
                        } label: {
                            Text("完成编辑")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 16)
                    }
                }
                .labelsHidden()
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.02))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .padding(.horizontal, 4)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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

