import AppKit
import SwiftUI
import WebKit

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
    let look: MermaidLook
    let theme: MermaidTheme
    @Binding var renderedHeight: CGFloat
    @Binding var renderFailed: Bool

    init(
        code: String,
        isDark: Bool,
        look: MermaidLook,
        theme: MermaidTheme,
        renderedHeight: Binding<CGFloat>,
        renderFailed: Binding<Bool>
    ) {
        self.code = code
        self.isDark = isDark
        self.look = look
        self.theme = theme
        self._renderedHeight = renderedHeight
        self._renderFailed = renderFailed
    }

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
        context.coordinator.renderIfChanged(
            code: code,
            isDark: isDark,
            look: look,
            theme: theme
        )
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
        private var lastRenderedLook: MermaidLook?
        private var lastRenderedTheme: MermaidTheme?

        init(parent: MermaidWebView) {
            self.parent = parent
        }

        func loadHTML() {
            guard let webView else { return }
            let html = MermaidTemplateProvider.htmlTemplate()
            webView.loadHTMLString(html, baseURL: nil)
        }

        func renderIfChanged(
            code: String,
            isDark: Bool,
            look: MermaidLook,
            theme: MermaidTheme
        ) {
            guard isPageLoaded else { return }
            if lastRenderedCode == code
                && lastRenderedIsDark == isDark
                && lastRenderedLook == look
                && lastRenderedTheme == theme {
                return
            }
            executeRender(code: code, isDark: isDark, look: look, theme: theme)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
            executeRender(
                code: parent.code,
                isDark: parent.isDark,
                look: parent.look,
                theme: parent.theme
            )
        }

        private func executeRender(
            code: String,
            isDark: Bool,
            look: MermaidLook,
            theme: MermaidTheme
        ) {
            guard let webView else { return }
            lastRenderedCode = code
            lastRenderedIsDark = isDark
            lastRenderedLook = look
            lastRenderedTheme = theme

            let payload: [Any] = [code, isDark, look.rawValue, theme.rawValue]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
                  let jsonArrayString = String(data: jsonData, encoding: .utf8) else {
                return
            }

            let js = "window.renderDiagram.apply(window, \(jsonArrayString));"
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
                        if height > 0, abs(self.parent.renderedHeight - height) >= 1 {
                            self.parent.renderedHeight = height
                        }
                    }
                    if self.parent.renderFailed {
                        self.parent.renderFailed = false
                    }
                } else if type == "error" {
                    if !self.parent.renderFailed {
                        self.parent.renderFailed = true
                    }
                }
            }
        }
    }
}
