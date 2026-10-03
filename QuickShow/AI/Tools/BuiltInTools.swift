import AppKit
import Foundation
import Darwin

// MARK: - 文件级辅助

/// 统一的成功结果包装：{"ok":true,"data":...}
/// 供同模块其他工具文件（如 WebTools）复用，故为 internal
func toolSuccessJSON(_ payload: Any) -> String {
    let object: [String: Any] = ["ok": true, "data": payload]
    guard JSONSerialization.isValidJSONObject(object),
          let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: encoded, encoding: .utf8) else {
        return "{\"ok\":true,\"data\":null}"
    }
    return text
}

/// 取必填字符串参数；缺失或类型不符抛错（供 WebTools 等工具文件复用）
func requiredString(_ arguments: [String: Any], _ key: String) throws -> String {
    guard let value = arguments[key], !(value is NSNull) else {
        throw ToolExecutionError("缺少必填参数：\(key)")
    }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    throw ToolExecutionError("参数 \(key) 类型错误，应为字符串")
}

/// 取可选字符串参数
private func optionalString(_ arguments: [String: Any], _ key: String) -> String? {
    if let string = arguments[key] as? String { return string }
    if let number = arguments[key] as? NSNumber { return number.stringValue }
    return nil
}

private func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
private func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

/// 布尔偏好读取：键缺失时回退到 App 默认值（@AppStorage 不会写入默认值）
private func boolSetting(_ defaults: UserDefaults, _ key: String, fallingBack fallback: Bool) -> Bool {
    (defaults.object(forKey: key) as? Bool) ?? fallback
}

// MARK: - 文件白名单

/// 白名单配置键：允许访问的目录数组
private let fileWhitelistKey = "ai.tools.fileWhitelist"

/// 校验路径落在白名单目录（或其子目录）内，返回标准化且解析软链后的 URL。
/// 采用标准化路径比较，阻止 ../ 逃逸；软链会被解析后再做前缀校验。
private func resolveWhitelistedURL(_ rawPath: String) throws -> URL {
    let expanded = (rawPath as NSString).expandingTildeInPath
    guard !expanded.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw ToolExecutionError("路径为空")
    }
    let target = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()

    let directories = UserDefaults.standard.stringArray(forKey: fileWhitelistKey) ?? []
    guard !directories.isEmpty else {
        throw ToolExecutionError("未配置可访问目录白名单（UserDefaults 键 \(fileWhitelistKey)），已拒绝访问")
    }

    for directory in directories {
        let dirExpanded = (directory as NSString).expandingTildeInPath
        guard !dirExpanded.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        let base = URL(fileURLWithPath: dirExpanded).standardizedFileURL.resolvingSymlinksInPath()
        let basePath = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        if target.path == basePath || target.path.hasPrefix(basePath + "/") {
            return target
        }
    }
    throw ToolExecutionError("路径不在白名单目录内，已拒绝访问：\(rawPath)")
}

// MARK: - 1. 读取剪贴板

/// 读取系统剪贴板文本，并检测是否包含图片
final class ReadClipboardTool: AITool {
    let name = "read_clipboard"
    /// 纯读剪贴板，无共享可变状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
    let description = "读取系统剪贴板中的文本内容，并检测剪贴板是否包含图片。"
    var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any](), "required": [String]()]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let snapshot: (text: String?, hasImage: Bool) = await MainActor.run {
            let pasteboard = NSPasteboard.general
            let imageTypes: Set<NSPasteboard.PasteboardType> = [.tiff, .png]
            let hasImage = pasteboard.types?.contains(where: { imageTypes.contains($0) }) ?? false
            return (pasteboard.string(forType: .string), hasImage)
        }
        let text: Any = snapshot.text ?? NSNull()
        return toolSuccessJSON(["text": text, "has_image": snapshot.hasImage])
    }
}

// MARK: - 2. 写入剪贴板

/// 将文本写入系统剪贴板
final class WriteClipboardTool: AITool {
    let name = "write_clipboard"
    let description = "将指定文本写入系统剪贴板（覆盖现有内容）。"
    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "要写入剪贴板的文本内容"]
            ],
            "required": ["text"]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let text = try requiredString(arguments, "text")
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        return toolSuccessJSON(["written": true, "length": text.count])
    }
}

// MARK: - 3. 系统状态

