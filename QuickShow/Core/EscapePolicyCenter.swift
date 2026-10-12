import AppKit
import Foundation
import SwiftUI

// MARK: - 作用域枚举

/// ESC 响应栈窗口作用域：隔离主面板与 AI 对话窗的响应者栈，避免全局单栈串扰
enum EscapeScope: String, CaseIterable, Hashable {
    case chat = "chat"
    case glance = "glance"
}

// MARK: - 统一 ESC 响应者协议

/// ESC 响应者统一协议：任何需要拦截 ESC 的组件均可实现此协议
@MainActor
protocol EscapeRespondable: AnyObject {
    var escapeResponderId: String { get }
    func handleEscape() -> Bool
}

// MARK: - ESC 响应者栈协调器

/// 全局 ESC 响应栈调度中心。
/// 核心模型：
/// - 支持按窗口作用域（.chat 与 .glance）完全隔离的纯粹 LIFO 响应者栈；
/// - 浮层/弹窗/编辑态挂载或激活时 push 入对应作用域栈，关闭或失活时 pop 出栈；
/// - 按下 ESC 时永远由对应作用域当前栈顶（Stack Top）优先消费；
/// - 只有当所有浮层全部退栈、栈顶回落到栈底根窗口时，ESC 才会触发隐藏/退出；
/// - 各作用域独立配备 0.3s 防穿透微秒锁，彻底消除 AppKit 事件链引发的关窗穿透。
@MainActor
final class EscapePolicyCenter: ObservableObject {
    static let shared = EscapePolicyCenter()

    struct StackEntry {
        let id: String
        let isRoot: Bool
        let action: () -> Bool
    }

    private struct ScopeState {
        var stack: [StackEntry] = []
        var lastConsumedTime: Date = .distantPast
    }

    /// 各作用域独立栈状态
    @Published private var states: [EscapeScope: ScopeState] = [
        .chat: ScopeState(),
        .glance: ScopeState()
    ]

    private init() {}

    /// 栈深度（默认 chat 作用域）
    func depth(scope: EscapeScope = .chat) -> Int {
        states[scope]?.stack.count ?? 0
    }

    /// 兼容旧属性：Chat 作用域当前是否有上层模态组件在场
    var isModalActive: Bool {
        isModalActive(scope: .chat)
    }

    /// 当前作用域是否有上层模态组件在场（栈中存在除根窗口外的其它浮层）
    func isModalActive(scope: EscapeScope) -> Bool {
        states[scope]?.stack.contains { !$0.isRoot } ?? false
    }

    /// 压入根节点（默认 Chat 窗口栈底，Glance 窗口亦可独立登记）
    func registerRoot(scope: EscapeScope = .chat, id: String = "chat_window", action: @escaping () -> Bool) {
        var state = states[scope] ?? ScopeState()
        state.stack.removeAll { $0.id == id }
        // 根节点永远置于栈底 (index 0)
        state.stack.insert(StackEntry(id: id, isRoot: true, action: action), at: 0)
        states[scope] = state
    }

    /// 移除根节点
    func unregisterRoot(scope: EscapeScope = .chat, id: String = "chat_window") {
        var state = states[scope] ?? ScopeState()
        state.stack.removeAll { $0.id == id }
        states[scope] = state
    }

    /// 上层组件压栈（Push）
    func push(scope: EscapeScope = .chat, id: String, action: @escaping () -> Bool) {
        var state = states[scope] ?? ScopeState()
        // 若已存在先移除旧项，再压入栈顶（刷新为最新激活）
        state.stack.removeAll { $0.id == id }
        state.stack.append(StackEntry(id: id, isRoot: false, action: action))
        states[scope] = state
    }

    /// 面向对象压栈
    func push(scope: EscapeScope = .chat, responder: EscapeRespondable) {
        push(scope: scope, id: responder.escapeResponderId) { [weak responder] in
            responder?.handleEscape() ?? false
        }
    }

    /// 上层组件出栈（Pop）
    func pop(scope: EscapeScope = .chat, id: String) {
        var state = states[scope] ?? ScopeState()
        state.stack.removeAll { $0.id == id }
        states[scope] = state
    }

    /// 面向对象出栈
    func pop(scope: EscapeScope = .chat, responder: EscapeRespondable) {
        pop(scope: scope, id: responder.escapeResponderId)
    }

    /// 统一响应 ESC：由栈顶依次往下询问执行
    /// - Returns: true 表示已被某一层成功消费并阻断
    @discardableResult
    func handleEscape(scope: EscapeScope = .chat) -> Bool {
        guard var state = states[scope] else { return false }
        let now = Date()
        // 0.3 秒内刚刚消费过 ESC：直接吞掉穿透事件，严禁重入关窗
        if now.timeIntervalSince(state.lastConsumedTime) < 0.3 {
            return true
        }

        // 自栈顶向栈底寻找可消费的响应者
        for entry in state.stack.reversed() {
            if entry.action() {
                state.lastConsumedTime = Date()
                states[scope] = state
                return true
            }
        }
        return false
    }
}

// MARK: - SwiftUI 声明式压栈出栈修饰符

struct EscapeResponderStackModifier: ViewModifier {
    var scope: EscapeScope = .chat
    let id: String
    let isActive: Bool
    let onEscape: () -> Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                if isActive {
                    EscapePolicyCenter.shared.push(scope: scope, id: id, action: onEscape)
                }
            }
            .onDisappear {
                EscapePolicyCenter.shared.pop(scope: scope, id: id)
            }
            .onChange(of: isActive) { active in
                if active {
                    EscapePolicyCenter.shared.push(scope: scope, id: id, action: onEscape)
                } else {
                    EscapePolicyCenter.shared.pop(scope: scope, id: id)
                }
            }
    }
}

extension View {
    /// 组件声明式挂接入 ESC 响应者栈：
    /// - 当 isActive 为 true 时 Push 进对应作用域栈顶；
    /// - 变为 false 或组件销毁时 Pop 出栈；
    /// - 永远按 LIFO 栈顶优先响应 ESC。
    func escapeResponder(
        scope: EscapeScope = .chat,
        id: String,
        isActive: Bool,
        onEscape: @escaping () -> Bool
    ) -> some View {
        modifier(EscapeResponderStackModifier(
            scope: scope,
            id: id,
            isActive: isActive,
            onEscape: onEscape
        ))
    }
}
