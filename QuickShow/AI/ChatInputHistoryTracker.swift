import Foundation

// MARK: - 输入历史模型与导航跟踪器

/// 用户输入历史项（包含文本 Prompt 与关联的图片附件）。
struct ChatInputHistoryItem: Equatable {
    var content: String
    var images: [ChatImageAttachment]

    /// 内容等价判定：忽略附件各自生成的随机 UUID，纯按 Prompt 文本与原图二进制数据严格对比。
    static func isContentEqual(_ lhs: ChatInputHistoryItem, _ rhs: ChatInputHistoryItem) -> Bool {
        guard lhs.content == rhs.content else { return false }
        guard lhs.images.count == rhs.images.count else { return false }
        for (lImg, rImg) in zip(lhs.images, rhs.images) {
            if lImg.base64JPEG != rImg.base64JPEG { return false }
        }
        return true
    }
}

/// 输入历史跟踪器：负责在 AI Chat 输入坞中清空状态下通过上下箭头快速翻阅历史用户消息。
///
/// 遵循经典终端（Terminal / Readline）心智模型：
/// 1. 门控判定：仅在输入坞为「清空状态」（文本与附件皆空）且非 IME 组字中时，按 `↑` 允许激活历史浏览模式；
/// 2. 浏览态穿梭：
///    - `↑`（上箭头）：向更早（更老）的一条用户消息回溯，到达最早历史条目后停留在最早项；
///    - `↓`（下箭头）：向更新的一条用户消息前进；当越过最新一条历史项后，自动还原最初暂存的清空状态并退出浏览模式；
/// 3. 相邻去重（HIST_IGNORE_DUPS）：自动跳过连续重复的 Prompt 及附件，防止翻阅时界面无变化；
/// 4. 安全脱离：一旦用户手动修改文本或增删附件，立即脱离历史浏览模式，上下箭头恢复原生文本光标移动。
@MainActor
final class ChatInputHistoryTracker {
    /// 导航结果枚举
    enum NavigationResult: Equatable {
        case updated(ChatInputHistoryItem)
        case unhandled
    }

    /// 当前浏览历史的倒序索引（0 表示倒数第 1 条即最新历史，1 表示倒数第 2 条...）。
    /// 为 nil 时表示未处于历史浏览状态。
    private(set) var browsingIndex: Int?

    /// 进入历史浏览模式前的草稿暂存（通常是清空状态，供向下越界退出时无损还原）。
    private(set) var stashedDraft: ChatInputHistoryItem?

    /// 当前所展示历史项的快照（用于检测用户是否在此基础上做出了手动修改）。
    private(set) var currentPresentedItem: ChatInputHistoryItem?

    /// 是否正处于历史浏览状态
    var isBrowsing: Bool { browsingIndex != nil }

    /// 从会话消息列表中提取所有用户发送的消息，并执行相邻重复去重。
    /// 返回的列表按时间正序排列（最早在前，最新在末尾）。
    func historyItems(from messages: [ChatMessage]) -> [ChatInputHistoryItem] {
        let userMessages = messages.filter { $0.role == .user && (!$0.content.isEmpty || !$0.images.isEmpty) }
        var result: [ChatInputHistoryItem] = []
        for msg in userMessages {
            let item = ChatInputHistoryItem(content: msg.content, images: msg.images)
            if let last = result.last, ChatInputHistoryItem.isContentEqual(last, item) {
                continue
            }
            result.append(item)
        }
        return result
    }

    /// 向上翻历史（上箭头 ↑）：
    /// - 若尚未进入历史模式：输入框为空时激活历史模式，暂存空草稿并调出最新一条；
    /// - 若已处于历史模式：回溯到更早的一条，已至最老项时保持在最老项。
    func navigateUp(
        currentText: String,
        currentImages: [ChatImageAttachment],
        messages: [ChatMessage]
    ) -> NavigationResult {
        let history = historyItems(from: messages)
        guard !history.isEmpty else { return .unhandled }

        if let currentIdx = browsingIndex {
            let nextIdx = currentIdx + 1
            if nextIdx < history.count {
                browsingIndex = nextIdx
                let targetItem = history[history.count - 1 - nextIdx]
                currentPresentedItem = targetItem
                return .updated(targetItem)
            } else {
                // 已至最早历史项，保持在最早项，消费事件
                if let presented = currentPresentedItem {
                    return .updated(presented)
                }
                return .unhandled
            }
        } else {
            // 未在浏览中：只有在清空状态下才允许进入历史浏览
            guard currentText.isEmpty && currentImages.isEmpty else {
                return .unhandled
            }
            stashedDraft = ChatInputHistoryItem(content: currentText, images: currentImages)
            browsingIndex = 0
            let targetItem = history[history.count - 1]
            currentPresentedItem = targetItem
            return .updated(targetItem)
        }
    }

    /// 向下翻历史（下箭头 ↓）：
    /// - 若未处于历史模式：放行不拦截（原生光标向下移动）；
    /// - 若处于历史模式：
    ///   - 若尚未到最新条目（currentIdx > 0）：前进至更新的一条；
    ///   - 若已在最新条目（currentIdx == 0）：恢复初始草稿（清空态）并退出历史模式。
    func navigateDown(
        currentText: String,
        currentImages: [ChatImageAttachment],
        messages: [ChatMessage]
    ) -> NavigationResult {
        guard let currentIdx = browsingIndex else {
            return .unhandled
        }

        let history = historyItems(from: messages)

        if currentIdx > 0 {
            let nextIdx = currentIdx - 1
            browsingIndex = nextIdx
            let targetItem = history[history.count - 1 - nextIdx]
            currentPresentedItem = targetItem
            return .updated(targetItem)
        } else {
            // 越过最新条目，还原进入前的暂存草稿并彻底退出
            let restored = stashedDraft ?? ChatInputHistoryItem(content: "", images: [])
            reset()
            return .updated(restored)
        }
    }

    /// 用户发生手动编辑检测：若当前文本或附件与快照不一致，立即重置并退出历史模式。
    func onUserEdited(newText: String, newImages: [ChatImageAttachment]) {
        guard browsingIndex != nil else { return }
        guard let presented = currentPresentedItem else {
            reset()
            return
        }
        let current = ChatInputHistoryItem(content: newText, images: newImages)
        if !ChatInputHistoryItem.isContentEqual(current, presented) {
            reset()
        }
    }

    /// 重置并退出历史浏览状态。
    func reset() {
        browsingIndex = nil
        stashedDraft = nil
        currentPresentedItem = nil
    }
}
