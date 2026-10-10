import AppKit
import Foundation
import SwiftUI

// MARK: - 统一 ESC 响应者协议

/// ESC 响应者统一协议：任何需要拦截 ESC 的组件均可实现此协议
@MainActor
protocol EscapeRespondable: AnyObject {
    var escapeResponderId: String { get }
    func handleEscape() -> Bool
}

// MARK: - ESC 响应者栈协调器（栈底为 Chat 窗口）

/// 全局 ESC 响应栈调度中心。
/// 核心模型：
/// - 纯粹的 LIFO 响应者栈（Responder Stack），栈底为 Chat 根窗口；
/// - 浮层/弹窗/编辑态挂载或激活时 push 入栈，关闭或失活时 pop 出栈；
/// - 按下 ESC 时永远由当前栈顶（Stack Top）优先消费；
/// - 只有当所有浮层全部退栈、栈顶回落到栈底根窗口时，ESC 才会触发隐藏/退出；
/// - 配合 0.3s 防穿透微秒锁，彻底消除 AppKit 事件链引发的关窗穿透。
@MainActor
final class EscapePolicyCenter: ObservableObject {
    static let shared = EscapePolicyCenter()

    struct StackEntry {
        let id: String
        let isRoot: Bool
        let action: () -> Bool
    }

    /// 响应者栈（index 0 为根节点/栈底，末尾为栈顶）
    @Published private(set) var stack: [StackEntry] = []

    /// 上一次成功消费 ESC 的时间戳（防硬件连击与 AppKit 事件穿透）
    private(set) var lastConsumedTime: Date = .distantPast

    private init() {}

    /// 栈深度
    var depth: Int {
        stack.count
    }

    /// 当前是否有上层模态组件在场（栈中存在除根窗口外的其它浮层）
    var isModalActive: Bool {
        stack.contains { !$0.isRoot }
    }

    /// 压入根节点（Chat 窗口栈底）
    func registerRoot(id: String = "chat_window", action: @escaping () -> Bool) {
        stack.removeAll { $0.id == id }
        // 根节点永远置于栈底 (index 0)
        stack.insert(StackEntry(id: id, isRoot: true, action: action), at: 0)
    }

    /// 移除根节点
    func unregisterRoot(id: String = "chat_window") {
        stack.removeAll { $0.id == id }
    }

    /// 上层组件压栈（Push）
    func push(id: String, action: @escaping () -> Bool) {
        // 若已存在先移除旧项，再压入栈顶（刷新为最新激活）
        stack.removeAll { $0.id == id }
        stack.append(StackEntry(id: id, isRoot: false, action: action))
    }

    /// 面向对象压栈
    func push(responder: EscapeRespondable) {
        push(id: responder.escapeResponderId) { [weak responder] in
            responder?.handleEscape() ?? false
        }
    }

    /// 上层组件出栈（Pop）
    func pop(id: String) {
        stack.removeAll { $0.id == id }
    }

    /// 面向对象出栈
    func pop(responder: EscapeRespondable) {
        pop(id: responder.escapeResponderId)
    }

    /// 统一响应 ESC：由栈顶依次往下询问执行
    /// - Returns: true 表示已被某一层成功消费并阻断
    @discardableResult
    func handleEscape() -> Bool {
        let now = Date()
        // 0.3 秒内刚刚消费过 ESC：直接吞掉穿透事件，严禁重入关窗
        if now.timeIntervalSince(lastConsumedTime) < 0.3 {
            return true
        }

        // 自栈顶向栈底寻找可消费的响应者
        for entry in stack.reversed() {
            if entry.action() {
                lastConsumedTime = Date()
                return true
            }
        }
        return false
    }
}

// MARK: - SwiftUI 声明式压栈出栈修饰符

struct EscapeResponderStackModifier: ViewModifier {
    let id: String
    let isActive: Bool
    let onEscape: () -> Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                if isActive {
                    EscapePolicyCenter.shared.push(id: id, action: onEscape)
                }
            }
            .onDisappear {
                EscapePolicyCenter.shared.pop(id: id)
            }
            .onChange(of: isActive) { active in
                if active {
                    EscapePolicyCenter.shared.push(id: id, action: onEscape)
                } else {
                    EscapePolicyCenter.shared.pop(id: id)
                }
            }
    }
}

extension View {
    /// 组件声明式挂接入 ESC 响应者栈：
    /// - 当 isActive 为 true 时 Push 进栈顶；
    /// - 变为 false 或组件销毁时 Pop 出栈；
    /// - 永远按 LIFO 栈顶优先响应 ESC。
    func escapeResponder(
        id: String,
        isActive: Bool,
        onEscape: @escaping () -> Bool
    ) -> some View {
        modifier(EscapeResponderStackModifier(
            id: id,
            isActive: isActive,
            onEscape: onEscape
        ))
    }
}
