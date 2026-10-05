import Foundation

// MARK: - JSON 文本辅助

/// 工具调用参数 / 结果的 JSON 文本处理：美化（键排序 + 缩进）与错误摘要提取。
enum ToolJSONText {
    /// JSON 美化：解析成功则按排序键 + 2 空格缩进重排；非 JSON 原文返回。
    static func pretty(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: prettyData, encoding: .utf8) else {
            return raw
        }
        return text
    }

    /// 从统一结果包装 {"ok":false,"error":"..."} 中提取用户可读错误文案。
    static func errorMessage(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? String,
              !error.isEmpty else {
            return nil
        }
        return error
    }
}