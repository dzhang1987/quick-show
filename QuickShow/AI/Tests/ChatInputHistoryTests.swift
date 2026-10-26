import Foundation

// MARK: - 输入坞历史导航单元测试

@MainActor
enum ChatInputHistoryTests {
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
        print("📜 开始执行输入坞历史导航与状态机测试")
        print("==================================================")
        passedCount = 0
        failedCount = 0

        testEmptyHistoryDoesNotNavigate()
        testNonEmptyInputCannotTriggerHistory()
        testHistoryNavigationSequence()
        testAdjacentDuplicateFiltering()
        testHistoryWithImageAttachments()
        testUserEditingExitsHistoryMode()

        print("==================================================")
        print("📊 历史导航测试完成汇总：通过 \(passedCount) 项，失败 \(failedCount) 项")
        print("==================================================")
        assert(failedCount == 0, "存在未通过的历史导航测试用例")
    }

    private static func createMessage(role: ChatMessage.Role, content: String, images: [ChatImageAttachment] = []) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: role,
            content: content,
            state: .done,
            images: images,
            createdAt: Date()
        )
    }

    /// 1. 空历史列表时不触发导航
    private static func testEmptyHistoryDoesNotNavigate() {
        let tracker = ChatInputHistoryTracker()
        let result = tracker.navigateUp(currentText: "", currentImages: [], messages: [])
        assertTest(result == .unhandled, "空历史列表按 ↑ 返回 unhandled")
        assertTest(!tracker.isBrowsing, "未进入浏览模式")

        let downResult = tracker.navigateDown(currentText: "", currentImages: [], messages: [])
        assertTest(downResult == .unhandled, "未浏览状态按 ↓ 返回 unhandled")
    }

    /// 2. 非空输入框（已有草稿打字中）绝不误触历史切换
    private static func testNonEmptyInputCannotTriggerHistory() {
        let tracker = ChatInputHistoryTracker()
        let messages = [createMessage(role: .user, content: "你好")]

        let result = tracker.navigateUp(currentText: "正在输入的草稿", currentImages: [], messages: messages)
        assertTest(result == .unhandled, "有草稿内容时按 ↑ 不拦截")
        assertTest(!tracker.isBrowsing, "有草稿时不激活浏览模式")
    }

    /// 3. 标准历史切换序列（最新倒序、穿梭、越界还原清空态）
    private static func testHistoryNavigationSequence() {
        let tracker = ChatInputHistoryTracker()
        let messages = [
            createMessage(role: .user, content: "第一条消息"),
            createMessage(role: .assistant, content: "回复 1"),
            createMessage(role: .user, content: "第二条消息"),
            createMessage(role: .assistant, content: "回复 2"),
            createMessage(role: .user, content: "第三条消息")
        ]

        // 首次 ↑：调出最新一条（第三条）
        let up1 = tracker.navigateUp(currentText: "", currentImages: [], messages: messages)
        assertTest(up1 == .updated(ChatInputHistoryItem(content: "第三条消息", images: [])), "首次 ↑ 调出最新一条")
        assertTest(tracker.isBrowsing, "处于浏览模式")

        // 再次 ↑：调出上一条（第二条）
        let up2 = tracker.navigateUp(currentText: "第三条消息", currentImages: [], messages: messages)
        assertTest(up2 == .updated(ChatInputHistoryItem(content: "第二条消息", images: [])), "再次 ↑ 调出第二条")

        // 再次 ↑：调出最早一条（第一条）
        let up3 = tracker.navigateUp(currentText: "第二条消息", currentImages: [], messages: messages)
        assertTest(up3 == .updated(ChatInputHistoryItem(content: "第一条消息", images: [])), "再次 ↑ 调出第一条")

        // 再次 ↑：已至最早，保持在第一条
        let up4 = tracker.navigateUp(currentText: "第一条消息", currentImages: [], messages: messages)
        assertTest(up4 == .updated(ChatInputHistoryItem(content: "第一条消息", images: [])), "到顶后 ↑ 保持在第一条")

        // 按 ↓：回到第二条
        let down1 = tracker.navigateDown(currentText: "第一条消息", currentImages: [], messages: messages)
        assertTest(down1 == .updated(ChatInputHistoryItem(content: "第二条消息", images: [])), "按 ↓ 回到第二条")

        // 按 ↓：回到第三条
        let down2 = tracker.navigateDown(currentText: "第二条消息", currentImages: [], messages: messages)
        assertTest(down2 == .updated(ChatInputHistoryItem(content: "第三条消息", images: [])), "按 ↓ 回到最新一条")

        // 按 ↓：越界退出，恢复进入前的空状态
        let down3 = tracker.navigateDown(currentText: "第三条消息", currentImages: [], messages: messages)
        assertTest(down3 == .updated(ChatInputHistoryItem(content: "", images: [])), "越界 ↓ 还原为空状态")
        assertTest(!tracker.isBrowsing, "退出浏览模式")
    }

    /// 4. 相邻重复项去重（HIST_IGNORE_DUPS）
    private static func testAdjacentDuplicateFiltering() {
        let tracker = ChatInputHistoryTracker()
        let messages = [
            createMessage(role: .user, content: "A"),
            createMessage(role: .user, content: "B"),
            createMessage(role: .user, content: "B"), // 重复
            createMessage(role: .user, content: "C")
        ]

        let items = tracker.historyItems(from: messages)
        assertTest(items.map(\.content) == ["A", "B", "C"], "相邻重复内容成功去重")
    }

    /// 5. 图片附件随历史完整回填
    private static func testHistoryWithImageAttachments() {
        let tracker = ChatInputHistoryTracker()
        let dummyImg = ChatImageAttachment(
            id: UUID(),
            base64JPEG: "sampleBase64ImageData",
            pixelWidth: 100,
            pixelHeight: 100,
            byteCount: 1024
        )
        let messages = [
            createMessage(role: .user, content: "纯文本"),
            createMessage(role: .user, content: "带图提问", images: [dummyImg])
        ]

        let up1 = tracker.navigateUp(currentText: "", currentImages: [], messages: messages)
        if case .updated(let item) = up1 {
            assertTest(item.content == "带图提问", "带图提问文本正确")
            assertTest(item.images.count == 1, "回填附件数量正确")
            assertTest(item.images.first?.base64JPEG == "sampleBase64ImageData", "附件图片内容一致")
        } else {
            assertTest(false, "带图历史回填失败")
        }

        let up2 = tracker.navigateUp(currentText: "带图提问", currentImages: [dummyImg], messages: messages)
        if case .updated(let item) = up2 {
            assertTest(item.content == "纯文本", "上一条纯文本正确")
            assertTest(item.images.isEmpty, "上一条附件为空")
        } else {
            assertTest(false, "纯文本历史回填失败")
        }
    }

    /// 6. 用户手动修改文本时立即安全脱离历史模式
    private static func testUserEditingExitsHistoryMode() {
        let tracker = ChatInputHistoryTracker()
        let messages = [
            createMessage(role: .user, content: "原始问题")
        ]

        _ = tracker.navigateUp(currentText: "", currentImages: [], messages: messages)
        assertTest(tracker.isBrowsing, "进入历史模式")

        // 模拟用户追加字符
        tracker.onUserEdited(newText: "原始问题并且继续打字", newImages: [])
        assertTest(!tracker.isBrowsing, "用户修改文本后立即脱离历史模式")

        // 再次按 ↑ / ↓ 不再拦截
        let down = tracker.navigateDown(currentText: "原始问题并且继续打字", currentImages: [], messages: messages)
        assertTest(down == .unhandled, "脱离后按 ↓ 放行原生光标移动")
    }
}
