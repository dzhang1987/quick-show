import Foundation

// MARK: - 图片拆段单元

/// 图片拆段后的显示单元：文本段（继续行内渲染）或图片项（交给 `MarkdownImageView`）。
/// `linkURL` 非 nil 表示该图片来自链接内嵌（`[![alt](img)](link)`），成功态可点击打开。
enum InlineDisplaySegment {
    case text([InlineToken])
    case image(alt: String, url: String, title: String?, linkURL: String?)
}

// MARK: - AST 属性与语义检查（公式 / 图片 / 东亚注音）

extension InlineToken {
    /// 递归检测是否包含数学公式
    var containsMath: Bool {
        switch self {
        case .math:
            return true
        case let .bold(inner), let .italic(inner),
             let .strikethrough(inner), let .underline(inner), let .highlight(inner),
             let .superscript(inner):
            return inner.containsMath
        case let .`subscript`(inner):
            return inner.containsMath
        case let .link(text, _, _):
            return text.containsMath
        case let .ruby(base, _, _):
            return base.containsMath
        case .text, .code, .kbd, .image, .lineBreak, .footnoteRef:
            return false
        }
    }

    /// 递归检测是否包含东亚文字注音（Ruby）
    var containsRuby: Bool {
        switch self {
        case .ruby:
            return true
        case let .bold(inner), let .italic(inner),
             let .strikethrough(inner), let .underline(inner), let .highlight(inner),
             let .superscript(inner), let .`subscript`(inner):
            return inner.containsRuby
        case let .link(text, _, _):
            return text.containsRuby
        case .text, .code, .kbd, .image, .lineBreak, .footnoteRef, .math:
            return false
        }
    }
}

extension Array where Element == InlineToken {
    /// 是否含公式 token（递归粗体/斜体/链接/删除线/下划线/高亮/上下标内部）。
    var containsMath: Bool { contains { $0.containsMath } }

    /// 是否含东亚文字注音
    var containsRuby: Bool { contains { $0.containsRuby } }

    /// 是否含**顶层**图片 token（不递归进入链接内层）。
    var containsTopLevelImage: Bool {
        contains { if case .image = $0 { return true } else { return false } }
    }

    /// 是否触发图片拆段：顶层 `.image`，或顶层 `.link` 的 text 顶层含 `.image`（即 `[![alt](img)](link)`）。
    var containsImage: Bool {
        contains { token in
            switch token {
            case .image:
                return true
            case let .link(text, _, _):
                return text.containsTopLevelImage
            default:
                return false
            }
        }
    }

    /// 仅按顶层 `.image` 拆段，供链接内层拆解复用。
    var topLevelImageSegments: [InlineDisplaySegment] {
        var segments: [InlineDisplaySegment] = []
        var buffer: [InlineToken] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            segments.append(.text(buffer))
            buffer.removeAll()
        }
        for token in self {
            if case let .image(alt, url, title) = token {
                flush()
                segments.append(.image(alt: alt, url: url, title: title, linkURL: nil))
            } else {
                buffer.append(token)
            }
        }
        flush()
        return segments
    }

    /// 把顶层 token 序列拆为交替的文本段与图片项：顺序保持，连续文本归一段，图片各自成项。
    var imageSegments: [InlineDisplaySegment] {
        var segments: [InlineDisplaySegment] = []
        var buffer: [InlineToken] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            segments.append(.text(buffer))
            buffer.removeAll()
        }
        for token in self {
            switch token {
            case let .image(alt, url, title):
                flush()
                segments.append(.image(alt: alt, url: url, title: title, linkURL: nil))
            case let .link(text, linkURL, _) where text.containsTopLevelImage:
                for inner in text.topLevelImageSegments {
                    switch inner {
                    case let .image(alt, url, title, _):
                        flush()
                        segments.append(.image(alt: alt, url: url, title: title, linkURL: linkURL))
                    case let .text(tokens):
                        buffer.append(contentsOf: tokens)
                    }
                }
            default:
                buffer.append(token)
            }
        }
        flush()
        return segments
    }
}
