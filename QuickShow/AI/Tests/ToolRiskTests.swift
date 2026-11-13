import Foundation
import Darwin

// MARK: - 工具风险模型与权限策略单元测试

@MainActor
enum ToolRiskTests {
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

    @discardableResult
    static func run() -> Bool {
        print("==================================================")
        print("🛡️ 开始执行工具风险评估与权限策略规则测试")
        print("==================================================")
        passedCount = 0
        failedCount = 0

        testShellAlwaysRequiresApproval()
        testShellDestructiveEvaluation()
        testShellQuotedSafety()
        testFileRiskEvaluation()
        testWebAccessTiering()
        testSensitiveCapabilitiesSessionGrantable()
        testFailClosedAuthorizationPolicy()
        testSessionGrantStore()
        testUndoSnapshotLifecycle()
        testSensitiveTextRedaction()
        testOrdinaryUserConfirmationPresentation()
        testBackgroundSourceAttribution()

        print("==================================================")
        print("📊 权限测试完成汇总：通过 \(passedCount) 项，失败 \(failedCount) 项")
        print("==================================================")
        return failedCount == 0
    }

    // MARK: - 1. 原始 Shell 必须逐次确认

    private static func testShellAlwaysRequiresApproval() {
        let evaluator = ShellSemanticRiskEvaluator()
        let shellTool = RunShellTool()
        let representativeCommands = [
            "pwd",
            "ls -la",
            "cat README.md",
            "cat ~/.ssh/id_rsa",
            "git status",
            "pnpm list",
            "python3 --version",
            "curl https://example.com",
            "echo 'test' > output.txt",
            "cd web && git status",
            "",
            ";;;"
        ]

        for command in representativeCommands {
            let risk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": command])
            assertTest(!risk.isAutoApproved, "原始 Shell 不得免审：\(command)")
        }
    }

    // MARK: - 2. 破坏性 Shell 识别与硬拦截测试

    private static func testShellDestructiveEvaluation() {
        let evaluator = ShellSemanticRiskEvaluator()
        let shellTool = RunShellTool()

        let dangerousCommands = [
            "rm -rf /tmp/foo",
            "rm -r .git",
            "rm ~/.ssh/id_rsa",
            "bash -c 'rm -rf ~/.ssh'",
            "/usr/bin/env bash -c 'rm -rf /tmp/x'",
            "/usr/bin/env -u HOME bash -c 'rm -rf /tmp/x'",
            "/usr/bin/xargs rm -rf /tmp/x",
            "/usr/bin/xargs -I {} bash -c 'rm -rf /tmp/x'",
            "python3 -c 'import os; os.remove(\"important\")'",
            "find . -name '*.tmp' -delete",
            "sudo rm -rf /",
            "FOO=1 sudo ls",
            "git reset --hard HEAD~1",
            "git clean -fd",
            "git push origin main --force",
            "git branch -D feature",
            "echo 'hacked' > ~/.zshrc",
            "echo x > /etc/hosts",
            "find . -name x | xargs sudo tee /etc/hosts",
            "echo $(sudo rm -rf /tmp/x)",
            "reboot"
        ]

        for cmd in dangerousCommands {
            let risk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": cmd])
            assertTest(risk.isDestructive, "破坏性高危命令硬拦截：\(cmd)")
        }

        // 曾被误杀、应按受控变更（非破坏性）处理的命令
        let falsePositiveCommands = [
            "cp ~/.zshrc ~/backup-zshrc",
            "mv ~/.zshrc ~/dotfiles-backup",
            "git commit -m 'docs: 解释 rm -rf 的危险'",
            "grep -r 'shutdown' docs/",
            "echo 'sudo 与 reboot 的文档说明' >> notes.md"
        ]
        for cmd in falsePositiveCommands {
            let risk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": cmd])
            assertTest(!risk.isDestructive, "引号/目标感知：不再误判破坏性：\(cmd)")
        }
    }

