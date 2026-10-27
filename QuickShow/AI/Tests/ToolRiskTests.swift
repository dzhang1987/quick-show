import Foundation

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

    static func run() {
        print("==================================================")
        print("🛡️ 开始执行工具风险评估与权限策略规则测试")
        print("==================================================")
        passedCount = 0
        failedCount = 0

        testShellReadOnlyEvaluation()
        testShellDestructiveEvaluation()
        testShellMutationPrefixExtraction()
        testFileRiskEvaluation()
        testPolicyEngineRuleMatching()
        testUndoSnapshotLifecycle()
        testShadowGuardDecisionParsing()

        print("==================================================")
        print("📊 权限测试完成汇总：通过 \(passedCount) 项，失败 \(failedCount) 项")
        print("==================================================")
        assert(failedCount == 0, "存在未通过的权限策略测试用例")
    }

    // MARK: - 1. 只读 Shell 启发式评估测试

    private static func testShellReadOnlyEvaluation() {
        let evaluator = ShellSemanticRiskEvaluator()
        let shellTool = RunShellTool()

        let safeCommands = [
            "pwd",
            "ls -la",
            "cat README.md",
            "git status",
            "git diff HEAD~1",
            "git log -n 5 --oneline",
            "pnpm list",
            "cargo check",
            "which swift",
            "sw_vers",
            "zsh --version",
            "bash --version",
            "arch",
            "hostname",
            "id",
            "sysctl -n machdep.cpu.brand_string 2>/dev/null",
            "uname -m >/dev/null 2>&1",
            "vm_stat | head -6",
            "pmset -g batt",
            "defaults read -g AppleInterfaceStyle",
            "echo '=== who/where ==='; whoami; pwd; echo; echo '=== macOS ==='; sw_vers; echo; echo '=== arch / chip ==='; uname -m; sysctl -n machdep.cpu.brand_string 2>/dev/null; echo; echo '=== shell ==='; echo $SHELL; zsh --version",
            "echo '=== uptime ==='; uptime; echo; echo '=== mem (GB) ==='; echo \"total: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB\"; vm_stat | head -6; echo; echo '=== battery ==='; pmset -g batt; echo; echo '=== cpu top5 ==='; ps -Ao %cpu,comm -r | head -6; echo; echo '=== cpu brand/cores ==='; sysctl -n machdep.cpu.brand_string; sysctl -n hw.ncpu hw.perflevel0.physicalcpu hw.perflevel1.physicalcpu 2>/dev/null"
        ]

        for cmd in safeCommands {
            let risk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": cmd])
            assertTest(risk == .readOnly, "只读命令判定免审直通：\(cmd)")
        }

        // 反向校验：包含真实文件写入或危险内核配置修改的不可免审
        let nonReadOnlyCommands = [
            "echo 'test' > output.txt",
            "ls -la >> list.log",
            "sysctl -w net.inet.ip.forwarding=1",
            "sysctl debug.test=1",
            "pmset sleep 0",
            "defaults write -g Key test"
        ]
        for cmd in nonReadOnlyCommands {
            let risk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": cmd])
            assertTest(risk != .readOnly, "非只读或修改型命令被成功拦截：\(cmd)")
        }
    }

    // MARK: - 2. 破坏性 Shell 识别与硬拦截测试

    private static func testShellDestructiveEvaluation() {
        let evaluator = ShellSemanticRiskEvaluator()
        let shellTool = RunShellTool()

        let dangerousCommands = [
            "rm -rf /tmp/foo",
            "rm -r .git",
            "sudo rm -rf /",
            "git reset --hard HEAD~1",
            "git clean -fd",
            "git push origin main --force",
            "echo 'hacked' > ~/.zshrc",
            "reboot"
        ]

        for cmd in dangerousCommands {
            let risk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": cmd])
            assertTest(risk.isDestructive, "破坏性高危命令硬拦截：\(cmd)")
        }
    }

    // MARK: - 3. 受控变更命令与前缀提取测试

    private static func testShellMutationPrefixExtraction() {
        let evaluator = ShellSemanticRiskEvaluator()
        let shellTool = RunShellTool()

        let mutationCases: [(String, String)] = [
            ("pnpm run test", "pnpm"),
            ("git commit -m 'feat: update'", "git"),
            ("swift build -c release", "swift"),
            ("cargo build", "cargo"),
            ("npm install lodash", "npm")
        ]

        for (cmd, expectedPrefix) in mutationCases {
            let risk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": cmd])
            if case .scopedMutation(let scope) = risk,
               case .shellPrefix(let prefix) = scope {
                assertTest(prefix == expectedPrefix, "正确提取前缀 [\(expectedPrefix)]：\(cmd)")
            } else {
                assertTest(false, "未能提取受控变更前缀：\(cmd)")
            }
        }
    }

    // MARK: - 4. 文件写入目标风险评估测试

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

        // 正常工程目录受控写入
        let normalPath = "/Users/admin/Projects/quick-time/Package.swift"
        let normalRisk = evaluator.evaluateRisk(tool: writeTool, arguments: ["path": normalPath, "content": "bar"])
        if case .scopedMutation(let scope) = normalRisk,
           case .directoryPath(let dir) = scope {
            assertTest(dir == "/Users/admin/Projects/quick-time", "正确推导目录作用域：\(normalPath)")
        } else {
            assertTest(false, "未能正确推导工程目录作用域")
        }
    }

    // MARK: - 5. 规则引擎放行与记忆测试

    private static func testPolicyEngineRuleMatching() {
        let engine = ToolPermissionPolicyEngine.shared
        engine.resetRules()

        let shellTool = RunShellTool()
        let testCmd = "pnpm run test"
        let risk = ToolRiskClassifier.shared.evaluateRisk(tool: shellTool, arguments: ["command": testCmd])

        // 1. 未授权前：拦截
        assertTest(!engine.isAllowed(tool: shellTool, arguments: ["command": testCmd], risk: risk), "初始状态未授权拦截")

        // 2. 注入 pnpm 前缀规则
        engine.recordRule(.shellPrefix(prefix: "pnpm"))

        // 3. 授权后：同前缀命令全部放行
        assertTest(engine.isAllowed(tool: shellTool, arguments: ["command": testCmd], risk: risk), "命中前缀规则放行：\(testCmd)")
        assertTest(engine.isAllowed(tool: shellTool, arguments: ["command": "pnpm run build"], risk: risk), "同前缀其他命令自动放行：pnpm run build")

        // 4. 高危命令即便有前缀也绝不放行（硬门禁）
        let hardCmd = "pnpm exec rm -rf /"
        let hardRisk = ToolRiskClassifier.shared.evaluateRisk(tool: shellTool, arguments: ["command": hardCmd])
        assertTest(!engine.isAllowed(tool: shellTool, arguments: ["command": hardCmd], risk: hardRisk), "破坏性命令即便命中前缀也绝不放行")

        // 5. 重置规则
        engine.resetRules()
        assertTest(!engine.isAllowed(tool: shellTool, arguments: ["command": testCmd], risk: risk), "重置后规则失效")
    }

    // MARK: - 6. 文件覆盖快照与撤销还原测试

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
            let token = manager.createSnapshot(path: tempPath)
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
        } catch {
            assertTest(false, "撤销快照测试抛错：\(error.localizedDescription)")
        }
    }

    // MARK: - 7. 旁路大模型守卫决策解析测试

    private static func testShadowGuardDecisionParsing() {
        let guardrail = AIToolShadowGuard.shared

        // 1. 标准 JSON 解析
        assertTest(guardrail.parseAuditDecision(from: "{\"is_safe\": true}") == true, "标准 JSON 安全判定成功")
        assertTest(guardrail.parseAuditDecision(from: "{\"is_safe\": false, \"reason\": \"write file\"}") == false, "标准 JSON 风险拦截判定成功")

        // 2. Markdown 代码块包裹
        let mdJson = """
        ```json
        {
            "is_safe": true,
            "reason": "only reads battery"
        }
        ```
        """
        assertTest(guardrail.parseAuditDecision(from: mdJson) == true, "Markdown 包裹 JSON 安全解析成功")

        // 3. 容错包含文本判定
        let textWrapped = "审查结果如下：\n{\"is_safe\": true}\n请放行"
        assertTest(guardrail.parseAuditDecision(from: textWrapped) == true, "带外围说明文字的 JSON 安全解析成功")

        let dangerText = "评估结果：该命令可能产生文件修改\n{\"is_safe\": false}"
        assertTest(guardrail.parseAuditDecision(from: dangerText) == false, "带外围说明文字的 JSON 拦截成功")
    }
}
