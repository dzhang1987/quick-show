import Foundation

// 说明：本工具除协议层 snake_case name 外，另提供中文 displayName 与 category，
// 仅供设置页/卡片展示；发给模型的 name/schema 与执行链路完全不变。

// MARK: - 预览文件
//
// 与「读文件」不同：本工具不读取文本内容，只做两件事——
//   1. 校验路径确实是一个可预览的常规文件（存在、非目录、未超 50MB 上限）；
//   2. 识别展示用类型名，返回携带 card 信封的结果，由 QuickLook 富卡片原生渲染。
// 结果顶层同时写入 card（渲染信封）与 data（模型可读摘要），
// 与 ShowMapTool 的双写模式一致。

/// 预览本地文件：结果携带 `preview_file` 富卡片信封，由 QuickLook 原生渲染。
final class PreviewFileTool: AITool {
    let name = "preview_file"
    let displayName = String(localized: "预览文件")
    let category: ToolCategory = .files
    /// 纯读文件元数据 + 交给 QuickLook 渲染，无共享可变状态：并行安全。
    let executionPolicy: ToolExecutionPolicy = .parallelSafe
    let description = "在对话中预览一个本地文件（图片、PDF、文本、音视频等），由系统 QuickLook 原生渲染。文件大小上限 50MB。"

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "要预览的本地文件绝对路径，支持 ~ 展开"]
            ],
            "required": ["path"]
        ]
    }

    /// 卡片可预览的文件大小上限：50MB（超过则拒绝，避免 QuickLook 载入大文件卡顿）。
    private static let maxBytes = 50 * 1024 * 1024

    func execute(arguments: [String: Any]) async throws -> String {
        let rawPath = try requiredString(arguments, "path")
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard !expanded.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolExecutionError("路径为空")
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ToolExecutionError("文件不存在或不是普通文件：\(rawPath)")
        }

        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxBytes else {
            throw ToolExecutionError("文件过大（\(Self.formatBytes(size))），超过 50MB 上限")
        }

        // 展示用类型名：优先系统 typeIdentifier（如 public.jpeg），取不到回退扩展名小写。
        let resourceValues = try? url.resourceValues(forKeys: [.typeIdentifierKey])
        let identifier = resourceValues?.typeIdentifier
        let kind = (identifier?.isEmpty == false ? identifier! : url.pathExtension.lowercased())

        let data: [String: Any] = ["path": url.path, "kind": kind]
        return AIToolExecutor.encodeJSON([
            "ok": true,
            "card": ["type": "preview_file", "data": data],
            "data": data
        ])
    }

    /// 字节数 → 人类可读（如 "52.4 MB"），供超限错误信息展示。
    private static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }
}