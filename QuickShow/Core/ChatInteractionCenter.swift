import Foundation
import Combine

// MARK: - 输入坞抽屉请求模型

/// 输入坞抽屉请求：权限确认 / 用户提问，二选一挂起。
/// 交互中心同一时刻只持有一个请求，故内层请求 id 即当前抽屉的稳定标识。
enum ChatDrawerRequest: Identifiable {
    case toolConfirmation(ToolConfirmationRequest)
    case userQuestions(UserQuestionRequest)

    /// 取内层请求 id（UI 侧 ForEach/身份判定用）
    var id: UUID {
        switch self {
        case .toolConfirmation(let request): return request.id
        case .userQuestions(let request): return request.id
        }
    }
}

/// 危险工具确认请求：逻辑层预生成单行摘要；argumentsJSON 保留参数原文，UI 负责折叠展示。
struct ToolConfirmationRequest: Identifiable {
    let id: UUID
    /// 工具名，如 "run_shell"
    let toolName: String
    /// 参数原文（未加工）
    let argumentsJSON: String
    /// 单行摘要（去换行、限 200 字），供 UI 直接展示
    let summary: String
}

/// 危险工具确认结果
enum ToolConfirmationOutcome {
    case denied
    case executeOnce
    case alwaysAllowThisSession
}

/// 用户提问请求（1..N 题）
struct UserQuestionRequest: Identifiable {
    let id: UUID
    let questions: [UserQuestion]
}

/// 单道用户提问
struct UserQuestion: Identifiable {
    let id: UUID
    /// 短标签
    let header: String
    /// 完整问题文本
    let question: String
    let options: [UserQuestionOption]
    /// false = 单选；true = 多选
    let multiple: Bool
}

/// 单个候选项
struct UserQuestionOption: Identifiable {
    let id: UUID
    let label: String
    let description: String?
}

/// 用户提交的答案集（answers 以 question.id 为键）
struct UserQuestionResponse {
    let requestID: UUID
    let answers: [UUID: QuestionAnswer]
}

/// 单题答案：可多选（selectedOptionIDs）+ 自由输入（customText），二者都可能为空
struct QuestionAnswer {
    var selectedOptionIDs: Set<UUID>
    var customText: String
}

/// ask_user 工具入参解析产物（喂给交互中心）
struct UserQuestionSpec {
    let header: String
    let question: String
    let options: [UserQuestionOptionSpec]
    let multiple: Bool
}

/// 选项规格（无 id，进入交互中心后生成稳定 id）
struct UserQuestionOptionSpec {
    let label: String
    let description: String?
}

// MARK: - 交互中心

/// 输入坞抽屉交互中心：逻辑层与 UI 层之间的单一挂起管道。
/// 逻辑层（工具执行器/工具）发起请求 → 发布到 `request` 并挂起 → UI 渲染抽屉 →
/// UI 经 resolve/submit/cancel 唤醒对应 continuation 并清空 request。
///
/// 安全兜底：UI 不在场（`!uiActive`）时，确认直接 `.denied`、提问直接 nil，
/// 绝不弹任何 AppKit 弹窗；请求挂起期间 UI 消失（onDisappear → markUIActive(false)）
/// 同样唤醒为兜底结果，避免 continuation 泄漏。遵守「ask_user 无超时静候」——
/// 不设任何超时，仅以 UI 消失作为取消信号。
@MainActor
final class ChatInteractionCenter: ObservableObject {
    static let shared = ChatInteractionCenter()

    /// 当前挂起的抽屉请求；nil = 无请求。UI 观察此属性渲染抽屉。
    @Published private(set) var request: ChatDrawerRequest?

    // MARK: - 私有状态

    /// UI 是否在场（onAppear/onDisappear 经 markUIActive 维护）
    private var uiActive = false
    /// 危险确认的挂起 continuation；同一时刻至多一个
    private var confirmationContinuation: CheckedContinuation<ToolConfirmationOutcome, Never>?
    /// 用户提问的挂起 continuation；同一时刻至多一个
    private var questionContinuation: CheckedContinuation<UserQuestionResponse?, Never>?
    /// 会话内「总是允许」记忆（key = toolName|argumentsJSON 去空白原文）。纯内存，随会话失效。
    private var sessionAllowedKeys: Set<String> = []