    // MARK: - 3. 引号安全与复合命令词法测试

    private static func testShellQuotedSafety() {
        let evaluator = ShellSemanticRiskEvaluator()
        let shellTool = RunShellTool()

        // 引号内的危险词不应误判为破坏性，但原始 Shell 仍必须逐次确认
        let quotedReadOnlyCommands = [
            "echo 'sudo && reboot 的说明文档'",
            "echo \"rm -rf 只是文档示例\"",
            "cat 'my;file.txt'",
            "echo \"a && b\""
        ]
        for cmd in quotedReadOnlyCommands {
            let risk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": cmd])
            assertTest(!risk.isDestructive && !risk.isAutoApproved, "引号内容不误判且仍需确认：\(cmd)")
        }

        // 引号内的危险词在「变更命令」中同样不误杀（走受控变更而非硬门禁）
        let quotedMutationCommands = [
            "git commit -m \"fix: 修复 rm -rf 误删问题\"",
            "git commit -m 'chore: 升级 sudo 相关文档'"
        ]
        for cmd in quotedMutationCommands {
            let risk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": cmd])
            assertTest(!risk.isDestructive && !risk.isAutoApproved, "引号内危险词不误杀变更命令：\(cmd)")
        }
    }

    // MARK: - 5. 文件写入目标风险评估测试

    private static func testFileRiskEvaluation() {
        let evaluator = FileRiskEvaluator()
        let writeTool = WriteFileTool()

        // 敏感系统目录破坏拦截
        let sensitiveCases = [
            "~/.ssh/id_rsa",
            "/etc/hosts",
            "/System/Library/Fonts",
            "~/.zshrc",
            "my_project/.git/config"
        ]
        for path in sensitiveCases {
            let risk = evaluator.evaluateRisk(tool: writeTool, arguments: ["path": path, "content": "foo"])
            assertTest(risk.isDestructive, "文件高危目标硬拦截：\(path)")
        }

        // 正常工程目录写入归入目录级会话授权档（首次写入问一次，同目录后续静默 + 撤销收据）
        let normalPath = "/Users/admin/Projects/quick-time/Package.swift"
        let normalRisk = evaluator.evaluateRisk(tool: writeTool, arguments: ["path": normalPath, "content": "bar"])
        assertTest(
            normalRisk.grantScope == .directory(path: "/Users/admin/Projects/quick-time"),
            "正常文件写入归入目录级会话授权"
        )
        assertTest(!normalRisk.isAutoApproved && !normalRisk.isDestructive, "目录授权档非静默也非硬门禁")
    }

    // MARK: - 5.5 Web 访问分级：公开只读静默，凭证/内网升级逐次

    private static func testWebAccessTiering() {
        let classifier = ToolRiskClassifier.shared
        guard let searchTool = AIToolRegistry.shared.tool(named: "web_search"),
              let fetchTool = AIToolRegistry.shared.tool(named: "fetch_url") else {
            assertTest(false, "Web 工具已注册")
            return
        }

        let publicSearch = classifier.evaluateRisk(tool: searchTool, arguments: ["query": "OpenAI 官方计费规则"])
        assertTest(publicSearch.isAutoApproved, "公开信息检索静默免审")

        let secretSearch = classifier.evaluateRisk(
            tool: searchTool,
            arguments: ["query": "API_KEY=test-secret-123456789 查询"]
        )
        assertTest(!secretSearch.isAutoApproved, "携带凭证的搜索升级逐次确认")

        let publicFetch = classifier.evaluateRisk(tool: fetchTool, arguments: ["url": "https://example.com/docs"])
        assertTest(publicFetch.isAutoApproved, "公共网页抓取静默免审")

        let intranetTargets = [
            "http://localhost:8080/admin",
            "http://127.0.0.1/secret",
            "http://192.168.1.1/router",
            "http://10.0.0.5/internal",
            "http://169.254.169.254/latest/meta-data",
            "file:///etc/hosts"
        ]
        for target in intranetTargets {
            let risk = classifier.evaluateRisk(tool: fetchTool, arguments: ["url": target])
            assertTest(!risk.isAutoApproved, "本机/内网/保留地址升级逐次确认：\(target)")
        }
    }

