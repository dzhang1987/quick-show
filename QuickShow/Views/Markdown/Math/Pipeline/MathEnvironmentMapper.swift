import Foundation

// MARK: - 环境映射与列数对齐收敛

enum MathEnvironmentMapper {

    private static let envRenames: [(from: String, to: String)] = [
        ("align", "aligned"), ("align*", "aligned"),
        ("alignat", "aligned"), ("alignat*", "aligned"),
        ("eqnarray", "aligned"),
        ("gather", "matrix"), ("gather*", "matrix"), ("gathered", "matrix"),
        ("multline", "matrix"), ("multline*", "matrix"),
        ("dcases", "cases"),
        ("smallmatrix", "matrix"),
        ("array", "matrix"),
    ]

    private static let twoColumnEnvironments = ["aligned", "eqalign", "split"]

    /// 环境名映射与列数收敛
    static func mapEnvironments(_ source: String) -> String {
        var result = stripArrayColumnSpec(source)
        for (from, to) in envRenames {
            result = result.replacingOccurrences(of: "\\begin{\(from)}", with: "\\begin{\(to)}")
            result = result.replacingOccurrences(of: "\\end{\(from)}", with: "\\end{\(to)}")
        }
        result = collapseAlignedColumns(result)
        return result
    }

    /// `\begin{array}{cc|c}` → `\begin{matrix}`
    private static func stripArrayColumnSpec(_ source: String) -> String {
        let chars = Array(source)
        let beginTag = Array("\\begin{array}")
        var out = ""
        var index = 0
        while index < chars.count {
            if MathBalancedParser.matches(chars, at: index, pattern: beginTag) {
                var after = index + beginTag.count
                while after < chars.count, chars[after] == " " || chars[after] == "\n" { after += 1 }
                if after < chars.count, chars[after] == "{",
                   let specEnd = MathBalancedParser.matchingBrace(chars, openIndex: after) {
                    out.append(contentsOf: "\\begin{matrix}")
                    index = specEnd + 1
                } else {
                    out.append(contentsOf: "\\begin{matrix}")
                    index = index + beginTag.count
                }
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    private static func collapseAlignedColumns(_ source: String) -> String {
        let chars = Array(source)
        let beginTag = Array("\\begin{")
        var out = ""
        var index = 0
        while index < chars.count {
            if MathBalancedParser.matches(chars, at: index, pattern: beginTag) {
                var nameIndex = index + beginTag.count
                var name = ""
                while nameIndex < chars.count, chars[nameIndex] != "}" {
                    name.append(chars[nameIndex])
                    nameIndex += 1
                }
                if nameIndex < chars.count, twoColumnEnvironments.contains(name) {
                    let bodyStart = nameIndex + 1
                    let endTag = Array("\\end{\(name)}")
                    if let endIndex = MathBalancedParser.findPattern(chars, pattern: endTag, from: bodyStart) {
                        let body = String(chars[bodyStart..<endIndex])
                        if !body.contains("\\begin{") {
                            out.append(contentsOf: beginTag)
                            out.append(name)
                            out.append("}")
                            out.append(collapseColumns(inBody: body))
                            out.append(contentsOf: endTag)
                            index = endIndex + endTag.count
                            continue
                        }
                    }
                }
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    private static func collapseColumns(inBody body: String) -> String {
        splitRowsTopLevel(body).map { row -> String in
            let ampersands = topLevelAmpersandCount(row)
            if ampersands == 0 { return row + " &" }
            if ampersands > 1 { return replaceAmpersandsAfterFirst(row) }
            return row
        }.joined(separator: "\\\\")
    }

    private static func splitRowsTopLevel(_ body: String) -> [String] {
        let chars = Array(body)
        var rows: [String] = []
        var current = ""
        var depth = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "{" { depth += 1; current.append(char); index += 1; continue }
            if char == "}" { depth -= 1; current.append(char); index += 1; continue }
            if depth == 0, char == "\\", index + 1 < chars.count, chars[index + 1] == "\\" {
                rows.append(current)
                current = ""
                index += 2
                while index < chars.count, chars[index] == " " { index += 1 }
                continue
            }
            current.append(char)
            index += 1
        }
        rows.append(current)
        return rows
    }

    private static func topLevelAmpersandCount(_ row: String) -> Int {
        var depth = 0
        var count = 0
        for char in row {
            if char == "{" { depth += 1 } else if char == "}" { depth -= 1 }
            else if char == "&", depth == 0 { count += 1 }
        }
        return count
    }

    private static func replaceAmpersandsAfterFirst(_ row: String) -> String {
        let chars = Array(row)
        var out = ""
        var depth = 0
        var ampersandsSeen = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "{" { depth += 1; out.append(char); index += 1; continue }
            if char == "}" { depth -= 1; out.append(char); index += 1; continue }
            if char == "&", depth == 0 {
                ampersandsSeen += 1
                if ampersandsSeen == 1 {
                    out.append(char)
                } else {
                    out.append(" \\quad ")
                }
                index += 1
                continue
            }
            out.append(char)
            index += 1
        }
        return out
    }

    /// 单列 cases 补列
    static func padSingleColumnCases(_ source: String) -> String {
        let chars = Array(source)
        let beginTag = Array("\\begin{cases}")
        let endTag = Array("\\end{cases}")
        var out = ""
        var index = 0
        while index < chars.count {
            if MathBalancedParser.matches(chars, at: index, pattern: beginTag) {
                let bodyStart = index + beginTag.count
                if let endIndex = MathBalancedParser.findPattern(chars, pattern: endTag, from: bodyStart) {
                    let body = String(chars[bodyStart..<endIndex])
                    out.append(contentsOf: beginTag)
                    out.append(body.contains("&") ? body : padCaseRows(body))
                    out.append(contentsOf: endTag)
                    index = endIndex + endTag.count
                    continue
                }
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    private static func padCaseRows(_ body: String) -> String {
        let chars = Array(body)
        var rows: [String] = []
        var current = ""
        var depth = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "{" { depth += 1; current.append(char); index += 1; continue }
            if char == "}" { depth -= 1; current.append(char); index += 1; continue }
            if depth == 0, char == "\\", index + 1 < chars.count, chars[index + 1] == "\\" {
                rows.append(current)
                current = ""
                index += 2
                continue
            }
            current.append(char)
            index += 1
        }
        rows.append(current)
        let padded = rows.map { row -> String in
            row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? row : row + " &"
        }
        return padded.joined(separator: "\\\\")
    }
}
