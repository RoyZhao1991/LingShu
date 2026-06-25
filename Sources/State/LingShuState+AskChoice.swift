import Foundation

/// `ask_choice` 四肢:需要主人在有限选项里**选择/确认**时,弹**可点击选项卡片**而不是让人打字回自由问句
/// (用户拍板:这种确认应该点击推进)。复用对话内 `LingShuChoiceCard` + `selectRouteChoice`:handler 挂起等点选、
/// 用户点了把所选项喂回在飞的循环继续(continuation 模式,同 requestShellApproval)。
@MainActor
extension LingShuState {

    func askChoiceTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "ask_choice",
            description: "需要主人在有限选项里做选择/确认时用它(别用自由问句让人打字)。给 question + options(2–5 个,每个 label 简短、detail 可选说明)。会在对话里弹**可点击选项**,主人点了你就拿到所选项继续。用于:要不要接入某设备、走哪条方案、是否授权某动作等确认。",
            parametersJSON: """
            {"type":"object","properties":{
            "question":{"type":"string","description":"要主人定的问题"},
            "options":{"type":"array","description":"2–5 个可点选项","items":{"type":"object","properties":{"label":{"type":"string","description":"选项(简短)"},"detail":{"type":"string","description":"(可选)一句话说明"}},"required":["label"]}}
            },"required":["question","options"]}
            """
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用。" }
            return await self.presentChoice(argsJSON)
        }
    }

    /// 弹选项卡片 + 挂起等点选(返回所选项 label)。非交互(自主/无头)不卡死,直接告知无法弹选项。
    func presentChoice(_ argsJSON: String) async -> String {
        let (question, options) = Self.parseChoiceArgs(argsJSON)
        guard options.count >= 2 else { return "(选项不足 2 个,改用 ask_user 直接提问,或给出默认建议)" }
        if clarificationCenter.isNonInteractive() {
            return "(当前无人值守,无法弹可点选项让主人确认;请给出你的默认建议、或稍后主人在场时再确认)"
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let prompt = LingShuRouteChoicePrompt(
                question: question,
                options: options.map { LingShuRouteChoiceOption(label: $0.label, detail: $0.detail) })
            let msg = ChatMessage(speaker: "灵枢", text: question, isUser: false, choices: prompt)
            chatMessages.append(msg)
            pendingChoiceResolvers[msg.id] = { picked in cont.resume(returning: picked) }
        }
    }

    nonisolated static func parseChoiceArgs(_ json: String) -> (String, [(label: String, detail: String?)]) {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ("", []) }
        let q = (o["question"] as? String) ?? ""
        var opts: [(String, String?)] = []
        if let arr = o["options"] as? [[String: Any]] {
            for it in arr where (it["label"] as? String)?.isEmpty == false {
                opts.append((it["label"] as! String, it["detail"] as? String))
            }
        } else if let arr = o["options"] as? [String] {
            for l in arr where !l.isEmpty { opts.append((l, nil)) }
        }
        return (q, opts.map { (label: $0.0, detail: $0.1) })
    }
}
