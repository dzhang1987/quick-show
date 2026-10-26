import Foundation

// MARK: - 文件覆盖写入前快照与一键撤销管理中心

/// 单个文件覆盖快照模型
struct FileSnapshot: Sendable {
    let id: UUID
    let path: String
    /// 覆盖写入前的原始内容；nil 代表此前该文件不存在（撤销时执行删除新建的文件）
    let previousContent: String?
    let timestamp: Date
    var isUndone: Bool
}

/// 文件覆盖写入前快照管理中心（事后安全网：有后悔药胜过频繁事前审批）
final class UndoSnapshotManager: @unchecked Sendable {
    static let shared = UndoSnapshotManager()

    private let lock = NSLock()
    private var snapshots: [UUID: FileSnapshot] = [:]
    /// 快照最长存活时间（30 分钟）
    private static let maxSnapshotLifetime: TimeInterval = 1800

    private init() {}

    /// 在写文件之前捕获当前文件状态并生成撤销 Token
    func createSnapshot(path: String) -> UUID {
        let token = UUID()
        let previousContent: String?
        if FileManager.default.fileExists(atPath: path),
           let data = FileManager.default.contents(atPath: path),
           let text = String(data: data, encoding: .utf8) {
            previousContent = text
        } else {
            previousContent = nil
        }

        let snapshot = FileSnapshot(
            id: token,
            path: path,
            previousContent: previousContent,
            timestamp: Date(),
            isUndone: false
        )

        lock.lock()
        defer { lock.unlock() }
        cleanupExpiredSnapshotsLocked()
        snapshots[token] = snapshot
        return token
    }

    /// 查询某 Token 是否已被撤销
    func isUndone(token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[token]?.isUndone ?? false
    }

    /// 查询某 Token 是否有效且可撤销
    func canUndo(token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let s = snapshots[token] else { return false }
        return !s.isUndone
    }

    /// 执行撤销：原子还原旧内容或删除新建的文件
    func undo(token: UUID) throws {
        lock.lock()
        guard var snapshot = snapshots[token] else {
            lock.unlock()
            throw ToolExecutionError(String(localized: "未找到撤销快照或已过期"))
        }
        guard !snapshot.isUndone else {
            lock.unlock()
            throw ToolExecutionError(String(localized: "该操作已撤销"))
        }
        lock.unlock()

        let fileURL = URL(fileURLWithPath: snapshot.path)
        if let previous = snapshot.previousContent {
            // 还原旧内容
            try previous.write(to: fileURL, atomically: true, encoding: .utf8)
        } else {
            // 此前不存在，撤销时将其删除
            if FileManager.default.fileExists(atPath: snapshot.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }

        lock.lock()
        snapshot.isUndone = true
        snapshots[token] = snapshot
        lock.unlock()
    }

    /// 清空所有快照（会话切换或彻底清理时）
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        snapshots.removeAll()
    }

    private func cleanupExpiredSnapshotsLocked() {
        let threshold = Date().addingTimeInterval(-Self.maxSnapshotLifetime)
        snapshots = snapshots.filter { $0.value.timestamp >= threshold }
    }
}
