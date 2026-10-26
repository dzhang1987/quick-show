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
        testAntigravityToolsAndThoughtSignature()
        ToolRiskTests.run()
        ChatInputHistoryTests.run()
        await testChaosAndConcurrencyStress()

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

        // 验证多 Agent 模式针对 Orchestrator 的白名单过滤
        let orch = AIAgent.defaultAgents().first { $0.id == "orchestrator" }!
        let orchTools = registry.tools(for: orch, mode: .multi)
        let orchToolNames = Set(orchTools.map(\.name))
        assertTest(orchToolNames == Set(["launch_subagents", "ask_user", "get_quickshow_state"]), "Orchestrator 过滤后只保留独占工具（刚好 3 个）")

        // 验证多 Agent 模式针对 Coder 的白名单过滤
        let coder = AIAgent.defaultAgents().first { $0.id == "coder" }!
        let coderTools = registry.tools(for: coder, mode: .multi)
        let coderToolNames = Set(coderTools.map(\.name))
        assertTest(!coderToolNames.contains("launch_subagents"), "Coder 不得被授予 launch_subagents")
        assertTest(!coderToolNames.contains("web_search"), "Coder 不得被授予 web_search")
        assertTest(coderToolNames.contains("read_file"), "Coder 必须持有 read_file")
        assertTest(coderToolNames.contains("write_file"), "Coder 必须持有 write_file")

        // 验证单 Agent 模式下直接挂载全套可用工具（排除 launch_subagents 与 send_message）
        let singleTools = registry.tools(for: orch, mode: .single)
        let singleToolNames = Set(singleTools.map(\.name))
        assertTest(!singleToolNames.contains("launch_subagents"), "单 Agent 模式下排除 launch_subagents")
        assertTest(!singleToolNames.contains("send_message"), "单 Agent 模式下排除 send_message")
        assertTest(singleToolNames.contains("web_search"), "单 Agent 模式下直挂 web_search")
        assertTest(singleToolNames.contains("read_file"), "单 Agent 模式下直挂 read_file")
        assertTest(singleToolNames.contains("get_system_status"), "单 Agent 模式下直挂 get_system_status")

        // 验证 nil 回退为全局工具
        let globalTools = registry.tools(for: nil, mode: .multi)
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
        let dispatched1 = accumulator.ingest([delta1])
        assertTest(!accumulator.isEmpty, "注入首片后累积器不为空")
        assertTest(dispatched1.count == 1 && dispatched1.first?.name == "launch_subagents", "首片捕获到工具名并成功产出即时预显派发信号")

        // 模拟第 2 片（参数尾段，id/name 为 nil）
        let delta2 = DeltaToolCall(
            index: 0,
            id: nil,
            type: nil,
            function: DeltaToolCall.DeltaFunction(name: nil, arguments: "{\"agent_id\":\"coder\",\"task\":\"test\"}]}")
        )
        let dispatched2 = accumulator.ingest([delta2])
        assertTest(dispatched2.isEmpty, "后续参数增量分片不重复产出预显派发信号")

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

        // 1. 多 Agent 模式下针对 Orchestrator 编码（白名单裁剪）
        let orchBodyData = try? AIChatService.shared.encodeRequestBody(
            proto: .chatCompletions,
            model: "glm-5.3",
            messages: sampleMessages,
            stream: true,
            includeTools: true,
            agent: orch,
            mode: .multi
        )
        assertTest(orchBodyData != nil, "Orchestrator 请求体编码成功")
        if let data = orchBodyData, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let tools = json["tools"] as? [[String: Any]] ?? []
            let toolNames = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
            assertTest(toolNames == Set(["launch_subagents", "ask_user", "get_quickshow_state"]), "Orchestrator 发包的 tools 字段严格限制为 3 个授权工具")
            assertTest(!toolNames.contains("read_file"), "Orchestrator 发包中绝无 read_file")
        }

        // 2. 多 Agent 模式下针对 Coder 编码（白名单裁剪）
        let coderBodyData = try? AIChatService.shared.encodeRequestBody(
            proto: .chatCompletions,
            model: "glm-5.3",
            messages: sampleMessages,
            stream: true,
            includeTools: true,
            agent: coder,
            mode: .multi
        )
        assertTest(coderBodyData != nil, "Coder 请求体编码成功")
        if let data = coderBodyData, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let tools = json["tools"] as? [[String: Any]] ?? []
            let toolNames = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
            assertTest(!toolNames.contains("launch_subagents"), "Coder 发包中绝无 launch_subagents")
            assertTest(toolNames.contains("read_file"), "Coder 发包中包含 read_file")
            assertTest(toolNames.contains("write_file"), "Coder 发包中包含 write_file")
        }

        // 3. 单 Agent 模式下编码（全套直挂，排除 launch_subagents 与 send_message）
        let singleBodyData = try? AIChatService.shared.encodeRequestBody(
            proto: .chatCompletions,
            model: "glm-5.3",
            messages: sampleMessages,
            stream: true,
            includeTools: true,
            agent: orch,
            mode: .single
        )
        assertTest(singleBodyData != nil, "单 Agent 模式请求体编码成功")
        if let data = singleBodyData, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let tools = json["tools"] as? [[String: Any]] ?? []
            let toolNames = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
            assertTest(!toolNames.contains("launch_subagents"), "单 Agent 模式发包中排除 launch_subagents")
            assertTest(!toolNames.contains("send_message"), "单 Agent 模式发包中排除 send_message")
            assertTest(toolNames.contains("read_file"), "单 Agent 模式发包中直挂 read_file")
            assertTest(toolNames.contains("web_search"), "单 Agent 模式发包中直挂 web_search")
            assertTest(toolNames.contains("get_system_status"), "单 Agent 模式发包中直挂 get_system_status")
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

    // MARK: - 7. Antigravity 直连 Gemini Function Calling 与 ThoughtSignature 测试
    private static func testAntigravityToolsAndThoughtSignature() {
        print("\n[Suite 7] Antigravity 直连 Gemini Function Calling 与 ThoughtSignature 规格测试...")

        let orch = AIAgent.defaultAgents().first { $0.id == "orchestrator" }!
        let orchTools = AIToolRegistry.shared.tools(for: orch, mode: .multi)

        // 1. 验证 Tools 声明装配
        let userMsg = ChatCompletionMessage(role: "user", content: "满帮最新的股价")
        let req = try? AntigravityCloudCodeAdapter.buildRequest(
            modelId: "gemini-3.8-flash-tiered",
            messages: [userMsg],
            options: AIChatRequestOptions(agentId: orch.id),
            token: "fake-test-token",
            projectId: "aicode-consumers",
            tools: orchTools
        )
        assertTest(req != nil, "Antigravity 请求对象构造成功")
        if let body = req?.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let requestObj = json["request"] as? [String: Any] {
            let tools = requestObj["tools"] as? [[String: Any]] ?? []
            assertTest(!tools.isEmpty, "request 中包含 tools 字段")
            if let firstTool = tools.first, let fns = firstTool["function_declarations"] as? [[String: Any]] {
                let fnNames = Set(fns.compactMap { $0["name"] as? String })
                assertTest(fnNames.contains("launch_subagents"), "Gemini tools 中成功声明 launch_subagents")
            } else {
                assertTest(false, "tools 必须为 function_declarations 结构")
            }
        }

        // 2. 验证多轮历史中 toolCalls 与 thoughtSignature 的回传装配
        let wireCall = WireToolCall(
            id: "call_9999",
            name: "launch_subagents",
            arguments: "{\"tasks\":[{\"agent_id\":\"librarian\",\"task\":\"查询股价\"}]}",
            thoughtSignature: "sig_test_thought_signature_xyz"
        )
        let assistantMsg = ChatCompletionMessage(
            role: "assistant",
            content: nil,
            toolCalls: [wireCall],
            toolCallId: nil
        )
        let toolResultMsg = ChatCompletionMessage.toolResult(
            callID: "call_9999",
            content: "{\"result\":\"10.25 USD\"}"
        )

        let multiTurnReq = try? AntigravityCloudCodeAdapter.buildRequest(
            modelId: "gemini-3.8-flash-tiered",
            messages: [userMsg, assistantMsg, toolResultMsg],
            options: AIChatRequestOptions(agentId: orch.id),
            token: "fake-test-token",
            projectId: "aicode-consumers",
            tools: orchTools
        )
        assertTest(multiTurnReq != nil, "多轮工具调用请求构造成功")

        if let body = multiTurnReq?.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let requestObj = json["request"] as? [String: Any],
           let contents = requestObj["contents"] as? [[String: Any]] {
            // 验证 contents 结构
            assertTest(contents.count == 3, "contents 严格包含 3 轮交替消息 (user -> model -> user)")
            if contents.count >= 3 {
                assertTest((contents[0]["role"] as? String) == "user", "第 1 轮为 user 提问")
                assertTest((contents[1]["role"] as? String) == "model", "第 2 轮为 model 工具调用")
                assertTest((contents[2]["role"] as? String) == "user", "第 3 轮为 user 工具结果")

                // 验证第 2 轮中的 thoughtSignature 与 functionCall
                let modelParts = contents[1]["parts"] as? [[String: Any]] ?? []
                if let firstPart = modelParts.first {
                    assertTest(firstPart["thoughtSignature"] as? String == "sig_test_thought_signature_xyz", "model 消息严格携带 thoughtSignature")
                    let fc = firstPart["functionCall"] as? [String: Any]
                    assertTest(fc?["name"] as? String == "launch_subagents", "functionCall 名称正确")
                }

                // 验证第 3 轮中的 functionResponse
                let toolParts = contents[2]["parts"] as? [[String: Any]] ?? []
                if let toolPart = toolParts.first, let fr = toolPart["functionResponse"] as? [String: Any] {
                    assertTest(fr["name"] as? String == "launch_subagents", "functionResponse 对应工具名称为 launch_subagents")
                    assertTest(fr["response"] != nil, "functionResponse 载荷非空")
                }
            }
        }
    }

    // MARK: - 8. 并发竞速与混沌压力测试 (Chaos & Concurrency Stress Test)
    private static func testChaosAndConcurrencyStress() async {
        print("\n[Suite 8] 并发竞速与混沌压力测试 (Chaos & Concurrency Stress)...")

        // 8.0 验证默认硬超时熔断上限常量已提升至 5 分钟 (300 秒)
        assertTest(
            AgentCoordinator.defaultSubagentTimeoutSeconds == 300,
            "默认硬超时熔断上限常量必须为 300 秒 (5 分钟)"
        )

        let store = ChatSessionStore.shared
        let coordinator = AgentCoordinator.shared

        // 8.1 极限竞速轰击 (Microsecond Race Blast - 30 轮)
        var raceSuccessCount = 0
        let parent1 = store.createSession(title: "Race Blast Parent")
        defer { store.deleteSession(id: parent1.id) }

        for i in 1...30 {
            let child = store.createChildSession(
                parentId: parent1.id,
                agentId: "coder",
                title: "Blast Task \(i)",
                switchToChild: false
            )
            let childId = child.id

            Task { @MainActor in
                // 模拟在 0.1~1.5ms 的纳秒级极短时间内瞬间完成
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.1...1.5) * 1_000_000))
                store.appendMessage(
                    ChatMessage(role: .assistant, content: "Blast payload \(i)", state: .done),
                    to: childId
                )
                store.updateTaskStatus(sessionId: childId, status: .completed, summary: "Completed \(i)")
                coordinator.notifyTaskCompletion(taskId: childId, result: "Blast payload \(i)")
            }

            let result = await coordinator.awaitSingleAgent(taskId: childId, timeoutSeconds: 3)
            if result.1 == .completed && result.2 == "Blast payload \(i)" {
                raceSuccessCount += 1
            }
        }
        assertTest(raceSuccessCount == 30, "30 轮纳秒级微竞速轰击 100% 成功且 0 误杀 (当前: \(raceSuccessCount)/30)")

        // 8.2 密集并发扇出/扇入压力测试 (20 任务并发扇出与收集)
        let parent2 = store.createSession(title: "Fan-out Stress Parent")
        defer { store.deleteSession(id: parent2.id) }

        var taskIds: [UUID] = []
        var expectedOutputs: [UUID: String] = [:]
        for i in 1...20 {
            let child = store.createChildSession(
                parentId: parent2.id,
                agentId: "librarian",
                title: "Fan-out Task \(i)",
                switchToChild: false
            )
            taskIds.append(child.id)
            expectedOutputs[child.id] = "Concurrent Output \(i)"

            let cId = child.id
            Task { @MainActor in
                let delayMs = Double.random(in: 1.0...15.0)
                try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
                store.appendMessage(
                    ChatMessage(role: .assistant, content: "Concurrent Output \(i)", state: .done),
                    to: cId
                )
                store.updateTaskStatus(sessionId: cId, status: .completed, summary: "Done \(i)")
                coordinator.notifyTaskCompletion(taskId: cId, result: "Concurrent Output \(i)")
            }
        }

        let gathered = await coordinator.awaitAgents(taskIds: taskIds, timeoutSeconds: 5)
        assertTest(gathered.count == 20, "20 任务高并发扇出收集数量严格为 20")

        var allMatched = true
        var allCompleted = true
        for (id, res) in gathered {
            if res.status != .completed { allCompleted = false }
            if res.output != expectedOutputs[id] { allMatched = false }
        }
        assertTest(allCompleted, "20 任务高并发执行全部为 .completed 状态")
        assertTest(allMatched, "20 任务高并发成果与各任务预设 payload 100% 精确吻合（无并发覆盖/漂移）")

        // 8.3 超时熔断边界与精准判定测试 (Timeout Boundary)
        let parent3 = store.createSession(title: "Timeout Parent")
        defer { store.deleteSession(id: parent3.id) }

        let timeoutChild = store.createChildSession(
            parentId: parent3.id,
            agentId: "oracle",
            title: "Timeout Task",
            switchToChild: false
        )
        let timeoutChildId = timeoutChild.id

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            store.appendMessage(
                ChatMessage(role: .assistant, content: "Late response", state: .done),
                to: timeoutChildId
            )
            store.updateTaskStatus(sessionId: timeoutChildId, status: .completed, summary: "Late")
            coordinator.notifyTaskCompletion(taskId: timeoutChildId, result: "Late response")
        }

        let start = Date()
        let timeoutRes = await coordinator.awaitSingleAgent(taskId: timeoutChildId, timeoutSeconds: 0.05)
        let elapsed = Date().timeIntervalSince(start)

        assertTest(timeoutRes.1 == .failed, "超时任务精准熔断判定为 .failed")
        assertTest(timeoutRes.2.contains("超时"), "超时原因文本正确包含'超时'")
        assertTest(elapsed < 0.25, "超时熔断响应迅速且时间符合设定 (耗时 \(String(format: "%.2f", elapsed))s)")

        // 8.4 突发级联中止风暴 (Abort Storm)
        let parent4 = store.createSession(title: "Abort Storm Parent")
        defer { store.deleteSession(id: parent4.id) }

        var abortTaskIds: [UUID] = []
        for i in 1...10 {
            let child = store.createChildSession(
                parentId: parent4.id,
                agentId: "concierge",
                title: "Abort Task \(i)",
                switchToChild: false
            )
            abortTaskIds.append(child.id)
            AgentTaskRegistry.shared.registerTask(
                id: "storm_task_\(i)_\(UUID().uuidString.prefix(6))",
                subagentId: "concierge",
                subagentName: "系统管家",
                parentSessionId: parent4.id,
                childSessionId: child.id,
                taskDescription: "To be aborted"
            )
        }

        Task { @MainActor in
            _ = await coordinator.awaitAgents(taskIds: abortTaskIds, timeoutSeconds: 5)
        }

        try? await Task.sleep(nanoseconds: 5_000_000)
        coordinator.abortSubagents(for: parent4.id)

        var allAborted = true
        for id in abortTaskIds {
            let s = store.session(id: id)
            if s?.taskStatus != .failed || s?.taskSummary != "用户已中止" {
                allAborted = false
            }
        }
        assertTest(allAborted, "级联中止风暴下 10 个子任务全部正确落定为 .failed 且标注'用户已中止'")
        assertTest(coordinator.debugContinuationCount == 0, "中止后挂起 Continuation 队列彻底清零 (零内存悬挂)")
    }
}
