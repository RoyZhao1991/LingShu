import Foundation

/// `ask_form` 四肢(用户定调 2026-06-21):灵枢一次需要主人确认**多个事项**(配置/偏好/下单参数…)时,
/// 不要连珠炮似地一个个问、也不要 flatten 成一个单选卡——弹一张**多字段确认表单**:每个事项一行、各带自己的选择菜单,
/// 每个菜单**末行恒是「其他(自行输入)」**让主人填自由值;主人一次性填完提交,灵枢拿到全部字段答案继续。
@MainActor
extension LingShuState {

    func askFormTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "ask_form",
            description: "需要主人**一次确认多个事项**(每个事项有若干可选值)时用它,而不是连续问好几个问题、或塞进一个单选卡。会弹一张**多字段表单**:每个事项一行、各带选择菜单(末行自动是「其他(自行输入)」让主人填自由值),主人填完一次性提交,你拿到全部答案。用于:配置/偏好/下单参数/多项设置等需要逐项定的确认。",
            parametersJSON: """
            {"type":"object","properties":{
            "title":{"type":"string","description":"表单标题(一句话说要确认什么)"},
            "fields":{"type":"array","description":"要确认的事项,每项一行","items":{"type":"object","properties":{"key":{"type":"string","description":"字段标识(回传用,如 city/pay)"},"question":{"type":"string","description":"这个事项的问题"},"options":{"type":"array","items":{"type":"string"},"description":"预设可选值(可空;末行的'其他(自行输入)'由系统自动加,不要自己加)"}},"required":["key","question"]}}
            },"required":["fields"]}
            """
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用。" }
            return await self.presentForm(argsJSON)
        }
    }

    /// 弹多字段确认表单 + 挂起等主人提交(返回拼好的各字段答案)。非交互(自主/无头)不卡死,直接告知无法弹。
    func presentForm(_ argsJSON: String) async -> String {
        guard let form = LingShuConfirmForm.parse(argsJSON) else {
            return "(ask_form 参数无效:需要 fields[{key,question,options}]。事项少就用 ask_user/ask_choice。)"
        }
        if clarificationCenter.isNonInteractive() {
            return "(当前无人值守,无法弹确认表单让主人逐项填;请按合理默认推进、或稍后主人在场时再确认。)"
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let msg = ChatMessage(speaker: "灵枢", text: form.title, isUser: false, form: form)
            chatMessages.append(msg)
            pendingFormResolvers[msg.id] = { answers in cont.resume(returning: form.formatAnswers(answers)) }
        }
    }

    /// 主人在表单卡上点「提交」:置已解决态(不再可改)、回传答案恢复挂起的工具协程。
    func submitFormAnswers(_ answers: [String: String], for messageID: UUID) {
        guard let idx = chatMessages.firstIndex(where: { $0.id == messageID }),
              chatMessages[idx].formAnswers == nil else { return }
        chatMessages[idx].formAnswers = answers
        logEvent("用户提交确认表单(\(answers.count) 项)")
        if let resolver = pendingFormResolvers.removeValue(forKey: messageID) { resolver(answers) }
    }
}
