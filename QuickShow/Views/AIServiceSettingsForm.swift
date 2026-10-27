// AIServiceSettingsForm: AI 服务设置中心，支持算力模型管理、角色人设编排、工具权限管控与交互偏好配置。

import SwiftUI
import AppKit

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

// MARK: - 设置子页面枚举（四大正交维度）
enum AIServiceSubTab: String, CaseIterable, Identifiable {
    case providers = "算力与模型"
    case agents = "角色与人设"
    case tools = "工具与权限"
    case interaction = "对话与交互"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .providers: return "cpu"
        case .agents: return "person.crop.circle"
        case .tools: return "wrench.and.screwdriver"
        case .interaction: return "bubble.left.and.bubble.right"
        }
    }
}

// MARK: - 连接测试状态枚举
enum ConnectionTestStatus: Equatable {
    case idle
    case testing
    case success(String)
    case failed(String)
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

    // 连接测试状态（按 providerId 隔离）
    @State private var testStatus: [String: ConnectionTestStatus] = [:]

    // 候选模型池搜索过滤
    @State private var availableModels: [String] = []
    @State private var modelFilter: String = ""

    // 模型列表行内编辑与悬停状态
    @State private var editingModelId: String? = nil
    @State private var hoveredModelId: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 顶部常驻：当前会话模型与连接状态概览卡片（一眼看清当前用的是什么）
            activeSessionOverviewCard
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // 子页面分段导航
            Picker("", selection: $selectedSubTab) {
                ForEach(AIServiceSubTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.iconName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            Form {
                switch selectedSubTab {
                case .providers:
                    providersFormSection
                case .agents:
                    agentsFormSection
                case .tools:
                    toolsFormSection
                case .interaction:
                    interactionFormSection
                }
            }
        }
    }

    // MARK: ================== 0. 顶部会话概览卡片 ==================

