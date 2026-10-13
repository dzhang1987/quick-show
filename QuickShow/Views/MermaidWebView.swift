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
                align-items: flex-start;
                overflow-x: auto;
                overflow-y: hidden;
                padding: 6px 0;
              }
              svg {
                display: block;
                height: auto;
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
              let lastReportedHeight = 0;
              let pendingRenderArgs = null;

              function reportContainerHeight() {
                const container = document.getElementById('container');
                const svgEl = container ? container.querySelector('svg') : null;
                if (!container || !svgEl) return;

                const svgRect = svgEl.getBoundingClientRect();
                const containerRect = container.getBoundingClientRect();
                let height = Math.ceil(Math.max(containerRect.height, svgRect.height + 12));
                if (!height || height <= 0) {
                  height = Math.ceil(container.scrollHeight);
                }
                const finalHeight = Math.max(height, 24);
                if (Math.abs(finalHeight - lastReportedHeight) >= 1) {
                  lastReportedHeight = finalHeight;
                  window.webkit.messageHandlers.mermaidBridge.postMessage({
                    type: 'rendered',
                    height: finalHeight
                  });
                }
              }

              const resizeObserver = new ResizeObserver(() => {
                if (pendingRenderArgs && document.body.clientWidth >= 10) {
                  const args = pendingRenderArgs;
                  pendingRenderArgs = null;
                  doRenderDiagram(args.code, args.isDark);
                  return;
                }
                requestAnimationFrame(reportContainerHeight);
              });

              window.addEventListener('DOMContentLoaded', () => {
                const container = document.getElementById('container');
                if (container) resizeObserver.observe(container);
                resizeObserver.observe(document.body);
              });

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

              function normalizeDiagram(container) {
                const svgEl = container.querySelector('svg');
                if (!svgEl) return;

                // 1. 根治 journey 等图表硬编码 height 属性与冗余 viewBox 导致的底部巨幅留白：
                //    journey 渲染器在设置 width="100%" 后又强行写入 height="565"，且将标题高度 70px 误加至底部 viewBox。
                //    此处针对 journey 按实际图形几何边界 (getBBox) 收紧 viewBox，并移除所有带 viewBox 图表的硬编码 height 属性，
                //    让 SVG 高度严格按 viewBox 宽高比随容器宽度等比缩放。
                if (svgEl.getAttribute('aria-roledescription') === 'journey') {
                  try {
                    const bbox = svgEl.getBBox();
                    if (bbox && bbox.width > 0 && bbox.height > 0) {
                      const padX = 16;
                      const padY = 12;
                      svgEl.setAttribute(
                        'viewBox',
                        `${bbox.x - padX} ${bbox.y - padY} ${bbox.width + padX * 2} ${bbox.height + padY * 2}`
                      );
                    }
                  } catch (_) {}
                }
                if (svgEl.getAttribute('viewBox')) {
                  svgEl.removeAttribute('height');
                }

                // 2. 根治时序图泳道生命线穿刺顶部参与者方框：
                //    Mermaid 原生绘制生命线从顶部方框内的 y=5 起笔，依赖不透明背景遮挡；
                //    在 macOS 毛玻璃半透明体系下，生命线会透过半透明方框暴露。
                //    此处从几何底层将生命线起点截断在方框底边（bottomY），彻底根治穿刺。
                const topActors = svgEl.querySelectorAll('rect.actor-top, g.actor-top');
                if (topActors.length > 0) {
                  const lines = svgEl.querySelectorAll('line');
                  topActors.forEach(actor => {
                    let rx, rw, ry, rh;
                    if (actor.tagName.toLowerCase() === 'rect') {
                      rx = parseFloat(actor.getAttribute('x'));
                      rw = parseFloat(actor.getAttribute('width'));
                      ry = parseFloat(actor.getAttribute('y'));
                      rh = parseFloat(actor.getAttribute('height'));
                    } else if (typeof actor.getBBox === 'function') {
                      try {
                        const bbox = actor.getBBox();
                        rx = bbox.x; rw = bbox.width; ry = bbox.y; rh = bbox.height;
                      } catch (_) { return; }
                    }
                    if (isNaN(rx) || isNaN(rw) || isNaN(ry) || isNaN(rh)) return;
                    const centerX = rx + rw / 2;
                    const bottomY = ry + rh;

                    lines.forEach(line => {
                      const lx1 = parseFloat(line.getAttribute('x1'));
                      const lx2 = parseFloat(line.getAttribute('x2'));
                      const ly1 = parseFloat(line.getAttribute('y1'));
                      if (isNaN(lx1) || isNaN(lx2) || isNaN(ly1)) return;
                      // 垂直生命线：x 坐标在中轴线附近 (±2px 容差)，且起点深入方框内部 (ly1 < bottomY)
                      if (Math.abs(lx1 - lx2) < 0.5 && Math.abs(lx1 - centerX) < 2 && ly1 < bottomY) {
                        line.setAttribute('y1', bottomY);
                      }
                    });
                  });
                }

                // 3. 根治 ER 图（erDiagram）关系连接线终端符号穿刺半透明实体框：
                //    Mermaid 原生将 ER 关系线绘制在实体框图层下方，且将鱼尾分叉（ONE_OR_MORE / ZERO_OR_MORE）的 refX 设在
                //    中心点并向实体框内部延伸 18px，依赖不透明实体框背景遮挡。在毛玻璃半透明主题下会穿透实体框遮挡表名。
                //    此处配合开放式鱼尾分叉路径，通过 SVG userSpaceOnUse 遮罩将所有实体框内部区域从关系线图层中精准镂空，
                //    确保任意角度入射的鱼尾三叉均严丝合缝止步于实体框外边缘。
                const relLines = svgEl.querySelectorAll('path.er.relationshipLine');
                const entityBoxes = svgEl.querySelectorAll('g[id^="entity-"] > rect.er.entityBox');
                if (relLines.length > 0 && entityBoxes.length > 0) {
                  const ns = 'http://www.w3.org/2000/svg';
                  let defs = svgEl.querySelector('defs');
                  if (!defs) {
                    defs = document.createElementNS(ns, 'defs');
                    svgEl.insertBefore(defs, svgEl.firstChild);
                  }
                  const maskId = (svgEl.id || 'mermaid-er') + '-entity-mask';
                  const mask = document.createElementNS(ns, 'mask');
                  mask.setAttribute('id', maskId);
                  mask.setAttribute('maskUnits', 'userSpaceOnUse');
                  mask.setAttribute('maskContentUnits', 'userSpaceOnUse');
                  mask.setAttribute('x', '-10000');
                  mask.setAttribute('y', '-10000');
                  mask.setAttribute('width', '20000');
                  mask.setAttribute('height', '20000');

                  const bg = document.createElementNS(ns, 'rect');
                  bg.setAttribute('x', '-10000');
                  bg.setAttribute('y', '-10000');
                  bg.setAttribute('width', '20000');
                  bg.setAttribute('height', '20000');
                  bg.setAttribute('fill', 'white');
                  mask.appendChild(bg);

                  entityBoxes.forEach(box => {
                    const g = box.parentElement;
                    const transform = (g && g.getAttribute('transform')) || '';
                    let tx = 0, ty = 0;
                    const tStart = transform.indexOf('translate(');
                    if (tStart !== -1) {
                      const tEnd = transform.indexOf(')', tStart);
                      if (tEnd !== -1) {
                        const parts = transform.slice(tStart + 10, tEnd).trim().split(/[ ,]+/);
                        tx = parseFloat(parts[0]) || 0;
                        ty = parseFloat(parts[1]) || 0;
                      }
                    }
                    const bx = parseFloat(box.getAttribute('x')) || 0;
                    const by = parseFloat(box.getAttribute('y')) || 0;
                    const bw = parseFloat(box.getAttribute('width')) || 0;
                    const bh = parseFloat(box.getAttribute('height')) || 0;
                    if (bw > 0 && bh > 0) {
                      const cut = document.createElementNS(ns, 'rect');
                      cut.setAttribute('x', String(tx + bx));
                      cut.setAttribute('y', String(ty + by));
                      cut.setAttribute('width', String(bw));
                      cut.setAttribute('height', String(bh));
                      cut.setAttribute('fill', 'black');
                      mask.appendChild(cut);
                    }
                  });
                  defs.appendChild(mask);

                  const relGroup = document.createElementNS(ns, 'g');
                  relGroup.setAttribute('mask', `url(#${maskId})`);
                  const firstLine = relLines[0];
                  if (firstLine.parentNode) {
                    firstLine.parentNode.insertBefore(relGroup, firstLine);
                    relLines.forEach(line => relGroup.appendChild(line));
                  }
                }
              }

              async function doRenderDiagram(code, isDark) {
                const container = document.getElementById('container');
                if (!window.mermaid) {
                  window.webkit.messageHandlers.mermaidBridge.postMessage({
                    type: 'error',
                    message: 'mermaid library not available'
                  });
                  return;
                }

                if (!code || !code.trim()) {
                  container.innerHTML = '';
                  lastReportedHeight = 0;
                  window.webkit.messageHandlers.mermaidBridge.postMessage({
                    type: 'rendered',
                    height: 0
                  });
                  return;
                }

                if (document.body.clientWidth < 10) {
                  pendingRenderArgs = { code, isDark };
                  return;
                }

                const renderId = 'mermaid-render-' + (++renderCounter);
                initMermaid(isDark);

                try {
                  const { svg } = await mermaid.render(renderId, code);
                  container.innerHTML = svg;
                  normalizeDiagram(container);

                  const svgEl = container.querySelector('svg');
                  if (svgEl) {
                    resizeObserver.observe(svgEl);
                  }

                  lastReportedHeight = 0;
                  requestAnimationFrame(() => {
                    reportContainerHeight();
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
