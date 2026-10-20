// AgentTaskRegistry.swift: 多智能体任务生命周期、本地持久化与产物管理中枢。
// 负责在 ~/.quickshow/agent_tasks.json 记录子智能体任务状态，
// 并统一管理 ~/.quickshow/artifacts/<sessionId>/<taskId>/ 产物目录。

import Foundation
import Combine
import os

/// 智能体任务运行状态
enum AgentTaskStatus: String, Codable, Equatable {
    case queued
    case running
    case toolExecuting = "tool_executing"
    case completed
    case failed
    case cancelled
}

/// 智能体任务持久化实体模型
struct AgentTaskRecord: Identifiable, Codable, Equatable {
    let id: String                      // taskId: 例如 "task_librarian_xxx"
    let subagentId: String              // "librarian", "coder", "oracle" 等
    let subagentName: String            // "知识检索", "代码专家" 等
    let parentSessionId: UUID           // 所属主会话 ID
    let childSessionId: UUID            // 专属子会话 ID
    let taskDescription: String         // 任务诉求
    var status: AgentTaskStatus         // 状态
    var currentAction: String           // 实时动态活动说明（如 "正在搜索满帮股价..."）
    var artifacts: [String]             // 产生的文件或深度报告本地路径
    let createdAt: Date
    var updatedAt: Date
}

@MainActor
final class AgentTaskRegistry: ObservableObject {
    static let shared = AgentTaskRegistry()

    private let logger = Logger(subsystem: "com.dzhang.quickshow.ai", category: "agentTaskRegistry")

    /// 内存真源：所有任务记录（按更新时间降序）
    @Published private(set) var tasks: [AgentTaskRecord] = []

    /// 根工作目录：~/.quickshow
    let baseDirectoryURL: URL
    /// 任务持久化文件：~/.quickshow/agent_tasks.json
    let tasksFileURL: URL
    /// 产物存储目录：~/.quickshow/artifacts/
    let artifactsDirectoryURL: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let baseDir = home.appendingPathComponent(".quickshow", isDirectory: true)
        self.baseDirectoryURL = baseDir
        self.tasksFileURL = baseDir.appendingPathComponent("agent_tasks.json")
        self.artifactsDirectoryURL = baseDir.appendingPathComponent("artifacts", isDirectory: true)

        ensureDirectories()
        loadTasks()
    }

    // MARK: - 目录保障

    private func ensureDirectories() {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: baseDirectoryURL.path) {
                try fm.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: artifactsDirectoryURL.path) {
                try fm.createDirectory(at: artifactsDirectoryURL, withIntermediateDirectories: true)
            }
        } catch {
            logger.error("创建 ~/.quickshow 目录失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 查询接口

    /// 获取特定主会话下当前正在运行中的所有子任务
    func runningTasks(parentSessionId: UUID) -> [AgentTaskRecord] {
        tasks.filter {
            $0.parentSessionId == parentSessionId &&
            ($0.status == .running || $0.status == .toolExecuting || $0.status == .queued)
        }
    }

    /// 根据 taskId 查找任务记录
    func task(id: String) -> AgentTaskRecord? {
        tasks.first { $0.id == id }
    }

    /// 根据子会话 ID 查找任务记录
    func task(childSessionId: UUID) -> AgentTaskRecord? {
        tasks.first { $0.childSessionId == childSessionId }
    }

    // MARK: - 状态突变接口

    /// 登记注册新子任务
    @discardableResult
    func registerTask(
        id: String,
        subagentId: String,
        subagentName: String,
        parentSessionId: UUID,
        childSessionId: UUID,
        taskDescription: String
    ) -> AgentTaskRecord {
        let now = Date()
        let record = AgentTaskRecord(
            id: id,
            subagentId: subagentId,
            subagentName: subagentName,
            parentSessionId: parentSessionId,
            childSessionId: childSessionId,
            taskDescription: taskDescription,
            status: .queued,
            currentAction: "等待分配调度…",
            artifacts: [],
            createdAt: now,
            updatedAt: now
        )
        tasks.removeAll { $0.id == id }
        tasks.insert(record, at: 0)
        persist()
        return record
    }

    /// 更新任务实时活动与状态
    func updateTaskAction(
        id: String,
        action: String,
        status: AgentTaskStatus? = nil
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].currentAction = action
        if let status {
            tasks[index].status = status
        }
        tasks[index].updatedAt = Date()
        persist()
    }

    /// 标记任务完成或失败
    func settleTask(
        id: String,
        status: AgentTaskStatus,
        summary: String? = nil,
        artifactPath: String? = nil
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = status
        if let summary {
            tasks[index].currentAction = summary
        }
        if let artifactPath, !tasks[index].artifacts.contains(artifactPath) {
            tasks[index].artifacts.append(artifactPath)
        }
        tasks[index].updatedAt = Date()
        persist()
    }

    /// 为指定任务创建并返回产物文件保存路径
    func makeArtifactPath(parentSessionId: UUID, taskId: String, fileName: String) -> URL {
        let sessionDir = artifactsDirectoryURL
            .appendingPathComponent(parentSessionId.uuidString, isDirectory: true)
            .appendingPathComponent(taskId, isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        return sessionDir.appendingPathComponent(fileName)
    }

    // MARK: - 持久化存取

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(tasks)
            try data.write(to: tasksFileURL, options: .atomic)
        } catch {
            logger.error("保存 agent_tasks.json 失败: \(error.localizedDescription)")
        }
    }

    /// 强制中止并清理特定任务
    func cancelTask(id: String) {
        settleTask(id: id, status: .cancelled, summary: String(localized: "用户已中止"))
    }

    private func loadTasks() {
        guard FileManager.default.fileExists(atPath: tasksFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: tasksFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode([AgentTaskRecord].self, from: data)

            // 跨进程冷启动自愈：扫描历史未完结任务（running / toolExecuting / queued）
            var didHeal = false
            for i in 0..<loaded.count {
                var record = loaded[i]
                if record.status == .running || record.status == .toolExecuting || record.status == .queued {
                    // 查询对应子会话自愈状态
                    if let childSession = ChatSessionStore.shared.session(id: record.childSessionId),
                       let lastAssistant = childSession.messages.last(where: { $0.role == .assistant }),
                       lastAssistant.state == .done,
                       !lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        record.status = .completed
                        record.currentAction = childSession.taskSummary ?? String(lastAssistant.content.prefix(120))
                    } else {
                        record.status = .cancelled
                        record.currentAction = String(localized: "应用重启，任务已中断")
                    }
                    record.updatedAt = Date()
                    loaded[i] = record
                    didHeal = true
                }
            }

            self.tasks = loaded
            if didHeal {
                persist()
            }
        } catch {
            logger.error("读取 agent_tasks.json 失败: \(error.localizedDescription)")
        }
    }
}
