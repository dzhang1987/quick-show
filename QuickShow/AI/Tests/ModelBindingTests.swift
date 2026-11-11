// ModelBindingTests.swift: 模型身份 (providerId, modelId) 二元组回归测试。
//
// 背景：不同服务商完全可以提供同名 model id（如百炼主账号与 Token Plan 都挂了
// `deepseek-v4.1-flash-1017`）。历史实现只按裸 model id 扫「第一个持有者」，
// 导致在 Token Plan 子菜单里选中模型后，请求实际打到百炼端点与百炼 Key，
// 一级勾选态也跟着错挂。这里锁定解析优先级与持久化契约，防止回归。

import Foundation

@MainActor
enum ModelBindingTests {
    private static var passedCount = 0
    private static var failedCount = 0

    private static func assertTest(_ condition: Bool, _ name: String, file: String = #file, line: Int = #line) {
        if condition {
            passedCount += 1
            print("  ✅ [PASS] \(name)")
        } else {
            failedCount += 1
            print("  ❌ [FAIL] \(name) (at \(URL(fileURLWithPath: file).lastPathComponent):\(line))")
        }
    }

    static func run() async {
        print("==================================================")
        print("🚀 开始执行模型绑定 (providerId, modelId) 回归测试")
        print("==================================================")

        testResolverPriority()
        testResolverLegacyFallback()
        testRequestOptionsDefault()
        testSessionCodableRoundTrip()
        testSessionStoreBinding()

        print("==================================================")
        print("📊 模型绑定测试完成：通过 \(passedCount) 项，失败 \(failedCount) 项")
        print("==================================================")
        exit(failedCount > 0 ? 1 : 0)
    }

    // MARK: - 解析优先级

    /// 真实配置里若存在「多个服务商共用同一 model id」的场景，用它做端到端断言；
    /// 否则（干净安装）退化为协议无歧义断言，保证测试在任意机器上都能跑。
    private static func testResolverPriority() {
        print("\n[ModelBinding 1] 显式绑定优先于「第一个持有者」...")
        let store = AIProviderStore.shared
        let owners = store.providers.filter { !$0.models.isEmpty }

        var duplicatedPair: (id: String, first: AIProvider, second: AIProvider)?
        for model in owners.flatMap({ $0.models }) {
            let holders = owners.filter { $0.model(for: model.id) != nil }
            if holders.count >= 2 {
                duplicatedPair = (model.id, holders[0], holders[1])
                break
            }
        }

        guard let pair = duplicatedPair else {
            print("  ⏭️  当前配置无同名模型跨服务商场景，跳过（不影响解析器断言）")
            let anyModel = owners.first?.models.first
            if let anyModel, let owner = owners.first {
                assertTest(
                    store.resolveProvider(forModelId: anyModel.id, providerId: owner.id)?.id == owner.id,
                    "显式绑定持有该模型的服务商时按其返回"
                )
            }
            return
        }

        let unbound = store.resolveProvider(forModelId: pair.id)
        assertTest(unbound?.id == pair.first.id, "未绑定 providerId 时回退到首个持有者（旧数据兼容）")

        let pinnedToSecond = store.resolveProvider(forModelId: pair.id, providerId: pair.second.id)
        assertTest(pinnedToSecond?.id == pair.second.id, "显式绑定第二个持有者时必须精确命中，绝不被首个持有者劫持")

        let secondSpec = store.resolvedModelSpec(forModelId: pair.id, providerId: pair.second.id)
        let secondOwnSpec = pair.second.model(for: pair.id)
        assertTest(
            secondSpec?.name == secondOwnSpec?.name && secondSpec?.supportsVision == secondOwnSpec?.supportsVision,
            "模型规格（显示名/视觉能力）必须取绑定服务商的条目，而非首个持有者"
        )

        // 智能体绑定同样只是「持有才采信」的次级依据
        let agentBound = store.resolveProvider(forModelId: pair.id, agentProviderId: pair.second.id)
        assertTest(agentBound?.id == pair.second.id, "智能体绑定的服务商持有该模型时可作为次级依据命中")
    }

    // MARK: - 旧数据与边界

