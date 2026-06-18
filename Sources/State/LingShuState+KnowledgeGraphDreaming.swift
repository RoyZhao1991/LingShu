import Foundation

/// dreaming 的「知识图谱轨」:从近期对话蒸馏**原子事实** → 并入图谱(园丁去重/归一/矛盾消解)→ 园丁维护
/// (衰减/补链/剪枝)。这是记忆 v2 自主扩充+自主维护的入口。全程 guarded:模型不可用/解析失败只跳过,不影响别的轨。
@MainActor
extension LingShuState {

    /// M3「子→主」核心记忆:子任务完成的产出/结论蒸馏进**常驻** v2 知识图谱(vault 全局持久=主线程的核心记忆),
    /// 这样子线程结束后,主线程事后仍能召回它做过/得出的东西。园丁负责去重/归并(同主题多次只长一条)。
    func promoteSubtaskKnowledge(objective: String, summary: String) {
        let title = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else { return }
        knowledgeGraph.remember(.init(
            kind: .decision, title: String(title.prefix(80)), body: String(body.prefix(400)),
            source: .tool, confidence: 0.7))
    }

    func consolidateKnowledgeGraph() async {
        // 1. 抽取:从近期对话蒸馏原子事实(只在有对话时跑)
        let recent = chatMessages
            .filter { !$0.isLoading && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(24)
        if !recent.isEmpty {
            let transcript = recent.map { "\($0.isUser ? "用户" : "灵枢"):\($0.text.prefix(300))" }.joined(separator: "\n")
            let prompt = """
            从下面对话里抽取**值得长期记住的原子事实**(一个概念一条),输出 **JSON 数组**,不要任何多余文字。每条字段:
            - kind: person / project / preference / decision / fact 之一
            - title: 简短规范名(同一实体每次用同一名,便于归并)
            - aliases: 别名数组(可空)
            - body: 一句话结论
            - source: 用户明确说的填 "user-explicit",你推断的填 "inference"
            - confidence: 0~1
            - sensitive: 涉及隐私/敏感(身份证、住址、密码、私密健康等)填 true
            **只抽稳定有价值的**(谁是谁、硬偏好、关键决定、长期事实);寒暄、临时内容、一次性问答**不要**。没有就返回 []。
            对话:
            \(transcript)
            """
            let adapter = makeAgentModelAdapter()
            let session = LingShuAgentSession(
                id: "kg-\(UUID().uuidString.prefix(6))",
                system: "你是知识抽取器,只输出 JSON 数组,不解释、不写代码。",
                tools: [],
                model: adapter,
                maxTurns: 1
            )
            if case .completed(let text) = await session.send(prompt) {
                let candidates = Self.parseKnowledgeCandidates(LingShuReasoningText.stripThinkTags(text))
                var merged = 0, created = 0
                for candidate in candidates {
                    switch knowledgeGraph.remember(candidate) {
                    case .create: created += 1
                    case .update: merged += 1
                    case .conflict(let note, let incoming):
                        // M5:等权用户事实矛盾 → 不静默择一,上报让主人定夺(保留原值)。
                        appendTrace(kind: .warning, actor: "记忆", title: "记忆冲突待定",
                                    detail: "「\(note.title)」原记「\(note.body.prefix(36))」与新说法「\(incoming.prefix(36))」矛盾(都来自你明说),已保留原值,请定夺。")
                    case .skip: break
                    }
                }
                if created + merged > 0 {
                    appendTrace(kind: .result, actor: "固化", title: "知识图谱",
                                detail: "新增 \(created) / 归并 \(merged) 条原子知识,共 \(knowledgeGraph.count) 条。")
                }
            }
        }

        // 2. 园丁维护(衰减/补链/剪枝)——即便本次没新料也跑。
        let change = knowledgeGraph.tend()
        if change != "无变更" {
            appendTrace(kind: .system, actor: "固化", title: "知识图谱维护", detail: change)
        }
    }

    /// 容错解析模型抽取的 JSON 数组为 Candidate(剥代码块/前后缀,定位首个 `[` 到末个 `]`)。纯函数,可单测。
    nonisolated static func parseKnowledgeCandidates(_ raw: String) -> [LingShuMemoryGardener.Candidate] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end else { return [] }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { obj in
            guard let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let kind = LingShuMemoryNote.Kind(rawValue: (obj["kind"] as? String) ?? "fact") else { return nil }
            let aliases = (obj["aliases"] as? [String]) ?? []
            let body = (obj["body"] as? String) ?? ""
            let source = LingShuMemoryNote.Source(rawValue: (obj["source"] as? String) ?? "inference") ?? .inference
            let confidence = (obj["confidence"] as? Double) ?? (obj["confidence"] as? NSNumber)?.doubleValue ?? 0.6
            let sensitive = (obj["sensitive"] as? Bool) ?? false
            return .init(kind: kind, title: title, aliases: aliases, body: body,
                         source: source, confidence: min(1, max(0, confidence)), sensitive: sensitive)
        }
    }
}
