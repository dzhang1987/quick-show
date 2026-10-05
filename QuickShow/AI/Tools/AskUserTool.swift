import Foundation

// MARK: - ask_user 工具

/// 向用户提问工具：当模型需求不明确/有歧义/方案有分支时，经输入坞抽屉向用户收集答案。
/// 一次可提 1-5 题，每题 2-6 个选项（单选/多选），用户亦可自由输入。
/// 本工具只负责入参校验、题面组装与结果序列化；挂起管道见 ChatInteractionCenter。
/// 标记 isInteractive = true：执行器对其豁免超时，无限静候用户作答。
final class AskUserTool: AITool {
    let name = "ask_user"
    let displayName = "向用户提问"
    let category: ToolCategory = .interaction
    /// 交互工具：挂起等待用户操作；默认 serial 执行策略不变。
    let isInteractive = true

    let description = "向用户提问以澄清需求。重要：接到模糊、有歧义或存在多种合理解释的请求时，必须先调用本工具确认后再执行，不要自行假设用户的意图。一次调用可提出多个问题（1-5 个），把需要澄清的点合并成一次提问；每个问题提供 2-6 个具体、可行动的选项并标注单选（multiple=false）或多选（multiple=true），用户也可能直接输入文字作答。仅在用户指令已明确、细节琐碎不影响结果、或用户已表达「直接做」时才跳过提问。"

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "questions": [
                    "type": "array",
                    "description": "要提出的问题列表（1-5 个）",
                    "items": [
                        "type": "object",
                        "properties": [
                            "question": [
                                "type": "string",
                                "description": "完整问题文本（必填）"
                            ],
                            "header": [
                                "type": "string",
                                "description": "短标签（可选；缺省取问题前 12 字）"
                            ],
                            "options": [
                                "type": "array",
                                "description": "候选选项（2-6 个）",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "label": [
                                            "type": "string",
                                            "description": "选项文案（必填）"
                                        ],
                                        "description": [
                                            "type": "string",
                                            "description": "选项补充说明（可选）"
                                        ]
                                    ],
                                    "required": ["label"]
                                ]
                            ],
                            "multiple": [
                                "type": "boolean",
                                "description": "是否多选，默认 false（单选）"
                            ]
                        ],
                        "required": ["question"]
                    ]
                ]
            ],
            "required": ["questions"]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let specs = try Self.parseSpecs(arguments)

        // 发布提问请求并挂起等待 UI（注意 MainActor 跳跃）；取消 → nil
        let exchange = await ChatInteractionCenter.shared.requestUserAnswersReturningQuestions(specs)
        guard let response = exchange.response else {
            return AIToolExecutor.encodeJSON(["ok": false, "error": "用户取消了提问"])
        }

        // 按题目顺序输出：answer 以 question.id 索引，选中 option 的 id 还原为 label。
        var answers: [[String: Any]] = []
        for question in exchange.questions {
            let answer = response.answers[question.id]
            let selected = question.options
                .filter { answer?.selectedOptionIDs.contains($0.id) == true }
                .map { $0.label }
            answers.append([
                "question": question.question,
                "selected": selected,
                "custom": answer?.customText ?? ""
            ])
        }
        return toolSuccessJSON(["answers": answers])
    }

    // MARK: - 入参解析与校验

    /// 解析并校验 questions：空/超 5 题/选项不足 2 个 → 抛「参数不合规」。
    private static func parseSpecs(_ arguments: [String: Any]) throws -> [UserQuestionSpec] {
        guard let rawQuestions = arguments["questions"] as? [[String: Any]] else {
            throw ToolExecutionError("参数不合规：缺少 questions 数组")
        }
        guard !rawQuestions.isEmpty else {
            throw ToolExecutionError("参数不合规：questions 不能为空")
        }
        guard rawQuestions.count <= 5 else {
            throw ToolExecutionError("参数不合规：一次最多提出 5 个问题（当前 \(rawQuestions.count) 个）")
        }

        return try rawQuestions.map { raw in
            guard let question = (raw["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !question.isEmpty else {
                throw ToolExecutionError("参数不合规：每题的 question 必填且非空")
            }

            guard let rawOptions = raw["options"] as? [[String: Any]], rawOptions.count >= 2 else {
                throw ToolExecutionError("参数不合规：每题至少提供 2 个选项")
            }
            let options: [UserQuestionOptionSpec] = try rawOptions.map { item in
                guard let label = (item["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !label.isEmpty else {
                    throw ToolExecutionError("参数不合规：选项 label 必填且非空")
                }
                let rawDescription = (item["description"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let description = (rawDescription?.isEmpty == false) ? rawDescription : nil
                return UserQuestionOptionSpec(label: label, description: description)
            }

            // header 缺省取 question 前 12 字；multiple 默认 false
            let rawHeader = (raw["header"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let header = (rawHeader?.isEmpty == false) ? rawHeader! : String(question.prefix(12))
            let multiple = (raw["multiple"] as? Bool) ?? false

            return UserQuestionSpec(header: header, question: question, options: options, multiple: multiple)
        }
    }
}