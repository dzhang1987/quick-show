import AppKit
import SwiftUI
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

// MARK: - AppKit 级无滚动拦截 WKWebView

/// 专为嵌入式图表定制的 WKWebView：
/// 1. 响应链透传：垂直滚轮事件直接上抛给外层 NSScrollView，会话列表上下滑动极致丝滑；
/// 2. 水平滚轮：主要分量为水平时由 WebView 自行消费，承载超宽图表横向平移；
/// 3. 禁用浏览器右键菜单：保持原生 App 质感；
/// 4. 彻底透明背景：drawsBackground = false，无缝融合 QuickShow 毛玻璃卡片。
final class NonScrollingWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }
}

// MARK: - SwiftUI 包装视图

struct MermaidWebView: NSViewRepresentable {
    let code: String
    let isDark: Bool
    @Binding var renderedHeight: CGFloat
    @Binding var renderFailed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NonScrollingWKWebView {
        let config = WKWebViewConfiguration()
        if let userScript = MermaidScriptLoader.shared.userScript {
            config.userContentController.addUserScript(userScript)
        }
        config.userContentController.add(context.coordinator, name: "mermaidBridge")

        let webView = NonScrollingWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        context.coordinator.webView = webView
        context.coordinator.loadHTML()

        return webView
    }

    func updateNSView(_ nsView: NonScrollingWKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.renderIfChanged(code: code, isDark: isDark)
    }

    static func dismantleNSView(_ nsView: NonScrollingWKWebView, coordinator: Coordinator) {
        nsView.navigationDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "mermaidBridge")
        coordinator.webView = nil
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MermaidWebView
        weak var webView: NonScrollingWKWebView?

        var isPageLoaded = false
        private var lastRenderedCode: String?
        private var lastRenderedIsDark: Bool?

        init(parent: MermaidWebView) {
            self.parent = parent
        }

        func loadHTML() {
            guard let webView else { return }
            let html = buildHTMLTemplate()
            webView.loadHTMLString(html, baseURL: nil)
        }

        func renderIfChanged(code: String, isDark: Bool) {
            guard isPageLoaded else { return }
            if lastRenderedCode == code && lastRenderedIsDark == isDark {
                return
            }
            executeRender(code: code, isDark: isDark)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
            executeRender(code: parent.code, isDark: parent.isDark)
        }

        private func executeRender(code: String, isDark: Bool) {
            guard let webView else { return }
            lastRenderedCode = code
            lastRenderedIsDark = isDark

            guard let jsonData = try? JSONSerialization.data(withJSONObject: [code], options: []),
                  let jsonArrayString = String(data: jsonData, encoding: .utf8) else {
                return
            }

            let js = "window.renderDiagram(\(jsonArrayString)[0], \(isDark ? "true" : "false"));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "mermaidBridge",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if type == "rendered" {
                    if let rawHeight = body["height"] as? Double {
                        let height = CGFloat(rawHeight)
                        if height > 0 {
                            self.parent.renderedHeight = height
                        }
                    }
                    self.parent.renderFailed = false
                } else if type == "error" {
                    self.parent.renderFailed = true
                }
            }
        }

        // MARK: 页面模板

        private func buildHTMLTemplate() -> String {
            """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
              * {
                box-sizing: border-box;
              }
              html, body {
                margin: 0;
                padding: 0;
                background-color: transparent !important;
                overflow: hidden;
                width: 100%;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
              }
              #container {
                width: 100%;
                display: flex;
                justify-content: center;
                align-items: center;
                overflow-x: auto;
                overflow-y: hidden;
                padding: 6px 0;
              }
              svg {
                max-width: 100% !important;
                height: auto !important;
                display: block;
              }
              #dmermaid-render-error, .error-icon, .error-text {
                display: none !important;
              }
            </style>
            </head>
            <body>
            <div id="container"></div>
            <script>
              let renderCounter = 0;
              let renderTimer = null;

              function initMermaid(isDark) {
                if (!window.mermaid) return;
                mermaid.initialize({
                  startOnLoad: false,
                  securityLevel: 'loose',
                  theme: isDark ? 'dark' : 'neutral',
                  fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
                  themeVariables: isDark ? {
                    darkMode: true,
                    background: 'transparent',
                    mainBkg: 'rgba(255, 255, 255, 0.08)',
                    nodeBorder: 'rgba(255, 255, 255, 0.25)',
                    clusterBkg: 'rgba(255, 255, 255, 0.04)',
                    clusterBorder: 'rgba(255, 255, 255, 0.15)',
                    titleColor: '#F3F4F6',
                    edgeLabelBackground: 'rgba(30, 30, 40, 0.85)',
                    textColor: '#E5E7EB',
                    lineColor: 'rgba(255, 255, 255, 0.45)'
                  } : {
                    darkMode: false,
                    background: 'transparent',
                    mainBkg: 'rgba(0, 0, 0, 0.04)',
                    nodeBorder: 'rgba(0, 0, 0, 0.2)',
                    clusterBkg: 'rgba(0, 0, 0, 0.02)',
                    clusterBorder: 'rgba(0, 0, 0, 0.1)',
                    titleColor: '#1F2937',
                    edgeLabelBackground: 'rgba(255, 255, 255, 0.85)',
                    textColor: '#1F2937',
                    lineColor: 'rgba(0, 0, 0, 0.35)'
                  }
                });
              }

              window.renderDiagram = function(code, isDark) {
                if (renderTimer) clearTimeout(renderTimer);
                renderTimer = setTimeout(() => {
                  doRenderDiagram(code, isDark);
                }, 40);
              };

              async function doRenderDiagram(code, isDark) {
                const container = document.getElementById('container');
                const renderId = 'mermaid-render-' + (++renderCounter);

                if (!window.mermaid) {
                  window.webkit.messageHandlers.mermaidBridge.postMessage({
                    type: 'error',
                    message: 'mermaid library not available'
                  });
                  return;
                }

                initMermaid(isDark);

                try {
                  if (!code || !code.trim()) {
                    container.innerHTML = '';
                    window.webkit.messageHandlers.mermaidBridge.postMessage({
                      type: 'rendered',
                      height: 0
                    });
                    return;
                  }

                  const { svg } = await mermaid.render(renderId, code);
                  container.innerHTML = svg;

                  requestAnimationFrame(() => {
                    const svgEl = container.querySelector('svg');
                    let height = 0;
                    if (svgEl) {
                      const rect = svgEl.getBoundingClientRect();
                      height = Math.ceil(rect.height);
                    }
                    if (!height || height === 0) {
                      height = Math.ceil(container.scrollHeight);
                    }
                    window.webkit.messageHandlers.mermaidBridge.postMessage({
                      type: 'rendered',
                      height: Math.max(height, 24)
                    });
                  });
                } catch (err) {
                  container.innerHTML = '';
                  const tempErr = document.getElementById('d' + renderId);
                  if (tempErr) tempErr.remove();

                  window.webkit.messageHandlers.mermaidBridge.postMessage({
                    type: 'error',
                    message: err.message || 'Render failed'
                  });
                }
              }
            </script>
            </body>
            </html>
            """
        }
    }
}
