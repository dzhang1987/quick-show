// LLMProvider: 行业通用大模型服务商（Provider）协议与统一分发总线。
// 遵循标准 Provider + Model 架构设计，抹平 OpenAI、Qoder、Gemini 等各大模型服务商在通信协议、鉴权与流式事件上的底层差异。

import Foundation

/// 大模型服务提供商通用协议 (聚合通信推理与多授权策略)
protocol LLMProvider: Sendable {
    /// 该 Provider 所对应的服务商类型
    var providerType: AIProviderType { get }

    /// 该 Provider 针对具体配置支持的授权方式列表 (1 对多聚合，一等公民)
    func supportedAuthMethods(for provider: AIProvider) -> [any AIAuthMethod]

    /// 发起流式推理请求，向外部统一输出打字机文本、思考流、工具调用与 Token 用量
    func stream(
        provider: AIProvider,
        model: AIModelSpec,
        messages: [ChatCompletionMessage],
        options: AIChatRequestOptions,
        apiKey: String
    ) -> AsyncThrowingStream<AIStreamEvent, Error>

    /// 从端点拉取该供应商可用模型列表
    func fetchModels(
        provider: AIProvider,
        apiKey: String
    ) async throws -> [String]

    /// 思考档位与模型参数适配
    func thinkingFields(
        for modelId: String,
        level: ThinkingLevel?
    ) -> [String: Any]
}

/// 统一 Provider 注册与分发总线
@MainActor
final class LLMProviderRegistry {
    static let shared = LLMProviderRegistry()

    private let providers: [AIProviderType: LLMProvider]

    private init() {
        self.providers = [
            .openAICompatible: OpenAIProvider(),
            .nativeBridge: OpenAIProvider(),
            .qoderNative: QoderProvider(),
            .antigravityNative: GeminiProvider()
        ]
    }

    /// 获取特定服务商类型的 Provider 实现
    func provider(for type: AIProviderType) -> LLMProvider {
        providers[type] ?? OpenAIProvider()
    }

    /// 获取所有注册的 Provider 实现
    func allProviders() -> [LLMProvider] {
        Array(providers.values)
    }

    /// 根据 provider 实体查询支持的所有授权方式
    func authMethods(for provider: AIProvider) -> [any AIAuthMethod] {
        let impl = self.provider(for: provider.type)
        return impl.supportedAuthMethods(for: provider)
    }
}

