import AppKit
import WebKit

// MARK: - Mermaid 脚本单例加载器

/// 全局单例持有 Mermaid.js 的 WKUserScript 实例：
/// 1. 彻底解决 WebKit 沙箱对 file:// 协议 <script src="..."> 的跨域屏蔽与 Script error 拦截；
/// 2. 避免每个 WebView 实例重复从磁盘读取 3.2MB JS 文件，启动零 I/O 开销，内存共享；
/// 3. 在 document 开始加载时即注入 JS 上下文，保证页面就绪时 window.mermaid 必然可用。
final class MermaidScriptLoader {
    static let shared = MermaidScriptLoader()

    let userScript: WKUserScript?

    private init() {
        let candidateURL = Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
            ?? Bundle.main.resourceURL?.appendingPathComponent("mermaid.min.js")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/mermaid.min.js")

        if FileManager.default.fileExists(atPath: candidateURL.path),
           let js = try? String(contentsOf: candidateURL, encoding: .utf8) {
            self.userScript = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        } else {
            self.userScript = nil
            #if DEBUG
            print("[MermaidScriptLoader] ⚠️ 未能找到 mermaid.min.js 资源文件: \(candidateURL.path)")
            #endif
        }
    }
}
