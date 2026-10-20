// AgentRoleProfile.swift
// 智能体角色档案策略与注册中心 (纯内存模板，不参与 Codable 持久化)
// 遵循 SOLID / OCP 原则：将角色元数据、工具列表、默认图标与模型推荐策略封装收敛。

import Foundation

/// 智能体角色档案 (作为角色的领域模板与元数据定义，纯内存构造)
struct AgentRoleProfile: Identifiable, Sendable {
    let id: String                          // 角色唯一标识: "orchestrator", "observer", "coder", "oracle", "librarian", "concierge"
    let name: String                        // 显示名称: "全能助理", "识图助理", 等
    let iconName: String                    // 默认图标
    let trayIconName: String                // 任务托盘/导航栏精简图标
    let description: String                 // 职责描述
    let systemPrompt: String                // 系统提示词模板
    let defaultTools: [String]              // 推荐默认工具列表
    let defaultThinkingLevel: ThinkingLevel? // 默认思考级别
    let isVisualDelegate: Bool              // 是否视觉担当

    /// 针对不同服务商智能推荐模型 ID
    let recommendedModelPicker: @Sendable (_ providerId: String) -> String
}

/// 智能体角色档案集中注册与查询中心
final class AgentRoleRegistry: Sendable {
    static let shared = AgentRoleRegistry()

    private let profiles: [String: AgentRoleProfile]
    private let orderedProfiles: [AgentRoleProfile]