    // MARK: - 6. 敏感能力会话授权档

    private static func testSensitiveCapabilitiesSessionGrantable() {
        let toolNames = [
            "read_clipboard", "write_clipboard", "list_running_apps", "open_app",
            "read_file", "preview_file",
            "get_env", "set_env", "list_env",
            "geocode", "search_places", "plan_route", "my_location",
            "launch_subagents", "send_message"
        ]
        for name in toolNames {
            guard let tool = AIToolRegistry.shared.tool(named: name) else {
                assertTest(false, "敏感工具已注册：\(name)")
                continue
            }
            let risk = ToolRiskClassifier.shared.evaluateRisk(tool: tool, arguments: [:])
            assertTest(!risk.isAutoApproved, "敏感能力不得静默执行：\(name)")
            assertTest(risk.grantScope == .capability(toolName: name), "敏感能力归入能力级会话授权：\(name)")
        }
    }

    // MARK: - 6.5 会话授权记忆：授权/拒绝/撤销/会话隔离

    private static func testSessionGrantStore() {
        let store = ToolPermissionGrantStore.shared
        let sessionA = UUID()
        let sessionB = UUID()
        let scope = PermissionGrantScope.capability(toolName: "read_clipboard")

        // 初始 undecided
        assertTest(store.decision(for: scope, sessionID: sessionA) == .undecided, "初始无记忆为 undecided")
        assertTest(store.decision(for: scope, sessionID: nil) == .undecided, "无会话上下文不记忆")

        // 授权记忆 + 会话隔离
        store.recordGrant(scope: scope, sessionID: sessionA)
        assertTest(store.decision(for: scope, sessionID: sessionA) == .granted, "授权后同会话静默放行")
        assertTest(store.decision(for: scope, sessionID: sessionB) == .undecided, "授权不串会话")

        // 拒绝覆盖授权（互斥）
        store.recordDenial(scope: scope, sessionID: sessionA)
        assertTest(store.decision(for: scope, sessionID: sessionA) == .denied, "拒绝后同会话静默拒绝")

        // 撤销拒绝 → 恢复询问
        store.revokeDenial(scope: scope, sessionID: sessionA)
        assertTest(store.decision(for: scope, sessionID: sessionA) == .undecided, "撤销拒绝后恢复询问")

        // 目录作用域与能力作用域互不覆盖
        let dirScope = PermissionGrantScope.directory(path: "/tmp/quickshow-grant-test")
        store.recordGrant(scope: dirScope, sessionID: sessionA)
        assertTest(store.decision(for: dirScope, sessionID: sessionA) == .granted, "目录授权独立记忆")
        assertTest(store.decision(for: scope, sessionID: sessionA) == .undecided, "能力作用域不受目录授权影响")
    }

    // MARK: - 7. 默认拒绝与显式免审白名单

