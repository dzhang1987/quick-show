// 职责来源：AIChatService.swift 的「SSE 流式请求」与「内部实现（流式生产链路）」MARK 分区。

import Foundation

extension AIChatService {
    // MARK: SSE 流式请求

    /// 发起一次流式对话，产出文本增量或完整工具调用事件。
    /// - 文本事件行为与旧 `AsyncThrowingStream<String>` 完全一致；工具调用在流结束时整批产出。
    /// - 错误通过 AsyncThrowingStream 抛出，由 State 层呈现。
    /// - 并行流支持（2026-10 会话并行专项）：本层不再持有全局任务句柄、不提供全局 abort——
    ///   多会话各自持有独立流，中止语义由消费侧 Task 取消经 onTermination 链路传导回网络任务。
    func send(
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions = AIChatRequestOptions()
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        return AsyncThrowingStream<AIStreamEvent, Error> { continuation in
            // 流局部取消盒：看门狗超时经此取消「本流」的生产任务（Task 无法自引用，盒中转）。
            let cancelBox = TaskCancellationBox()
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.performStream(
                        messages: messages,
                        options: options,
                        cancel: { cancelBox.cancel() }
                    ) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    // 用户主动中止：无错误，半截内容由 State 层落定为 .aborted。
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            cancelBox.set(task)
            // 下游提前终止（消费任务被取消）时同步取消网络请求。
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: 内部实现

    /// 首 token 到达标记（watchdog 与读取循环同处 MainActor，读写天然串行）。
    private final class FirstTokenFlag {
        var received = false
    }

    /// 流局部任务取消盒：生产 Task 无法在自身闭包内自引用，经盒中转供看门狗超时取消。
    /// set 在 Task 创建后立即执行（微秒级），watchdog 最早 120s 后才触发，无竞态窗口。
    /// @unchecked Sendable：NSLock 保护唯一可变状态 task。
    private final class TaskCancellationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func set(_ task: Task<Void, Never>) {
            lock.lock()
            defer { lock.unlock() }
            self.task = task
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            task?.cancel()
        }
    }

    /// 执行一次 SSE 请求并逐事件回调（MainActor 上下文）。
    /// `cancel`：本流生产任务的取消入口（首 token 看门狗超时调用；流局部，不影响其他会话）。
    private func performStream(
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions,
        cancel: (() -> Void)?,
        onEvent: (AIStreamEvent) -> Void
    ) async throws {
        // 协议在请求发起时一次性快照，避免流进行中被设置变更影响分流。
        let proto = apiProtocol

        let endpointPath = proto == .responses ? "/responses" : "/chat/completions"
        guard let url = endpointURL(path: endpointPath) else { throw AIChatError.invalidBaseURL }
        guard let key = apiKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIChatError.missingAPIKey
        }
        // 模型解析优先级：会话绑定模型（请求传入且非空）→ 全局 selectedModel。
        let requestedModel = options.modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel: String
        if let requestedModel, !requestedModel.isEmpty {
            resolvedModel = requestedModel
        } else {
            resolvedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !resolvedModel.isEmpty else { throw AIChatError.missingModel }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120 // 与首 token 看门狗一致，避免默认 60s 提前打断
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // 思考字段由适配层按「模型 + 统一档位」转换，服务层不感知具体模型差异。
        let thinkingFields = AIModelAdapter.thinkingFields(for: resolvedModel, level: options.thinkingLevel)
        request.httpBody = try encodeRequestBody(
            proto: proto,
            model: resolvedModel,
            messages: messages,
            stream: true,
            includeTools: true,
            thinkingFields: thinkingFields
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AIChatError.invalidResponse
        }

        // 非 2xx：读取 body 提取错误信息，映射为中文化提示后抛出。
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 4000 { break } // 防异常端点返回超长 body
            }
            throw AIChatError.http(
                status: http.statusCode,
                message: extractErrorMessage(from: body)
            )
        }

