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
            "sw_vers"
        ]

        for cmd in safeCommands {
            let risk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": cmd])
            assertTest(risk == .readOnly, "只读命令判定免审直通：\(cmd)")
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
}
