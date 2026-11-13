import Combine
import Foundation

// MARK: - 会话授权记录

/// 一条会话级授权：用户对某个有界作用域授予「本会话放行」。
struct PermissionGrant: Identifiable, Equatable, Sendable {
    let id: UUID
    let scope: PermissionGrantScope
    let grantedAt: Date
}

/// 一条会话级拒绝：用户拒绝后同作用域不再反复打扰，模型收到拒绝结果自行改道。
struct PermissionDenial: Identifiable, Equatable, Sendable {
    let id: UUID
    let scope: PermissionGrantScope
    let deniedAt: Date
}

/// 授权裁决三态
enum PermissionGrantDecision: Equatable, Sendable {
    case granted
    case denied
    case undecided
}

// MARK: - 会话授权中心

/// 会话级授权记忆中心（可见、可撤销、拒绝也记忆）。
///
/// 设计边界：
/// - 只服务于 `ToolRiskLevel.sessionGrantable` 的有界作用域；原始 Shell 与高危操作永不进入；
/// - 授权按「发起会话」隔离存储：后台 Agent 的授权不串到前台会话，切换会话不泄漏；
/// - 纯内存：随 App 退出清空；会话被删除时同步 purge；
/// - 授权与拒绝互斥：记录一方即清除另一方同作用域记录；
/// - 撤销授权或撤销拒绝 → 回到 undecided（下次再问）。
@MainActor
final class ToolPermissionGrantStore: ObservableObject {
    static let shared = ToolPermissionGrantStore()

    /// 当前会话的授权列表（顶栏徽标与 popover 直接观察）
    @Published private(set) var activeGrants: [PermissionGrant] = []
    /// 当前会话的拒绝列表
    @Published private(set) var activeDenials: [PermissionDenial] = []

    private var grantsBySession: [UUID: [PermissionGrant]] = [:]
    private var denialsBySession: [UUID: [PermissionDenial]] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let store = ChatSessionStore.shared
        // 会话切换：刷新当前会话的可见列表（授权按会话隔离，切换不串权）
        store.$currentSessionId
            .sink { [weak self] _ in self?.refreshActiveLists() }
            .store(in: &cancellables)
        // 会话删除：purge 被删会话的授权/拒绝，避免孤儿记忆
        store.$sessions
            .map { Set($0.map { $0.id }) }
            .removeDuplicates()
            .sink { [weak self] ids in
                guard let self else { return }
                for sessionID in self.grantsBySession.keys where !ids.contains(sessionID) {
                    self.grantsBySession[sessionID] = nil
                }
                for sessionID in self.denialsBySession.keys where !ids.contains(sessionID) {
                    self.denialsBySession[sessionID] = nil
                }
                self.refreshActiveLists()
            }
            .store(in: &cancellables)
    }

    // MARK: - 裁决

    /// 查询某会话对某作用域的既有裁决；无会话上下文时一律 undecided（不记忆）。
    func decision(for scope: PermissionGrantScope, sessionID: UUID?) -> PermissionGrantDecision {
        guard let sessionID else { return .undecided }
        if grantsBySession[sessionID]?.contains(where: { $0.scope == scope }) == true {
            return .granted
        }
        if denialsBySession[sessionID]?.contains(where: { $0.scope == scope }) == true {
            return .denied
        }
        return .undecided
    }

    // MARK: - 记录

    func recordGrant(scope: PermissionGrantScope, sessionID: UUID?) {
        guard let sessionID else { return }
        denialsBySession[sessionID]?.removeAll { $0.scope == scope }
        var grants = grantsBySession[sessionID] ?? []
        guard !grants.contains(where: { $0.scope == scope }) else { return }
        grants.append(PermissionGrant(id: UUID(), scope: scope, grantedAt: Date()))
        grantsBySession[sessionID] = grants
        refreshActiveLists()
    }

    func recordDenial(scope: PermissionGrantScope, sessionID: UUID?) {
        guard let sessionID else { return }
        grantsBySession[sessionID]?.removeAll { $0.scope == scope }
        var denials = denialsBySession[sessionID] ?? []
        guard !denials.contains(where: { $0.scope == scope }) else { return }
        denials.append(PermissionDenial(id: UUID(), scope: scope, deniedAt: Date()))
        denialsBySession[sessionID] = denials
        refreshActiveLists()
    }

    // MARK: - 撤销（顶栏授权列表调用）

    /// 撤销授权：回到 undecided，下次使用该能力时重新询问。
    func revokeGrant(id: UUID) {
        for (sessionID, grants) in grantsBySession {
            if let grant = grants.first(where: { $0.id == id }) {
                revokeGrant(scope: grant.scope, sessionID: sessionID)
                return
            }
        }
    }

    /// 撤销拒绝：恢复询问资格（用户改主意时不必重建会话）。
    func revokeDenial(id: UUID) {
        for (sessionID, denials) in denialsBySession {
            if let denial = denials.first(where: { $0.id == id }) {
                revokeDenial(scope: denial.scope, sessionID: sessionID)
                return
            }
        }
    }

    /// 按作用域撤销授权（逻辑层/测试入口）。
    func revokeGrant(scope: PermissionGrantScope, sessionID: UUID?) {
        guard let sessionID else { return }
        grantsBySession[sessionID]?.removeAll { $0.scope == scope }
        refreshActiveLists()
    }

    /// 按作用域撤销拒绝（逻辑层/测试入口）。
    func revokeDenial(scope: PermissionGrantScope, sessionID: UUID?) {
        guard let sessionID else { return }
        denialsBySession[sessionID]?.removeAll { $0.scope == scope }
        refreshActiveLists()
    }

    // MARK: - 私有

    private func refreshActiveLists() {
        let currentID = ChatSessionStore.shared.currentSessionId
        activeGrants = currentID.flatMap { grantsBySession[$0] } ?? []
        activeDenials = currentID.flatMap { denialsBySession[$0] } ?? []
    }
}