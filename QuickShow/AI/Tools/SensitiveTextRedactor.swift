import Foundation

// MARK: - 敏感文本展示脱敏

/// 面向权限确认、工具卡片与通知摘要的确定性脱敏器。
///
/// 该类型只处理展示文本，不参与工具执行参数改写。规则覆盖常见 HTTP Authorization、
/// JSON 密钥字段、Shell 环境变量、命令行敏感参数与 URL 查询参数，避免凭证在审批界面
/// 和可复制文本中以明文出现。
enum SensitiveTextRedactor {
    private struct Rule {
        let expression: NSRegularExpression
        let replacement: String

        init?(_ pattern: String, replacement: String) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else {
                return nil
            }
            self.expression = expression
            self.replacement = replacement
        }
    }

    private static let rules: [Rule] = [
        Rule(
            #"(?i)(authorization\s*:\s*(?:bearer|basic)\s+)[^\s\"'\\]+"#,
            replacement: "$1••••••"
        ),
        Rule(
            #"(?i)(\"(?:access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|client[_-]?secret|secret|password|passwd|cookie|authorization)\"\s*:\s*\")[^\"]*(\")"#,
            replacement: "$1••••••$2"
        ),
        Rule(
            #"(?i)(\b(?:access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|client[_-]?secret|secret|password|passwd|cookie|authorization)=)(?:\"[^\"]*\"|'[^']*'|[^\s;|&]+)"#,
            replacement: "$1••••••"
        ),
        Rule(
            #"(?i)(\b[A-Za-z_][A-Za-z0-9_]*(?:token|secret|password|passwd|cookie|authorization|api[_-]?key|access[_-]?key|private[_-]?key|credential)[A-Za-z0-9_]*=)(?:\"[^\"]*\"|'[^']*'|[^\s;|&]+)"#,
            replacement: "$1••••••"
        ),
        Rule(
            #"(?i)(--(?:access-token|refresh-token|id-token|api-key|client-secret|token|secret|password|cookie|authorization)(?:=|\s+))(?:\"[^\"]*\"|'[^']*'|[^\s;|&]+)"#,
            replacement: "$1••••••"
        ),
        Rule(
            #"(?i)([?&](?:access_token|refresh_token|id_token|api_key|client_secret|token|key|secret|password)=)[^&\s\"']+"#,
            replacement: "$1••••••"
        ),
        Rule(
            #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]{8,})?\b"#,
            replacement: "••••••"
        )
    ].compactMap { $0 }

    static func redact(_ text: String) -> String {
        let homeDirectory = NSHomeDirectory()
        let homeRedacted = homeDirectory.isEmpty
            ? text
            : text.replacingOccurrences(of: homeDirectory, with: "~")
        return rules.reduce(homeRedacted) { partial, rule in
            let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
            return rule.expression.stringByReplacingMatches(
                in: partial,
                options: [],
                range: range,
                withTemplate: rule.replacement
            )
        }
    }

    static func containsSensitiveValue(in text: String) -> Bool {
        redact(text) != text
    }
}

// MARK: - 工具记录持久化脱敏

/// 执行链路继续使用原始参数与结果；写入会话和工具卡的副本按工具语义收紧。
enum ToolRecordSanitizer {
    private static let maskedValue = "••••••"

    static func arguments(toolName: String, json: String) -> String {
        if toolName == "run_shell" || toolName == "shell" {
            return encodeJSON([
                "description": String(localized: "系统操作细节仅用于当前任务，未写入会话记录")
            ])
        }
        if toolName == "set_env" {
            return sanitizeJSONObject(json, forceMaskValueFields: true)
        }
        return SensitiveTextRedactor.redact(json)
    }

    static func result(toolName: String, json: String) -> String {
        if toolName == "run_shell" || toolName == "shell" {
            let succeeded: Bool = {
                guard let data = json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return false
                }
                return object["ok"] as? Bool != false
            }()
            return succeeded
                ? encodeJSON([
                    "ok": true,
                    "data": String(localized: "系统操作结果仅用于当前任务，未写入会话记录")
                ])
                : encodeJSON([
                    "ok": false,
                    "error": String(localized: "系统操作失败，详细输出未写入会话记录")
                ])
        }
        if toolName == "get_env" || toolName == "set_env" {
            return sanitizeJSONObject(json, forceMaskValueFields: true)
        }
        return SensitiveTextRedactor.redact(json)
    }

    private static func sanitizeJSONObject(_ json: String, forceMaskValueFields: Bool) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return SensitiveTextRedactor.redact(json)
        }
        return encodeJSON(mask(object, forceMaskValueFields: forceMaskValueFields))
    }

    private static func mask(_ value: Any, forceMaskValueFields: Bool) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, nestedValue) in dictionary {
                let normalizedKey = key.lowercased().replacingOccurrences(of: "-", with: "_")
                let isSensitiveKey = normalizedKey.contains("token")
                    || normalizedKey.contains("secret")
                    || normalizedKey.contains("password")
                    || normalizedKey.contains("passwd")
                    || normalizedKey.contains("cookie")
                    || normalizedKey.contains("authorization")
                    || normalizedKey.contains("api_key")
                    || (forceMaskValueFields && normalizedKey == "value")
                result[key] = isSensitiveKey
                    ? maskedValue
                    : mask(nestedValue, forceMaskValueFields: forceMaskValueFields)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { mask($0, forceMaskValueFields: forceMaskValueFields) }
        }
        if let string = value as? String {
            return SensitiveTextRedactor.redact(string)
        }
        return value
    }

    private static func encodeJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"记录脱敏失败\"}"
        }
        return string
    }
}
