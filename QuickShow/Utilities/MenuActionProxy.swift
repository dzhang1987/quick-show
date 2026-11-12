import AppKit

// MARK: - NSMenu 闭包动作代理与生命周期协调器

/// NSMenuItem 动作代理：NSMenuItem.target 是弱引用、action 必须是 @objc 方法，
/// closure 不能直接做 target——本类持 closure 转发。由 MenuActionRetainer 强持有保证生命周期安全。
final class MenuActionProxy: NSObject {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

/// 菜单生命周期协调器：强持有当前弹出菜单中所有 item 的 target proxy，
/// 杜绝 NSMenuItem.target (weak) 因局部栈变量提前释放而变成 nil 导致的点击丢失。
/// 每次弹出构建前 reset；弹出期间（模态）所有动作生命期绝对安全。
@MainActor
final class MenuActionRetainer {
    static let shared = MenuActionRetainer()
    private var activeActions: [MenuActionProxy] = []

    func retain(_ action: MenuActionProxy) {
        activeActions.append(action)
    }

    func reset() {
        activeActions.removeAll()
    }
}
