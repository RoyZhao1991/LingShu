import Foundation

/// dreaming 的「知识图谱轨」:从近期对话蒸馏**原子事实** → 并入图谱(园丁去重/归一/矛盾消解)→ 园丁维护
/// (衰减/补链/剪枝)。这是记忆 v2 自主扩充+自主维护的入口。全程 guarded:模型不可用/解析失败只跳过,不影响别的轨。
@MainActor
extension LingShuState {

    /// M3「子→主」核心记忆:子任务完成的产出/结论蒸馏进**常驻** v2 知识图谱(vault 全局持久=主线程的核心记忆),
    /// 这样子线程结束后,主线程事后仍能召回它做过/得出的东西。
    ///
    /// **不再裸 dump 原始 objective/summary**——那会把每条子任务的原始指令原样存成 decision 笔记
    /// (标题=整句指令、正文=客套话、连"建个文件"这类一次性操作也污染图谱)。改为走与 dreaming
    /// **同一条「LLM 原子抽取 + 园丁去重」管线**:抽取器自己判断该不该留(操作型/一次性任务→返回空→不入库)、
    /// 产出规范原子标题与结论,并复用已知实体名归并。异步 fire-and-forget,不阻塞编排收尾。
    func promoteSubtaskKnowledge(objective: String, summary: String) {
        let obj = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let sum = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !obj.isEmpty, !sum.isEmpty else { return }
        let transcript = "用户(交给子任务):\(obj.prefix(300))\n灵枢(子任务结果):\(sum.prefix(600))"
        Task { @MainActor [weak self] in
            await self?.extractAndIntegrateKnowledge(fromTranscript: transcript, label: "子任务")
        }
    }

    func consolidateKnowledgeGraph() async {
        // 1. 抽取:从近期对话蒸馏原子事实(只在有对话时跑)
        let recent = chatMessages
            .filter { !$0.isLoading && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(24)
        if !recent.isEmpty {
            let transcript = recent.map { "\($0.isUser ? "用户" : "灵枢"):\($0.text.prefix(300))" }.joined(separator: "\n")
            await extractAndIntegrateKnowledge(fromTranscript: transcript, label: "对话")
        }

        // 2. 园丁维护(衰减/补链/剪枝)——即便本次没新料也跑。
        let change = knowledgeGraph.tend()
        if change != "无变更" {
            appendTrace(kind: .system, actor: "固化", title: "知识图谱维护", detail: change)
        }
    }

    /// 统一的「转写 → LLM 原子抽取 → 并入图谱(去重/矛盾上报)」管线。dreaming 与子→主共用同一条,
    /// 保证两边产出一致的干净原子笔记(规范标题+结论),而不是裸 dump;喂已知实体清单做命名归一。
    /// 模型不可用/解析失败只跳过(全程 guarded)。返回 (新增, 归并) 计数。
    @discardableResult
    func extractAndIntegrateKnowledge(fromTranscript transcript: String, label: String) async -> (created: Int, merged: Int) {
        let content = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return (0, 0) }
        // 通用归一:把已记住的实体清单喂给抽取器,要求同一实体复用原标题。否则同一实体每次另起标题 →
        // gardener 精确归一命中不了 → 永远新建 → 重复滋生 + 矛盾漏检(M5 失效)。喂清单是治本(对任意实体生效,零硬编码)。
        let knownEntities = knowledgeGraph.notes
            .sorted { $0.updated > $1.updated }
            .prefix(60)
            .map { n -> String in
                let alias = n.aliases.isEmpty ? "" : "(别名:\(n.aliases.joined(separator: "、")))"
                return "- \(n.title)〔\(n.kind.rawValue)〕\(alias):\(n.body.prefix(36))"
            }
            .joined(separator: "\n")
        let knownBlock = knownEntities.isEmpty ? "" : """

            【已知实体清单(归一用,最重要)】以下是已经记住的实体。若本次内容是关于其中某个实体的(哪怕换了说法/补充细节/做了纠正),其 title **必须原样照抄该实体的名字**,绝不另造新名、也别把属性细节拼进 title(例:已知有「项目X」,即便说"项目X换了技术栈",title 也只填「项目X」)。只有全新实体才取新 title。
            \(knownEntities)
            """
        let prompt = """
        从下面内容里抽取**值得长期记住的原子事实**(一个概念一条),输出 **JSON 数组**,不要任何多余文字。每条字段:
        - kind: person / project / preference / decision / fact 之一
        - title: 简短规范名;**若属于下面【已知实体清单】里的实体,必须原样复用其名字**(同一实体始终同名,归并/矛盾检测才生效)
        - aliases: 别名数组(可空)
        - body: 一句话结论
        - source: 用户明确说的填 "user-explicit",你推断的填 "inference"
        - confidence: 0~1
        - sensitive: 仅**真正需保密、不该留存**的隐私填 true——身份证/护照号、家庭住址、密码/密钥/Token、银行卡/账号、私密病史诊断等。**用户明确要你记住并据此规避的安全/健康约束(如食物过敏、用药禁忌、饮食禁忌、不能接触某物)不算 sensitive**:那是用户要你每次遵守的硬性偏好,应当作 preference/fact 存下(填 false),否则会害到用户。
        **只抽两类**:① 用户(「用户:」开头)明确陈述的事实/偏好/决定;② 灵枢(「灵枢:」开头)**实际完成的工作产出/结论**(如"已完成X、产出文件Y"、"调研得出Z")。
        **灵枢在对话里即兴给出的一般性回答、建议、看法、常识、推测、寒暄,绝不抽成事实**——那是即时生成的,不是用户的长期真相,固化它等于把模型自己瞎说的话变成"长期记忆"(严重污染)。
        寒暄、临时操作、一次性任务/问答(如建个文件、跑条命令、查个临时数)也**不要**。没有就返回 []。
        \(knownBlock)
        内容:
        \(content)
        """
        let adapter = makeAgentModelAdapter()
        let session = LingShuAgentSession(
            id: "kg-\(UUID().uuidString.prefix(6))",
            system: "你是知识抽取器,只输出 JSON 数组,不解释、不写代码。",
            tools: [],
            model: adapter,
            maxTurns: 1
        )
        guard case .completed(let text) = await session.send(prompt) else { return (0, 0) }
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
                        detail: "据\(label)新增 \(created) / 归并 \(merged) 条原子知识,共 \(knowledgeGraph.count) 条。")
        }
        return (created, merged)
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
