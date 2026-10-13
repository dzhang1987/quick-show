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

// MARK: - Mermaid 原生内置风格与主题配置

/// Mermaid 官方内置外观风格 (`look` 参数)
enum MermaidLook: String, CaseIterable, Identifiable {
    static let storageKey = "ai.mermaid.look"

    case classic = "classic"
    case neo = "neo"
    case handDrawn = "handDrawn"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return String(localized: "经典规整 (classic)")
        case .neo: return String(localized: "现代新风 (neo)")
        case .handDrawn: return String(localized: "手绘草图 (handDrawn)")
        }
    }

    var shortName: String {
        switch self {
        case .classic: return String(localized: "规整")
        case .neo: return String(localized: "现代")
        case .handDrawn: return String(localized: "手绘")
        }
    }

    var iconName: String {
        switch self {
        case .classic: return "square.on.circle"
        case .neo: return "sparkles.rectangle.stack"
        case .handDrawn: return "scribble.variable"
        }
    }
}

/// Mermaid 官方内置主题 (`theme` 参数)
enum MermaidTheme: String, CaseIterable, Identifiable {
    static let storageKey = "ai.mermaid.theme"

    case auto = "auto"
    case defaultTheme = "default"
    case neutral = "neutral"
    case dark = "dark"
    case forest = "forest"
    case base = "base"
    case neo = "neo"
    case neoDark = "neo-dark"
    case redux = "redux"
    case reduxDark = "redux-dark"
    case reduxColor = "redux-color"
    case reduxDarkColor = "redux-dark-color"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "自动（跟随深浅色毛玻璃）")
        case .defaultTheme: return String(localized: "默认 (default)")
        case .neutral: return String(localized: "中性黑白 (neutral)")
        case .dark: return String(localized: "深色 (dark)")
        case .forest: return String(localized: "森林绿 (forest)")
        case .base: return String(localized: "基础 (base)")
        case .neo: return String(localized: "现代浅色 (neo)")
        case .neoDark: return String(localized: "现代深色 (neo-dark)")
        case .redux: return String(localized: "极简浅色 (redux)")
        case .reduxDark: return String(localized: "极简深色 (redux-dark)")
        case .reduxColor: return String(localized: "多彩浅色 (redux-color)")
        case .reduxDarkColor: return String(localized: "多彩深色 (redux-dark-color)")
        }
    }

    var shortName: String {
        switch self {
        case .auto: return String(localized: "自动")
        default: return rawValue
        }
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
            let html = buildHTMLTemplate()
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

        // MARK: 页面模板

        private func buildHTMLTemplate() -> String {
            #"""
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
            <style id="qs-canvas-contrast"></style>
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
                  doRenderDiagram(args.code, args.isDark, args.look, args.theme);
                  return;
                }
                requestAnimationFrame(reportContainerHeight);
              });

              window.addEventListener('DOMContentLoaded', () => {
                const container = document.getElementById('container');
                if (container) resizeObserver.observe(container);
                resizeObserver.observe(document.body);
              });

              function quoteIfNeeded(s) {
                const t = s.trim();
                if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
                  return t;
                }
                return '"' + t.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
              }

              // 语法预归一化层：
              // 针对 Mermaid 各子图解析器（Jison / Langium）对中文、连字符 '-'、百分号 '%'、括号或未加引号文本的严苛词法限制，
              // 在进入 mermaid.render 前进行无损语法归正，消除大模型生成标准语法却触发 "语法未闭合或暂不可预览" 的问题。
              function normalizeMermaidSource(raw) {
                if (!raw) return raw;
                const lines = raw.split(/\r?\n/);
                let firstContentIdx = -1;
                for (let i = 0; i < lines.length; i++) {
                  const t = lines[i].trim();
                  if (!t || t.startsWith('%%')) continue;
                  if (t === '---') {
                    i++;
                    while (i < lines.length && lines[i].trim() !== '---') i++;
                    continue;
                  }
                  firstContentIdx = i;
                  break;
                }
                if (firstContentIdx === -1) return raw;
                const header = lines[firstContentIdx].trim();

                // 1. requirementDiagram: Jison unqString 词法规则禁止包含 '-' / ':' / ',' / '=' / '<' / '>'（如 id: REQ-101 会直接报错）
                if (/^requirementDiagram\b/i.test(header)) {
                  return lines.map((line, idx) => {
                    if (idx <= firstContentIdx) return line;
                    const attrMatch = line.match(/^(\s*(?:id|text|type|docref)\s*:\s*)(.+?)(\s*)$/i);
                    if (attrMatch) {
                      return attrMatch[1] + quoteIfNeeded(attrMatch[2]) + attrMatch[3];
                    }
                    const declMatch = line.match(/^(\s*(?:requirement|functionalRequirement|interfaceRequirement|performanceRequirement|physicalRequirement|designConstraint|element)\s+)([^\s"{]+)(\s*(?::::[^\s{]+)?\s*\{.*)$/i);
                    if (declMatch && /[-:,=<>]/.test(declMatch[2])) {
                      return declMatch[1] + quoteIfNeeded(declMatch[2]) + declMatch[3];
                    }
                    const relMatch = line.match(/^(\s*)([^\s"<-]+)(\s+(?:-\s*(?:contains|copies|derives|satisfies|verifies|refines|traces)\s*->|<-\s*(?:contains|copies|derives|satisfies|verifies|refines|traces)\s*-)\s+)([^\s"]+)(\s*)$/i);
                    if (relMatch) {
                      const lhs = /[-:,=<>]/.test(relMatch[2]) ? quoteIfNeeded(relMatch[2]) : relMatch[2];
                      const rhs = /[-:,=<>]/.test(relMatch[4]) ? quoteIfNeeded(relMatch[4]) : relMatch[4];
                      return relMatch[1] + lhs + relMatch[3] + rhs + relMatch[5];
                    }
                    return line;
                  }).join('\n');
                }

                // 2. xychart / xychart-beta: 未加引号的标题或坐标轴若含 '%' / '/' / '$' 等字符会触发词法错误，且空格会被吞掉
                if (/^xychart(?:-beta)?\b/i.test(header)) {
                  return lines.map((line, idx) => {
                    if (idx <= firstContentIdx) return line;
                    const titleMatch = line.match(/^(\s*title\s+)(.+?)(\s*)$/i);
                    if (titleMatch) {
                      return titleMatch[1] + quoteIfNeeded(titleMatch[2]) + titleMatch[3];
                    }
                    const bandMatch = line.match(/^(\s*x-axis\s+)(?:(.+?)\s+)?(\[[^\]]*\])(\s*)$/i);
                    if (bandMatch) {
                      const axisTitle = bandMatch[2] ? quoteIfNeeded(bandMatch[2]) + ' ' : '';
                      const inner = bandMatch[3].slice(1, -1).split(',').map(item => {
                        const t = item.trim();
                        if (!t) return item;
                        if (/^[+-]?(?:\d+(?:\.\d+)?|\.\d+)$/.test(t)) return t;
                        return quoteIfNeeded(t);
                      }).join(', ');
                      return bandMatch[1] + axisTitle + '[' + inner + ']' + bandMatch[4];
                    }
                    const rangeMatch = line.match(/^(\s*[xy]-axis\s+)(.+?)(\s+[+-]?(?:\d+(?:\.\d+)?|\.\d+)\s*-->\s*[+-]?(?:\d+(?:\.\d+)?|\.\d+)\s*)$/i);
                    if (rangeMatch) {
                      return rangeMatch[1] + quoteIfNeeded(rangeMatch[2]) + rangeMatch[3];
                    }
                    const titleOnlyAxis = line.match(/^(\s*[xy]-axis\s+)(?!\[)(.+?)(\s*)$/i);
                    if (titleOnlyAxis && !/-->/.test(titleOnlyAxis[2])) {
                      return titleOnlyAxis[1] + quoteIfNeeded(titleOnlyAxis[2]) + titleOnlyAxis[3];
                    }
                    return line;
                  }).join('\n');
                }

                // 3. packet / packet-beta: 报文段冒号后的描述必须为双引号字符串
                if (/^packet(?:-beta)?\b/i.test(header)) {
                  return lines.map((line, idx) => {
                    if (idx <= firstContentIdx) return line;
                    const blkMatch = line.match(/^(\s*(?:\d+(?:\s*-\s*\d+)?|\+\d+)\s*:\s*)(.+?)(\s*)$/);
                    if (blkMatch) {
                      return blkMatch[1] + quoteIfNeeded(blkMatch[2]) + blkMatch[3];
                    }
                    return line;
                  }).join('\n');
                }

                // 4. radar-beta: Langium 要求 axis/curve 标识符为 ASCII [\w-]+，且 [...] 内标签必须加引号
                if (/^radar-beta\b/i.test(header)) {
                  let axisCounter = 0;
                  let curveCounter = 0;
                  const axisIdMap = new Map();
                  return lines.map((line, idx) => {
                    if (idx <= firstContentIdx) return line;
                    const axisMatch = line.match(/^(\s*axis\s+)(.+?)(\s*)$/i);
                    if (axisMatch) {
                      const items = axisMatch[2].split(',').map(rawItem => {
                        const item = rawItem.trim();
                        if (!item) return rawItem;
                        const idLabelMatch = item.match(/^([A-Za-z0-9_][A-Za-z0-9_-]*)\s*\[(.*)\]$/);
                        if (idLabelMatch) {
                          return `${idLabelMatch[1]}[${quoteIfNeeded(idLabelMatch[2])}]`;
                        }
                        if (/^[A-Za-z0-9_][A-Za-z0-9_-]*$/.test(item)) {
                          return item;
                        }
                        const cleanLabel = item.replace(/^["']|["']$/g, '');
                        const genId = `ax_${++axisCounter}`;
                        axisIdMap.set(cleanLabel, genId);
                        return `${genId}[${quoteIfNeeded(cleanLabel)}]`;
                      });
                      return axisMatch[1] + items.join(', ') + axisMatch[3];
                    }
                    const curveMatch = line.match(/^(\s*curve\s+)(.+?)(\s*\{)(.*)(\}\s*)$/i);
                    if (curveMatch) {
                      const rawCurve = curveMatch[2].trim();
                      let normCurve = rawCurve;
                      const idLabelMatch = rawCurve.match(/^([A-Za-z0-9_][A-Za-z0-9_-]*)\s*\[(.*)\]$/);
                      if (idLabelMatch) {
                        normCurve = `${idLabelMatch[1]}[${quoteIfNeeded(idLabelMatch[2])}]`;
                      } else if (!/^[A-Za-z0-9_][A-Za-z0-9_-]*$/.test(rawCurve)) {
                        const cleanLabel = rawCurve.replace(/^["']|["']$/g, '');
                        normCurve = `cv_${++curveCounter}[${quoteIfNeeded(cleanLabel)}]`;
                      }
                      let body = curveMatch[4];
                      if (body.includes(':')) {
                        body = body.split(',').map(entry => {
                          const kv = entry.split(':');
                          if (kv.length === 2) {
                            const k = kv[0].trim().replace(/^["']|["']$/g, '');
                            const mapped = axisIdMap.get(k) || k;
                            return `${mapped}: ${kv[1].trim()}`;
                          }
                          return entry;
                        }).join(', ');
                      }
                      return curveMatch[1] + normCurve + curveMatch[3] + body + curveMatch[5];
                    }
                    return line;
                  }).join('\n');
                }

                // 5. erDiagram: 实体属性行末尾未加引号的注释自动补双引号
                if (/^erDiagram\b/i.test(header)) {
                  let inBlock = false;
                  return lines.map((line, idx) => {
                    if (idx <= firstContentIdx) return line;
                    const trimmed = line.trim();
                    if (!inBlock && trimmed.endsWith('{') && !trimmed.includes(':')) {
                      inBlock = true;
                      return line;
                    }
                    if (inBlock && trimmed === '}') {
                      inBlock = false;
                      return line;
                    }
                    if (inBlock && trimmed && !trimmed.startsWith('%%')) {
                      const m = line.match(/^(\s*\S+\s+\S+)(\s+(?:(?:PK|FK|UK)(?:\s*,\s*(?:PK|FK|UK))*))?(\s+)(.+?)(\s*)$/i);
                      if (m) {
                        const comment = m[4].trim();
                        if (comment && !/^(?:PK|FK|UK)$/i.test(comment) && !(comment.startsWith('"') && comment.endsWith('"'))) {
                          return m[1] + (m[2] || '') + m[3] + quoteIfNeeded(comment) + m[5];
                        }
                      }
                    }
                    return line;
                  }).join('\n');
                }

                // 6. pie: 切片名称未加引号时自动补双引号
                if (/^pie\b/i.test(header)) {
                  return lines.map((line, idx) => {
                    if (idx <= firstContentIdx) return line;
                    const trimmed = line.trim();
                    if (!trimmed || trimmed.startsWith('%%') || /^(?:title|accTitle|accDescr)\b/i.test(trimmed)) return line;
                    const m = line.match(/^(\s*)([^":]+?)(\s*:\s*-?\d+(?:\.\d+)?\s*)$/);
                    if (m) {
                      return m[1] + quoteIfNeeded(m[2]) + m[3];
                    }
                    return line;
                  }).join('\n');
                }

                // 7. gitGraph: 分支名含中文或特殊字符时自动补双引号
                if (/^gitGraph\b/i.test(header)) {
                  return lines.map((line, idx) => {
                    if (idx <= firstContentIdx) return line;
                    const m = line.match(/^(\s*(?:branch|checkout|switch|merge)\s+)([^\s"]+)(\s+.*|\s*)$/i);
                    if (m && !/^[A-Za-z0-9_][-\./A-Za-z0-9_]*[A-Za-z0-9_-]$|^[A-Za-z0-9_]$/.test(m[2])) {
                      return m[1] + quoteIfNeeded(m[2]) + m[3];
                    }
                    return line;
                  }).join('\n');
                }

                // 8. treemap-beta / treemap: 节点名称未加引号时自动补双引号
                if (/^treemap(?:-beta)?\b/i.test(header)) {
                  return lines.map((line, idx) => {
                    if (idx <= firstContentIdx) return line;
                    const trimmed = line.trim();
                    if (!trimmed || trimmed.startsWith('%%') || /^(?:title|accTitle|accDescr|classDef)\b/i.test(trimmed)) return line;
                    const m = line.match(/^(\s*)([^":\n]+?)(\s*(?::\s*[\d.,_]+)?\s*(?::::[A-Za-z_]\w*)?\s*)$/);
                    if (m && !m[2].trim().startsWith("'") && !m[2].trim().startsWith('"')) {
                      return m[1] + quoteIfNeeded(m[2]) + m[3];
                    }
                    return line;
                  }).join('\n');
                }

                // 9. C4 系列图表 (C4Context / C4Container / C4Component / C4Dynamic / C4Deployment):
                //    - Jison 语法仅允许 *_Boundary / Boundary / Deployment_Node / Node 后接 '{ ... }'，若对 Container / System 等加 '{' 会报错；
                //    - 反之，Deployment_Node / Node / *_Boundary 在语法中必须后接非空 '{ ... }' 且不进入形状表 Yl（无法被 Rel 连线），
                //      若作为不带 '{ ... }' 的叶子节点出现，需归正为 Container 叶子形状。
                if (/^C4(?:Context|Container|Component|Dynamic|Deployment)\b/i.test(header)) {
                  const result = [...lines];
                  for (let i = firstContentIdx + 1; i < result.length; i++) {
                    const line = result[i];
                    const trimmed = line.trim();
                    if (!trimmed || trimmed.startsWith('%%')) continue;

                    // 处理单行空花括号块（如 Deployment_Node(...) {}）
                    const emptyInlineMatch = line.match(/^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*\(.*\))\s*\{\s*\}\s*$/);
                    if (emptyInlineMatch) {
                      result[i] = emptyInlineMatch[1] + 'Container' + emptyInlineMatch[3];
                      continue;
                    }

                    const m = line.match(/^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*\(.*\))(\s*)(\{?\s*)$/);
                    if (!m) continue;
                    const [, indent, kw, argsPart, midSpace, bracePart] = m;
                    let hasBrace = bracePart.startsWith('{');
                    if (!hasBrace) {
                      for (let j = i + 1; j < result.length; j++) {
                        const nt = result[j].trim();
                        if (!nt || nt.startsWith('%%')) continue;
                        if (nt.startsWith('{')) {
                          hasBrace = true;
                        }
                        break;
                      }
                    }

                    if (hasBrace) {
                      let newKw = kw;
                      if (/^Container(?:Db|Queue)?(?:_Ext)?$/i.test(kw)) {
                        newKw = 'Container_Boundary';
                      } else if (/^System(?:Db|Queue)?(?:_Ext)?$/i.test(kw)) {
                        newKw = 'System_Boundary';
                      } else if (/^Enterprise$/i.test(kw)) {
                        newKw = 'Enterprise_Boundary';
                      } else if (/^(?:Component(?:Db|Queue)?(?:_Ext)?|Person(?:_Ext)?)$/i.test(kw)) {
                        newKw = 'Boundary';
                      }
                      if (newKw !== kw) {
                        result[i] = indent + newKw + argsPart + midSpace + bracePart;
                      }
                    } else {
                      if (/^(?:Deployment_Node|Node|Node_L|Node_R|(?:Container|System|Enterprise)_Boundary|Boundary)$/i.test(kw)) {
                        result[i] = indent + 'Container' + argsPart + midSpace + bracePart;
                      }
                    }
                  }
                  return result.join('\n');
                }

                // 10. mindmap: Jison 词法规则 1 (/^(?:mindmap\b)/i) 优先级高于普通节点规则 19 (NODE_ID)，
                //     当缩进子节点裸文本以 "mindmap" 开头（如 "mindmap 思维导图"）时会被误判为图表头关键字而语法报错；
                //     在缩进与文本之间注入零宽空格 \u200B，既不改变 SPACELIST 缩进长度，又可避开关键字抢占并保留默认无框样式。
                if (/^mindmap\b/i.test(header)) {
                  return lines.map((line, idx) => {
                    if (idx <= firstContentIdx) return line;
                    return line.replace(/^(\s*)(mindmap\b)/i, '$1\u200B$2');
                  }).join('\n');
                }

                return raw;
              }

              function updateCanvasContrastCSS(isDark, theme) {
                const styleEl = document.getElementById('qs-canvas-contrast');
                if (!styleEl) return;

                const isThemeBuiltForDark = (theme === 'dark' || theme === 'neo-dark' || theme === 'redux-dark' || theme === 'redux-dark-color');
                const canvasFg = isDark ? '#F1F5F9' : '#1E293B';
                const canvasTitleFg = isDark ? '#F8FAFC' : '#0F172A';
                const canvasLine = isDark ? '#CBD5E1' : '#475569';
                const canvasSubtleLine = isDark ? '#94A3B8' : '#64748B';
                const canvasHalo = isDark ? 'rgba(24, 28, 38, 0.88)' : 'rgba(248, 250, 252, 0.9)';

                // 1. 基础跨图表补齐层（始终生效）：
                //    针对 Mermaid 源码中硬编码 #444444 / #666 / black / lightgrey、将 SVG text 误写为 color 而非 fill、
                //    或使用 mix-blend-mode: multiply 导致暗色背景下连线/文字消失的图表进行统一归正。
                let css = `
                  /* C4 架构图 (C4Context / C4Container / C4Component / C4Dynamic / C4Deployment) */
                  svg[aria-roledescription="c4"] [stroke="#444444"] {
                    stroke: ${canvasLine} !important;
                  }
                  svg[aria-roledescription="c4"] line[stroke="#444444"],
                  svg[aria-roledescription="c4"] path[stroke="#444444"] {
                    stroke-width: 1.5px !important;
                  }
                  svg[aria-roledescription="c4"] text[fill="#444444"],
                  svg[aria-roledescription="c4"] tspan[fill="#444444"] {
                    fill: ${canvasFg} !important;
                    paint-order: stroke fill;
                    stroke: ${canvasHalo};
                    stroke-width: 3.5px;
                    stroke-linejoin: round;
                  }
                  svg[aria-roledescription="c4"] > text {
                    fill: ${canvasTitleFg} !important;
                    font-size: 16px !important;
                    font-weight: 600 !important;
                  }
                  svg[aria-roledescription="c4"] defs marker path {
                    fill: ${canvasLine} !important;
                    stroke: ${canvasLine} !important;
                  }
                  svg[aria-roledescription="c4"] .c4-shape .label text,
                  svg[aria-roledescription="c4"] .c4-shape .label tspan {
                    fill: #FFFFFF !important;
                    paint-order: stroke fill;
                    stroke: rgba(15, 23, 42, 0.68);
                    stroke-width: 2.5px;
                    stroke-linejoin: round;
                  }

                  /* Packet 报文结构图与 TreeView 树形视图（源码未随主题覆盖时默认回退为 black 纯黑字） */
                  svg .packetTitle,
                  svg .treeView-title {
                    fill: ${canvasTitleFg} !important;
                    font-weight: 600;
                  }
                  svg .packetLabel,
                  svg .packetByte,
                  svg .treeView-node-label,
                  svg .treeView-node-dir {
                    fill: ${canvasFg} !important;
                  }
                  svg .packetBlock {
                    stroke: ${canvasSubtleLine} !important;
                    fill: ${isDark ? 'rgba(255, 255, 255, 0.07)' : 'rgba(15, 23, 42, 0.04)'} !important;
                  }
                  svg[aria-roledescription="treeView"] path,
                  svg[aria-roledescription="treeView"] line {
                    stroke: ${canvasSubtleLine} !important;
                  }

                  /* Radar 雷达图（源码误用 color 而非 SVG fill，导致标题/轴标签/图例在暗黑下全黑） */
                  svg .radarTitle {
                    fill: ${canvasTitleFg} !important;
                    font-weight: 600;
                  }
                  svg .radarAxisLabel,
                  svg .radarLegendText {
                    fill: ${canvasFg} !important;
                  }
                  svg .radarAxisLine {
                    stroke: ${canvasSubtleLine} !important;
                  }
                  svg .radarGraticule {
                    stroke: ${isDark ? 'rgba(255, 255, 255, 0.2)' : 'rgba(15, 23, 42, 0.16)'} !important;
                    fill: ${isDark ? 'rgba(255, 255, 255, 0.03)' : 'rgba(15, 23, 42, 0.02)'} !important;
                  }

                  /* Sankey 桑基图（源码 mix-blend-mode: multiply 在深色毛玻璃底上会正片叠底变黑消失） */
                  svg .links .link {
                    mix-blend-mode: ${isDark ? 'normal' : 'multiply'} !important;
                    stroke-opacity: ${isDark ? '0.62' : '0.5'} !important;
                  }
                  svg .node-labels text {
                    fill: ${canvasTitleFg} !important;
                  }

                  /* Architecture 架构图（源码未给服务/分组/连线文本设置 fill） */
                  svg .architecture-services text,
                  svg .architecture-services tspan,
                  svg .architecture-groups text,
                  svg .architecture-groups tspan,
                  svg .architecture-edges text,
                  svg .architecture-edges tspan {
                    fill: ${canvasFg} !important;
                  }
                  svg .architecture-groups rect.node-bkg,
                  svg .architecture-services path.node-bkg {
                    stroke: ${canvasSubtleLine} !important;
                  }

                  /* GitGraph 提交图（源码将 commit-id/msg 硬编码为 lightgrey，亮色下看不清） */
                  svg .commit-id,
                  svg .commit-msg {
                    fill: ${canvasFg} !important;
                    color: ${canvasFg} !important;
                  }
                  svg .commit-label {
                    fill: ${canvasTitleFg} !important;
                  }
                  svg .commit-label-bkg {
                    fill: ${isDark ? 'rgba(30, 41, 59, 0.85)' : 'rgba(241, 245, 249, 0.9)'} !important;
                    opacity: 0.92 !important;
                  }

                  /* Journey 用户旅程图（源码将画布任务虚线、底轴箭头与左侧角色名硬编码为 #666） */
                  svg[aria-roledescription="journey"] .task-line {
                    stroke: ${canvasSubtleLine} !important;
                  }
                  svg[aria-roledescription="journey"] line[stroke="#666"] {
                    stroke: ${canvasLine} !important;
                  }
                  svg[aria-roledescription="journey"] defs marker path {
                    fill: ${canvasLine} !important;
                    stroke: ${canvasLine} !important;
                  }
                  svg[aria-roledescription="journey"] text.legend {
                    fill: ${canvasFg} !important;
                  }
                  svg[aria-roledescription="journey"] > text {
                    fill: ${canvasTitleFg} !important;
                  }
                `;

                if (isDark) {
                  // 脑图 (mindmap) 分支连线在暗色画布下使用高亮彩线，避免与深色节点底色 cScale 一同变暗
                  css += `
                    svg[aria-roledescription="mindmap"] path.section-edge-0 { stroke: #94A3B8 !important; }
                    svg[aria-roledescription="mindmap"] path.section-edge-1 { stroke: #60A5FA !important; }
                    svg[aria-roledescription="mindmap"] path.section-edge-2 { stroke: #C084FC !important; }
                    svg[aria-roledescription="mindmap"] path.section-edge-3 { stroke: #2DD4BF !important; }
                    svg[aria-roledescription="mindmap"] path.section-edge-4 { stroke: #FB923C !important; }
                    svg[aria-roledescription="mindmap"] path.section-edge-5 { stroke: #F472B6 !important; }
                    svg[aria-roledescription="mindmap"] path.section-edge-6 { stroke: #A78BFA !important; }
                    svg[aria-roledescription="mindmap"] path.section-edge-7 { stroke: #FBBF24 !important; }
                    svg[aria-roledescription="mindmap"] path.section-edge-8 { stroke: #4ADE80 !important; }
                    svg[aria-roledescription="mindmap"] path.section-edge-9 { stroke: #818CF8 !important; }
                    svg[aria-roledescription="mindmap"] path.section-edge-10 { stroke: #38BDF8 !important; }
                    svg[aria-roledescription="mindmap"] path.section-edge-11 { stroke: #22D3EE !important; }
                  `;
                }

                // 2. 跨深浅色主题画布对比度补偿层：
                if (isDark && theme && theme !== 'auto' && !isThemeBuiltForDark) {
                  // 暗黑毛玻璃底 + 浅色系内置主题：保留节点方框内部浅底深字，将暴露在暗色毛玻璃画布上的连线、箭头、连线标签提亮
                  css += `
                    svg .edgePaths path,
                    svg .edges path,
                    svg .flowchart-link,
                    svg path.transition,
                    svg path.relation,
                    svg path.relationshipLine,
                    svg path.er.relationshipLine,
                    svg .messageLine0,
                    svg .messageLine1,
                    svg .ishikawa-line {
                      stroke: #CBD5E1 !important;
                    }
                    svg defs marker path,
                    svg defs marker circle,
                    svg defs marker line,
                    svg defs marker polygon {
                      stroke: #CBD5E1 !important;
                    }
                    svg defs marker[id*="point"] path,
                    svg defs marker[id*="point"] polygon,
                    svg defs marker[id*="barb"] path,
                    svg defs marker.composition path,
                    svg defs marker.dependency path,
                    svg defs marker#arrowhead path,
                    svg defs marker#filled-head path {
                      fill: #CBD5E1 !important;
                    }
                    svg .loopLine,
                    svg .lineWrapper line {
                      stroke: #94A3B8 !important;
                    }
                    svg circle.state-start,
                    svg [data-look="neo"].node circle.state-start {
                      fill: #E2E8F0 !important;
                      stroke: #CBD5E1 !important;
                    }
                    svg .edgeTerminals text,
                    svg .edgeTerminals span,
                    svg .edgeTerminals div,
                    svg .messageText,
                    svg .loopText,
                    svg .loopText > tspan,
                    svg g.actor-man text,
                    svg g.actor-man tspan,
                    svg .grid .tick text,
                    svg .sectionTitle,
                    svg .sectionTitle > tspan,
                    svg .titleText,
                    svg .flowchartTitleText,
                    svg .classTitleText,
                    svg .statediagramTitleText,
                    svg .erDiagramTitleText,
                    svg .requirementDiagramTitleText,
                    svg .gitTitleText,
                    svg .pieTitleText,
                    svg .pieOuterCircle + text,
                    svg .legend text,
                    svg .taskTextOutsideLeft,
                    svg .taskTextOutsideRight,
                    svg[aria-roledescription="timeline"] > g > text,
                    svg[aria-roledescription="timeline"] > text,
                    svg .ishikawa-head-label,
                    svg .ishikawa-label,
                    svg .ishikawa-label tspan,
                    svg .venn-title,
                    svg[aria-roledescription="venn"] .label,
                    svg[aria-roledescription="venn"] .label tspan,
                    svg .treemapSectionLabel,
                    svg .treemapSectionValue,
                    svg .treemapLabel,
                    svg .treemapValue {
                      fill: #F1F5F9 !important;
                      color: #F1F5F9 !important;
                    }
                    svg g.actor-man line,
                    svg g.actor-man circle {
                      stroke: #E2E8F0 !important;
                    }
                    svg .edgeLabel,
                    svg .edgeLabel span,
                    svg .edgeLabel div,
                    svg .edgeLabel p,
                    svg .edgeLabel text,
                    svg .edgeLabel tspan {
                      color: #F1F5F9 !important;
                      fill: #F1F5F9 !important;
                      background-color: transparent !important;
                    }
                    svg .edgeLabel .labelBkg,
                    svg .edgeLabel rect {
                      background-color: rgba(30, 34, 46, 0.88) !important;
                      fill: rgba(30, 34, 46, 0.88) !important;
                      opacity: 0.92 !important;
                      rx: 4px;
                      ry: 4px;
                    }
                  `;
                } else if (!isDark && isThemeBuiltForDark) {
                  // 亮色毛玻璃底 + 深色系内置主题：将暴露在浅色毛玻璃画布上的连线、箭头、连线标签加深
                  css += `
                    svg .edgePaths path,
                    svg .edges path,
                    svg .flowchart-link,
                    svg path.transition,
                    svg path.relation,
                    svg path.relationshipLine,
                    svg path.er.relationshipLine,
                    svg .messageLine0,
                    svg .messageLine1,
                    svg .ishikawa-line {
                      stroke: #334155 !important;
                    }
                    svg defs marker path,
                    svg defs marker circle,
                    svg defs marker line,
                    svg defs marker polygon {
                      stroke: #334155 !important;
                    }
                    svg defs marker[id*="point"] path,
                    svg defs marker[id*="point"] polygon,
                    svg defs marker[id*="barb"] path,
                    svg defs marker.composition path,
                    svg defs marker.dependency path,
                    svg defs marker#arrowhead path,
                    svg defs marker#filled-head path {
                      fill: #334155 !important;
                    }
                    svg .loopLine,
                    svg .lineWrapper line {
                      stroke: #64748B !important;
                    }
                    svg .edgeTerminals text,
                    svg .edgeTerminals span,
                    svg .edgeTerminals div,
                    svg .messageText,
                    svg .loopText,
                    svg .loopText > tspan,
                    svg g.actor-man text,
                    svg g.actor-man tspan,
                    svg .grid .tick text,
                    svg .sectionTitle,
                    svg .sectionTitle > tspan,
                    svg .titleText,
                    svg .flowchartTitleText,
                    svg .classTitleText,
                    svg .statediagramTitleText,
                    svg .erDiagramTitleText,
                    svg .requirementDiagramTitleText,
                    svg .gitTitleText,
                    svg .pieTitleText,
                    svg .legend text,
                    svg .taskTextOutsideLeft,
                    svg .taskTextOutsideRight,
                    svg[aria-roledescription="timeline"] > g > text,
                    svg[aria-roledescription="timeline"] > text,
                    svg .ishikawa-head-label,
                    svg .ishikawa-label,
                    svg .ishikawa-label tspan,
                    svg .venn-title,
                    svg[aria-roledescription="venn"] .label,
                    svg[aria-roledescription="venn"] .label tspan {
                      fill: #1E293B !important;
                      color: #1E293B !important;
                    }
                    svg .edgeLabel,
                    svg .edgeLabel span,
                    svg .edgeLabel div,
                    svg .edgeLabel p,
                    svg .edgeLabel text,
                    svg .edgeLabel tspan {
                      color: #1E293B !important;
                      fill: #1E293B !important;
                      background-color: transparent !important;
                    }
                    svg .edgeLabel .labelBkg,
                    svg .edgeLabel rect {
                      background-color: rgba(255, 255, 255, 0.88) !important;
                      fill: rgba(255, 255, 255, 0.88) !important;
                      opacity: 0.92 !important;
                    }
                  `;
                }

                styleEl.textContent = css;
              }

              function initMermaid(isDark, look, theme) {
                if (!window.mermaid) return;
                const selectedLook = (look === 'handDrawn' || look === 'neo') ? look : 'classic';
                const fontFamily = (selectedLook === 'handDrawn')
                  ? '"Chalkboard SE", "Bradley Hand", "Comic Sans MS", "PingFang SC", sans-serif'
                  : '-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Segoe UI", Roboto, Helvetica, Arial, sans-serif';

                updateCanvasContrastCSS(isDark, theme);

                // 修正 Mermaid dark/neo-dark/redux-dark 内部将 scaleLabelColor 设为 black、gitBranchLabel0 设为深灰、
                // attributeBackgroundColorOdd/Even 设为纯白、taskTextDarkColor 设为浅灰、以及 cScale 设为纯黑 (#0b0000 / hsl(..., 0%)) 的缺陷
                const darkSectionVars = {
                  scaleLabelColor: '#F8FAFC',
                  cScaleLabel0: '#F8FAFC',
                  cScaleLabel1: '#F8FAFC',
                  cScaleLabel2: '#F8FAFC',
                  cScaleLabel3: '#F8FAFC',
                  cScaleLabel4: '#F8FAFC',
                  cScaleLabel5: '#F8FAFC',
                  cScaleLabel6: '#F8FAFC',
                  cScaleLabel7: '#F8FAFC',
                  cScaleLabel8: '#F8FAFC',
                  cScaleLabel9: '#F8FAFC',
                  cScaleLabel10: '#F8FAFC',
                  cScaleLabel11: '#F8FAFC',
                  branchLabelColor: '#F8FAFC',
                  gitBranchLabel0: '#F8FAFC',
                  gitBranchLabel1: '#F8FAFC',
                  gitBranchLabel2: '#F8FAFC',
                  gitBranchLabel3: '#F8FAFC',
                  gitBranchLabel4: '#F8FAFC',
                  gitBranchLabel5: '#F8FAFC',
                  gitBranchLabel6: '#F8FAFC',
                  gitBranchLabel7: '#F8FAFC',
                  git0: '#334155',
                  cScale0: '#334155',
                  cScale1: '#1E3A5F',
                  cScale2: '#4C1D4B',
                  cScale3: '#1F4E5B',
                  cScale4: '#5C3418',
                  cScale5: '#5B1E2D',
                  cScale6: '#3B235A',
                  cScale7: '#5A4314',
                  cScale8: '#1B4D2E',
                  cScale9: '#2A344B',
                  cScale10: '#173B6C',
                  cScale11: '#164E63',
                  fillType0: '#1E3A5F',
                  fillType1: '#3B235A',
                  fillType2: '#1F4E5B',
                  fillType3: '#5C3418',
                  fillType4: '#4C1D4B',
                  fillType5: '#1B4D2E',
                  fillType6: '#2A344B',
                  fillType7: '#5B1E2D',
                  attributeBackgroundColorOdd: '#1E293B',
                  attributeBackgroundColorEven: '#0F172A',
                  taskTextDarkColor: '#1E293B',
                  taskTextColor: '#F8FAFC',
                  actorTextColor: '#F1F5F9',
                  pieTitleTextColor: '#F8FAFC',
                  pieLegendTextColor: '#E2E8F0',
                  xyChart: {
                    backgroundColor: 'transparent',
                    titleColor: '#F8FAFC',
                    dataLabelColor: '#F1F5F9',
                    legendTextColor: '#E2E8F0',
                    xAxisTitleColor: '#F1F5F9',
                    xAxisLabelColor: '#CBD5E1',
                    xAxisTickColor: '#94A3B8',
                    xAxisLineColor: '#94A3B8',
                    yAxisTitleColor: '#F1F5F9',
                    yAxisLabelColor: '#CBD5E1',
                    yAxisTickColor: '#94A3B8',
                    yAxisLineColor: '#94A3B8',
                    plotColorPalette: '#38BDF8,#34D399,#F472B6,#FBBF24,#A78BFA,#FB923C,#60A5FA,#4ADE80'
                  }
                };

                const lightSectionVars = {
                  scaleLabelColor: '#0F172A',
                  cScaleLabel0: '#0F172A',
                  cScaleLabel1: '#0F172A',
                  cScaleLabel2: '#0F172A',
                  cScaleLabel3: '#0F172A',
                  cScaleLabel4: '#0F172A',
                  cScaleLabel5: '#0F172A',
                  cScaleLabel6: '#0F172A',
                  cScaleLabel7: '#0F172A',
                  cScaleLabel8: '#0F172A',
                  cScaleLabel9: '#0F172A',
                  cScaleLabel10: '#0F172A',
                  cScaleLabel11: '#0F172A',
                  branchLabelColor: '#0F172A',
                  gitBranchLabel0: '#0F172A',
                  gitBranchLabel1: '#0F172A',
                  gitBranchLabel2: '#0F172A',
                  gitBranchLabel3: '#0F172A',
                  gitBranchLabel4: '#0F172A',
                  gitBranchLabel5: '#0F172A',
                  gitBranchLabel6: '#0F172A',
                  gitBranchLabel7: '#0F172A',
                  git0: '#CBD5E1',
                  cScale0: '#94A3B8',
                  cScale1: '#93C5FD',
                  cScale2: '#C4B5FD',
                  cScale3: '#86EFAC',
                  cScale4: '#FCD34D',
                  cScale5: '#F9A8D4',
                  cScale6: '#A5B4FC',
                  cScale7: '#5EEAD4',
                  cScale8: '#FDBA74',
                  cScale9: '#F0ABFC',
                  cScale10: '#7DD3FC',
                  cScale11: '#BEF264',
                  xyChart: {
                    backgroundColor: 'transparent',
                    titleColor: '#0F172A',
                    dataLabelColor: '#1E293B',
                    legendTextColor: '#334155',
                    xAxisTitleColor: '#1E293B',
                    xAxisLabelColor: '#334155',
                    xAxisTickColor: '#64748B',
                    xAxisLineColor: '#64748B',
                    yAxisTitleColor: '#1E293B',
                    yAxisLabelColor: '#334155',
                    yAxisTickColor: '#64748B',
                    yAxisLineColor: '#64748B',
                    plotColorPalette: '#2563EB,#059669,#DB2777,#D97706,#7C3AED,#EA580C,#0284C7,#16A34A'
                  }
                };

                // 跨图表子系统统一配置（C4 / Packet / TreeView / Treemap）
                const sharedDiagramConfigs = {
                  c4: {
                    useMaxWidth: true,
                    person_bg_color: '#08427B',
                    person_border_color: '#3C7FC0',
                    external_person_bg_color: '#475569',
                    external_person_border_color: '#64748B',
                    system_bg_color: '#1168BD',
                    system_border_color: '#3C7FC0',
                    system_db_bg_color: '#1168BD',
                    system_db_border_color: '#3C7FC0',
                    system_queue_bg_color: '#1168BD',
                    system_queue_border_color: '#3C7FC0',
                    external_system_bg_color: '#475569',
                    external_system_border_color: '#64748B',
                    external_system_db_bg_color: '#475569',
                    external_system_db_border_color: '#64748B',
                    external_system_queue_bg_color: '#475569',
                    external_system_queue_border_color: '#64748B',
                    container_bg_color: '#2563EB',
                    container_border_color: '#60A5FA',
                    container_db_bg_color: '#2563EB',
                    container_db_border_color: '#60A5FA',
                    container_queue_bg_color: '#2563EB',
                    container_queue_border_color: '#60A5FA',
                    external_container_bg_color: '#475569',
                    external_container_border_color: '#64748B',
                    external_container_db_bg_color: '#475569',
                    external_container_db_border_color: '#64748B',
                    external_container_queue_bg_color: '#475569',
                    external_container_queue_border_color: '#64748B',
                    component_bg_color: '#1D4ED8',
                    component_border_color: '#60A5FA',
                    component_db_bg_color: '#1D4ED8',
                    component_db_border_color: '#60A5FA',
                    component_queue_bg_color: '#1D4ED8',
                    component_queue_border_color: '#60A5FA',
                    external_component_bg_color: '#475569',
                    external_component_border_color: '#64748B',
                    external_component_db_bg_color: '#475569',
                    external_component_db_border_color: '#64748B',
                    external_component_queue_bg_color: '#475569',
                    external_component_queue_border_color: '#64748B'
                  }
                };

                if (!theme || theme === 'auto') {
                  // 自动毛玻璃模式：跟随深浅色半透明卡片
                  mermaid.initialize(Object.assign({
                    startOnLoad: false,
                    securityLevel: 'loose',
                    look: selectedLook,
                    theme: isDark ? 'dark' : 'neutral',
                    fontFamily: fontFamily,
                    themeVariables: isDark ? Object.assign({
                      darkMode: true,
                      mainBkg: 'rgba(255, 255, 255, 0.08)',
                      nodeBorder: 'rgba(255, 255, 255, 0.25)',
                      clusterBkg: 'rgba(255, 255, 255, 0.04)',
                      clusterBorder: 'rgba(255, 255, 255, 0.15)',
                      titleColor: '#F3F4F6',
                      edgeLabelBackground: 'rgba(30, 30, 40, 0.85)',
                      textColor: '#E5E7EB',
                      lineColor: '#CBD5E1',
                      arrowheadColor: '#CBD5E1',
                      relationColor: '#CBD5E1',
                      transitionColor: '#CBD5E1',
                      signalColor: '#E2E8F0',
                      actorLineColor: 'rgba(255, 255, 255, 0.45)'
                    }, darkSectionVars) : Object.assign({
                      darkMode: false,
                      mainBkg: 'rgba(0, 0, 0, 0.04)',
                      nodeBorder: 'rgba(0, 0, 0, 0.2)',
                      clusterBkg: 'rgba(0, 0, 0, 0.02)',
                      clusterBorder: 'rgba(0, 0, 0, 0.1)',
                      titleColor: '#1F2937',
                      edgeLabelBackground: 'rgba(255, 255, 255, 0.85)',
                      textColor: '#1F2937',
                      lineColor: '#475569',
                      arrowheadColor: '#475569',
                      relationColor: '#475569',
                      transitionColor: '#475569',
                      signalColor: '#334155',
                      actorLineColor: 'rgba(0, 0, 0, 0.35)'
                    }, lightSectionVars)
                  }, sharedDiagramConfigs));
                } else {
                  // Mermaid 官方原生内置主题：
                  // 注意：严禁传入 background: 'transparent'，否则 Mermaid 内部 invert('transparent') 会算出
                  // rgba(255, 255, 255, 0) 全透明色，导致 lineColor / relationColor / transitionColor 连线隐形！
                  const isThemeBuiltForDark = (theme === 'dark' || theme === 'neo-dark' || theme === 'redux-dark' || theme === 'redux-dark-color');
                  let canvasVars = {};
                  if (theme === 'dark' || theme === 'neo-dark' || theme === 'redux-dark') {
                    Object.assign(canvasVars, darkSectionVars);
                  } else if (theme === 'redux-dark-color') {
                    canvasVars.attributeBackgroundColorOdd = '#1E293B';
                    canvasVars.attributeBackgroundColorEven = '#0F172A';
                    canvasVars.taskTextDarkColor = '#1E293B';
                    canvasVars.taskTextColor = '#F8FAFC';
                    canvasVars.actorTextColor = '#F1F5F9';
                    canvasVars.pieTitleTextColor = '#F8FAFC';
                    canvasVars.pieLegendTextColor = '#E2E8F0';
                    canvasVars.xyChart = darkSectionVars.xyChart;
                  } else if (theme === 'default') {
                    canvasVars.cScaleLabel0 = '#1E293B';
                    canvasVars.cScaleLabel3 = '#1E293B';
                  }

                  if (isDark && !isThemeBuiltForDark) {
                    Object.assign(canvasVars, {
                      lineColor: '#CBD5E1',
                      arrowheadColor: '#CBD5E1',
                      defaultLinkColor: '#CBD5E1',
                      transitionColor: '#CBD5E1',
                      relationColor: '#CBD5E1',
                      archEdgeColor: '#CBD5E1',
                      archEdgeArrowColor: '#CBD5E1',
                      actorLineColor: '#94A3B8',
                      signalColor: '#E2E8F0',
                      signalTextColor: '#F1F5F9',
                      loopTextColor: '#F1F5F9',
                      titleColor: '#F8FAFC',
                      edgeLabelBackground: 'rgba(30, 34, 46, 0.88)',
                      relationLabelBackground: 'rgba(30, 34, 46, 0.88)',
                      erEdgeLabelBackground: 'rgba(30, 34, 46, 0.88)',
                      requirementEdgeLabelBackground: 'rgba(30, 34, 46, 0.88)',
                      relationLabelColor: '#F1F5F9',
                      transitionLabelColor: '#F1F5F9',
                      sequenceNumberColor: '#0F172A',
                      specialStateColor: '#E2E8F0',
                      innerEndBackground: '#E2E8F0',
                      pieTitleTextColor: '#F8FAFC',
                      pieLegendTextColor: '#E2E8F0',
                      quadrantTitleFill: '#F8FAFC',
                      quadrantXAxisTextFill: '#E2E8F0',
                      quadrantYAxisTextFill: '#E2E8F0',
                      taskTextOutsideColor: '#E2E8F0',
                      xyChart: darkSectionVars.xyChart
                    });
                  } else if (!isDark && isThemeBuiltForDark) {
                    Object.assign(canvasVars, {
                      lineColor: '#334155',
                      arrowheadColor: '#334155',
                      defaultLinkColor: '#334155',
                      transitionColor: '#334155',
                      relationColor: '#334155',
                      archEdgeColor: '#334155',
                      archEdgeArrowColor: '#334155',
                      actorLineColor: '#64748B',
                      signalColor: '#1E293B',
                      signalTextColor: '#1E293B',
                      loopTextColor: '#1E293B',
                      titleColor: '#0F172A',
                      edgeLabelBackground: 'rgba(255, 255, 255, 0.88)',
                      relationLabelBackground: 'rgba(255, 255, 255, 0.88)',
                      erEdgeLabelBackground: 'rgba(255, 255, 255, 0.88)',
                      requirementEdgeLabelBackground: 'rgba(255, 255, 255, 0.88)',
                      relationLabelColor: '#1E293B',
                      transitionLabelColor: '#1E293B',
                      sequenceNumberColor: '#FFFFFF',
                      xyChart: lightSectionVars.xyChart
                    });
                  }

                  mermaid.initialize(Object.assign({
                    startOnLoad: false,
                    securityLevel: 'loose',
                    look: selectedLook,
                    theme: theme,
                    fontFamily: fontFamily,
                    themeVariables: canvasVars
                  }, sharedDiagramConfigs));
                }
              }

              window.renderDiagram = function(code, isDark, look, theme) {
                if (renderTimer) clearTimeout(renderTimer);
                renderTimer = setTimeout(() => {
                  doRenderDiagram(code, isDark, look || 'classic', theme || 'auto');
                }, 40);
              };

              function normalizeDiagram(container, isDark, look, theme) {
                const svgEl = container.querySelector('svg');
                if (!svgEl) return;

                // 0. 手绘风格 (handDrawn) 节点衬底可读性增强：
                //    Rough.js 手绘模式默认以稀疏斜线 (fill="none" + stroke) 绘制节点填充，无实心底色；
                //    当暗黑毛玻璃画布搭配浅色系主题（节点内为深色字）或 C4 外部系统块（浅灰斜线 + 白字）时，
                //    斜线缝隙透出底色会导致文字难以辨认。此处为手绘填充路径注入同色系半透明衬底，既保留手绘笔触又确保文字锐利清晰。
                if (look === 'handDrawn') {
                  const roughPaths = svgEl.querySelectorAll('g.node path[fill="none"][stroke], g.c4-shape path[fill="none"][stroke], g.cluster path[fill="none"][stroke]');
                  roughPaths.forEach(p => {
                    const sw = parseFloat(p.getAttribute('stroke-width') || '1');
                    const d = p.getAttribute('d') || '';
                    // Rough.js hachure 阴影路径特征：stroke-width >= 2.5 或包含多段 M...L 排线
                    const mCount = (d.match(/M/g) || []).length;
                    if (sw >= 2.5 || mCount >= 4) {
                      const st = p.getAttribute('stroke') || '';
                      // 若后续兄弟节点是边框闭合路径，则在边框路径上注入半透明实心衬底
                      const nextPath = p.nextElementSibling;
                      if (nextPath && nextPath.tagName.toLowerCase() === 'path' && (!nextPath.getAttribute('fill') || nextPath.getAttribute('fill') === 'none')) {
                        nextPath.setAttribute('fill', st);
                        nextPath.setAttribute('fill-opacity', '0.82');
                      }
                    }
                  });
                }

                // 1. 根治 journey 与 c4 图表硬编码 height / 偏移 viewBox 导致的巨幅留白与标题偏置：
                //    - journey 渲染器强行写入 height="565"，且将标题高度 70px 误加至底部 viewBox；
                //    - c4 渲染器将 viewBox 起点设为 y=-70（而图形从 y=110 起绘），且将标题置于 v/2 - 200 偏左位置。
                //    此处对 c4 标题居中归位，并按实际图形几何边界 (getBBox) 收紧 journey 与 c4 的 viewBox。
                const roleDesc = svgEl.getAttribute('aria-roledescription');
                if (roleDesc === 'c4') {
                  try {
                    const c4Title = svgEl.querySelector(':scope > text');
                    if (c4Title) {
                      c4Title.style.display = 'none';
                      const shapesBox = svgEl.getBBox();
                      c4Title.style.display = '';
                      if (shapesBox && shapesBox.width > 0) {
                        c4Title.setAttribute('x', String(shapesBox.x + shapesBox.width / 2));
                        c4Title.setAttribute('y', String(shapesBox.y - 24));
                        c4Title.setAttribute('text-anchor', 'middle');
                      }
                    }
                  } catch (_) {}
                }
                if (roleDesc === 'journey' || roleDesc === 'c4') {
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
                const entityBoxes = svgEl.querySelectorAll('g[id^="entity-"] > rect.er.entityBox, g[id^="entity-"] > path');
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
                    let bx = parseFloat(box.getAttribute('x'));
                    let by = parseFloat(box.getAttribute('y'));
                    let bw = parseFloat(box.getAttribute('width'));
                    let bh = parseFloat(box.getAttribute('height'));
                    if (isNaN(bx) || isNaN(bw)) {
                      try {
                        const bbox = box.getBBox();
                        bx = bbox.x; by = bbox.y; bw = bbox.width; bh = bbox.height;
                      } catch (_) { return; }
                    }
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

              async function doRenderDiagram(code, isDark, look, theme) {
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
                  pendingRenderArgs = { code, isDark, look, theme };
                  return;
                }

                const renderId = 'mermaid-render-' + (++renderCounter);
                initMermaid(isDark, look, theme);

                try {
                  const normalizedCode = normalizeMermaidSource(code);
                  const { svg } = await mermaid.render(renderId, normalizedCode);
                  container.innerHTML = svg;
                  normalizeDiagram(container, isDark, look, theme);

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
            """#
        }
    }
}
