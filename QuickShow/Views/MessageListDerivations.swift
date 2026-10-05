// 从 AIChatMessageList.swift 机械拆分：SessionMessageList 的纯派生计算
// （消息分组缓存接入 / 刻度轨取样与当前条定位 / 压缩卡与边界 / 最后可重生成与可编辑消息）。
// 全部为无状态静态辅助，输入显式传参；滚动与虚拟化状态机不在此文件、亦不由此文件触碰。

import AppKit
import Combine
import SwiftUI

// MARK: - 单会话消息列表派生计算

/// SessionMessageList 的纯派生计算集合：计算体逐字迁移自视图计算属性，
/// 仅将隐式依赖（messages / @State / state 门面）改为显式入参，输出与迁移前逐字一致。
enum MessageListDerivations {

    // MARK: - 分组缓存

    /// 消息分组：委托 MessageGroupingCache（messages 底层存储未变则复用上次分组结果）。
    /// 缓存实例仍由视图 @State 持有，本函数只是把调用点收敛到派生计算命名空间。
    static func groupedMessages(cache: MessageGroupingCache,
                                messages: [ChatMessage]) -> [MessageGroup] {
        cache.groups(for: messages)
    }

    // MARK: - 刻度轨

    /// 刻度轨数据源：当前会话全部用户消息；超过 chatTickMaxCount 时按视口取样——
    /// 以「当前条」锚点为中心保留前后各半（密度主由轨内自适应 pitch 承担，取样仅作极端兜底）。
    /// - Parameters:
    ///   - messages: 本会话全部消息。
    ///   - currentTickMessageId: 「当前条」用户消息 id（视图侧由当前视口锚点派生，可 nil）。
    static func tickMessages(messages: [ChatMessage],
                             currentTickMessageId: UUID?) -> [ChatMessage] {
        let users = messages.filter { $0.role == .user }
        let limit = Theme.Layout.chatTickMaxCount
        guard users.count > limit else { return users }
        let anchorId = currentTickMessageId ?? users.last?.id
        guard let anchorId, let index = users.firstIndex(where: { $0.id == anchorId }) else {
            return Array(users.suffix(limit))
        }
        let half = limit / 2
        let lower = max(0, min(index - half, users.count - limit))
        return Array(users[lower ..< lower + limit])
    }

    /// 当前查看的用户消息 tick：视口锚点（含自身）所属的最近一条用户消息，
    /// 随滚动经行级几何信号实时更新；无锚点时兜底取最后一条用户消息。
    /// - Parameters:
    ///   - messages: 本会话全部消息。
    ///   - topVisibleMessageID: 真实视口顶部消息 id（@State，由行级几何信号维护）。
    static func currentTickMessageId(messages: [ChatMessage],
                                     topVisibleMessageID: UUID?) -> UUID? {
        guard let anchor = topVisibleMessageID,
              let index = messages.firstIndex(where: { $0.id == anchor }) else {
            return messages.last { $0.role == .user }?.id
        }
        return messages[...index].last { $0.role == .user }?.id
    }

    /// 刻度轨条目：采样后用户消息 → 轨渲染模型（预览文本预裁剪、当前条标记）。
    /// - Parameters:
    ///   - messages: 本会话全部消息。
    ///   - currentTickMessageId: 「当前条」用户消息 id（isCurrent 标记真源）。
    static func tickItems(messages: [ChatMessage],
                          currentTickMessageId: UUID?) -> [ChatTickRail.Item] {
        tickMessages(messages: messages, currentTickMessageId: currentTickMessageId).map {
            ChatTickRail.Item(
                id: $0.id,
                preview: $0.content.trimmingCharacters(in: .whitespacesAndNewlines),
                isCurrent: $0.id == currentTickMessageId
            )
        }
    }

    // MARK: - 压缩卡 / 边界

    /// 是否渲染压缩边界卡：仅活跃会话（compactionInfo 是「当前会话」门面，隐藏会话树
    /// 不渲染，防跨会话错位；切回活跃时随重求值自然出现）；有压缩记录或压缩进行中。
    static func showsCompactionCard(isActive: Bool,
                                    isCompacting: Bool,
                                    compactionInfo: CompactionInfo?) -> Bool {
        isActive && (isCompacting || compactionInfo != nil)
    }

    /// 压缩边界消息 id：beforeMessageID（String）转 UUID 且在本会话消息里存在时按位插入；
    /// nil / 转换失败 / 消息已不存在 → nil（卡片落到会话流最顶部，契约语义）。
    static func compactionBoundaryMessageId(messages: [ChatMessage],
                                            beforeMessageID: String?) -> UUID? {
        guard let raw = beforeMessageID,
              let uuid = UUID(uuidString: raw),
              messages.contains(where: { $0.id == uuid }) else { return nil }
        return uuid
    }

    // MARK: - 可重生成 / 可编辑

    /// 最后一条可重新生成的助手消息 id：仅活跃会话 + 本会话非生成中时提供
    /// （重试动作只对当前会话有效，隐藏会话不显示按钮）。
    static func lastRegeneratableAssistantId(messages: [ChatMessage],
                                             isActive: Bool,
                                             isStreaming: Bool) -> UUID? {
        guard isActive, !isStreaming else { return nil }
        return messages.last { message in
            guard message.role == .assistant else { return false }
            switch message.state {
            case .done, .aborted: return true
            default: return false
            }
        }?.id
    }

    /// 会话内最后一条 user 消息 id：仅活跃会话 + 非生成中时提供
    /// （撤回/编辑只对当前会话最后一轮有效；隐藏会话与生成中不显示入口）。
    static func lastEditableUserMessageId(messages: [ChatMessage],
                                          isActive: Bool,
                                          isGenerating: Bool) -> UUID? {
        guard isActive, !isGenerating else { return nil }
        return messages.last { $0.role == .user }?.id
    }
}