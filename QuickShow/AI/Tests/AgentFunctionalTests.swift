// AgentFunctionalTests.swift: 多智能体协同与工具链完整接口功能测试套件。
// 涵盖智能体矩阵规范、权限隔离矩阵、launch_subagents 规格、Qoder 请求与流式归并、编码过滤等核心功能。

import Foundation
import AppKit

@MainActor
enum AgentFunctionalTests {
    private static var passedCount = 0
    private static var failedCount = 0

    private static func assertTest(_ condition: Bool, _ name: String, file: String = #file, line: Int = #line) {
        if condition {
            passedCount += 1
            print("  ✅ [PASS] \(name)")
        } else {
            failedCount += 1
            print("  ❌ [FAIL] \(name) (at \(URL(fileURLWithPath: file).lastPathComponent):\(line))")
        }
    }

    static func run() async {
        print("==================================================")
        print("🚀 开始执行 QuickShow 多智能体与工具链接口功能测试")
        print("==================================================")
        passedCount = 0
        failedCount = 0

        testAgentMatrixAndPresets()
        testToolRegistryAndFiltering()
        await testLaunchSubagentsToolSpec()
        testWireModelsAndToolCallAccumulator()
        testRequestEncodingForAgents()
        testTaskRegistryAndInputRouting()

        print("==================================================")
        print("📊 测试完成汇总：通过 \(passedCount) 项，失败 \(failedCount) 项")
        print("==================================================")

        if failedCount > 0 {
            exit(1)
        } else {
            print("🎉 所有多智能体与工具链接口功能测试全部通过！")
            exit(0)
        }
    }

    // MARK: - 1. 智能体矩阵与人设规范测试
    private static func testAgentMatrixAndPresets() {
        print("\n[Suite 1] 6 大垂类智能体矩阵与人设规范测试...")
        
        let agents = AIAgent.defaultAgents(primaryProviderId: "qoder")
        assertTest(agents.count == 6, "Qoder 预设必须包含完整的 6 大智能体")
        
        let ids = Set(agents.map(\.id))
        let expectedIds: Set<String> = ["orchestrator", "observer", "coder", "oracle", "librarian", "concierge"]
        assertTest(ids == expectedIds, "智能体 ID 必须精确匹配 6 大垂类集合")

        // 验证编排中枢
        let orch = agents.first { $0.id == "orchestrator" }
        assertTest(orch != nil, "Orchestrator 存在")
        assertTest(orch?.thinkingLevel == .medium, "Orchestrator 默认思考档位为 medium")
        assertTest(orch?.resolvedTools.contains("launch_subagents") == true, "Orchestrator 必须拥有 launch_subagents 工具")
        assertTest(orch?.resolvedTools.contains("ask_user") == true, "Orchestrator 必须拥有 ask_user 工具")
        assertTest(!orch!.resolvedTools.contains("read_file"), "Orchestrator 严禁拥有 read_file 工具")
        assertTest(!orch!.resolvedTools.contains("web_search"), "Orchestrator 严禁拥有 web_search 工具")

        // 验证视觉担当
        let obs = agents.first { $0.id == "observer" }
        assertTest(obs?.isVisualDelegate == true, "Observer 必须被标记为 isVisualDelegate")
        assertTest(obs?.resolvedTools == ["preview_file"], "Observer 默认仅拥有 preview_file 工具")

        // 验证代码专家
        let coder = agents.first { $0.id == "coder" }
        assertTest(coder?.resolvedTools.contains("read_file") == true, "Coder 必须拥有 read_file")
        assertTest(coder?.resolvedTools.contains("write_file") == true, "Coder 必须拥有 write_file")
        assertTest(!coder!.resolvedTools.contains("launch_subagents"), "Coder 严禁持有 launch_subagents")

        // 验证知识检索
        let lib = agents.first { $0.id == "librarian" }
        assertTest(lib?.resolvedTools.contains("web_search") == true, "Librarian 必须拥有 web_search")
        assertTest(lib?.resolvedTools.contains("fetch_url") == true, "Librarian 必须拥有 fetch_url")
        assertTest(!lib!.resolvedTools.contains("write_file"), "Librarian 严禁持有 write_file")

        // 验证系统管家
        let concierge = agents.first { $0.id == "concierge" }
        assertTest(concierge?.resolvedTools.contains("get_system_status") == true, "Concierge 拥有 get_system_status")
        assertTest(concierge?.resolvedTools.contains("open_app") == true, "Concierge 拥有 open_app")
        assertTest(concierge?.resolvedTools.contains("show_map") == true, "Concierge 拥有 show_map")

        // 验证自定义 enabledTools 优先级
        var customAgent = orch!
        customAgent.enabledTools = ["test_tool"]
        assertTest(customAgent.resolvedTools == ["test_tool"], "当显式配置 enabledTools 时优先使用自定义值")
        customAgent.enabledTools = []
        assertTest(customAgent.resolvedTools == AIAgent.defaultToolNames(for: "orchestrator"), "当 enabledTools 为空时回退角色推荐默认")
    }

