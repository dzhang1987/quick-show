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
    /// 意图字段优先级（与字典版提取顺序一致）：description 为统一规范，title/intent 容错。
    /// 流式部分解析与完整解析共用同一份顺序契约。
    static let intentFieldPriority = ["description", "title", "intent"]
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
        guard !trimmed.isEmpty else {
            return fallbackIntent(toolName: fallbackToolName)
        }
        if let data = trimmed.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return extractIntent(from: dict, fallbackToolName: fallbackToolName)
        }
        // 完整解析失败但文本非空：多为流式参数尚未闭合（逐片生成期），
        // 尽早提取已完整到达的意图字段，驱动占位卡标题流式预显。
        if let intent = PartialJSONFieldScanner.firstStringValue(
            in: trimmed,
            keys: ToolIntentExtractor.intentFieldPriority
        ) {
            return intent
        }
        return fallbackIntent(toolName: fallbackToolName)
    }

    /// 兜底人类可读意图（当模型因偶发原因未输出 description 时）
    static func fallbackIntent(toolName: String?, arguments: [String: Any]? = nil) -> String? {
        guard let toolName = toolName else { return nil }
        let tool = AIToolRegistry.shared.tool(named: toolName)
        let display = tool?.displayName ?? toolName

        switch toolName {
        case "run_shell", "shell":
            return "运行一项系统操作"
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

// MARK: - 流式部分 JSON 顶层字段扫描器

/// 流式部分 JSON 的顶层字符串字段扫描器（Streaming Partial JSON Field Scanner）。
///
/// 设计边界（第一性原理）：工具参数 JSON 由注册中心下发的 schema 约束为「顶层扁平对象 +
/// 字符串/基础类型值」；流式逐片生成期间，意图预显只需要尽早拿到「已完整闭合」的顶层
/// 字符串字段（description/title/intent）。完整解析仍由 JSONSerialization 在参数闭合后
/// 统一完成，本扫描器不承担通用 JSON 解析职责，天然容错于任意截断。
///
/// 正确性保障：
/// - 仅提取 depth == 1 的字符串字段，嵌套对象/数组内的同名字段不误读；
/// - 字符串未闭合（截断）即放弃该字段，绝不拼接半截内容；
/// - 转义按 JSON 标准语义解码（含 \uXXXX 与代理对），非法转义保守放弃。
enum PartialJSONFieldScanner {
    /// 顶层字段位置状态机：根对象内「键 → 冒号 → 值 → 逗号」的相位流转。
    private enum Phase {
        case expectKey
        case expectColon
        case expectValue
        case afterValue
    }

    /// 按 keys 优先级返回第一个「已完整闭合」的顶层字符串字段值；目标字段尚未闭合时返回 nil。
    static func firstStringValue(in json: String, keys: [String]) -> String? {
        guard json.contains("\"") else { return nil }
        let chars = Array(json)
        var found: [String: String] = [:]
        var index = 0
        var depth = 0
        var phase = Phase.expectKey
        var pendingKey: String?

        while index < chars.count {
            let char = chars[index]

            // 字符串字面量（键或值）：未闭合即截断，直接以已有结果收场
            if char == "\"" {
                guard let (token, next) = scanStringToken(chars, from: index) else { break }
                if depth == 1 {
                    switch phase {
                    case .expectKey:
                        pendingKey = token
                        phase = .expectColon
                    case .expectValue:
                        if let key = pendingKey { found[key] = token }
                        phase = .afterValue
                    case .expectColon, .afterValue:
                        break // 语法异常容错：跳过，等逗号/花括号重新归位
                    }
                }
                index = next
                continue
            }

            switch char {
            case "{", "[":
                depth += 1
            case "}", "]":
                depth -= 1
                if depth == 1, phase == .expectValue {
                    // 嵌套值（对象/数组）闭合：值已完成
                    phase = .afterValue
                }
                if depth <= 0 { index = chars.count; continue } // 根对象闭合：收场
            case ":":
                if depth == 1, phase == .expectColon { phase = .expectValue }
            case ",":
                if depth == 1 {
                    pendingKey = nil
                    phase = .expectKey
                }
            default:
                break // 空白与非字符串标量（数字/布尔）：由冒号/逗号相位收束
            }
            index += 1
        }

        for key in keys {
            if let value = found[key], !value.isEmpty { return value }
        }
        return nil
    }

    /// 扫描自 from（指向开引号）的字符串字面量：返回 (解码值, 下一索引)；未闭合或非法转义返回 nil。
    private static func scanStringToken(_ chars: [Character], from: Int) -> (value: String, next: Int)? {
        var index = from + 1
        var value = ""
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                return (value, index + 1)
            }
            if char == "\\" {
                guard index + 1 < chars.count else { return nil }
                let escape = chars[index + 1]
                switch escape {
                case "\"": value.append("\""); index += 2
                case "\\": value.append("\\"); index += 2
                case "/": value.append("/"); index += 2
                case "b": value.append("\u{08}"); index += 2
                case "f": value.append("\u{0C}"); index += 2
                case "n": value.append("\n"); index += 2
                case "r": value.append("\r"); index += 2
                case "t": value.append("\t"); index += 2
                case "u":
                    guard let (scalar, consumed) = scanUnicodeEscape(chars, at: index + 2) else { return nil }
                    value.unicodeScalars.append(scalar)
                    index += 2 + consumed // '\\' + 'u' + 十六进制位数
                default:
                    return nil // 非法转义：保守视为未闭合
                }
                continue
            }
            value.append(char)
            index += 1
        }
        return nil
    }

    /// 解码 \uXXXX 转义（含代理对组合）：返回 (标量, 消耗的十六进制字符数)。
    private static func scanUnicodeEscape(_ chars: [Character], at start: Int) -> (scalar: Unicode.Scalar, consumed: Int)? {
        guard let high = hexQuad(chars, at: start) else { return nil }
        var code = high
        var consumed = 4
        if (0xD800...0xDBFF).contains(high) {
            // 高代理：必须紧跟 \uDC00-\uDFFF 组合成标量，否则视为截断
            guard start + 6 + 4 <= chars.count,
                  chars[start + 4] == "\\", chars[start + 5] == "u",
                  let low = hexQuad(chars, at: start + 6),
                  (0xDC00...0xDFFF).contains(low) else { return nil }
            code = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
            consumed = 10
        } else if (0xDC00...0xDFFF).contains(high) {
            return nil // 落单低代理：非法
        }
        guard let scalar = Unicode.Scalar(code) else { return nil }
        return (scalar, consumed)
    }

    /// 解析 4 位十六进制；不足 4 位（截断）或含非十六进制字符返回 nil。
    private static func hexQuad(_ chars: [Character], at start: Int) -> UInt32? {
        guard start + 4 <= chars.count else { return nil }
        var value: UInt32 = 0
        for i in start..<(start + 4) {
            guard let digit = chars[i].hexDigitValue else { return nil }
            value = (value << 4) | UInt32(digit)
        }
        return value
    }
}