        // 首 token 看门狗：120s 内无任何增量即判超时并取消本流生产任务（流局部取消）。
        let firstTokenFlag = FirstTokenFlag()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if !firstTokenFlag.received {
                cancel?()
            }
        }
        defer { watchdog.cancel() }

        // 首 token 到达时撤销看门狗，两种协议共用。
        let markFirstToken = {
            if !firstTokenFlag.received {
                firstTokenFlag.received = true
                watchdog.cancel() // 首 token 已到，撤销超时判定
            }
        }

        // 工具调用分片累积器（每轮流各自独立）。
        let chatAccumulator = ChatToolCallAccumulator()
        let responsesAccumulator = ResponsesToolCallAccumulator()

        do {
            streaming: for try await line in bytes.lines {
                try Task.checkCancellation()

                // 只处理 data: 行：忽略空行、`:` 注释行与心跳行、event:/id: 等字段。
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst("data:".count)
                    .trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty else { continue }
                guard let data = payload.data(using: .utf8) else { continue }

                if proto == .responses {
                    // Responses：按顶层 type 分流，无 [DONE] 哨兵，靠 completed/failed 结束。
                    guard let event = try? JSONDecoder().decode(ResponsesEvent.self, from: data) else {
                        continue
                    }
                    // usage 归一：独立事件顶层 usage 或 response.completed 的 response.usage。
                    if let usage = event.usage ?? event.response?.usage,
                       let prompt = usage.resolvedPromptTokens {
                        onEvent(.usage(promptTokens: prompt))
                    }
                    switch event.type {
                    case "response.output_text.delta":
                        guard let delta = event.delta, !delta.isEmpty else { continue }
                        markFirstToken()
                        onEvent(.text(delta))
                    case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
                        // Responses 思考增量：正文之外的 reasoning 通道，与 output_text 分开派发。
                        guard let delta = event.delta, !delta.isEmpty else { continue }
                        markFirstToken()
                        onEvent(.reasoning(delta))
                    case "response.output_item.added", "response.output_item.done":
                        // function_call 项登记：added 记 call_id/name，done 时携带最终 arguments。
                        guard let item = event.item, item.type == "function_call" else { continue }
                        let key = item.id ?? "index-\(event.outputIndex ?? 0)"
                        responsesAccumulator.register(
                            key: key,
                            callID: item.callId,
                            name: item.name,
                            arguments: item.arguments
                        )
                        markFirstToken()
                    case "response.function_call_arguments.delta":
                        guard let delta = event.delta, !delta.isEmpty else { continue }
                        let key = event.itemId ?? "index-\(event.outputIndex ?? 0)"
                        responsesAccumulator.appendArguments(key: key, delta: delta)
                        markFirstToken()
                    case "response.function_call_arguments.done":
                        guard let itemID = event.itemId else { continue }
                        responsesAccumulator.register(
                            key: itemID,
                            callID: nil,
                            name: nil,
                            arguments: event.arguments
                        )
                    case "response.completed":
                        if !responsesAccumulator.isEmpty {
                            onEvent(.toolCalls(responsesAccumulator.completed))
                            responsesAccumulator.clear()
                        }
                        break streaming // 正常结束
                    case "response.failed", "response.error", "error":
                        throw AIChatError.streamError(event.resolvedErrorMessage)
                    default:
                        continue // response.created / content_part.* 等一律忽略
                    }
                } else {
                    // Chat Completions：data: {...} 取 delta.content / delta.tool_calls，[DONE] 结束。
                    if payload == "[DONE]" {
                        if !chatAccumulator.isEmpty {
                            onEvent(.toolCalls(chatAccumulator.completed))
                            chatAccumulator.clear()
                        }
                        break streaming
                    }
                    // 个别分片解析失败不中断整段流（如 usage-only chunk）。
                    guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
                        continue
                    }
                    // usage-only 分片：choices 为空数组、顶层携带 usage，先提取再继续。
                    if let usage = chunk.usage, let prompt = usage.resolvedPromptTokens {
                        onEvent(.usage(promptTokens: prompt))
                    }
                    guard let delta = chunk.choices.first?.delta else {
                        continue
                    }
                    if let content = delta.content, !content.isEmpty {
                        markFirstToken()
                        onEvent(.text(content))
                    }
                    // 思考增量：reasoning_content（DeepSeek 风格）/ reasoning（兼容端点）同归一通道。
                    if let reasoning = delta.resolvedReasoning, !reasoning.isEmpty {
                        markFirstToken()
                        onEvent(.reasoning(reasoning))
                    }
                    if let toolCalls = delta.toolCalls, !toolCalls.isEmpty {
                        chatAccumulator.ingest(toolCalls)
                        markFirstToken()
                    }
                }
            }
            // 流自然结束（部分端点无 [DONE]/completed 哨兵）：补发累积的工具调用。
            if proto == .responses {
                if !responsesAccumulator.isEmpty {
                    onEvent(.toolCalls(responsesAccumulator.completed))
                    responsesAccumulator.clear()
                }
            } else if !chatAccumulator.isEmpty {
                onEvent(.toolCalls(chatAccumulator.completed))
                chatAccumulator.clear()
            }
        } catch is CancellationError {
            // 区分「用户主动中止」与「首 token 超时」：超时需向 State 抛出明确错误。
            if !firstTokenFlag.received {
                throw AIChatError.timeout
            }
            throw CancellationError()
        }
    }
}