/// 获取宿主 Mac 的实时系统状态快照（CPU / 内存 / 电池 / 网络 / 磁盘）
final class SystemStatusTool: AITool {
    let name = "get_system_status"
    let description = "获取宿主 Mac 的实时系统状态快照，包括 CPU 使用率、内存、电池、网络与磁盘。可用 section 参数只取其中一项。"
    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "section": [
                    "type": "string",
                    "enum": ["cpu", "memory", "battery", "network", "disk"],
                    "description": "可选，仅返回指定类别的状态；不传则返回全部"
                ]
            ],
            "required": [String]()
        ]
    }

    private static let sections = ["cpu", "memory", "battery", "network", "disk"]

    func execute(arguments: [String: Any]) async throws -> String {
        let section = optionalString(arguments, "section")?.lowercased()
        if let section, !Self.sections.contains(section) {
            throw ToolExecutionError("不支持的 section：\(section)，可选值为 \(Self.sections.joined(separator: "/"))")
        }

        let provider = SystemStatusProvider.shared
        let all = (section == nil)
        var result: [String: Any] = [:]

        // CPU / 内存共用一次性能采样
        if all || section == "cpu" || section == "memory" {
            let performance = provider.getSystemPerformanceInfo()
            if all || section == "cpu" {
                result["cpu"] = ["usage_percent": round1(performance.cpuUsage)]
            }
            if all || section == "memory" {
                result["memory"] = [
                    "usage_percent": round1(performance.memoryUsagePercent),
                    "used_gb": round2(performance.memoryUsedGB),
                    "total_gb": round2(performance.memoryTotalGB)
                ]
            }
        }

        if all || section == "battery" {
            let battery = provider.getBatteryInfo()
            result["battery"] = [
                "percentage": battery.percentage,
                "is_charging": battery.isCharging,
                "is_on_ac_power": battery.isOnACPower,
                "has_battery": battery.hasBattery
            ]
        }

        if all || section == "network" {
            let wifi = provider.getWiFiInfo()
            let traffic = provider.getNetworkTrafficInfo()
            let ssid: Any = wifi.ssid ?? NSNull()
            result["network"] = [
                "wifi_connected": wifi.isConnected,
                "wifi_ssid": ssid,
                "download_speed": traffic.downloadSpeed,
                "upload_speed": traffic.uploadSpeed
            ]
        }

        if all || section == "disk" {
            let disk = provider.getDiskInfo()
            result["disk"] = [
                "free_gb": round2(disk.freeGB),
                "total_gb": round2(disk.totalGB)
            ]
        }

        return toolSuccessJSON(result)
    }
}

// MARK: - 4. 列出运行中的应用

/// 列出当前以常规方式运行的图形应用
final class ListRunningAppsTool: AITool {
    let name = "list_running_apps"
    /// 纯读运行中应用列表，无共享可变状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
    let description = "列出当前正在运行的常规图形应用（不含后台代理），返回应用名与 Bundle Identifier。"
    var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any](), "required": [String]()]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let apps: [[String: Any]] = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app -> [String: Any]? in
                    guard let appName = app.localizedName else { return nil }
                    return [
                        "name": appName,
                        "bundle_identifier": app.bundleIdentifier ?? ""
                    ]
                }
                .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        }
        return toolSuccessJSON(["apps": apps, "count": apps.count])
    }
}

// MARK: - 5. 打开应用

/// 按 Bundle Identifier 或应用名打开一个应用
final class OpenAppTool: AITool {
    let name = "open_app"
    let description = "打开指定应用。可通过 bundle_identifier 或 name 二选一指定目标。"
    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "bundle_identifier": ["type": "string", "description": "应用的 Bundle Identifier，如 com.apple.Safari"],
                "name": ["type": "string", "description": "应用显示名，如 Safari"]
            ],
            "required": [String]()
        ]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let bundleID = optionalString(arguments, "bundle_identifier")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = optionalString(arguments, "name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (bundleID?.isEmpty == false) || (appName?.isEmpty == false) else {
            throw ToolExecutionError("必须提供 bundle_identifier 或 name 之一")
        }

        let found: (url: URL, identifier: String?, displayName: String)? = await MainActor.run {
            var url: URL?
            if let bundleID, !bundleID.isEmpty {
                url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            } else if let appName, !appName.isEmpty {
                if let path = NSWorkspace.shared.fullPath(forApplication: appName) {
                    url = URL(fileURLWithPath: path)
                }
            }
            guard let target = url else { return nil }
            let bundle = Bundle(url: target)
            let display = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? target.deletingPathExtension().lastPathComponent
            NSWorkspace.shared.open(target)
            return (target, bundle?.bundleIdentifier, display)
        }

        guard let found else {
            throw ToolExecutionError("未找到要打开的应用：\(bundleID ?? appName ?? "")")
        }
        return toolSuccessJSON([
            "opened": true,
            "path": found.url.path,
            "bundle_identifier": found.identifier ?? "",
            "name": found.displayName
        ])
    }
}