    private var activeSessionOverviewCard: some View {
        let agent = currentAgent
        let boundProvider = providerStore.provider(for: agent?.providerId ?? "")
        let boundModel = providerStore.modelSpec(providerId: agent?.providerId ?? "", modelId: agent?.modelId ?? "")
        let hasKey = !(providerStore.apiKey(for: boundProvider?.id ?? "") ?? "").isEmpty
        let isSingleMode = appState.settings.executionMode == .single

        return HStack(spacing: 12) {
            // 角色图标与模式
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: agent?.iconName ?? "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent?.name ?? "未指定助手")
                        .font(.system(size: Theme.Typography.body, weight: .semibold))
                    Text(isSingleMode ? "单 Agent 极简" : "多 Agent 协作")
                        .font(.system(size: Theme.Typography.micro, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(isSingleMode ? Color.teal.opacity(0.15) : Color.purple.opacity(0.15))
                        .foregroundColor(isSingleMode ? Color.teal : Color.purple)
                        .cornerRadius(4)
                }

                HStack(spacing: 6) {
                    Text(boundProvider?.name ?? "未选择服务商")
                        .font(.system(size: Theme.Typography.footnote))
                        .foregroundColor(.secondary)
                    Text("·")
                        .font(.system(size: Theme.Typography.footnote))
                        .foregroundColor(.secondary)
                    Text(boundModel?.name ?? agent?.modelId ?? "无可用模型")
                        .font(.system(size: Theme.Typography.footnote, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }

            Spacer()

            // 凭据状态徽章与快捷切换
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(hasKey ? Theme.Colors.statusGood : Theme.Colors.statusWarning)
                        .frame(width: 7, height: 7)
                    Text(hasKey ? "凭据已就绪" : "未配置 API Key")
                        .font(.system(size: Theme.Typography.footnote, weight: .medium))
                        .foregroundColor(hasKey ? Theme.Colors.statusGood : Theme.Colors.statusWarning)
                }

                // 快捷直达下拉切换
                Menu {
                    ForEach(providerStore.providers.filter { $0.isEnabled }) { p in
                        Menu(p.name) {
                            ForEach(p.models) { m in
                                Button {
                                    makeModelDefault(providerId: p.id, modelId: m.id)
                                } label: {
                                    if agent?.providerId == p.id && agent?.modelId == m.id {
                                        Label(m.name, systemImage: "checkmark")
                                    } else {
                                        Text(m.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Text("切换当前模型 ▾")
                        .font(.system(size: Theme.Typography.micro))
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: ================== 1. 算力与模型 ==================

    @ViewBuilder
    private var providersFormSection: some View {
        // 预设厂商快捷切换胶囊（帮助用户 1 秒找到阿里云、OpenAI 等）
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("主流服务商快速通道")
                    .font(.system(size: Theme.Typography.footnote, weight: .medium))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    quickPresetPill(title: "阿里云百炼", id: "alibaba", preset: AIProvider.alibabaPreset())
                    quickPresetPill(title: "OpenAI 官方", id: "openai", preset: AIProvider.openAIPreset())
                    quickPresetPill(title: "Antigravity (Gemini)", id: "antigravity", preset: AIProvider.antigravityPreset())
                    quickPresetPill(title: "Qoder 国际版", id: "qoder", preset: AIProvider.qoderPreset())
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("快速配置")
        }

        // 服务商选择与管理
        Section {
            HStack(spacing: 12) {
                Picker("当前编辑服务商", selection: $providerStore.selectedProviderId) {
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
                    Label("添加", systemImage: "plus")
                        .font(.system(size: Theme.Typography.body))
                }
            }
        } header: {
            Text("服务商列表")
        } footer: {
            Text("管理用于向大模型发起调用的服务商端点、鉴权信息与模型能力规格。")
        }

        if let provider = currentProvider {
            // 基本参数与端点
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

                TextField("端点 Base URL", text: providerBaseURLBinding(for: provider.id), prompt: Text(providerURLPlaceholder(for: provider.type)))
                    .textFieldStyle(.roundedBorder)

                Toggle("启用此服务商", isOn: providerEnabledBinding(for: provider.id))
            } header: {
                Text("基本配置与端点")
            } footer: {
                Text(providerURLFooter(for: provider.type))
            }

            // HTTP 头部配置（可选，适配网关白名单与自定义客户端标识）
            Section {
                let headers = provider.customHeaders
                if headers.isEmpty {
                    Text("暂未配置自定义请求头（默认携带兼容客户端标识）")
                        .font(.system(size: Theme.Typography.footnote))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(headers.enumerated()), id: \.element.id) { index, _ in
                        HStack(spacing: 8) {
                            TextField("Header 名（如 User-Agent）", text: headerKeyBinding(for: provider.id, at: index))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                            TextField("Header 值", text: headerValueBinding(for: provider.id, at: index))
                                .textFieldStyle(.roundedBorder)
                            Button {
                                removeHeader(for: provider.id, at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(Theme.Colors.statusWarning)
                            }
                            .buttonStyle(.plain)
                            .help("删除此请求头")
                        }
                    }
                }

                HStack(spacing: 12) {
                    Menu {
                        ForEach(HTTPHeaderPreset.presets) { preset in
                            Button(preset.displayName) {
                                addHeaderPreset(preset, for: provider.id)
                            }
                        }
                    } label: {
                        Label("选择内置头信息", systemImage: "chevron.down.circle")
                            .font(.system(size: Theme.Typography.footnote))
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)

                    Button {
                        addCustomHeader(for: provider.id)
                    } label: {
                        Label("添加自定义头", systemImage: "plus")
                            .font(.system(size: Theme.Typography.footnote))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } header: {
                Text("HTTP 请求头配置（可选）")
            } footer: {
                Text("可下拉选择内置客户端标识（如 OpenCode、Cline 等），或自由配置自定义 Header。")
            }

            // 凭据与认证中心
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

                // 1. 已认证凭据展示
                if !storedKey.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Theme.Colors.statusGood)
                            Text("已配置连接凭据 (••••\(String(storedKey.suffix(4))))")
                                .font(.system(size: Theme.Typography.body, weight: .semibold))

                            Spacer()

                            // 测试连接按钮
                            Button {
                                testConnection(for: provider)
                            } label: {
                                if testStatus[provider.id] == .testing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("测试连接", systemImage: "bolt.badge.checkmark")
                                        .font(.system(size: Theme.Typography.footnote))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(testStatus[provider.id] == .testing)

                            Button("清除") {
                                authManager.logout(for: provider.id)
                                apiKeyInput = ""
                                testStatus[provider.id] = nil
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

                        // 测试状态提示
                        if let status = testStatus[provider.id] {
                            switch status {
                            case .success(let msg):
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundColor(Theme.Colors.statusGood)
                                    Text(msg)
                                        .font(.system(size: Theme.Typography.footnote))
                                        .foregroundColor(Theme.Colors.statusGood)
                                }
                            case .failed(let err):
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundColor(Theme.Colors.statusWarning)
                                    Text("连接测试失败：\(err)")
                                        .font(.system(size: Theme.Typography.footnote))
                                        .foregroundColor(Theme.Colors.statusWarning)
                                }
                            default:
                                EmptyView()
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Divider().padding(.vertical, 2)
                }

                // 2. 外部免密与导入方式 (浏览器登录 / 触控 ID 导入)
                if !browserMethods.isEmpty || (!biometricMethods.isEmpty && detected != nil) {
                    VStack(alignment: .leading, spacing: 10) {
                        if case .authorizing(let msg) = authState {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(msg)
                                    .font(.system(size: Theme.Typography.body))
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

                // 3. 手工录入 API Key
                if let keyMethod = primaryAPIKeyMethod {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            SecureField(storedKey.isEmpty ? keyMethod.placeholder : "输入新的 API Key 以替换现有凭据", text: $apiKeyInput)
                                .textFieldStyle(.roundedBorder)

                            let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            Button("保存凭据") {
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
                                testConnection(for: provider)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .disabled(trimmedKey.isEmpty)
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
                    Text("连接凭据安全保存在本机受保护目录，绝不上云。")
                }
            }

            // Antigravity 专属 OAuth 折叠小节
            if provider.id == "antigravity" {
                AntigravityOAuthSettingsSection()
            }

            // 模型能力池
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("可用模型 (\(provider.models.count) 个)")
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
                                    Label("拉取模型池", systemImage: "arrow.down.circle")
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
                            Text("尚未配置模型，点击右上角「恢复官方推荐」或「添加模型」")
                                .font(.system(size: Theme.Typography.footnote))
                                .foregroundColor(.secondary)
                                .padding(.vertical, 16)
                            Spacer()
                        }
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(8)
                    } else {
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
                            TextField("在拉取的候选中搜索并快速添加...", text: $modelFilter)
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
                Text("在此维护各模型的上下文规格、视觉与思考支持；点击模型卡片右侧的「设为默认」可直接设为当前对话主模型。")
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

    private func quickPresetPill(title: String, id: String, preset: AIProvider) -> some View {
        let isSelected = providerStore.selectedProviderId == id
        return Button {
            if !providerStore.providers.contains(where: { $0.id == id }) {
                providerStore.saveProvider(preset)
            }
            providerStore.selectedProviderId = id
        } label: {
            Text(title)
                .font(.system(size: Theme.Typography.footnote, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
                .foregroundColor(isSelected ? Color.accentColor : Color.primary)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: ================== 2. 角色与人设 ==================

    @ViewBuilder
    private var agentsFormSection: some View {
        // 单 Agent 核心人设（极简优先）
        singleAgentFormContent

        // 高级多 Agent 协作团队（折叠收敛）
        Section {
            Toggle("启用多 Agent 专家团队协作（主控/代码/识图/检索）", isOn: Binding(
                get: { appState.settings.executionMode == .multi },
                set: { appState.settings.executionMode = $0 ? .multi : .single }
            ))
        } header: {
            Text("高级运行模式")
        } footer: {
            Text(appState.settings.executionMode == .single
                 ? "当前为「单 Agent 模式」（默认）：直接调度绑定的模型与可用工具，响应轻快利落，零团队开销。日常绝大多数任务推荐此模式。"
                 : "当前为「多 Agent 协作模式」：由全能助理根据任务类型将工作调度给代码专家、资料检索、系统管家等子智能体并发协作。适合长流程复杂任务。")
        }

        if appState.settings.executionMode == .multi {
            multiAgentFormContent
        }
    }

    // MARK: - 单 Agent 专属极简表单
    @ViewBuilder
    private var singleAgentFormContent: some View {
        if let agent = currentAgent {
            Section {
                TextField("助手显示名称", text: agentNameBinding(for: agent.id))
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Text("助手图标:")
                        .font(.system(size: Theme.Typography.body))
                    Image(systemName: agent.iconName)
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(6)

                    // 预置常用图标按钮组
                    ForEach(["sparkles", "brain.head.profile", "eye", "curlybraces", "books.vertical", "macbook.and.iphone"], id: \.self) { sym in
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

                TextField("助手职责简介", text: agentDescBinding(for: agent.id))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("助手档案")
            }

            Section {
                Picker("绑定算力服务商", selection: agentProviderBinding(for: agent.id)) {
                    ForEach(providerStore.providers.filter { $0.isEnabled }) { p in
                        Text(p.name).tag(p.id)
                    }
                }

                let boundProvider = providerStore.provider(for: agent.providerId)
                let models = boundProvider?.models ?? []

                Picker("绑定主模型", selection: agentModelBinding(for: agent.id)) {
                    if models.isEmpty {
                        Text("无可用模型（请在「算力与模型」中配置）").tag("")
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
                Text("为当前助手指定算力提供商与默认执行模型。")
            }

            Section {
                TextField("定制人设提示词，留空则使用内置全局通用设定", text: agentSystemPromptBinding(for: agent.id), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4...8)

                HStack {
                    Spacer()
                    Button("恢复官方推荐人设") {
                        var copy = agent
                        copy.systemPrompt = "你是一个集成于 macOS 原生环境的高效、智能 AI 助手，善用系统工具为用户解决问题。"
                        agentStore.saveAgent(copy)
                    }
                    .font(.system(size: Theme.Typography.footnote))
                }
            } header: {
                Text("系统人设设定 (System Prompt)")
            } footer: {
                Text("定义 AI 助手的思考风格、语调特征与专业倾向。")
            }
        }
    }

    // MARK: - 多 Agent 团队矩阵表单（仅在启用多 Agent 时展开）
    @ViewBuilder
    private var multiAgentFormContent: some View {
        Section {
            HStack(spacing: 12) {
                Picker("选择要配置的专家", selection: $agentStore.activeAgentId) {
                    ForEach(agentStore.agents) { a in
                        HStack {
                            Image(systemName: a.iconName)
                            Text(a.name)
                            if a.isVisualDelegate {
                                Text("[识图担当]").foregroundColor(.cyan)
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
                    Button("重置为官方默认团队 (全能、识图、代码、深度思考、检索、管家)") {
                        agentStore.resetToDefaults()
                    }
                } label: {
                    Label("团队操作", systemImage: "ellipsis.circle")
                        .font(.system(size: Theme.Typography.body))
                }
            }
        } header: {
            Text("多智能体团队成员")
        } footer: {
            Text("团队成员可在聊天输入框点击切换胶囊随时切换，亦可在长流程中由全能助理按需自动唤醒。")
        }

        if let agent = currentAgent {
            Section {
                TextField("智能体名称", text: agentNameBinding(for: agent.id))
                    .textFieldStyle(.roundedBorder)

                TextField("职责描述", text: agentDescBinding(for: agent.id))
                    .textFieldStyle(.roundedBorder)

                Toggle("启用此智能体", isOn: agentEnabledBinding(for: agent.id))
                Toggle("设为全局视觉分析担当 (Visual Observer)", isOn: agentVisualDelegateBinding(for: agent.id))
            } header: {
                Text("专家角色档案")
            }

            Section {
                Picker("专属服务商", selection: agentProviderBinding(for: agent.id)) {
                    ForEach(providerStore.providers.filter { $0.isEnabled }) { p in
                        Text(p.name).tag(p.id)
                    }
                }

                let boundProvider = providerStore.provider(for: agent.providerId)
                let models = boundProvider?.models ?? []

                Picker("专属模型", selection: agentModelBinding(for: agent.id)) {
                    ForEach(models) { m in
                        Text(m.name).tag(m.id)
                    }
                }

                Picker("默认思考强度", selection: agentThinkingBinding(for: agent.id)) {
                    Text("无 (None)").tag(ThinkingLevel?.none)
                    Text("低 (Low)").tag(ThinkingLevel?.some(.low))
                    Text("中 (Medium)").tag(ThinkingLevel?.some(.medium))
                    Text("高 (High)").tag(ThinkingLevel?.some(.high))
                }
            } header: {
                Text("模型绑定")
            }

            Section {
                let resolved = agent.resolvedTools
                HStack {
                    Text("授权工具 (\(resolved.count) / \(AIToolRegistry.shared.allTools().count))")
                        .font(.system(size: Theme.Typography.body))
                    Spacer()
                    Button("恢复角色推荐工具") {
                        var copy = agent
                        copy.enabledTools = AIAgent.defaultToolNames(for: agent.id)
                        agentStore.saveAgent(copy)
                    }
                    .font(.system(size: Theme.Typography.footnote))
                }

                DisclosureGroup("展开工具白名单明细") {
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
                    }
                }
            } header: {
                Text("专家工具授权")
            }

            Section {
                TextField("定制专家专属提示词", text: agentSystemPromptBinding(for: agent.id), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4...8)
            } header: {
                Text("专家专属提示词 (System Prompt)")
            }

            if agentStore.agents.count > 1 {
                Section {
                    Button("删除此专家角色", role: .destructive) {
                        agentStore.deleteAgent(id: agent.id)
                    }
                }
            }
        }
    }

    // MARK: ================== 3. 工具与权限 ==================

    @ViewBuilder
    private var toolsFormSection: some View {
        // 内置系统工具开关（按类别展示）
        AIToolsSettingsSection()

        // 智能安全守卫（旁路 LLM 审核）
        AISecurityShadowGuardSettingsSection()

        // 文件读写沙盒白名单
        AIFileWhitelistSettingsSection()

        // 外部联网搜索扩展（Tavily 等）
        AIWebSearchSettingsSection()

        // 环境变量扩展
        AIEnvVarsSettingsSection()
    }

    // MARK: ================== 4. 对话与交互 ==================

    @ViewBuilder
    private var interactionFormSection: some View {
        // 消息发送与排队行为
        AIChatInteractionSettingsSection()

        // Mermaid 图表渲染偏好
        AIMermaidSettingsSection()

        // 代码块高亮偏好
        Section {
            Picker("代码高亮主题", selection: Binding(
                get: { appState.codeHighlightTheme },
                set: { appState.codeHighlightTheme = $0 }
            )) {
                ForEach(CodeHighlightTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
        } header: {
            Text("代码渲染")
        } footer: {
            Text("设置 AI 回复中代码块的语法高亮主题配色。")
        }

        // 唤醒快捷键速查提示
        Section {
            HStack {
                Text("双击唤醒 AI 对话窗口")
                Spacer()
                KeyBadge(key: String(localized: "⌥ ⌥"))
            }
            HStack {
                Text("在主信息面板中打开 AI")
                Spacer()
                KeyBadge(key: "I")
            }
        } header: {
            Text("快捷键提示")
        } footer: {
            Text("可在左侧「快捷键设置」中自定义全局双击唤醒修饰键。")
        }
    }

    // MARK: ================== 5. 模型卡片与操作 ==================

    private func modelRowView(provider: AIProvider, model: AIModelSpec, index: Int, count: Int) -> some View {
        let isEditing = (editingModelId == model.id)
        let isHovered = (hoveredModelId == model.id)
        let isDefault = (currentAgent?.providerId == provider.id && currentAgent?.modelId == model.id)

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                // 1. 左侧名称、标识与默认标签
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.system(size: Theme.Typography.body, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if isDefault {
                            Text("当前默认")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.accentColor.opacity(0.18))
                                .foregroundColor(Color.accentColor)
                                .cornerRadius(4)
                        }
                    }

                    Text(model.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(0)

                Spacer(minLength: 8)

                // 2. 中间能力胶囊
                HStack(spacing: 6) {
                    Text(formatTokens(model.contextWindow))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(5)
                        .fixedSize()
                        .help("上下文窗口: \(model.contextWindow) tokens")

                    Button {
                        toggleModelVision(providerId: provider.id, modelId: model.id)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: model.supportsVision ? "eye.fill" : "eye.slash")
                                .font(.system(size: 10))
                            Text("视觉")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(model.supportsVision ? Color.teal.opacity(0.16) : Color.primary.opacity(0.05))
                        .foregroundColor(model.supportsVision ? Color.teal : Color.secondary.opacity(0.55))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .help(model.supportsVision ? "支持视觉分析图片 (点击关闭)" : "仅文本 (点击开启视觉)")

                    Button {
                        toggleModelThinking(providerId: provider.id, modelId: model.id)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 10))
                            Text("思考")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(model.supportsThinking ? Color.purple.opacity(0.16) : Color.primary.opacity(0.05))
                        .foregroundColor(model.supportsThinking ? Color.purple : Color.secondary.opacity(0.55))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .help(model.supportsThinking ? "支持深度思考输出 (点击关闭)" : "不输出思考 (点击开启)")
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

                // 3. 右侧操作按钮组
                HStack(spacing: 2) {
                    if !isDefault {
                        Button {
                            makeModelDefault(providerId: provider.id, modelId: model.id)
                        } label: {
                            Text("设为默认")
                                .font(.system(size: 11))
                                .foregroundColor(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.08))
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                        .help("将此模型设为当前助手默认模型")
                    }

                    // 编辑参数展开
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            editingModelId = (editingModelId == model.id ? nil : model.id)
                        }
                    } label: {
                        Image(systemName: isEditing ? "xmark.circle.fill" : "slider.horizontal.3")
                            .font(.system(size: 11))
                            .frame(width: 20, height: 20)
                            .foregroundColor(isEditing ? Color.accentColor : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isEditing ? "关闭编辑" : "展开编辑参数")

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
                    .stroke(isEditing ? Color.accentColor.opacity(0.3) : (isDefault ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)), lineWidth: isDefault ? 1 : 0.5)
            )
            .onHover { h in
                withAnimation(.easeOut(duration: 0.15)) {
                    hoveredModelId = h ? model.id : nil
                }
            }

            // 行内精细编辑抽屉
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

                        Button("完成编辑") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                editingModelId = nil
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 16)
                    }
                }
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
            }
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

    private func makeModelDefault(providerId: String, modelId: String) {
        if let agent = currentAgent {
            var copy = agent
            copy.providerId = providerId
            copy.modelId = modelId
            agentStore.saveAgent(copy)
        }
        providerStore.selectedProviderId = providerId
    }

    private func testConnection(for provider: AIProvider) {
        testStatus[provider.id] = .testing
        Task { @MainActor in
            do {
                let models = try await AIChatService.shared.fetchModels(for: provider)
                testStatus[provider.id] = .success("连接测试成功，已检测到 \(models.count) 个可用模型")
            } catch {
                testStatus[provider.id] = .failed(error.localizedDescription)
            }
        }
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
            description: "自定义专家职责",
            systemPrompt: "你是一个专业的 AI 专家助手。",
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
                    fetchError = "接口未返回任何可用模型。"
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

    // MARK: - HTTP Header Bindings

    private func headerKeyBinding(for providerId: String, at index: Int) -> Binding<String> {
        Binding(
            get: {
                let list = providerStore.provider(for: providerId)?.customHeaders ?? []
                guard index < list.count else { return "" }
                return list[index].key
            },
            set: { newKey in
                guard var p = providerStore.provider(for: providerId) else { return }
                guard index < p.customHeaders.count else { return }
                p.customHeaders[index].key = newKey
                providerStore.saveProvider(p)
            }
        )
    }

    private func headerValueBinding(for providerId: String, at index: Int) -> Binding<String> {
        Binding(
            get: {
                let list = providerStore.provider(for: providerId)?.customHeaders ?? []
                guard index < list.count else { return "" }
                return list[index].value
            },
            set: { newVal in
                guard var p = providerStore.provider(for: providerId) else { return }
                guard index < p.customHeaders.count else { return }
                p.customHeaders[index].value = newVal
                providerStore.saveProvider(p)
            }
        )
    }

    private func addHeaderPreset(_ preset: HTTPHeaderPreset, for providerId: String) {
        guard var p = providerStore.provider(for: providerId) else { return }
        if let idx = p.customHeaders.firstIndex(where: { $0.key.caseInsensitiveCompare(preset.key) == .orderedSame }) {
            p.customHeaders[idx].value = preset.value
        } else {
            p.customHeaders.append(HTTPHeaderEntry(key: preset.key, value: preset.value))
        }
        providerStore.saveProvider(p)
    }

    private func addCustomHeader(for providerId: String) {
        guard var p = providerStore.provider(for: providerId) else { return }
        p.customHeaders.append(HTTPHeaderEntry(key: "", value: ""))
        providerStore.saveProvider(p)
    }

    private func removeHeader(for providerId: String, at index: Int) {
        guard var p = providerStore.provider(for: providerId) else { return }
        guard index < p.customHeaders.count else { return }
        p.customHeaders.remove(at: index)
        providerStore.saveProvider(p)
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

    private func addNewModel(providerId: String) {
        guard var p = providerStore.provider(for: providerId) else { return }
        let newModelId = "model-\(UUID().uuidString.prefix(4).lowercased())"
        p.models.append(AIModelSpec(id: newModelId, name: "新模型", contextWindow: 524288, supportsVision: false, supportsThinking: false))
        providerStore.saveProvider(p)
    }

    private func addModelFromAvailable(providerId: String, modelId: String) {
        guard var p = providerStore.provider(for: providerId) else { return }
        guard !p.models.contains(where: { $0.id == modelId }) else { return }
        p.models.append(AIModelSpec(id: modelId, name: modelId, contextWindow: 524288, supportsVision: false, supportsThinking: false))
        providerStore.saveProvider(p)
    }

    private func removeModel(providerId: String, modelId: String) {
        guard var p = providerStore.provider(for: providerId) else { return }
        p.models.removeAll(where: { $0.id == modelId })
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
