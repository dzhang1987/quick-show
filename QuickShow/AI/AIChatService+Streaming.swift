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

    private final class FirstTokenFlag {
        var received = false
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
        let provider = AIProviderStore.shared.provider(for: agent.providerId) ?? AIProviderStore.shared.selectedProvider ?? AIProvider.alibabaPreset()
        let key = AIProviderStore.shared.apiKey(for: provider.id) ?? apiKey ?? ""

        let requestedModel = options.modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModelId: String
        if let requestedModel, !requestedModel.isEmpty {
            resolvedModelId = requestedModel
        } else {
            resolvedModelId = agent.modelId
        }
        guard !resolvedModelId.isEmpty else { throw AIChatError.missingModel }

        let modelSpec = provider.model(for: resolvedModelId) ?? AIModelSpec(id: resolvedModelId, name: resolvedModelId)

        let llmProvider = LLMProviderRegistry.shared.provider(for: provider.type)

        let firstTokenFlag = FirstTokenFlag()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !firstTokenFlag.received {
                cancel?()
            }
        }
        defer { watchdog.cancel() }

        do {
            let stream = llmProvider.stream(
                provider: provider,
                model: modelSpec,
                messages: messages,
                options: options,
                apiKey: key
            )

            for try await event in stream {
                if !firstTokenFlag.received {
                    firstTokenFlag.received = true
                    watchdog.cancel()
                }
                onEvent(event)
            }
        } catch is CancellationError {
            if !firstTokenFlag.received {
                throw AIChatError.timeout
            }
            throw CancellationError()
        }
    }
}