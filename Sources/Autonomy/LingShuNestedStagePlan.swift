import Foundation

/// 嵌套分阶段循环(`.nested`)的**纯逻辑**子域:阶段类型、规划提示与解析、互动完成信号判定、
/// 阶段上下文交接、终验聚合。全部无副作用(不碰网络/State),便于单测——机制层确定性可靠的根基。
///
/// 设计(用户定调):一次请求 → 规划成有序【阶段】,每阶段标 **任务**(有交付物→按交付物验收)/
/// **互动**(演示/答疑/陪聊→不验收,完成信号=主人确认没后续)。逐阶段推进、按性质验收,大 LOOP 终验。

/// 阶段性质:决定该阶段收尾后**验不验交付物**。
enum LingShuStageKind: String, Sendable, Equatable {
    case task        // 有确定交付物 → 复用 verifyAgentDeliverable 按交付物验收,不过则本阶段内返工
    case interaction // 演示/答疑/陪聊 → 不验交付物;是"活的",完成信号=主人确认没后续
}

/// 一个阶段:一句话目标 + 性质。
struct LingShuNestedStage: Sendable, Equatable {
    var title: String
    var kind: LingShuStageKind
}

/// 嵌套循环的纯规划/判定逻辑(静态、无副作用)。
enum LingShuNestedStagePlanner {

    // MARK: - 是否值得分阶段(快路启发式,保守)

    /// 是否需要走"分阶段流水线"。**保守**:只有明确的多阶段信号才 true,其余一律 false → 走 spine 直通
    /// (= 经典循环行为),让 `.nested` 对简单问答/单交付物请求**零影响**、不平白多一次规划模型调用。
    /// 触发条件(任一):① 有序衔接词(先/再/然后/依次/最后…)+ 动作动词;② 互动词(演示/讲解/答疑/陪聊)+ 制作动词。
    static func shouldPlanStages(_ request: String) -> Bool {
        let t = request
        let orderedMarkers = ["先做", "先写", "先生成", "再做", "再写", "然后", "接着", "之后", "最后", "依次", "逐个", "逐一", "第一步", "第二步", "首先", "其次"]
        let actionVerbs = ["做", "写", "生成", "创建", "制作", "搭", "建", "整理", "汇报", "演示", "讲", "答疑"]
        let interactionKeywords = ["演示", "讲解", "答疑", "陪聊", "放映", "讲一讲", "讲讲", "带我看", "带你看"]
        let makeVerbs = ["做", "写", "生成", "创建", "制作", "出一个", "出一份", "出个"]
        let hasOrdered = orderedMarkers.contains { t.contains($0) }
        let hasAction = actionVerbs.contains { t.contains($0) }
        let hasInteraction = interactionKeywords.contains { t.contains($0) }
        let hasMake = makeVerbs.contains { t.contains($0) }
        if hasOrdered && hasAction { return true }
        if hasInteraction && hasMake { return true }
        return false
    }

    // MARK: - 规划提示 + 解析

    /// 规划器系统提示(独立一次性会话,不带工具)。
    static let plannerSystem = "你是任务阶段规划器。把用户这次请求拆成有序执行的【阶段】,每阶段一行,只输出阶段列表、不寒暄、不解释。"

    /// 规划提示:要求模型按固定格式输出有序阶段(每行 `序号. [任务|互动] 一句话阶段目标`)。
    static func planningPrompt(_ request: String) -> String {
        """
        把下面这次请求拆成有序执行的阶段,每个阶段标注性质:
        - **任务**:有确定交付物(写文件/做PPT/写代码/查资料等),要按交付物验收。
        - **互动**:和主人实时来回(全屏演示/讲解/答疑/陪聊),不交付文件、不验收。
        输出格式(严格,每行一个阶段,2–6 个为宜):
        序号. [任务] 一句话阶段目标
        序号. [互动] 一句话阶段目标
        例:
        1. [任务] 制作一份介绍长城的PPT
        2. [互动] 全屏演示讲解这份PPT
        3. [互动] 回答主人关于内容的提问
        现在拆解这次请求(只输出阶段列表):
        \(request)
        """
    }

