import Foundation

// MARK: - 面向普通用户的操作影响说明

struct ToolImpactItem: Equatable, Sendable, Identifiable {
    let id: String
    let systemImage: String
    let text: String

    init(systemImage: String, text: String) {
        self.id = systemImage + "|" + text
        self.systemImage = systemImage
        self.text = text
    }
}

struct ToolConfirmationPresentation: Equatable, Sendable {
    let title: String
    let primaryActionTitle: String
    let impacts: [ToolImpactItem]
    let technicalDetailsTitle: String

    static func make(for request: ToolConfirmationRequest) -> ToolConfirmationPresentation {
        let arguments = parseArguments(request.argumentsJSON)
        let containsSensitiveValue = SensitiveTextRedactor.containsSensitiveValue(in: request.argumentsJSON)

        switch request.toolName {
        case "write_file":
            let path = arguments["path"] as? String ?? ""
            let filename = URL(fileURLWithPath: path).lastPathComponent
            let displayFilename = filename.isEmpty ? String(localized: "当前文件") : filename
            let existed = !path.isEmpty && FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
            let changeText = existed
                ? String(localized: "将更新“\(displayFilename)”中的内容")
                : String(localized: "将新建文件“\(displayFilename)”")
            return ToolConfirmationPresentation(
                title: String(localized: "要应用这项修改吗？"),
                primaryActionTitle: String(localized: "应用修改"),
                impacts: [
                    ToolImpactItem(systemImage: "doc.text", text: changeText),
                    ToolImpactItem(systemImage: "arrow.uturn.backward", text: String(localized: "应用后可在当前运行期间立即撤销"))
                ],
                technicalDetailsTitle: technicalTitle(containsSensitiveValue: containsSensitiveValue)
            )

        case "run_shell", "shell":
            let command = arguments["command"] as? String ?? ""
            return shellPresentation(
                command: command,
                risk: request.riskLevel,
                containsSensitiveValue: containsSensitiveValue
            )

        case "read_file", "preview_file":
            let path = arguments["path"] as? String ?? ""
            let filename = URL(fileURLWithPath: path).lastPathComponent
            let displayFilename = filename.isEmpty ? String(localized: "本地文件") : filename
            return ToolConfirmationPresentation(
                title: String(localized: "要打开“\(displayFilename)”吗？"),
                primaryActionTitle: String(localized: "仅允许这一次"),
                impacts: [
                    ToolImpactItem(systemImage: "doc.text.magnifyingglass", text: String(localized: "文件内容可能包含个人或工作信息"))
                ],
                technicalDetailsTitle: technicalTitle(containsSensitiveValue: containsSensitiveValue)
            )

        case "launch_subagents":
            return ToolConfirmationPresentation(
                title: String(localized: "要把任务交给其他 AI 吗？"),
                primaryActionTitle: String(localized: "仅允许这一次"),
                impacts: [
                    ToolImpactItem(systemImage: "person.2", text: String(localized: "任务内容会发送给其他 AI；相关附件也可能一并发送"))
                ],
                technicalDetailsTitle: technicalTitle(containsSensitiveValue: containsSensitiveValue)
            )

        case "send_message":
            return ToolConfirmationPresentation(
                title: String(localized: "要把这段内容发给其他 AI 吗？"),
                primaryActionTitle: String(localized: "仅允许这一次"),
                impacts: [
                    ToolImpactItem(systemImage: "paperplane", text: String(localized: "消息内容会离开当前对话并发送给另一个 AI"))
                ],
                technicalDetailsTitle: technicalTitle(containsSensitiveValue: containsSensitiveValue)
            )

        case "web_search", "fetch_url":
            let detail: String
            if request.toolName == "web_search" {
                detail = String(localized: "将把搜索内容发送到外部搜索服务")
            } else if let rawURL = arguments["url"] as? String,
                      let host = URL(string: rawURL)?.host {
                detail = String(localized: "将连接 \(host) 并读取网页内容")
            } else {
                detail = String(localized: "将连接外部网站并读取网页内容")
            }
            return ToolConfirmationPresentation(
                title: String(localized: "要连接外部服务吗？"),
                primaryActionTitle: String(localized: "仅允许这一次"),
                impacts: [ToolImpactItem(systemImage: "network", text: detail)],
                technicalDetailsTitle: technicalTitle(containsSensitiveValue: containsSensitiveValue)
            )

        case "geocode", "search_places", "plan_route":
            return ToolConfirmationPresentation(
                title: String(localized: "要使用位置相关服务吗？"),
                primaryActionTitle: String(localized: "仅允许这一次"),
                impacts: [
                    ToolImpactItem(systemImage: "map", text: String(localized: "将把地点或路线信息发送到外部地图服务"))
                ],
                technicalDetailsTitle: technicalTitle(containsSensitiveValue: containsSensitiveValue)
            )

        case "my_location":
            return ToolConfirmationPresentation(
                title: String(localized: "要读取当前位置吗？"),
                primaryActionTitle: String(localized: "仅允许这一次"),
                impacts: [
                    ToolImpactItem(systemImage: "location.fill", text: String(localized: "当前位置会用于完成当前任务"))
                ],
                technicalDetailsTitle: technicalTitle(containsSensitiveValue: containsSensitiveValue)
            )

        case "read_clipboard":
            return ToolConfirmationPresentation(
                title: String(localized: "要读取剪贴板内容吗？"),
                primaryActionTitle: String(localized: "仅允许这一次"),
                impacts: [
                    ToolImpactItem(systemImage: "doc.on.clipboard", text: String(localized: "剪贴板可能包含刚刚复制的个人内容"))
                ],
                technicalDetailsTitle: technicalTitle(containsSensitiveValue: containsSensitiveValue)
            )

        case "write_clipboard":
            return ToolConfirmationPresentation(
                title: String(localized: "要替换剪贴板内容吗？"),
                primaryActionTitle: String(localized: "确认替换"),
                impacts: [
                    ToolImpactItem(systemImage: "clipboard", text: String(localized: "当前剪贴板内容将被新的结果替换"))
                ],
                technicalDetailsTitle: technicalTitle(containsSensitiveValue: containsSensitiveValue)
            )

        case "get_env", "list_env":
            return ToolConfirmationPresentation(
                title: String(localized: "要读取电脑上的环境信息吗？"),
                primaryActionTitle: String(localized: "仅允许这一次"),
                impacts: [
                    ToolImpactItem(systemImage: "key.fill", text: String(localized: "环境信息可能包含账号或服务凭证"))
                ],
                technicalDetailsTitle: technicalTitle(containsSensitiveValue: true)
            )

        case "set_env":
            return ToolConfirmationPresentation(
                title: String(localized: "要保存这项环境设置吗？"),
                primaryActionTitle: String(localized: "确认保存"),
                impacts: [
                    ToolImpactItem(systemImage: "gearshape", text: String(localized: "这项设置会保存在 QuickShow 中"))
                ],
                technicalDetailsTitle: technicalTitle(containsSensitiveValue: true)
            )

        case "open_app":
            let appName = (arguments["name"] as? String) ?? (arguments["app"] as? String) ?? String(localized: "应用")
            return ToolConfirmationPresentation(
                title: String(localized: "要打开“\(appName)”吗？"),
                primaryActionTitle: String(localized: "打开"),
                impacts: [
                    ToolImpactItem(systemImage: "macwindow", text: String(localized: "将切换到另一个应用"))
                ],
                technicalDetailsTitle: technicalTitle(containsSensitiveValue: containsSensitiveValue)
            )

        default:
            let destructiveReason: String?
            if case .destructive(let reason) = request.riskLevel {
                destructiveReason = reason
            } else {
                destructiveReason = nil
            }
            let impacts = [
                ToolImpactItem(
                    systemImage: "wand.and.stars",
                    text: String(localized: "QuickShow 将只执行当前这一次操作")
                )
            ]
            return ToolConfirmationPresentation(
                title: destructiveReason == nil
                    ? String(localized: "要允许这次操作吗？")
                    : String(localized: "要执行这项高风险操作吗？"),
                primaryActionTitle: destructiveReason == nil
                    ? String(localized: "仅允许这一次")
                    : String(localized: "确认执行"),
                impacts: impacts,
                technicalDetailsTitle: technicalTitle(containsSensitiveValue: containsSensitiveValue)
            )
        }
    }

