import Foundation

/// 语义任务拆分器(Layer ①)。
///
/// 策略:模型驱动为主 + 启发式快路。
/// - 没有「多任务连接信号」的常见单句 → 走快路,直接 1 个意图,**不调模型**(省时省 token)。
/// - 出现多任务信号(另外/还有/顺便/同时/分号…)→ 交模型解析成 N 个意图 + 相关性分组 + 续接线索。
/// - 模型不可用或解析失败 → 安全回退为单意图(绝不丢任务)。
struct LingShuTaskSegmenter {

    /// 多任务连接信号:出现这些词时一句话很可能含多个任务,需模型拆。
    static let multiTaskSignals = [
        "另外", "还有", "顺便", "同时", "以及", "外加", "除此之外", "对了",
        "还要", "再帮我", "再给我", "并且帮", "一并", "接着还", "然后还", "其次"
    ]

    /// 启发式快路:返回 nil 表示「拿不准,需要模型拆」;返回非 nil 表示已确定(单任务/闲聊)。
    func heuristicSegmentation(_ prompt: String) -> LingShuTaskSegmentation? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .single(trimmed, isTask: false, source: "heuristic")
        }
        let normalized = LingShuMemoryTextToolkit.normalize(prompt)
        if Self.multiTaskSignals.contains(where: { normalized.contains($0) }) {
            return nil   // 有多任务信号 → 交给模型
        }
        // 无多任务信号:单意图。是否为任务用话题/动词信号粗判(仅用于快路标注)。
        return .single(trimmed, isTask: Self.looksLikeTask(normalized), source: "heuristic")
    }

    /// 模型驱动拆分。`complete` 注入「发提示拿文本」的能力(便于测试与解耦)。
    func segment(_ prompt: String, complete: (String) async -> String?) async -> LingShuTaskSegmentation {
        if let fast = heuristicSegmentation(prompt) {
            return fast
        }
        guard let raw = await complete(Self.segmentationPrompt(for: prompt)), !raw.isEmpty else {
            return .single(prompt, isTask: true, source: "model-fallback")
        }
        return Self.parseModelSegmentation(raw, original: prompt)
    }

    /// 解析模型返回的 JSON:{"tasks":[{"text":..,"group":..,"is_task":..,"resume_hint":..}, ...]}
    /// 容错:剥 markdown 围栏;解析失败回退单意图。
    static func parseModelSegmentation(_ raw: String, original: String) -> LingShuTaskSegmentation {
        let cleaned = stripCodeFence(raw)
        guard
            let data = jsonSlice(from: cleaned)?.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tasks = object["tasks"] as? [[String: Any]],
            !tasks.isEmpty
        else {
            return .single(original, isTask: true, source: "model-fallback")
        }

        let intents: [LingShuTaskSegmentIntent] = tasks.enumerated().compactMap { index, entry in
            let text = (entry["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            let group = (entry["group"] as? String).map { $0.isEmpty ? "g\(index + 1)" : $0 } ?? "g\(index + 1)"
            let isTask = (entry["is_task"] as? Bool) ?? true
            let hintRaw = (entry["resume_hint"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hint = (hintRaw?.isEmpty == false) ? hintRaw : nil
            return LingShuTaskSegmentIntent(text: text, group: group, isTask: isTask, resumeHint: hint)
        }

        guard !intents.isEmpty else {
            return .single(original, isTask: true, source: "model-fallback")
        }
        return .init(intents: intents, source: "model")
    }

    static func segmentationPrompt(for prompt: String) -> String {
        """
        你是任务拆分器。把用户这句话拆成若干独立任务意图,只输出 JSON,不要解释。
        规则:
        - 每个意图要可独立执行(把原句相关部分补成自足指令)。
        - group:相关任务用同一 group 值(可并入同一线程),无关任务用不同 group。
        - is_task:闲聊/寒暄/纯提问为 false,需要推进的任务为 true。
        - resume_hint:若该意图疑似续接历史任务(如"昨天那个爬虫"),给出线索文本,否则省略。
        输出格式:{"tasks":[{"text":"...","group":"g1","is_task":true,"resume_hint":"..."}]}

        用户输入:
        \(prompt)
        """
    }

    // MARK: - 辅助

    static func looksLikeTask(_ normalized: String) -> Bool {
        if LingShuSelfReferenceIntent.isDirectAssistantSelfIntroduction(normalized) { return false }
        if !LingShuTaskThreadScheduler.topicTokens(from: normalized).isEmpty { return true }
        let buildVerbs = ["做", "写", "生成", "开发", "实现", "搭", "制作", "整理", "部署", "修复", "重构", "测试", "爬", "构建", "设计"]
        return buildVerbs.contains { normalized.contains($0) }
    }

    private static func stripCodeFence(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            // 去掉首行 ``` 或 ```json
            if let firstNewline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNewline)...])
            }
            if let fenceRange = t.range(of: "```", options: .backwards) {
                t = String(t[t.startIndex..<fenceRange.lowerBound])
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从文本里截取第一个 {...} JSON 片段(容忍模型在 JSON 前后夹杂文字)。
    private static func jsonSlice(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(text[start...end])
    }
}
