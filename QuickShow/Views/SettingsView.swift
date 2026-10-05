import SwiftUI
import AppKit
import os
import ServiceManagement
import EventKit

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general = "通用"
    case statusBar = "一瞥底栏"
    case dashboard = "监控看板"
    case aiService = "AI 服务"
    case shortcuts = "快捷键设置"
    case about = "关于"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .statusBar: return "sparkles"
        case .dashboard: return "gauge.with.needle.fill"
        case .aiService: return "brain.head.profile"
        case .shortcuts: return "command"
        case .about: return "info.circle.fill"
        }
    }
    
    var iconColor: Color {
        switch self {
        case .general: return Color.gray
        case .statusBar: return Color.cyan
        case .dashboard: return Color.blue
        case .aiService: return Color.indigo
        case .shortcuts: return Color.orange
        case .about: return Color.purple
        }
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: SettingsTab? = .general
    @State private var launchAtLogin: Bool = false
    @State private var isCalendarAuthorized: Bool = false
    @State private var isLocationAuthorized: Bool = false
    
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.doubleColumn)) {
            // 左侧原生 macOS 侧边栏
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                NavigationLink(value: tab) {
                    Label {
                        Text(tab.rawValue)
                            .font(.system(size: Theme.Typography.badge, weight: .medium))
                    } icon: {
                        Image(systemName: tab.iconName)
                            .font(.system(size: Theme.Typography.body, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .fill(tab.iconColor)
                            )
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 240)
            .safeAreaInset(edge: .top) {
                // 留出左上角沉浸式红绿灯避让间距
                Spacer().frame(height: 32)
            }
        } detail: {
            // 右侧详情：纯正的 macOS 原生 .formStyle(.grouped)。
            // 显式 ScrollView 接管滚动：此前内容（~822pt）溢出 hosting 视口（506pt）时
            // SwiftUI 自动包了 HostingScrollView，其滚动指示条是 CALayer 自绘——玻璃
            // 环境下退化成常驻宽体、闲置不淡出，且不挂 verticalScroller（AppKit 清扫
            // 扑空）、不属 SwiftUI ScrollView 节点（.scrollIndicators 无目标）两侧都
            // 管不到；显式接管后指示条回到 SwiftUI 管辖，.scrollIndicators 直接生效。
            ScrollView {
                Group {
                    switch selectedTab ?? .general {
                    case .general:
                        GeneralSettingsForm(appState: appState, launchAtLogin: $launchAtLogin)
                    case .statusBar:
                        StatusBarSettingsForm(appState: appState, isLocationAuthorized: $isLocationAuthorized)
                    case .dashboard:
                        DashboardSettingsForm(appState: appState, isCalendarAuthorized: $isCalendarAuthorized)
                    case .aiService:
                        AIServiceSettingsForm(appState: appState)
                    case .shortcuts:
                        ShortcutsSettingsForm(appState: appState)
                    case .about:
                        AboutSettingsForm()
                    }
                }
                .formStyle(.grouped)
            }
            .scrollIndicators(.never, axes: .vertical)
            .navigationTitle(selectedTab?.rawValue ?? "设置")
        }
        .frame(minWidth: 700, minHeight: 480)
        // AppKit 桥接层 legacy scroller 清扫：Form(.grouped) 底层 NSScrollView 在玻璃
        // contentView 嵌套环境下挂出 legacy 常驻宽体 NSScroller（thumb 冻结失联的死控件），
        // SwiftUI .scrollIndicators 管不到 AppKit 层，须遍历窗口树关闭。
        .background(LegacyScrollerSweeper())
        .onAppear {
            checkLaunchAtLoginStatus()
            checkCalendarStatus()
            checkLocationStatus()
        }
    }
    
    private func checkLocationStatus() {
        isLocationAuthorized = appState.isLocationAuthorized
    }
    
    private func checkCalendarStatus() {
        let status = SystemStatusProvider.shared.getCalendarAuthorizationStatus()
        if #available(macOS 14.0, *) {
            isCalendarAuthorized = (status == .fullAccess || status == .authorized)
        } else {
            isCalendarAuthorized = (status == .authorized)
        }
    }
    
    private func checkLaunchAtLoginStatus() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - 基础组件: 按键微胶囊
struct KeyBadge: View {
    let key: String
    
    var body: some View {
        Text(key)
            .font(.system(size: Theme.Typography.keyCap, weight: .bold, design: .monospaced))
            .foregroundColor(.primary.opacity(0.88))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.90))
                    .shadow(color: Color.black.opacity(0.08), radius: 1, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.75)
            )
    }
}

// MARK: - AppKit 桥接层 legacy scroller 清扫
//
// Form(.grouped) 底层桥接的 NSScrollView 在玻璃 contentView（NSGlassEffectView）嵌套
// 环境下可能挂出 legacy 常驻宽体 scroller（thumb 冻结失联的死控件）——SwiftUI
// .scrollIndicators 管不到 AppKit 桥接层，此处兜底关闭。根治靠 .scrollIndicators(.never)
//（Form 层：macOS 接鼠标时系统会忽略 .hidden，仅 .never 可覆盖常显行为）。
// 时机：视图挂窗与每次 SwiftUI body 重建（覆盖 tab 切换重建 Form 产生新
// NSScrollView 的场景）；修复动作幂等无副作用。
private struct LegacyScrollerSweeper: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.sweep(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.sweep(view.window) }
    }

    private static func sweep(_ window: NSWindow?) {
        guard let root = window?.contentView else { return }
        walk(root)
    }

    private static func walk(_ view: NSView) {
        if let scroll = view as? NSScrollView, scroll.hasVerticalScroller {
            scroll.hasVerticalScroller = false
        }
        if let scroller = view as? NSScroller {
            scroller.isHidden = true
        }
        view.subviews.forEach(walk)
    }
}