    private static func testFailClosedAuthorizationPolicy() {
        let undeclared = UndeclaredAuthorizationTool()
        assertTest(
            undeclared.authorizationPolicy == .requiresConfirmation,
            "新工具未声明授权策略时默认需要确认"
        )
        assertTest(
            ToolRiskClassifier.shared.evaluateRisk(tool: undeclared, arguments: [:]) == .requiresConfirmation,
            "未知工具风险评估默认拒绝静默放行"
        )
        assertTest(
            !undeclared.isParallelExecutionSafe(arguments: [:]),
            "误标可并行的未授权工具不能进入免审并行批"
        )

        let expectedAutoApproved: Set<String> = [
            "get_system_status", "get_quickshow_state", "show_map", "ask_user", "web_search"
        ]
        let actualAutoApproved = Set(AIToolRegistry.shared.allTools().compactMap { tool in
            ToolRiskClassifier.shared.evaluateRisk(tool: tool, arguments: [:]).isAutoApproved
                ? tool.name
                : nil
        })
        assertTest(actualAutoApproved == expectedAutoApproved, "只有显式结构化安全工具可以免审")

        let registry = AIToolRegistry.shared
        assertTest(registry.tools(for: nil, mode: .multi).isEmpty, "多 Agent 缺失角色上下文时工具白名单默认拒绝")
        let emptyRole = AIAgent(name: "空白角色", enabledTools: [])
        assertTest(registry.tools(for: emptyRole, mode: .multi).isEmpty, "多 Agent 空白名单不会继承全局工具")
        if let orchestrator = AIAgent.defaultAgents().first(where: { $0.id == "orchestrator" }) {
            assertTest(
                !registry.isToolAllowed("get_system_status", for: orchestrator, mode: .multi),
                "多 Agent 执行入口拒绝角色白名单外的免审工具"
            )
        } else {
            assertTest(false, "默认 Orchestrator 角色存在")
        }
    }

    // MARK: - 8. 文件覆盖快照与撤销还原测试

