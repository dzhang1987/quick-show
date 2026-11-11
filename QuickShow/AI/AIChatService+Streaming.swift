// AIChatService+Streaming: SSE 流式请求总调度，通过 LLMProviderRegistry 统一分发至对应厂商 Provider。

import Foundation

extension AIChatService {
    // MARK: - SSE 流式请求总入口

    func send(
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions = AIChatRequestOptions()
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        return AsyncThrowingStream<AIStreamEvent, Error> { continuation in
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
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            cancelBox.set(task)
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - 内部调度机制

    private final class StreamMonitorFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _receivedFirstContent = false
        private var _didStall = false
        private var _lastActivity = Date()

        var receivedFirstContent: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _receivedFirstContent
        }

        var didStall: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _didStall
        }

        var lastActivity: Date {
            lock.lock()
            defer { lock.unlock() }
            return _lastActivity
        }

        func markContentReceived() {
            lock.lock()
            defer { lock.unlock() }
            _receivedFirstContent = true
            _lastActivity = Date()
        }

        func touchActivity() {
            lock.lock()
            defer { lock.unlock() }
            _lastActivity = Date()
        }

        func markStalled() {
            lock.lock()
            defer { lock.unlock() }
            _didStall = true
        }
    }

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

    /// 执行流式请求并逐事件回调（MainActor 上下文）
    private func performStream(
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions,
        cancel: (() -> Void)?,
        onEvent: (AIStreamEvent) -> Void
    ) async throws {
        let agent = AIAgentStore.shared.agent(for: options.agentId ?? "") ?? AIAgentStore.shared.activeAgent

        let requestedModel = options.modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModelId: String
        if let requestedModel, !requestedModel.isEmpty {
            resolvedModelId = requestedModel
        } else {
            resolvedModelId = agent.modelId
        }
        guard !resolvedModelId.isEmpty else { throw AIChatError.missingModel }

        // 按 (providerId, modelId) 二元组解析归属服务商：会话绑定的服务商优先，
        // 其次智能体绑定，最后才按「谁持有该模型 id」推断。
        // 不同服务商可能提供同名模型 id（如百炼主账号与 Token Plan），只按 id 猜会静默打错端点与 Key。
        let resolvedProvider = AIProviderStore.shared.resolveProvider(
            forModelId: resolvedModelId,
            providerId: options.providerId,
            agentProviderId: agent.providerId
        ) ?? AIProvider.alibabaPreset()
        let effectiveProvider = resolvedProvider

        // 路由可观测：同名模型跨服务商撞车时，唯一能直接看出「这次实际打到谁」的地方。
        qsDebugLog("AI 路由 → provider=\(effectiveProvider.id) [\(effectiveProvider.name)] model=\(resolvedModelId) endpoint=\(effectiveProvider.baseURL)")

        let key = AIProviderStore.shared.apiKey(for: effectiveProvider.id) ?? apiKey ?? ""
        let modelSpec = effectiveProvider.model(for: resolvedModelId) ?? AIModelSpec(id: resolvedModelId, name: resolvedModelId)
        let llmProvider = LLMProviderRegistry.shared.provider(for: effectiveProvider.type)

        let monitor = StreamMonitorFlag()

        // 1. 首帧内容看门狗（120秒内必须收到实质内容文本、思考或工具调用，纯 usage 统计包不计入）
        let firstContentWatchdog = Task {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !monitor.receivedFirstContent {
                cancel?()
            }
        }
        defer { firstContentWatchdog.cancel() }

        // 2. 流传输中途停滞看门狗（若首内容到达后，网络停滞超过 60 秒无新分片，触发主动熔断）
        let stallWatchdog = Task {
            let stallLimit: TimeInterval = 60
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                if monitor.receivedFirstContent && Date().timeIntervalSince(monitor.lastActivity) > stallLimit {
                    monitor.markStalled()
                    cancel?()
                    break
                }
            }
        }
        defer { stallWatchdog.cancel() }

        do {
            let stream = llmProvider.stream(
                provider: effectiveProvider,
                model: modelSpec,
                messages: messages,
                options: options,
                apiKey: key
            )

            for try await event in stream {
                monitor.touchActivity()
                let isSubstantialContent: Bool
                switch event {
                case .text(let t):
                    isSubstantialContent = !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .reasoning(let r):
                    isSubstantialContent = !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .toolCallDispatched, .toolCallArgumentsDelta, .toolCalls:
                    isSubstantialContent = true
                case .usage:
                    isSubstantialContent = false
                }

                if isSubstantialContent && !monitor.receivedFirstContent {
                    monitor.markContentReceived()
                    firstContentWatchdog.cancel()
                }
                onEvent(event)
            }
        } catch is CancellationError {
            if monitor.didStall {
                throw AIChatError.streamError("大模型流式传输长时间停滞无响应（超过 60 秒）")
            }
            if !monitor.receivedFirstContent {
                throw AIChatError.timeout
            }
            throw CancellationError()
        }
    }
}