    // MARK: - 2. 工具注册表与 Agent 权限过滤测试
    private static func testToolRegistryAndFiltering() {
        print("\n[Suite 2] AIToolRegistry 注册与 Agent 权限过滤测试...")

        let registry = AIToolRegistry.shared
        let allTools = registry.allTools()

        // 验证新工具已注册，旧工具已彻底清除
        assertTest(allTools.contains { $0.name == "launch_subagents" }, "AIToolRegistry 必须注册 launch_subagents")
        assertTest(!allTools.contains { $0.name == "launch_agent" }, "已废弃的 launch_agent 不应存在于注册表中")
        assertTest(!allTools.contains { $0.name == "await_agents" }, "已废弃的 await_agents 不应存在于注册表中")
        assertTest(!allTools.contains { $0.name == "delegate_to_agent" }, "已废弃的 delegate_to_agent 不应存在于注册表中")

        // 验证针对 Orchestrator 的过滤
        let orch = AIAgent.defaultAgents().first { $0.id == "orchestrator" }!
        let orchTools = registry.tools(for: orch)
        let orchToolNames = Set(orchTools.map(\.name))
        assertTest(orchToolNames == Set(["launch_subagents", "ask_user", "get_quickshow_state"]), "Orchestrator 过滤后只保留独占工具（刚好 3 个）")

        // 验证针对 Coder 的过滤
        let coder = AIAgent.defaultAgents().first { $0.id == "coder" }!
        let coderTools = registry.tools(for: coder)
        let coderToolNames = Set(coderTools.map(\.name))
        assertTest(!coderToolNames.contains("launch_subagents"), "Coder 不得被授予 launch_subagents")
        assertTest(!coderToolNames.contains("web_search"), "Coder 不得被授予 web_search")
        assertTest(coderToolNames.contains("read_file"), "Coder 必须持有 read_file")
        assertTest(coderToolNames.contains("write_file"), "Coder 必须持有 write_file")

        // 验证 nil 回退为全局工具
        let globalTools = registry.tools(for: nil)
        assertTest(globalTools.count == registry.enabledTools().count, "传入 nil 时应安全回退为全局启用的工具全集")
    }

    // MARK: - 3. launch_subagents 规格与参数解析测试
    private static func testLaunchSubagentsToolSpec() async {
        print("\n[Suite 3] LaunchSubagentsTool 规格与参数解析测试...")

        let tool = LaunchSubagentsTool()
        assertTest(tool.name == "launch_subagents", "工具名称必须为 launch_subagents")
        assertTest(tool.displayName == "并发调度子智能体", "展示名称正确")
        assertTest(tool.category == .interaction, "分类必须为 interaction")
        assertTest(tool.isInteractive == true, "isInteractive 必须为 true 以豁免超时")

        let schema = tool.parametersSchema
        assertTest(schema["type"] as? String == "object", "Schema 根节点必须是 object")
        let required = schema["required"] as? [String] ?? []
        assertTest(required.contains("tasks"), "必需参数必须包含 tasks")

        let props = schema["properties"] as? [String: Any] ?? [:]
        let tasksProp = props["tasks"] as? [String: Any] ?? [:]
        assertTest(tasksProp["type"] as? String == "array", "tasks 必须是 array 类型")

        // 边界异常测试：空 tasks 传入必须抛错
        var caughtError = false
        do {
            _ = try await tool.execute(arguments: ["tasks": []])
        } catch is ToolExecutionError {
            caughtError = true
        } catch {}
        assertTest(caughtError, "传入空 tasks 数组时必须正确抛出 ToolExecutionError")
    }

