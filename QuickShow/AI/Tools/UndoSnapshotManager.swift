import Foundation

// MARK: - 文件覆盖写入前快照与一键撤销管理中心

/// 单个文件覆盖快照模型
struct FileSnapshot: Sendable {
    let id: UUID
    let path: String
    /// 覆盖前文件是否存在；与 previousData 分离，避免把“读取失败/非 UTF-8”误判成新文件。
    let fileExisted: Bool
    /// 原始字节；已有文件必须成功捕获，否则禁止继续覆盖。
    let previousData: Data?
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

    /// 在写文件之前捕获当前文件状态并生成撤销 Token。
    /// 已有文件若无法完整读取则抛错，调用方不得继续覆盖。
    func createSnapshot(path: String) throws -> UUID {
        let token = UUID()
        let fileManager = FileManager.default
        let fileExisted = fileManager.fileExists(atPath: path)
        let previousData: Data?
        if fileExisted {
            guard let data = fileManager.contents(atPath: path) else {
                throw ToolExecutionError(String(localized: "无法创建安全快照，已取消文件修改"))
            }
            previousData = data
        } else {
            previousData = nil
        }

        let snapshot = FileSnapshot(
            id: token,
            path: path,
            fileExisted: fileExisted,
            previousData: previousData,
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
        cleanupExpiredSnapshotsLocked()
        return snapshots[token]?.isUndone ?? false
    }

    /// 查询某 Token 是否有效且可撤销
    func canUndo(token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        cleanupExpiredSnapshotsLocked()
        guard let s = snapshots[token] else { return false }
        return !s.isUndone
    }

    /// 执行撤销：原子还原旧内容或删除新建的文件
    func undo(token: UUID) throws {
        lock.lock()
        cleanupExpiredSnapshotsLocked()
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
        if snapshot.fileExisted {
            guard let previousData = snapshot.previousData else {
                throw ToolExecutionError(String(localized: "撤销快照不完整，未修改当前文件"))
            }
            try previousData.write(to: fileURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: snapshot.path) {
            // 文件原先不存在，撤销时删除本次新建文件。
            try FileManager.default.removeItem(at: fileURL)
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
