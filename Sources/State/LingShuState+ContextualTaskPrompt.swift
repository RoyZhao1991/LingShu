import Foundation

@MainActor
extension LingShuState {
    /// 把“当前用户原话 + 大脑解析出的 GoalSpec + agent 子目标”合成自洽的子任务输入。
    /// 这里不做关键词判断；所有承接/省略/指代都来自 GoalSpec 的结构化结果。
    func contextualTaskPrompt(rawObjective: String, userPrompt: String, goalSpec: LingShuGoalSpec?) -> String {
        let raw = rawObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spec = goalSpec else { return raw.isEmpty ? user : raw }

        var sections: [String] = [
            "【结构化目标】\n\(spec.summary)"
        ]

        if !raw.isEmpty, raw != spec.objective {
            sections.append("【分派给执行者的原始子目标】\n\(raw)")
        }
        if !user.isEmpty, user != raw {
            sections.append("【用户本轮原话】\n\(user)")
        }
        if !spec.acceptanceCriteriaBlock.isEmpty {
            sections.append(spec.acceptanceCriteriaBlock)
        }

        sections.append("""
        【执行要求】
        - 以“结构化目标”为准推进；原始子目标只作为执行者视角的补充说明。
        - 如果目标引用了上一轮/默认承接回合，必须保留其主题、对象和约束，不要只按当前句子的片段执行。
        - 最终回复遵守结构化输出协议，只把给用户看的结论写入 reply。
        """)

        return sections.joined(separator: "\n\n")
    }
}
