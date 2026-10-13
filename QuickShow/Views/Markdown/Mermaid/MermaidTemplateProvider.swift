import Foundation

// MARK: - Mermaid HTML 渲染模板装配器

enum MermaidTemplateProvider {
    /// 全局缓存拼装后的完整 HTML 模板，仅在首次访问时读取磁盘资源，运行时零 I/O 开销
    private static let cachedHTMLTemplate: String = loadAndAssembleTemplate()

    static func htmlTemplate() -> String {
        return cachedHTMLTemplate
    }

    private static func loadResource(name: String, ext: String) -> String? {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: ext, subdirectory: "Mermaid"),
            bundle.url(forResource: name, withExtension: ext),
            bundle.resourceURL?.appendingPathComponent("Mermaid/\(name).\(ext)"),
            bundle.resourceURL?.appendingPathComponent("\(name).\(ext)"),
            bundle.bundleURL.appendingPathComponent("Contents/Resources/Mermaid/\(name).\(ext)"),
            bundle.bundleURL.appendingPathComponent("Contents/Resources/\(name).\(ext)")
        ]

        for case let url? in candidates {
            if FileManager.default.fileExists(atPath: url.path),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }

        // 本地开发/测试环境降级容灾查找（针对直接运行或未完整拷贝资源的情形）
        let sourceDirCandidates = [
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent() // Mermaid
                .deletingLastPathComponent() // Markdown
                .deletingLastPathComponent() // Views
                .appendingPathComponent("Resources/Mermaid/\(name).\(ext)"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("QuickShow/Resources/Mermaid/\(name).\(ext)")
        ]

        for url in sourceDirCandidates {
            if FileManager.default.fileExists(atPath: url.path),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }

        #if DEBUG
        print("[MermaidTemplateProvider] ⚠️ 未能找到资源文件: \(name).\(ext)")
        #endif
        return nil
    }

    private static func loadAndAssembleTemplate() -> String {
        guard let template = loadResource(name: "mermaid_template", ext: "html") else {
            #if DEBUG
            print("[MermaidTemplateProvider] ❌ 加载 mermaid_template.html 失败，回退到基础容器")
            #endif
            return fallbackTemplate
        }

        let baseCSS = loadResource(name: "mermaid_base", ext: "css") ?? ""
        let normalizerJS = loadResource(name: "mermaid_normalizer", ext: "js") ?? ""
        let bridgeJS = loadResource(name: "mermaid_bridge", ext: "js") ?? ""

        var html = template
        html = html.replacingOccurrences(of: "/* __MERMAID_BASE_CSS__ */", with: baseCSS)
        html = html.replacingOccurrences(of: "/* __MERMAID_NORMALIZER_JS__ */", with: normalizerJS)
        html = html.replacingOccurrences(of: "/* __MERMAID_BRIDGE_JS__ */", with: bridgeJS)
        return html
    }

    private static var fallbackTemplate: String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        html, body { margin: 0; padding: 0; background-color: transparent !important; }
        #container { width: 100%; display: flex; justify-content: center; }
        </style>
        </head>
        <body>
        <div id="container"></div>
        </body>
        </html>
        """
    }
}