// MARK: - 6. 读取文件

/// 读取白名单目录内的文本文件（≤ 200KB）
final class ReadFileTool: AITool {
    let name = "read_file"
    /// 纯读白名单文件，无共享可变状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
    let description = "读取白名单目录内的 UTF-8 文本文件，文件大小上限 200KB。"
    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "要读取的文件绝对路径（须在白名单目录内）"]
            ],
            "required": ["path"]
        ]
    }

    private static let maxBytes = 200 * 1024

    func execute(arguments: [String: Any]) async throws -> String {
        let path = try requiredString(arguments, "path")
        let url = try resolveWhitelistedURL(path)

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ToolExecutionError("文件不存在或不是普通文件：\(path)")
        }

        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxBytes else {
            throw ToolExecutionError("文件过大（\(size) 字节），超过 200KB 上限")
        }

        guard let data = try? Data(contentsOf: url) else {
            throw ToolExecutionError("读取文件失败：\(path)")
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw ToolExecutionError("文件不是 UTF-8 文本，无法读取：\(path)")
        }
        return toolSuccessJSON(["path": url.path, "size_bytes": size, "content": content])
    }
}

// MARK: - 7. 写入文件（危险）

/// 写入白名单目录内的文本文件（危险：可能覆盖内容）
final class WriteFileTool: AITool {
    let name = "write_file"
    let description = "将文本内容写入白名单目录内的文件（覆盖写入）。属于危险操作，执行前需用户确认。"
    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "要写入的文件绝对路径（须在白名单目录内）"],
                "content": ["type": "string", "description": "要写入的文本内容"]
            ],
            "required": ["path", "content"]
        ]
    }

    let isDangerous = true

    func execute(arguments: [String: Any]) async throws -> String {
        let path = try requiredString(arguments, "path")
        let content = try requiredString(arguments, "content")
        let url = try resolveWhitelistedURL(path)

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ToolExecutionError("写入文件失败：\(error.localizedDescription)")
        }
        return toolSuccessJSON(["path": url.path, "written_bytes": content.utf8.count])
    }
}

// MARK: - 8. 读取环境变量

/// 读取环境变量：优先自定义变量，其次进程环境
final class GetEnvTool: AITool {
    let name = "get_env"
    /// 纯读环境变量，无共享可变状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
    let description = "读取环境变量。先查 QuickShow 自定义变量，未命中再查系统进程环境变量。"
    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "key": ["type": "string", "description": "环境变量名"]
            ],
            "required": ["key"]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let key = try requiredString(arguments, "key")
        let custom = UserDefaults.standard.dictionary(forKey: envVarsKey) as? [String: String] ?? [:]
        if let value = custom[key] {
            return toolSuccessJSON(["key": key, "value": value, "source": "custom"])
        }
        if let value = ProcessInfo.processInfo.environment[key] {
            return toolSuccessJSON(["key": key, "value": value, "source": "process"])
        }
        throw ToolExecutionError("未找到环境变量：\(key)")
    }
}

/// 自定义环境变量存储键
private let envVarsKey = "ai.envVars"

// MARK: - 9. 设置环境变量

/// 写入 QuickShow 自定义环境变量存储
final class SetEnvTool: AITool {
    let name = "set_env"
    let description = "设置一个 QuickShow 自定义环境变量（存储于本地偏好，供 get_env 读取）。"
    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "key": ["type": "string", "description": "环境变量名"],
                "value": ["type": "string", "description": "环境变量值"]
            ],
            "required": ["key", "value"]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let key = try requiredString(arguments, "key")
        let value = try requiredString(arguments, "value")
        var custom = UserDefaults.standard.dictionary(forKey: envVarsKey) as? [String: String] ?? [:]
        custom[key] = value
        UserDefaults.standard.set(custom, forKey: envVarsKey)
        return toolSuccessJSON(["key": key, "value": value, "saved": true])
    }
}

// MARK: - 10. 列出环境变量名

