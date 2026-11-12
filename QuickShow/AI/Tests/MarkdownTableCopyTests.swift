import Foundation

// MARK: - 表格复制 / 下载序列化单元测试

/// 定向回归（--test-table-copy）：Markdown / TSV / CSV 三路径序列化契约。
/// 纯 AST → 字符串变换，无 UI / 网络依赖，Release 下以 exit code 判定成败。
enum MarkdownTableCopyTests {
    private static var passedCount = 0
    private static var failedCount = 0

    private static func assertTest(_ condition: Bool, _ name: String, file: String = #file, line: Int = #line) {
        if condition {
            passedCount += 1
            print("  ✅ [PASS] \(name)")
        } else {
            failedCount += 1
            print("  ❌ [FAIL] \(name) (at \(URL(fileURLWithPath: file).lastPathComponent):\(line))")
        }
    }

    static func run() {
        print("==================================================")
        print("📋 开始执行表格复制 / 下载序列化测试")
        print("==================================================")
        passedCount = 0
        failedCount = 0

        testMarkdownStructureAndAlignment()
        testMarkdownInlineReconstruction()
        testTSVPlainAndSanitization()
        testCSVQuoting()
        testEmptyTable()

        print("==================================================")
        print("📊 表格序列化测试完成汇总：通过 \(passedCount) 项，失败 \(failedCount) 项")
        print("==================================================")
        if failedCount > 0 {
            exit(1)
        }
        print("🎉 表格复制 / 下载序列化测试全部通过！")
        exit(0)
    }

    // MARK: - 1. Markdown 结构与对齐分隔行

    private static func testMarkdownStructureAndAlignment() {
        let table = MarkdownTable(
            headers: [[.text("型号")], [.text("封装")]],
            rows: [
                [[.text("DLX001E")], [.text("DFN-12")]],
                [[.text("DIO8936")], [.text("QN48")]]
            ],
            alignments: [nil, .center]
        )
        let expected = """
        | 型号 | 封装 |
        | --- | :---: |
        | DLX001E | DFN-12 |
        | DIO8936 | QN48 |
        """
        assertTest(table.copyMarkdown == expected, "Markdown 表头 / 对齐分隔行 / 数据行结构精确")

        let allAlignments = MarkdownTable(
            headers: [[.text("a")], [.text("b")], [.text("c")], [.text("d")]],
            rows: [],
            alignments: [nil, .left, .center, .right]
        )
        assertTest(
            allAlignments.copyMarkdown == "| a | b | c | d |\n| --- | :--- | :---: | ---: |",
            "四档对齐（默认 / 左 / 中 / 右）分隔行映射精确"
        )
    }

    // MARK: - 2. Markdown 行内重建与单元格转义

    private static func testMarkdownInlineReconstruction() {
        let cell: [InlineToken] = [
            .bold([.text("粗")]),
            .text(" "),
            .code("a`b"),
            .text(" "),
            .link(text: [.text("链")], url: "https://x.y", title: nil),
            .text(" "),
            .math("e=mc^2"),
            .text(" p|q"),
            .lineBreak,
            .text("r"),
            .footnoteRef("1")
        ]
        let table = MarkdownTable(headers: [cell], rows: [], alignments: [nil])
        let expected = "| **粗** `` a`b `` [链](https://x.y) $e=mc^2$ p\\|q<br>r[^1] |\n| --- |"
        assertTest(table.copyMarkdown == expected, "行内语法重建 + 竖线转义 + 硬换行 <br> + 脚注引用")
    }

    // MARK: - 3. TSV 纯文本化与结构 sanitization

    private static func testTSVPlainAndSanitization() {
        let table = MarkdownTable(
            headers: [[.bold([.text("型号")])], [.text("备注")]],
            rows: [
                [
                    [.link(text: [.text("DLX001E")], url: "https://x.y", title: nil)],
                    [.text("x\ty\nz"), .code("c")]
                ]
            ],
            alignments: [nil, nil]
        )
        let expected = "型号\t备注\nDLX001E\tx y zc"
        assertTest(table.copyTSV == expected, "TSV 格式剥离 / 链接取文字 / 制表符换行折空格")
    }

    // MARK: - 4. CSV RFC 4180 引号规则

    private static func testCSVQuoting() {
        let table = MarkdownTable(
            headers: [[.text("a")], [.text("b")]],
            rows: [
                [[.text("plain")], [.text("a,b\"c\nd")]],
                [[.text("x\ty")], [.text("ok")]]
            ],
            alignments: [nil, nil]
        )
        let expected = "a,b\r\nplain,\"a,b\"\"c\nd\"\r\nx\ty,ok"
        assertTest(table.copyCSV == expected, "CSV 特殊字符字段加引号 / 引号 doubling / CRLF 行尾")
    }

    // MARK: - 5. 空表边界

    private static func testEmptyTable() {
        let empty = MarkdownTable(headers: [], rows: [], alignments: [])
        assertTest(empty.copyMarkdown == "", "空表 Markdown 为空串")
        assertTest(empty.copyTSV == "", "空表 TSV 为空串")
        assertTest(empty.copyCSV == "", "空表 CSV 为空串")
    }
}