    // MARK: - 4. 消息协议与流式工具分片累积器测试
    private static func testWireModelsAndToolCallAccumulator() {
        print("\n[Suite 4] 消息协议与流式工具分片累积测试...")

        // 测试 Assistant tool_calls 消息 JSON 序列化
        let wireCall = WireToolCall(id: "call_999", name: "launch_subagents", arguments: "{\"tasks\":[]}")
        let assistantMsg = ChatCompletionMessage(
            role: "assistant",
            content: .text("正在并发调度专家..."),
            toolCalls: [wireCall],
            toolCallId: nil
        )

        let encodedData = try? JSONEncoder().encode(assistantMsg)
        assertTest(encodedData != nil, "ChatCompletionMessage 能正常 JSON 编码")
        if let data = encodedData, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            assertTest(json["role"] as? String == "assistant", "角色字段编码为 assistant")
            let calls = json["tool_calls"] as? [[String: Any]] ?? []
            assertTest(calls.count == 1, "tool_calls 数组成功保留")
            assertTest(calls.first?["id"] as? String == "call_999", "tool_call id 正确序列化")
        }

        // 测试 ChatToolCallAccumulator 流式分片归并
        let accumulator = ChatToolCallAccumulator()
        assertTest(accumulator.isEmpty, "初始状态下累积器为空")

        // 模拟第 1 片（带 id 与 name，参数首段）
        let delta1 = DeltaToolCall(
            index: 0,
            id: "call_abc",
            type: "function",
            function: DeltaToolCall.DeltaFunction(name: "launch_subagents", arguments: "{\"tasks\":[")
        )
        accumulator.ingest([delta1])
        assertTest(!accumulator.isEmpty, "注入首片后累积器不为空")

        // 模拟第 2 片（参数尾段，id/name 为 nil）
        let delta2 = DeltaToolCall(
            index: 0,
            id: nil,
            type: nil,
            function: DeltaToolCall.DeltaFunction(name: nil, arguments: "{\"agent_id\":\"coder\",\"task\":\"test\"}]}")
        )
        accumulator.ingest([delta2])

        let completed = accumulator.completed
        assertTest(completed.count == 1, "流结束时成功归并产出 1 个完整工具调用")
        let firstCall = completed.first
        assertTest(firstCall?.id == "call_abc", "合并后的 callID 正确")
        assertTest(firstCall?.name == "launch_subagents", "合并后的 name 正确")
        assertTest(firstCall?.arguments == "{\"tasks\":[{\"agent_id\":\"coder\",\"task\":\"test\"}]}", "分片 arguments 成功拼接完整")