    private static func shellPresentation(
        command: String,
        risk: ToolRiskLevel,
        containsSensitiveValue: Bool
    ) -> ToolConfirmationPresentation {
        let units = ShellCommandParser.parseUnits(command)
        let executableWords = Set(units.map { $0.forwardingAnalysis.word }.filter { !$0.isEmpty })
        let networkCommands: Set<String> = ["curl", "wget", "ssh", "scp", "rsync", "nc", "ncat", "ftp"]
        let fileChangingCommands: Set<String> = ["cp", "mv", "rm", "mkdir", "rmdir", "touch", "tee", "install", "chmod", "chown"]
        let domains = externalDomains(in: command)
        let usesNetwork = !domains.isEmpty || !executableWords.isDisjoint(with: networkCommands)
        let mayChangeFiles = units.contains(where: { $0.hasFileWritingRedirection })
            || !executableWords.isDisjoint(with: fileChangingCommands)

        var impacts = [
            ToolImpactItem(
                systemImage: "desktopcomputer",
                text: String(localized: "将在这台 Mac 上运行一项系统操作")
            )
        ]

        if usesNetwork {
            let destination: String
            if domains.isEmpty {
                destination = String(localized: "将连接外部服务，可能发送本机数据")
            } else if domains.count == 1, let domain = domains.first {
                destination = String(localized: "将连接 \(domain)，可能发送本机数据")
            } else {
                destination = String(localized: "将连接 \(domains.joined(separator: "、"))，可能发送本机数据")
            }
            impacts.append(ToolImpactItem(systemImage: "network", text: destination))
        }

        if mayChangeFiles {
            impacts.append(
                ToolImpactItem(systemImage: "doc.badge.ellipsis", text: String(localized: "可能创建、修改或删除本地文件"))
            )
        }

        if containsSensitiveValue {
            impacts.append(
                ToolImpactItem(
                    systemImage: "key.fill",
                    text: String(localized: "操作会使用凭证；敏感值已在详情中隐藏")
                )
            )
        }

        return ToolConfirmationPresentation(
            title: risk.isDestructive
                ? String(localized: "要执行这项高风险系统操作吗？")
                : String(localized: "要执行这项系统操作吗？"),
            primaryActionTitle: risk.isDestructive
                ? String(localized: "确认执行")
                : String(localized: "仅执行这一次"),
            impacts: impacts,
            technicalDetailsTitle: technicalTitle(containsSensitiveValue: containsSensitiveValue)
        )
    }

    private static func technicalTitle(containsSensitiveValue: Bool) -> String {
        containsSensitiveValue
            ? String(localized: "技术详情（敏感信息已隐藏）")
            : String(localized: "查看技术详情")
    }

    private static func parseArguments(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func externalDomains(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s\"'\\]+"#, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var domains = Set<String>()
        for match in regex.matches(in: text, options: [], range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let rawURL = String(text[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;]}"))
            if let host = URL(string: rawURL)?.host, !host.isEmpty {
                domains.insert(host)
            }
        }
        return domains.sorted()
    }
}