    private init() {}

    // MARK: - 逻辑层调用（挂起等待 UI 响应）

    /// 请求危险工具确认。UI 无观察者时立即返回 `.denied`（默认拒绝，安全兜底）。
    func requestToolConfirmation(toolName: String, argumentsJSON: String) async -> ToolConfirmationOutcome {
        // 无 UI 兜底：默认拒绝，绝不弹任何 AppKit 弹窗
        guard uiActive else { return .denied }
        // 防重入：实际对话回路串行执行工具，不应并发请求；遇到并发防御性拒绝
        guard request == nil, confirmationContinuation == nil, questionContinuation == nil else {
            NSLog("[QuickShow] 交互中心已有挂起请求，拒绝并发危险确认：\(toolName)")
            return .denied
        }

        let req = ToolConfirmationRequest(
            id: UUID(),
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            summary: Self.singleLineSummary(argumentsJSON)
        )
        request = .toolConfirmation(req)
        notifyIfInactive(for: .toolConfirmation(req))
        // withCheckedContinuation 的闭包同步执行（无 await 间隙），request 与 continuation 不会错位
        return await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
        }
    }

    /// 请求用户作答。UI 无观察者或用户取消时返回 nil。
    func requestUserAnswers(_ questions: [UserQuestionSpec]) async -> UserQuestionResponse? {
        await requestUserAnswersReturningQuestions(questions).response
    }

    /// 内部（同模块 AskUserTool 专用）：与公开契约 `requestUserAnswers(_:)` 同源，
    /// 额外回传本次生成的题面结构。原因：`UserQuestionResponse` 与 `QuestionAnswer` 均以
    /// 逻辑层生成的 question/option UUID 索引，调用方需据此把 id 还原为可读 label；
    /// 公开方法委托至此，UI lane 仍只需公开契约。
    func requestUserAnswersReturningQuestions(
        _ questions: [UserQuestionSpec]
    ) async -> (questions: [UserQuestion], response: UserQuestionResponse?) {
        // 无 UI 兜底：直接返回空题面 + nil（视为用户取消）
        guard uiActive else { return ([], nil) }
        // 防重入：同一时刻只允许一个请求
        guard request == nil, confirmationContinuation == nil, questionContinuation == nil else {
            NSLog("[QuickShow] 交互中心已有挂起请求，拒绝并发用户提问")
            return ([], nil)
        }

        // spec → 带稳定 id 的题面：question/option 的 id 在此一次性生成
        let built: [UserQuestion] = questions.map { spec in
            UserQuestion(
                id: UUID(),
                header: spec.header,
                question: spec.question,
                options: spec.options.map { optionSpec in
                    UserQuestionOption(id: UUID(), label: optionSpec.label, description: optionSpec.description)
                },
                multiple: spec.multiple
            )
        }
        let req = UserQuestionRequest(id: UUID(), questions: built)
        request = .userQuestions(req)
        notifyIfInactive(for: .userQuestions(req))
        let response = await withCheckedContinuation { continuation in
            questionContinuation = continuation
        }
        return (built, response)
    }

    // MARK: - UI 层调用（resolve/submit/cancel 会唤醒挂起 continuation 并清空 request）

    /// UI 在场标志。置 false 时（onDisappear）把挂起请求唤醒为兜底结果：
    /// 确认 → .denied；提问 → nil。避免 continuation 永久挂起泄漏。
    func markUIActive(_ active: Bool) {
        uiActive = active
        guard !active else { return }
        clearPendingNotification()
        if let continuation = confirmationContinuation {
            confirmationContinuation = nil
            request = nil
            continuation.resume(returning: .denied)
        } else if let continuation = questionContinuation {
            questionContinuation = nil
            request = nil
            continuation.resume(returning: nil)
        }
    }

    /// UI 提交危险确认结果。request 已换/空时静默丢弃，绝不重复 resume。
    func resolveConfirmation(_ outcome: ToolConfirmationOutcome) {
        guard case .toolConfirmation? = request, let continuation = confirmationContinuation else {
            return
        }
        clearPendingNotification()
        confirmationContinuation = nil
        request = nil
        continuation.resume(returning: outcome)
    }

    /// UI 提交用户答案。按 requestID 匹配当前提问请求；不匹配时静默丢弃。
    func submitQuestions(_ response: UserQuestionResponse) {
        guard case .userQuestions(let req)? = request,
              req.id == response.requestID,
              let continuation = questionContinuation else {
            return
        }
        clearPendingNotification()
        questionContinuation = nil
        request = nil
        continuation.resume(returning: response)
    }

    /// UI 取消用户提问（用户主动关闭抽屉）。唤醒为 nil。
    func cancelQuestions() {
        guard case .userQuestions? = request, let continuation = questionContinuation else {
            return
        }
        clearPendingNotification()
        questionContinuation = nil
        request = nil
        continuation.resume(returning: nil)
    }

    // MARK: - 后台通知与撤销

    /// 当 AI 窗口未在前台活跃时，向用户发送持久系统通知，提醒用户作答/授权
    private func notifyIfInactive(for request: ChatDrawerRequest) {
        let manager = AIWindowManager.shared
        // 仅在窗口不可见或非 key 激活状态时提醒
        guard !(manager.isPanelVisible && manager.isPanelKey) else { return }

        let sessionId = AIChatState.shared.store.currentSessionId
        switch request {
        case .userQuestions(let req):
            let title = String(localized: "QuickShow AI · 需要您回答")
            let count = req.questions.count
            let firstQ = req.questions.first?.question ?? ""
            let body: String
            if count > 1 {
                body = String(format: String(localized: "AI 提出 %d 个问题待确认：\n%@"), count, firstQ)
            } else {
                body = String(format: String(localized: "AI 提问：\n%@"), firstQ)
            }
            AICompletionNotifier.shared.notifyInteraction(
                id: req.id,
                title: title,
                body: body,
                sessionId: sessionId
            )
        case .toolConfirmation(let req):
            let title = String(localized: "QuickShow AI · 操作授权确认")
            let body = String(format: String(localized: "请求执行工具「%@」：\n%@"), req.toolName, req.summary)
            AICompletionNotifier.shared.notifyInteraction(
                id: req.id,
                title: title,
                body: body,
                sessionId: sessionId
            )
        }
    }

    /// 窗口失焦时调用：若当前存在未决的抽屉交互，确保向用户发送系统通知
    func notifyPendingInteractionIfInactive() {
        guard let request else { return }
        notifyIfInactive(for: request)
    }

    /// 清除当前活跃抽屉在通知中心的待办通知
    private func clearPendingNotification() {
        guard let id = request?.id else { return }
        AICompletionNotifier.shared.cancelInteractionNotification(id: id)
    }

    // MARK: - 会话内「总是允许」记忆

    /// 该工具+参数原文在本会话内是否已被允许（命中则跳过确认）。
    func isSessionAllowed(toolName: String, argumentsJSON: String) -> Bool {
        sessionAllowedKeys.contains(Self.sessionKey(toolName: toolName, argumentsJSON: argumentsJSON))
    }

    /// 记录本会话允许（同一命令原文 = 同一记忆）
    func rememberSessionAllowed(toolName: String, argumentsJSON: String) {
        sessionAllowedKeys.insert(Self.sessionKey(toolName: toolName, argumentsJSON: argumentsJSON))
    }

    /// 会话切换/新对话时调用，记忆随会话失效（幂等）
    func resetSessionMemory() {
        sessionAllowedKeys.removeAll()
    }

    // MARK: - 私有辅助

    /// 记忆 key：toolName + "|" + 去首尾空白的参数原文（同一命令原文 = 同一记忆）
    private static func sessionKey(toolName: String, argumentsJSON: String) -> String {
        toolName + "|" + argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 单行摘要：CRLF/LF/CR 统一替换为空格、去首尾空白、限 200 字（超出加省略号）。
    private static func singleLineSummary(_ text: String) -> String {
        let single = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return single.count <= 200 ? single : String(single.prefix(200)) + "…"
    }
}