    private init() {
        let list: [AgentRoleProfile] = [
            AgentRoleProfile(
                id: "orchestrator",
                name: "全能助理",
                iconName: "sparkles",
                trayIconName: "sparkles",
                description: "主控助理，负责通用对话、需求拆解与多领域调度协调。",
                systemPrompt: """
                你是一个专业博学的 AI 全能助理（Orchestrator），崇尚从第一性原理分析问题。
                说话做事直接了当，实事求是。遇到不清楚的边界主动调用 `ask_user` 确认。
                面对复杂多步骤工程，使用 `launch_subagents` 并发调度专业专家（代码专家、资料检索、深度思考、系统管家、识图助理），汇总成果后输出清晰结构化的解答。
                """,
                defaultTools: ["launch_subagents", "ask_user", "get_quickshow_state"],
                defaultThinkingLevel: .medium,
                isVisualDelegate: false,
                recommendedModelPicker: { providerId in
                    if providerId == "qoder" { return "qoder/gmodel" }
                    if providerId == "antigravity" { return "gemini-3.1-pro" }
                    if providerId == "openai" { return "gpt-4o" }
                    return "glm-5.3"
                }
            ),
            AgentRoleProfile(
                id: "observer",
                name: "识图助理",
                iconName: "eye",
                trayIconName: "eye",
                description: "图文与多模态解析助手，专门负责图片分析、图表解析与屏幕截图特征提取。",
                systemPrompt: """
                你是专业的识图助手（Observer）。你的核心职责是精准理解用户提供的各类图像（界面截图、架构图、表格图、流程图或照片）。
                请客观、详细地提取图像中的文字（OCR）、布局结构、核心要素与异常信息，以结构化 Markdown 清晰呈现。
                """,
                defaultTools: ["preview_file"],
                defaultThinkingLevel: nil,
                isVisualDelegate: true,
                recommendedModelPicker: { providerId in
                    if providerId == "qoder" { return "qoder/qmodel" }
                    if providerId == "antigravity" { return "gemini-3.8-flash" }
                    if providerId == "openai" { return "gpt-4o" }
                    return "qwen3.8-flash"
                }
            ),
            AgentRoleProfile(
                id: "coder",
                name: "代码专家",
                iconName: "curlybraces",
                trayIconName: "chevron.left.forwardslash.chevron.right",
                description: "代码特化助手，专注高性能代码编写、Bug 修复与现代软件架构设计。",
                systemPrompt: """
                你是顶尖的软件架构与代码工程专家（Coder）。遵循极致工程规范，追求零冗余、高可读与极致性能。
                给出代码时务必完整可靠，注释清晰，并点明关键技术设计考量。
                """,
                defaultTools: ["read_file", "write_file", "preview_file", "get_env", "list_env", "run_shell", "send_message"],
                defaultThinkingLevel: .high,
                isVisualDelegate: false,
                recommendedModelPicker: { providerId in
                    if providerId == "qoder" { return "qoder/kmodel" }
                    if providerId == "antigravity" { return "claude-sonnet-4-6" }
                    if providerId == "openai" { return "o3-mini" }
                    return "glm-5.3"
                }
            ),
            AgentRoleProfile(
                id: "oracle",
                name: "深度思考",
                iconName: "brain.head.profile",
                trayIconName: "brain.head.profile",
                description: "高思考强度分析师，擅长数学逻辑推演、复杂系统方案决策与深度论证。",
                systemPrompt: """
                你是一个深思熟虑的逻辑与决策推演助手（Oracle）。在输出最终结论前，先从基本公理出发逐层推导演绎，
                剖析方案利弊权衡（Trade-offs），给出严谨缜密的推论过程。
                """,
                defaultTools: ["send_message"],
                defaultThinkingLevel: .high,
                isVisualDelegate: false,
                recommendedModelPicker: { providerId in
                    if providerId == "qoder" { return "qoder/kmodel_latest" }
                    if providerId == "antigravity" { return "claude-opus-4-6" }
                    if providerId == "openai" { return "o1" }
                    return "kimi-k3"
                }
            ),
            AgentRoleProfile(
                id: "librarian",
                name: "资料检索",
                iconName: "books.vertical",
                trayIconName: "globe",
                description: "联网资料检索与情报专家，专属配备 web_search 公网搜索引擎与 fetch_url 网页抓取工具，擅长全网检索最新实时行情、新闻资讯、技术文档与财报，并输出高密度要点报告。",
                systemPrompt: """
                你是高效的资料研究员与联网情报专家（Librarian）。
                你专属配备了 `web_search`（公网搜索引擎）与 `fetch_url`（网页全文抓取）等联网工具。
                当需要获取最新的实时行情、新闻资讯、技术动态、百科或企业财报时，优先通过这些工具搜索公网最新信息，并迅速提炼关键数据。
                回答言简意赅、条理分明，用最少的废话呈现最高密度的信息，并给出可靠的数据来源或链接。
                """,
                defaultTools: ["web_search", "fetch_url", "read_clipboard", "send_message"],
                defaultThinkingLevel: .low,
                isVisualDelegate: false,
                recommendedModelPicker: { providerId in
                    if providerId == "qoder" { return "qoder/dfmodel" }
                    if providerId == "antigravity" { return "gemini-3.7-flash" }
                    if providerId == "openai" { return "gpt-4o-mini" }
                    return "deepseek-v4.1-flash"
                }
            ),
            AgentRoleProfile(
                id: "concierge",
                name: "系统管家",
                iconName: "macbook.and.iphone",
                trayIconName: "macbook.and.iphone",
                description: "macOS 桌面管家与系统自动化助理，负责硬件指标监测、应用调度控制、剪贴板交互与地图导航。",
                systemPrompt: """
                你是贴心的 macOS 系统管家与桌面助理（Concierge）。
                精通 macOS 系统生态，负责硬件指标监测、应用调度控制、剪贴板联动与地图通勤导航。
                表达风格亲切得体、利落简洁，突出原生 macOS 桌面交互的流畅质感。
                """,
                defaultTools: ["get_system_status", "list_running_apps", "open_app", "read_clipboard", "write_clipboard", "geocode", "search_places", "plan_route", "show_map", "my_location", "get_quickshow_state"],
                defaultThinkingLevel: .low,
                isVisualDelegate: false,
                recommendedModelPicker: { providerId in
                    if providerId == "qoder" { return "qoder/gmodel" }
                    if providerId == "antigravity" { return "gemini-3.8-flash" }
                    if providerId == "openai" { return "gpt-4o-mini" }
                    return "glm-5.3"
                }
            )
        ]

        self.orderedProfiles = list
        var dict: [String: AgentRoleProfile] = [:]
        for profile in list {
            dict[profile.id] = profile
        }
        self.profiles = dict
    }

    /// 获取特定角色 Profile
    func profile(for id: String) -> AgentRoleProfile? {
        profiles[id]
    }

    /// 获取全部角色 Profile 列表
    func allProfiles() -> [AgentRoleProfile] {
        orderedProfiles
    }

    /// 托盘或导航栏图标 (若无匹配回退到默认图标)
    func trayIcon(for subagentId: String, fallback: String = "person.2.fill") -> String {
        profiles[subagentId]?.trayIconName ?? fallback
    }
}
