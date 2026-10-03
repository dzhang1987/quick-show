import Foundation
import SwiftUI

// MARK: - 富内容卡片统一契约
//
// 目标：AI 工具结果中的富内容（地图、天气、音乐、图表……）统一走「卡片信封」渲染，
// 而不是在渲染链里为每种内容写特判。新增一张卡片只需两步：
//   1. 实现一个 Codable payload 模型 + 一个 RichCardProvider（视图）；
//   2. 在 RichCardRegistry.registerBuiltIns() 追加一行注册。
//
// 数据流：
//   工具结果 JSON（顶层携带 card 信封，随 ToolCallRecord.result 持久化，历史会话可回放）
//     {"ok":true, "card":{"type":"map","data":{...}}, "data":{...}}
//   → 渲染时 RichCard.extract(fromToolResultJSON:) 提取信封
//   → RichCardRegistry 按 type 解析视图工厂
//   → 未注册 / 提取失败 → 降级为现有 JSON 卡片渲染（前后向兼容均安全）
//
// 本文件为纯契约层：不依赖任何具体卡片实现，不引入设计令牌。

// MARK: 卡片信封模型

/// 卡片信封：随工具结果 JSON 持久化的富内容声明。
/// - `type`：卡片类型标识（如 `"map"`），决定渲染视图
/// - `data`：卡片自由结构 payload，由各卡片 Provider 自行解码为强类型模型
struct RichCard: Codable, Equatable {
    let type: String
    let data: RichCardJSON

    /// 从工具结果 JSON 原文提取顶层 `card` 信封。
    /// 解析失败 / 无 card 字段 → nil，调用方按普通 JSON 结果渲染（降级安全）。
    static func extract(fromToolResultJSON json: String) -> RichCard? {
        guard let raw = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: raw) else { return nil }
        return envelope.card
    }

    /// payload 序列化为 Data（供 Provider 解码为强类型模型）。
    var payloadData: Data? { try? JSONEncoder().encode(data) }

    /// 结果信封外层：只关心顶层 `card` 字段，其余字段忽略。
    private struct Envelope: Decodable {
        let card: RichCard?
    }
}

// MARK: 通用 JSON 值

/// 卡片 payload 的通用 JSON 值：结构由各卡片自定义，契约层只做透传与持久化。
/// 独立于 AIChatService 的 `JSONValue`（该类型仅 Encodable）；本类型需要完整 Codable + Equatable。
enum RichCardJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RichCardJSON])
    case object([String: RichCardJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolean = try? container.decode(Bool.self) {
            self = .bool(boolean)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([RichCardJSON].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: RichCardJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let boolean):
            try container.encode(boolean)
        case .number(let number):
            // 整数值落盘为整数字面量，保持 payload JSON 可读
            if number.rounded() == number, abs(number) < 1e15 {
                try container.encode(Int(number))
            } else {
                try container.encode(number)
            }
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }
}

// MARK: - 卡片视图工厂与注册表

/// 卡片视图工厂：payload Data → 视图。工厂内部完成解码与错误态处理。
typealias RichCardViewFactory = (Data) -> AnyView

/// 卡片提供者协议：每种富卡片一个实现（payload 解码 + 视图构造一体）。
/// `makeView` 内部自行 decode：解码失败时应返回可读的错误占位视图，而不是抛出。
protocol RichCardProvider {
    /// 卡片类型标识（写入工具结果信封的 `card.type`）
    static var cardType: String { get }
    /// 由 payload Data 构造卡片视图
    static func makeView(payload: Data) -> AnyView
}

/// 富卡片注册表：type → 视图工厂。
/// 未注册类型不渲染专属卡片，由工具卡片降级为 JSON 展示（旧会话在新版本 / 新卡片在旧会话均安全）。
final class RichCardRegistry {
    static let shared = RichCardRegistry()

    private var factories: [String: RichCardViewFactory] = [:]

    private init() {}

    /// 已注册的卡片类型（调试 / 设置页展示用）
    var registeredTypes: [String] { Array(factories.keys).sorted() }

    func register(type: String, factory: @escaping RichCardViewFactory) {
        factories[type] = factory
    }

    func register<P: RichCardProvider>(_ provider: P.Type) {
        factories[P.cardType] = P.makeView
    }

    /// 按信封解析视图：未注册类型 / payload 序列化失败返回 nil（调用方降级为 JSON 渲染）。
    func makeView(for card: RichCard) -> AnyView? {
        guard let factory = factories[card.type], let payload = card.payloadData else { return nil }
        return factory(payload)
    }

    /// 注册内置卡片（应用启动时调用一次）。
    /// 新增卡片在此追加一行注册。
    func registerBuiltIns() {
        register(MapCardProvider.self)   // 地图卡（AIChatMapCardView.swift）
    }
}

// MARK: - 富卡片宿主视图

/// 富卡片宿主：从工具结果 JSON 提取 card 信封并渲染注册卡片，供消息渲染链直接嵌入。
/// 解析结果缓存于 @State（仅解析一次）：流式刷新期父视图反复重建本视图时，
/// 不重复解码 payload / 重建底层 NSView，用户在交互式卡片上的操作（如手动拖动地图）不受干扰。
/// 无信封 / 未注册类型 → 不渲染任何内容（降级路径由调用方现有 JSON 展示兜底）。
struct RichCardHostView: View {
    let resultJSON: String

    @State private var cardView: AnyView?

    // 两个 SwiftUI 陷阱的规避（均经最小复现实验验证）：
    // 1) onChange 的 action 闭包捕获的是旧视图实例——解析必须用传入的 newValue，
    //    读 self.resultJSON 拿到的是更新前的旧值（工具执行中插入视图时为空串），导致静默解析失败
    // 2) Group + 空条件分支会吞掉 onAppear（修饰符被转发到不存在的内容上）——
    //    改用 ZStack 实体容器保证 onAppear 稳定触发；无卡片时 ZStack 空内容零尺寸，无布局影响
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let cardView { cardView }
        }
        .onAppear { resolveIfNeeded(resultJSON) }
        .onChange(of: resultJSON) { newValue in resolveIfNeeded(newValue) }
    }

    /// 解析一次：卡片视图落定后不再重建。
    /// （工具结果在执行完成时一次性写入 ToolCallRecord.result，之后不再变更，故单次解析即正确。）
    private func resolveIfNeeded(_ json: String) {
        guard cardView == nil,
              let card = RichCard.extract(fromToolResultJSON: json) else { return }
        cardView = RichCardRegistry.shared.makeView(for: card)
    }
}