/// 列出自定义变量名与进程环境变量名（不返回进程变量值，避免泄露敏感信息）
final class ListEnvTool: AITool {
    let name = "list_env"
    /// 纯读环境变量名列表，无共享可变状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
    let description = "列出 QuickShow 自定义环境变量名以及系统进程环境变量名（不返回进程变量的值）。"
    var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any](), "required": [String]()]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let custom = UserDefaults.standard.dictionary(forKey: envVarsKey) as? [String: String] ?? [:]
        let customKeys = custom.keys.sorted()
        let processKeys = ProcessInfo.processInfo.environment.keys.sorted()
        return toolSuccessJSON(["custom_keys": customKeys, "process_keys": processKeys])
    }
}

// MARK: - 11. QuickShow 宿主状态

/// 尽力而为返回宿主状态快照（窗口可见性、侧栏、模型、主题等）
final class QuickShowStateTool: AITool {
    let name = "get_quickshow_state"
    /// 纯读宿主状态快照，无共享可变状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
    let description = "获取 QuickShow 宿主应用的当前状态：面板/AI 窗是否可见、侧栏开关、当前模型、主题与外观等。"
    var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any](), "required": [String]()]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let defaults = UserDefaults.standard

        // 实时窗口可见性：NSApp.windows 中查找主面板（FloatingPanel）与 AI 窗（AIPanel）
        let visibility: (panel: Bool, aiWindow: Bool) = await MainActor.run {
            let panelVisible = NSApp.windows.contains { $0 is FloatingPanel && $0.isVisible }
            let aiVisible = NSApp.windows.contains { $0 is AIPanel && $0.isVisible }
            return (panelVisible, aiVisible)
        }

        var state: [String: Any] = [
            "panel_visible": visibility.panel,
            "ai_window_visible": visibility.aiWindow,
            "sidebar_visible": defaults.bool(forKey: "ai.sidebarVisible"),
            "show_seconds": boolSetting(defaults, "showSeconds", fallingBack: true),
            "is_24_hour_format": boolSetting(defaults, "is24HourFormat", fallingBack: true),
            "show_on_launch": boolSetting(defaults, "showOnLaunch", fallingBack: true)
        ]

        // 字符串类配置：键缺失用 null 占位，保持结构稳定
        state["current_model"] = defaults.string(forKey: "ai.selectedModel") ?? NSNull()
        state["api_protocol"] = defaults.string(forKey: "ai.apiProtocol") ?? NSNull()
        state["panel_scale_option"] = defaults.string(forKey: "panelScaleOption") ?? NSNull()
        state["theme_variant"] = defaults.string(forKey: "themeVariant") ?? NSNull()
        state["appearance_mode"] = defaults.string(forKey: "appearanceMode") ?? NSNull()

        return toolSuccessJSON(state)
    }
}

// MARK: - 12. 执行 Shell 命令（危险）

/// 执行 shell 命令（危险：可修改系统）
final class RunShellTool: AITool {
    let name = "run_shell"
    let description = "通过 zsh 执行一条 shell 命令，返回标准输出与标准错误的合并结果。可修改系统，属于危险工具。"
    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "command": ["type": "string", "description": "要执行的 shell 命令"]
            ],
            "required": ["command"]
        ]
    }

    let isDangerous = true

    private static let timeout: TimeInterval = 30
    private static let maxOutputBytes = 32 * 1024

    func execute(arguments: [String: Any]) async throws -> String {
        let command = try requiredString(arguments, "command")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Self.run(command: command))
            }
        }
    }

    /// 同步执行：进程超时 30 秒，输出合并 stdout/stderr 并按 32KB 截断
    private static func run(command: String) -> Result<String, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return .failure(ToolExecutionError("启动 shell 失败：\(error.localizedDescription)"))
        }

        // 并发读取合并输出：边读边截断，持续排空管道避免子进程写阻塞
        let handle = pipe.fileHandleForReading
        var output = Data()
        var truncated = false
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk: Data
                do {
                    guard let read = try handle.read(upToCount: 64 * 1024), !read.isEmpty else { break }
                    chunk = read
                } catch {
                    break
                }
                if output.count < maxOutputBytes {
                    let remain = maxOutputBytes - output.count
                    output.append(chunk.prefix(remain))
                    if chunk.count > remain { truncated = true }
                } else {
                    truncated = true
                }
            }
            readGroup.leave()
        }

        // 等待结束或超时；超时先 SIGTERM，仍不退则 SIGKILL
        var timedOut = false
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if semaphore.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        readGroup.wait()

        let text = String(decoding: output, as: UTF8.self)
        let exitCode = process.isRunning ? -1 : Int(process.terminationStatus)
        return .success(toolSuccessJSON([
            "command": command,
            "output": text,
            "exit_code": exitCode,
            "timed_out": timedOut,
            "truncated": truncated
        ]))
    }
}