    private static func testUndoSnapshotLifecycle() {
        let manager = UndoSnapshotManager.shared
        manager.clearAll()

        let tempPath = NSTemporaryDirectory() + "quickshow_undo_test_\(UUID().uuidString).txt"
        let initialContent = "Original Content 12345"
        let modifiedContent = "Overwritten by AI"

        do {
            try initialContent.write(toFile: tempPath, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: tempPath) }

            // 1. 创建覆盖前快照
            let token = try manager.createSnapshot(path: tempPath)
            assertTest(manager.canUndo(token: token), "快照创建成功且处于可撤销状态")
            assertTest(!manager.isUndone(token: token), "初始状态未被撤销")

            // 2. 模拟写入覆盖
            try modifiedContent.write(toFile: tempPath, atomically: true, encoding: .utf8)
            let readModified = try String(contentsOfFile: tempPath, encoding: .utf8)
            assertTest(readModified == modifiedContent, "模拟文件被覆盖写入成功")

            // 3. 执行撤销
            try manager.undo(token: token)
            assertTest(manager.isUndone(token: token), "撤销状态被标记为已撤销")
            assertTest(!manager.canUndo(token: token), "已撤销快照不再允许二次撤销")

            // 4. 验证内容已还原
            let restoredContent = try String(contentsOfFile: tempPath, encoding: .utf8)
            assertTest(restoredContent == initialContent, "文件原始内容成功原子还原")

            // 非 UTF-8 原文件必须按原始字节恢复，绝不能在撤销时误删。
            let binaryPath = NSTemporaryDirectory() + "quickshow_undo_binary_\(UUID().uuidString).bin"
            let originalBinary = Data([0x00, 0xFF, 0x10, 0x80])
            try originalBinary.write(to: URL(fileURLWithPath: binaryPath), options: .atomic)
            defer { try? FileManager.default.removeItem(atPath: binaryPath) }
            let binaryToken = try manager.createSnapshot(path: binaryPath)
            try Data("replacement".utf8).write(to: URL(fileURLWithPath: binaryPath), options: .atomic)
            try manager.undo(token: binaryToken)
            let restoredBinary = try Data(contentsOf: URL(fileURLWithPath: binaryPath))
            assertTest(restoredBinary == originalBinary, "非 UTF-8 原文件按字节完整还原")

            // 原先不存在的文件，撤销时只能删除本次新建文件。
            let newFilePath = NSTemporaryDirectory() + "quickshow_undo_new_\(UUID().uuidString).txt"
            let newFileToken = try manager.createSnapshot(path: newFilePath)
            try modifiedContent.write(toFile: newFilePath, atomically: true, encoding: .utf8)
            try manager.undo(token: newFileToken)
            assertTest(!FileManager.default.fileExists(atPath: newFilePath), "撤销新建文件时删除本次产物")

            // 已存在但不可读的文件必须拒绝创建快照，不能误当成“原先不存在”。
            let unreadablePath = NSTemporaryDirectory() + "quickshow_undo_unreadable_\(UUID().uuidString).txt"
            try initialContent.write(toFile: unreadablePath, atomically: true, encoding: .utf8)
            defer {
                chmod(unreadablePath, S_IRUSR | S_IWUSR)
                try? FileManager.default.removeItem(atPath: unreadablePath)
            }
            chmod(unreadablePath, 0)
            do {
                _ = try manager.createSnapshot(path: unreadablePath)
                assertTest(false, "不可读原文件不得创建可覆盖快照")
            } catch {
                assertTest(true, "不可读原文件会拒绝后续覆盖")
            }
        } catch {
            assertTest(false, "撤销快照测试抛错：\(error.localizedDescription)")
        }
    }

    // MARK: - 10. 敏感信息展示脱敏

    private static func testSensitiveTextRedaction() {
        let secret = "test-secret-123456789"
        let samples = [
            "Authorization: Bearer \(secret)",
            "{\"access_token\":\"\(secret)\"}",
            "{\"nested\":[{\"CLIENT_SECRET\":\"\(secret)\"}]}",
            "API_KEY=\(secret) curl https://example.com",
            "OPENAI_API_KEY=\(secret) curl https://example.com",
            "AWS_SECRET_ACCESS_KEY='\(secret)' command",
            "curl --token \(secret) https://example.com",
            "https://example.com/path?token=\(secret)&page=1"
        ]

        for sample in samples {
            let redacted = SensitiveTextRedactor.redact(sample)
            assertTest(!redacted.contains(secret), "敏感值不会出现在展示文本：\(sample.prefix(30))")
            assertTest(redacted.contains("••••••"), "敏感值替换为统一遮蔽符")
        }

        let json = "{\"user\":\"alice\",\"authorization\":\"Bearer \(secret)\"}"
        let redactedJSON = SensitiveTextRedactor.redact(json)
        let remainsValidJSON = redactedJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
        assertTest(remainsValidJSON, "JSON 脱敏后仍可解析")
        assertTest(redactedJSON.contains("alice"), "非敏感字段保持不变")

        let envArguments = "{\"key\":\"OPENAI_API_KEY\",\"value\":\"\(secret)\"}"
        let storedEnvArguments = ToolRecordSanitizer.arguments(toolName: "set_env", json: envArguments)
        assertTest(!storedEnvArguments.contains(secret), "环境变量 value 不进入会话参数记录")

        let envResult = "{\"ok\":true,\"data\":{\"key\":\"OPENAI_API_KEY\",\"value\":\"\(secret)\"}}"
        let storedEnvResult = ToolRecordSanitizer.result(toolName: "get_env", json: envResult)
        assertTest(!storedEnvResult.contains(secret), "环境变量读取结果不进入会话记录")

        let shellArguments = AIToolExecutor.encodeJSON([
            "command": "OPENAI_API_KEY=\(secret) curl https://example.com"
        ])
        let storedShellArguments = ToolRecordSanitizer.arguments(toolName: "run_shell", json: shellArguments)
        assertTest(!storedShellArguments.contains(secret), "Shell 命令原文不进入会话记录")
        assertTest(storedShellArguments.contains("未写入会话记录"), "Shell 参数卡明确说明命令未持久化")

        let shellResult = "{\"ok\":true,\"data\":\"\(secret)\"}"
        let storedShellResult = ToolRecordSanitizer.result(toolName: "run_shell", json: shellResult)
        assertTest(!storedShellResult.contains(secret), "Shell 原始输出不进入会话记录")
        assertTest(storedShellResult.contains("未写入会话记录"), "Shell 工具卡明确说明结果未持久化")

        let failedShellResult = "{\"ok\":false,\"error\":\"OPENAI_API_KEY=\(secret)\"}"
        let storedFailedShellResult = ToolRecordSanitizer.result(toolName: "run_shell", json: failedShellResult)
        assertTest(!storedFailedShellResult.contains(secret), "Shell 失败输出同样不进入会话记录")
    }

    // MARK: - 11. 普通用户操作影响说明

    private static func testOrdinaryUserConfirmationPresentation() {
        let command = "curl https://coarena.ai/api/upload -H 'Authorization: Bearer test-secret-123456789' -d @image.png"
        let shellArguments = AIToolExecutor.encodeJSON(["command": command])
        let shellRequest = ToolConfirmationRequest(
            id: UUID(),
            toolName: "run_shell",
            actionIntent: "识别图片颜色",
            argumentsJSON: shellArguments,
            summary: command,
            riskLevel: .requiresConfirmation,
            sourceSessionID: nil,
            sourceLabel: nil
        )
        let shellPresentation = ToolConfirmationPresentation.make(for: shellRequest)
        assertTest(shellPresentation.primaryActionTitle == "仅执行这一次", "Shell 只提供单次执行")
        assertTest(shellPresentation.impacts.contains(where: { $0.text.contains("coarena.ai") }), "外部接收方以域名展示")
        assertTest(shellPresentation.impacts.contains(where: { $0.text.contains("凭证") }), "凭证使用以普通语言提示")
        assertTest(shellPresentation.technicalDetailsTitle.contains("敏感信息已隐藏"), "技术详情明确提示已脱敏")

        let writeArguments = AIToolExecutor.encodeJSON([
            "path": "/tmp/quickshow-preview.txt",
            "content": "preview"
        ])
        let writeRequest = ToolConfirmationRequest(
            id: UUID(),
            toolName: "write_file",
            actionIntent: "整理文档",
            argumentsJSON: writeArguments,
            summary: writeArguments,
            riskLevel: .requiresConfirmation,
            sourceSessionID: nil,
            sourceLabel: nil
        )
        let writePresentation = ToolConfirmationPresentation.make(for: writeRequest)
        assertTest(writePresentation.primaryActionTitle == "应用修改", "文件写入以应用修改表达")
        assertTest(writePresentation.impacts.contains(where: { $0.text.contains("撤销") }), "文件修改明确可撤销")
    }

    // MARK: - 12. 后台任务来源归属

    private static func testBackgroundSourceAttribution() {
        let currentID = UUID()
        assertTest(
            ChatInteractionCenter.sourceLabel(
                sourceSessionID: currentID,
                currentSessionID: currentID,
                sessionTitle: "当前任务"
            ) == nil,
            "当前会话操作不显示冗余来源"
        )
        assertTest(
            ChatInteractionCenter.sourceLabel(
                sourceSessionID: currentID,
                currentSessionID: UUID(),
                sessionTitle: "当前任务"
            )?.contains("后台任务") == true,
            "请求挂起后切换会话会动态显示后台来源"
        )

        let secret = "source-secret-123456789"
        let backgroundLabel = ChatInteractionCenter.sourceLabel(
            sourceSessionID: UUID(),
            currentSessionID: currentID,
            sessionTitle: "Authorization: Bearer \(secret)"
        )
        assertTest(backgroundLabel?.contains("后台任务") == true, "后台会话操作明确标注来源")
        assertTest(backgroundLabel?.contains(secret) == false, "后台来源标题先脱敏再展示")
    }

    /// 故意只标注 parallelSafe，不声明 authorizationPolicy，用于验证协议默认值始终 fail-closed。
    private struct UndeclaredAuthorizationTool: AITool {
        let name = "undeclared_authorization_test"
        let displayName = "测试工具"
        let category: ToolCategory = .system
        let description = "测试默认授权策略"
        let executionPolicy: ToolExecutionPolicy = .parallelSafe
        let parametersSchema: [String: Any] = [
            "type": "object",
            "properties": [String: Any](),
            "required": [String]()
        ]

        func execute(arguments: [String: Any]) async throws -> String {
            "{\"ok\":true}"
        }
    }
}
