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
        testShellQuotedSafety()
        testShellMutationScopeExtraction()
        testFileRiskEvaluation()
        testPolicyEngineRuleMatching()
        testPolicyEngineDevCommands()
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
            "git blame -L 1,10 main.swift",
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
            "jq '.name' package.json",
            "awk '{print $1}' access.log",
            "sed -n '1,5p' notes.txt",
            "FOO=1 ls",
            "/usr/bin/git status",
            "cd web && git status",
            "env",
            "env FOO=1 node --version",
            "find . | xargs grep TODO",
            "grep 'sudo' /var/log/system.log",
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
            "defaults write -g Key test",
            "find . -delete",
            "sed -i 's/a/b/' file.txt",
            "git branch -d feature",
            "git remote add upstream https://example.com/repo.git",
            "curl https://example.com"
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

        // 引号内的危险词不应触发破坏性，也不影响只读判定
        let quotedReadOnlyCommands = [
            "echo 'sudo && reboot 的说明文档'",
            "echo \"rm -rf 只是文档示例\"",
            "cat 'my;file.txt'",
            "echo \"a && b\""
        ]
        for cmd in quotedReadOnlyCommands {
            let risk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": cmd])
            assertTest(risk == .readOnly, "引号包裹的危险词不改变只读判定：\(cmd)")
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

    // MARK: - 4. 受控变更命令与作用域建议测试

    private static func testShellMutationScopeExtraction() {
        let evaluator = ShellSemanticRiskEvaluator()
        let shellTool = RunShellTool()

        // 常规前缀建议（非策展目录命令）
        let prefixCases: [(String, String)] = [
            ("git commit -m 'feat: update'", "git"),
            ("npm install lodash", "npm"),
            ("python script.py", "python"),
            ("docker build -t app .", "docker")
        ]
        for (cmd, expectedPrefix) in prefixCases {
            let risk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": cmd])
            if case .scopedMutation(let scope) = risk,
               case .shellPrefix(let prefix) = scope {
                assertTest(prefix == expectedPrefix, "正确提取前缀 [\(expectedPrefix)]：\(cmd)")
            } else {
                assertTest(false, "未能提取受控变更前缀：\(cmd)")
            }
        }

        // 复合命令：取首个非只读单元的执行词（cd 等只读单元不再污染前缀建议）
        let compoundCase = "cd web && pnpm run build"
        let compoundRisk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": compoundCase])
        if case .scopedMutation(let scope) = compoundRisk {
            assertTest(scope == .devCommands || {
                if case .shellPrefix(let prefix) = scope { return prefix == "pnpm" }
                return false
            }(), "复合命令前缀取自首个变更单元：\(compoundCase)")
        } else {
            assertTest(false, "复合命令应判为受控变更：\(compoundCase)")
        }

        // 策展开发命令：建议 devCommands 一键信任作用域
        let devCommandCases = [
            "swift build -c release",
            "pnpm run test",
            "cargo build",
            "xcodebuild test -scheme QuickShow",
            "go test ./..."
        ]
        for cmd in devCommandCases {
            let risk = evaluator.evaluateRisk(tool: shellTool, arguments: ["command": cmd])
            if case .scopedMutation(let scope) = risk {
                assertTest(scope == .devCommands, "策展开发命令建议 devCommands 作用域：\(cmd)")
            } else {
                assertTest(false, "策展开发命令应为受控变更：\(cmd)")
            }
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

    // MARK: - 6. 规则引擎放行与记忆测试（逐命令单元匹配）

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

        // 3.1 复合命令逐单元匹配：只读单元直通 + 变更单元命中前缀
        let compoundCmd = "cd web && pnpm build"
        let compoundRisk = ToolRiskClassifier.shared.evaluateRisk(tool: shellTool, arguments: ["command": compoundCmd])
        assertTest(engine.isAllowed(tool: shellTool, arguments: ["command": compoundCmd], risk: compoundRisk), "复合命令命中前缀规则放行：\(compoundCmd)")

        // 3.2 复合命令中未覆盖的执行词仍拦截
        let uncoveredCmd = "cd web && npm test"
        let uncoveredRisk = ToolRiskClassifier.shared.evaluateRisk(tool: shellTool, arguments: ["command": uncoveredCmd])
        assertTest(!engine.isAllowed(tool: shellTool, arguments: ["command": uncoveredCmd], risk: uncoveredRisk), "未覆盖执行词的复合命令仍拦截：\(uncoveredCmd)")

        // 4. 高危命令即便有前缀也绝不放行（硬门禁）
        let hardCmd = "pnpm exec rm -rf /"
        let hardRisk = ToolRiskClassifier.shared.evaluateRisk(tool: shellTool, arguments: ["command": hardCmd])
        assertTest(!engine.isAllowed(tool: shellTool, arguments: ["command": hardCmd], risk: hardRisk), "破坏性命令即便命中前缀也绝不放行")

        // 5. 重置规则
        engine.resetRules()
        assertTest(!engine.isAllowed(tool: shellTool, arguments: ["command": testCmd], risk: risk), "重置后规则失效")
    }

    // MARK: - 7. devCommands 信任作用域测试

    private static func testPolicyEngineDevCommands() {
        let engine = ToolPermissionPolicyEngine.shared
        engine.resetRules()

        let shellTool = RunShellTool()

        func allowed(_ cmd: String) -> Bool {
            let risk = ToolRiskClassifier.shared.evaluateRisk(tool: shellTool, arguments: ["command": cmd])
            return engine.isAllowed(tool: shellTool, arguments: ["command": cmd], risk: risk)
        }

        // 1. 授予 devCommands 作用域
        engine.recordRule(.devCommands)

        // 2. 策展目录内命令：放行
        assertTest(allowed("swift build"), "devCommands 放行：swift build")
        assertTest(allowed("xcodebuild test -scheme QuickShow"), "devCommands 放行：xcodebuild test")
        assertTest(allowed("pnpm run build"), "devCommands 放行：pnpm run build")
        assertTest(allowed("cargo test"), "devCommands 放行：cargo test")
        assertTest(allowed("cd web && swift test"), "devCommands 放行复合命令：cd web && swift test")

        // 3. 目录外命令（install 等未策展子命令）仍拦截
        assertTest(!allowed("pnpm install lodash"), "devCommands 不覆盖未策展子命令：pnpm install")
        assertTest(!allowed("python deploy.py"), "devCommands 不覆盖非策展命令：python deploy.py")

        engine.resetRules()
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

    // MARK: - 9. 旁路大模型守卫三档裁决解析测试

    private static func testShadowGuardDecisionParsing() {
        let guardrail = AIToolShadowGuard.shared

        // 1. 标准 JSON 解析
        assertTest(guardrail.parseVerdict(from: "{\"verdict\":\"readonly\"}") == .readonly, "标准 JSON 只读裁决成功")
        assertTest(guardrail.parseVerdict(from: "{\"verdict\":\"low_risk\"}") == .lowRiskMutation, "标准 JSON 低危变更裁决成功")
        assertTest(guardrail.parseVerdict(from: "{\"verdict\":\"needs_approval\",\"reason\":\"覆盖系统配置\"}") == .needsApproval, "标准 JSON 需审批裁决成功")

        // 2. Markdown 代码块包裹
        let mdJson = """
        ```json
        {
            "verdict": "low_risk",
            "reason": "项目内构建"
        }
        ```
        """
        assertTest(guardrail.parseVerdict(from: mdJson) == .lowRiskMutation, "Markdown 包裹 JSON 裁决解析成功")

        // 3. 容错包含文本判定
        let textWrapped = "审查结果如下：\n{\"verdict\": \"readonly\"}\n可放行"
        assertTest(guardrail.parseVerdict(from: textWrapped) == .readonly, "带外围说明文字的 JSON 裁决解析成功")

        let dangerText = "评估结果：该命令修改系统配置，不可自动放行\n{\"verdict\": \"needs_approval\"}"
        assertTest(guardrail.parseVerdict(from: dangerText) == .needsApproval, "带外围说明文字的审批拦截成功")

        // 4. 无法判定时按需审批兜底
        assertTest(guardrail.parseVerdict(from: "我觉得没问题") == nil, "无法判定文本返回 nil（按需审批兜底）")

        // 5. 免审批语义：readonly 与 low_risk 可放行，needsApproval 不可
        assertTest(ShadowGuardVerdict.readonly.isAutoApprovable && ShadowGuardVerdict.lowRiskMutation.isAutoApprovable, "readonly 与 low_risk 均可免审放行")
        assertTest(!ShadowGuardVerdict.needsApproval.isAutoApprovable, "needsApproval 不可免审放行")
    }
}
