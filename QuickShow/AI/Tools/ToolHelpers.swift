import Foundation

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

// MARK: - 工具动作意图提取器

/// 工具动作意图提取与自然语义解析器
enum ToolIntentExtractor {
    /// 从 arguments 字典提取动作意图（Action Intent）
    static func extractIntent(from arguments: [String: Any]?, fallbackToolName: String? = nil) -> String? {
        guard let arguments = arguments else {
            return fallbackIntent(toolName: fallbackToolName)
        }
        // 1. 优先取 description（统一规范）
        if let desc = arguments["description"] as? String {
            let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // 2. 容错取 title 或 intent
        if let title = arguments["title"] as? String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let intent = arguments["intent"] as? String {
            let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // 3. 兜底回退为参数上下文智能语义
        return fallbackIntent(toolName: fallbackToolName, arguments: arguments)
    }

    /// 从 argumentsJSON 文本解析并提取动作意图
    static func extractIntent(from argumentsJSON: String, fallbackToolName: String? = nil) -> String? {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return fallbackIntent(toolName: fallbackToolName)
        }
        return extractIntent(from: dict, fallbackToolName: fallbackToolName)
    }

    /// 兜底人类可读意图（当模型因偶发原因未输出 description 时）
    static func fallbackIntent(toolName: String?, arguments: [String: Any]? = nil) -> String? {
        guard let toolName = toolName else { return nil }
        let tool = AIToolRegistry.shared.tool(named: toolName)
        let display = tool?.displayName ?? toolName

        switch toolName {
        case "run_shell", "shell":
            if let cmd = arguments?["command"] as? String, !cmd.isEmpty {
                let firstLine = cmd.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? cmd
                let cleaned = firstLine.count <= 60 ? firstLine : String(firstLine.prefix(60)) + "…"
                return "执行命令: \(cleaned)"
            }
            return "执行终端 Shell 命令"
        case "write_file":
            if let path = arguments?["path"] as? String, !path.isEmpty {
                let filename = URL(fileURLWithPath: path).lastPathComponent
                return "写入文件: \(filename)"
            }
            return "写入文件"
        case "read_file":
            if let path = arguments?["path"] as? String, !path.isEmpty {
                let filename = URL(fileURLWithPath: path).lastPathComponent
                return "读取文件: \(filename)"
            }
            return "读取文件"
        case "preview_file":
            if let path = arguments?["path"] as? String, !path.isEmpty {
                let filename = URL(fileURLWithPath: path).lastPathComponent
                return "预览文件: \(filename)"
            }
            return "快速预览文件"
        case "web_search":
            if let q = arguments?["query"] as? String, !q.isEmpty {
                return "搜索网络: \(q)"
            }
            return "网页搜索"
        case "fetch_url":
            if let u = arguments?["url"] as? String, !u.isEmpty {
                return "抓取网页: \(u)"
            }
            return "抓取网页内容"
        default:
            return display
        }
    }
}