    /// 解析模型规划输出 → 有序阶段。容错:逐行匹配 `序号 [任务|互动] 标题`;一个都没解析出来 → 兜底成单个【任务】阶段。
    static func parsePlan(_ modelText: String, fallbackRequest: String) -> [LingShuNestedStage] {
        var stages: [LingShuNestedStage] = []
        for rawLine in modelText.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let (kind, title) = parseStageLine(line) else { continue }
            guard !title.isEmpty else { continue }
            stages.append(.init(title: title, kind: kind))
            if stages.count >= 8 { break }   // 防失控:最多 8 阶段
        }
        if stages.isEmpty {
            // 兜底:解析失败一律当单个【任务】阶段(= 整件事直接交给一段内层会话做完再验,等价经典路径)。
            return [.init(title: fallbackRequest.trimmingCharacters(in: .whitespacesAndNewlines), kind: .task)]
        }
        return stages
    }

    /// 解析单行 → (性质, 标题)。**只接受像阶段条目的行**(有前导序号/列表符 或 含显式标记);散文行返回 nil(跳过)。
    /// 有标记按标记定性质,无标记按关键词推断。
    static func parseStageLine(_ line: String) -> (LingShuStageKind, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 去掉前导序号(1. / 1、/ 1) / ① / - 等);剥掉了说明这行有阶段条目特征。
        var body = stripLeadingOrdinal(trimmed)
        let hadOrdinal = body != trimmed
        guard !body.isEmpty else { return nil }
        var kind: LingShuStageKind? = nil
        // 抽标记(中英、方/圆括号都认)。
        let taskMarkers = ["[任务]", "【任务】", "(任务)", "（任务）", "[task]", "task:", "任务:", "任务："]
        let interactionMarkers = ["[互动]", "【互动】", "(互动)", "（互动）", "[interaction]", "interaction:", "互动:", "互动："]
        for m in taskMarkers where body.localizedCaseInsensitiveContains(m) {
            kind = .task; body = removeFirstOccurrence(of: m, in: body); break
        }
        if kind == nil {
            for m in interactionMarkers where body.localizedCaseInsensitiveContains(m) {
                kind = .interaction; body = removeFirstOccurrence(of: m, in: body); break
            }
        }
        let title = body.trimmingCharacters(in: CharacterSet(charactersIn: " :：-—·、")).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        // **不像阶段条目的散文行(既无序号/列表符、也无标记)一律跳过** → 全跳过则 parsePlan 兜底单任务阶段。
        guard hadOrdinal || kind != nil else { return nil }
        // 无显式标记 → 按关键词推断(含演示/讲解/答疑/陪聊 = 互动,否则任务)。
        let resolved = kind ?? (inferKindByKeyword(title))
        return (resolved, title)
    }

    /// 按标题关键词推断性质(无显式标记时兜底)。
    static func inferKindByKeyword(_ title: String) -> LingShuStageKind {
        let interactionWords = ["演示", "讲解", "答疑", "陪聊", "放映", "讲一讲", "讲讲", "回答", "提问", "带我看", "带你看", "互动"]
        return interactionWords.contains { title.contains($0) } ? .interaction : .task
    }

    /// 去前导序号标记(`1. ` / `1、` / `1) ` / `① ` / `- ` / `* `)。
    static func stripLeadingOrdinal(_ line: String) -> String {
        var s = Substring(line)
        // 圆圈数字
        let circled = "①②③④⑤⑥⑦⑧⑨⑩"
        if let first = s.first, circled.contains(first) {
            s = s.dropFirst()
            return s.trimmingCharacters(in: CharacterSet(charactersIn: " .、)）:：-")).description
        }
        // 列表符号
        if let first = s.first, first == "-" || first == "*" || first == "·" {
            return s.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        // 阿拉伯数字 + 分隔符
        var digits = ""
        var rest = s
        while let f = rest.first, f.isNumber { digits.append(f); rest = rest.dropFirst() }
        if !digits.isEmpty, let sep = rest.first, ".、)）:：".contains(sep) {
            return rest.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func removeFirstOccurrence(of needle: String, in haystack: String) -> String {
        guard let range = haystack.range(of: needle, options: .caseInsensitive) else { return haystack }
        var copy = haystack
        copy.removeSubrange(range)
        return copy
    }

    // MARK: - 互动阶段完成信号

    /// 主人是否在示意"互动到此为止、没后续了"(互动阶段的完成信号——不验交付物,靠这个推进到下一阶段)。
    /// 命中常见收口语:没了/结束/可以了/不用了/就这样/没问题了/好了等。**保守**:只认明确收口,模棱两可一律当"继续互动"。
    static func isInteractionDone(_ userText: String) -> Bool {
        let t = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        // 太长(像是新提问/新指示)→ 不当收口,继续互动里答它。
        guard t.count <= 12 else {
            // 长句里若明确说"没有其他问题了/没问题了/可以结束了"也算收口。
            let longDone = ["没有其他", "没有了", "没问题了", "可以结束", "结束吧", "就到这", "到此为止", "不用了谢谢"]
            return longDone.contains { t.contains($0) }
        }
        let doneSignals = ["没了", "没有了", "结束", "结束吧", "可以了", "行了", "好了", "不用了", "就这样",
                           "没问题了", "没其他了", "没有其他", "够了", "到此为止", "就到这", "ok了", "可以结束", "停吧", "退出"]
        return doneSignals.contains { t.contains($0) }
    }

    /// 是否"退出/关闭演示"的显式命令(主人要把演示窗关掉)。命中即**确定性关预览**,不靠模型(实测 DeepSeek 口头答应却不调 present_fullscreen(false))。
    static func isExitPresentationCommand(_ userText: String) -> Bool {
        let t = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let exits = [
            "退出演示", "关闭演示", "结束演示", "关掉演示", "关了演示",
            "退出全屏", "退出放映", "结束放映",
            "关闭预览", "关掉预览", "收起预览", "关闭材料", "收起材料", "演示收尾",
            "关掉ppt", "关闭ppt", "关掉PPT", "关闭PPT", "别演示了", "不演示了", "不看了", "关掉幻灯", "关闭幻灯"
        ]
        return exits.contains { t.contains($0) }
    }

    // MARK: - 阶段上下文交接 + 终验聚合

    /// 构造某阶段交给内层会话的输入(带前序产物上下文 + 只做本阶段的约束)。
    static func stageInput(stage: LingShuNestedStage, index: Int, total: Int, priorSummaries: [String], originalRequest: String) -> String {
        var lines: [String] = []
        lines.append("【分阶段执行 · 第 \(index + 1)/\(total) 阶段 · 性质:\(stage.kind == .task ? "任务(有交付物)" : "互动(实时来回)")】")
        lines.append("本次完整请求:\(originalRequest)")
        if !priorSummaries.isEmpty {
            lines.append("前序阶段已完成(可作为本阶段的上下文/素材,产出物路径见下):")
            for (i, s) in priorSummaries.enumerated() {
                lines.append("  \(i + 1). \(s.prefix(300))")
            }
        }
        lines.append("本阶段目标:\(stage.title)")
        if stage.kind == .task {
            lines.append("要求:**只做本阶段这一件事,不要做后续阶段**。有交付物必须真用 write_file/run_command 把文件落到工作目录并在回复里给出绝对路径(否则验收不过)。做完用一句话交付:做了什么 + 产出物绝对路径。")
        } else {
            lines.append("要求:这是**和主人实时互动**(演示/讲解/答疑),不是交付文件、不要写交付物。若是演示就 open_preview 打开前序产出物 → present_fullscreen(true) → 用口语逐页讲解(讲稿照实际内容);讲完/答完后 speak 一句『还需要我做什么吗?』并停下等主人,**不要自己关闭演示、不要直接收尾**。")
        }
        return lines.joined(separator: "\n")
    }

    /// 大 LOOP 终验通过后,把各阶段成果聚合成一句面向主人的交付说明。
    static func aggregateSummary(stages: [LingShuNestedStage], summaries: [String]) -> String {
        let taskCount = stages.filter { $0.kind == .task }.count
        let interactionCount = stages.filter { $0.kind == .interaction }.count
        var head = "已分 \(stages.count) 个阶段完成"
        if taskCount > 0 && interactionCount > 0 {
            head += "(\(taskCount) 个任务阶段已验收交付、\(interactionCount) 个互动阶段已完成)"
        } else if taskCount > 0 {
            head += "(\(taskCount) 个任务阶段均已验收交付)"
        }
        head += ":"
        let body = summaries.enumerated().map { "\($0.offset + 1)、\($0.element.prefix(200))" }.joined(separator: "\n")
        return body.isEmpty ? head : "\(head)\n\(body)"
    }
}
