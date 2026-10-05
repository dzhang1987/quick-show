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