        accumulator.clear()
        assertTest(accumulator.isEmpty, "调用 clear 后累积器清空")
    }

    // MARK: - 5. 请求体动态工具 Schema 过滤测试
    private static func testRequestEncodingForAgents() {
        print("\n[Suite 5] AIChatService+RequestEncoding 动态工具 Schema 过滤测试...")

        let orch = AIAgent.defaultAgents().first { $0.id == "orchestrator" }!
        let coder = AIAgent.defaultAgents().first { $0.id == "coder" }!

        let sampleMessages = [
            ChatCompletionMessage(role: "user", content: "测试请求")
        ]

        // 1. 针对 Orchestrator 编码
        let orchBodyData = try? AIChatService.shared.encodeRequestBody(
            proto: .chatCompletions,
            model: "glm-5.3",
            messages: sampleMessages,
            stream: true,
            includeTools: true,
            agent: orch
        )
        assertTest(orchBodyData != nil, "Orchestrator 请求体编码成功")
        if let data = orchBodyData, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let tools = json["tools"] as? [[String: Any]] ?? []
            let toolNames = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
            assertTest(toolNames == Set(["launch_subagents", "ask_user", "get_quickshow_state"]), "Orchestrator 发包的 tools 字段严格限制为 3 个授权工具")
            assertTest(!toolNames.contains("read_file"), "Orchestrator 发包中绝无 read_file")
        }

        // 2. 针对 Coder 编码
        let coderBodyData = try? AIChatService.shared.encodeRequestBody(
            proto: .chatCompletions,
            model: "glm-5.3",
            messages: sampleMessages,
            stream: true,
            includeTools: true,
            agent: coder
        )
        assertTest(coderBodyData != nil, "Coder 请求体编码成功")
        if let data = coderBodyData, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let tools = json["tools"] as? [[String: Any]] ?? []
            let toolNames = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
            assertTest(!toolNames.contains("launch_subagents"), "Coder 发包中绝无 launch_subagents")
            assertTest(toolNames.contains("read_file"), "Coder 发包中包含 read_file")
            assertTest(toolNames.contains("write_file"), "Coder 发包中包含 write_file")
        }
    }

    // MARK: - 6. 任务持久化注册表与 Steering 输入路由测试
    private static func testTaskRegistryAndInputRouting() {
        print("\n[Suite 6] AgentTaskRegistry 本地持久化与 Steering 路由测试...")

        let registry = AgentTaskRegistry.shared
        assertTest(registry.baseDirectoryURL.lastPathComponent == ".quickshow", "持久化根目录必须为 ~/.quickshow")
        assertTest(registry.tasksFileURL.lastPathComponent == "agent_tasks.json", "任务状态文件必须为 agent_tasks.json")
        assertTest(registry.artifactsDirectoryURL.lastPathComponent == "artifacts", "产物根目录必须为 artifacts")

        let testParentId = UUID()
        let testChildId = UUID()
        let testTaskId = "task_test_librarian_123"

        // 1. 注册新任务
        let record = registry.registerTask(
            id: testTaskId,
            subagentId: "librarian",
            subagentName: "知识检索",
            parentSessionId: testParentId,
            childSessionId: testChildId,
            taskDescription: "搜索满帮最新股价与财报数据"
        )
        assertTest(record.id == testTaskId, "注册任务成功且 ID 匹配")
        assertTest(record.status == .queued, "初始状态必须为 queued")

        let running = registry.runningTasks(parentSessionId: testParentId)
        assertTest(running.contains(where: { $0.id == testTaskId }), "runningTasks 能准确命中刚注册的任务")

        // 2. 状态动作更新
        registry.updateTaskAction(id: testTaskId, action: "正在调用 web_search...", status: .toolExecuting)
        let updated = registry.task(id: testTaskId)
        assertTest(updated?.status == .toolExecuting, "状态成功更新为 toolExecuting")
        assertTest(updated?.currentAction == "正在调用 web_search...", "实时活动描述更新成功")

        // 3. 产物路径生成与任务完成
        let artifactPath = registry.makeArtifactPath(parentSessionId: testParentId, taskId: testTaskId, fileName: "test_report.md")
        assertTest(artifactPath.path.contains("/.quickshow/artifacts/\(testParentId.uuidString)/\(testTaskId)/test_report.md"), "产物保存路径结构完全符合规范")

        registry.settleTask(id: testTaskId, status: .completed, summary: "股价获取完成", artifactPath: artifactPath.path)
        let settled = registry.task(id: testTaskId)
        assertTest(settled?.status == .completed, "任务最终状态成功落定为 completed")
        assertTest(settled?.artifacts.contains(artifactPath.path) == true, "产物路径成功记录到持久化任务中")

        // 4. 输入路由 (A+B 方案) 测试
        let testParent2 = UUID()
        let taskLibId = "task_route_lib_1"
        let taskCoderId = "task_route_coder_2"

        registry.registerTask(
            id: taskLibId,
            subagentId: "librarian",
            subagentName: "知识检索",
            parentSessionId: testParent2,
            childSessionId: UUID(),
            taskDescription: "查满帮财报"
        )
        registry.updateTaskAction(id: taskLibId, action: "搜索中", status: .running)

        registry.registerTask(
            id: taskCoderId,
            subagentId: "coder",
            subagentName: "代码专家",
            parentSessionId: testParent2,
            childSessionId: UUID(),
            taskDescription: "编写数据抓取脚本"
        )
        registry.updateTaskAction(id: taskCoderId, action: "写代码中", status: .running)

        // 显式前缀匹配
        let routeExplicit = AgentCoordinator.shared.routeInput(text: "@librarian 顺便查一下货拉拉的市值", parentSessionId: testParent2)
        assertTest(routeExplicit?.taskId == taskLibId, "显式 @librarian 正确命中知识检索任务")
        assertTest(routeExplicit?.cleanText == "顺便查一下货拉拉的市值", "前缀剥离后干净提取正文")

        let routeChinese = AgentCoordinator.shared.routeInput(text: "让代码专家把函数改为异步", parentSessionId: testParent2)
        assertTest(routeChinese?.taskId == taskCoderId, "自然称谓'让代码专家'正确命中代码任务")

        // 语义评分匹配
        let routeSemanticLib = AgentCoordinator.shared.routeInput(text: "再查一下雪球上的最新行情走势", parentSessionId: testParent2)
        assertTest(routeSemanticLib?.taskId == taskLibId, "语义关键词'雪球/行情'自动路由至知识检索专家")

        let routeSemanticCoder = AgentCoordinator.shared.routeInput(text: "优化一下这个 Swift 脚本并修复编译报错", parentSessionId: testParent2)
        assertTest(routeSemanticCoder?.taskId == taskCoderId, "语义关键词'Swift/编译报错'自动路由至代码专家")

        // 清理测试任务状态
        registry.settleTask(id: taskLibId, status: .completed)
        registry.settleTask(id: taskCoderId, status: .completed)
    }
}
