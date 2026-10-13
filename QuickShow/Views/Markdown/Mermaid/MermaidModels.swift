import Foundation

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
