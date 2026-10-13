import Foundation

// MARK: - 基础扫描与花括号平衡匹配器

enum MathBalancedParser {

    /// 在 chars 的 index 处是否精确匹配 pattern。
    static func matches(_ chars: [Character], at index: Int, pattern: [Character]) -> Bool {
        guard index + pattern.count <= chars.count else { return false }
        for offset in 0..<pattern.count where chars[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    /// 从 from 起查找 pattern 首次出现的位置。
    static func findPattern(_ chars: [Character], pattern: [Character], from: Int) -> Int? {
        var index = from
        while index < chars.count {
            if matches(chars, at: index, pattern: pattern) { return index }
            index += 1
        }
        return nil
    }

    /// openIndex 指向 `{`，返回配对 `}` 的下标（含嵌套花括号深度计数）。
    static func matchingBrace(_ chars: [Character], openIndex: Int) -> Int? {
        guard openIndex < chars.count, chars[openIndex] == "{" else { return nil }
        var depth = 0
        var index = openIndex
        while index < chars.count {
            if chars[index] == "{" {
                depth += 1
            } else if chars[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// 替换命令名时要求后一个字符不是字母（命令边界），避免 `\dfracX` 之类被误伤。
    static func replaceCommand(_ source: String, command: String, with replacement: String) -> String {
        let chars = Array(source)
        let pattern = Array(command)
        var out = ""
        out.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            if matches(chars, at: index, pattern: pattern) {
                let after = index + pattern.count
                if after >= chars.count || !chars[after].isLetter {
                    out.append(contentsOf: replacement)
                    index = after
                    continue
                }
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }
}