    private static func testResolverLegacyFallback() {
        print("\n[ModelBinding 2] 旧数据与边界回退...")
        let store = AIProviderStore.shared

        assertTest(store.resolveProvider(forModelId: "") == nil, "空 modelId 不解析出服务商")
        assertTest(
            store.resolveProvider(forModelId: "   ") == nil,
            "纯空白 modelId 不解析出服务商"
        )

        let unknown = store.resolveProvider(forModelId: "no-such-model-\(UUID().uuidString.prefix(6))")
        assertTest(
            unknown?.id == store.selectedProviderId || unknown?.id == store.selectedProvider?.id,
            "完全未知模型回退到全局选中服务商"
        )

        // 模型已被移出模型池：仍回到显式绑定的服务商，避免静默换端点换 Key
        guard let pinned = store.providers.first else { return }
        let orphan = store.resolveProvider(
            forModelId: "removed-model-\(UUID().uuidString.prefix(6))",
            providerId: pinned.id
        )
        assertTest(orphan?.id == pinned.id, "模型被移出模型池时仍回到显式绑定的服务商")
    }

    // MARK: - 请求选项

    private static func testRequestOptionsDefault() {
        print("\n[ModelBinding 3] 请求选项默认契约...")
        let options = AIChatRequestOptions()
        assertTest(options.modelId == nil && options.providerId == nil, "默认选项的模型与服务商均为 nil（交给服务层推断）")

        let bound = AIChatRequestOptions(modelId: "m", providerId: "p")
        assertTest(bound.modelId == "m" && bound.providerId == "p", "模型与服务商可同时显式绑定")
    }

    // MARK: - 会话持久化契约

    private static func testSessionCodableRoundTrip() {
        print("\n[ModelBinding 4] 会话持久化契约...")
        let session = ChatSession(title: "binding", modelId: "deepseek-v4.1-flash-1017", providerId: "custom-d385")

        guard let data = try? JSONEncoder().encode(session),
              let decoded = try? JSONDecoder().decode(ChatSession.self, from: data) else {
            assertTest(false, "会话 JSON 编解码成功")
            return
        }
        assertTest(decoded.providerId == "custom-d385", "会话 providerId 编解码后保持不变")
        assertTest(decoded.modelId == "deepseek-v4.1-flash-1017", "会话 modelId 编解码后保持不变")

        // 旧会话 JSON 无 providerId 键：必须解码为 nil 而不是失败
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","title":"legacy","createdAt":0,"updatedAt":0,"modelId":"deepseek-v4.1-flash-1017"}
        """
        if let legacyData = legacyJSON.data(using: .utf8),
           let legacy = try? JSONDecoder().decode(ChatSession.self, from: legacyData) {
            assertTest(legacy.providerId == nil, "旧会话缺少 providerId 时解码为 nil（向后兼容）")
            assertTest(legacy.modelId == "deepseek-v4.1-flash-1017", "旧会话 modelId 正常解码")
        } else {
            assertTest(false, "旧会话 JSON 必须仍可解码")
        }
    }

    // MARK: - 会话存储写入契约（菜单点了模型之后的落点）

    private static func testSessionStoreBinding() {
        print("\n[ModelBinding 5] 会话存储写入契约...")
        let store = ChatSessionStore.shared
        let session = store.createSession(title: "model-binding-test")
        defer { store.deleteSession(id: session.id) }

        store.setSessionModel(id: session.id, modelId: "deepseek-v4.1-flash-1017", providerId: "custom-d385")
        let bound = store.session(id: session.id)
        assertTest(bound?.modelId == "deepseek-v4.1-flash-1017", "写入后会话 modelId 落定")
        assertTest(bound?.providerId == "custom-d385", "写入后会话 providerId 落定（同名模型不再丢服务商身份）")

        // 解绑模型必须一并清掉服务商，避免残留错配的二元组
        store.setSessionModel(id: session.id, modelId: nil)
        let unbound = store.session(id: session.id)
        assertTest(unbound?.modelId == nil && unbound?.providerId == nil, "解绑模型时 providerId 一并清空")
    }
}