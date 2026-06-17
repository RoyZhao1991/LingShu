import Foundation

/// 「托管模式」转入确认(用户定调 2026-06-17)。
/// 取向:复杂任务**不在一开始就进自主/托管模式**——先在普通模式做事(写文件/生成 PPT/查资料…);
/// 由**大脑自己判断**何时真要进入**实时演示 / 实时互动答疑 / 接管屏幕操作**那一刻,才调 `enter_managed_mode`
/// 申请,**弹窗征求主人同意**;同意才转入托管(本体在位 + 占屏 + 实时互动)。
/// **通配,不固化流程**:何时申请由模型自己想,不靠关键字预判。手动上岗(bolt / go_live)直接进、不走此确认。
struct LingShuPendingManagedMode: Identifiable {
    let id = UUID()
    let reason: String
    /// 用户点选后回传(恢复挂起的工具协程)。只消费一次。
    let resume: (Bool) -> Void
}

@MainActor
extension LingShuState {

    /// 申请进入托管模式:弹窗 await 主人同意。已在岗(手动/已托管)→ 直接放行不重复弹;已有待确认→拒绝堆叠。
    func requestManagedMode(reason: String) async -> Bool {
        if isStandingPersonOnDuty { return true }
        if pendingManagedModeRequest != nil { return false }
        appendTrace(kind: .route, actor: "灵枢", title: "申请进入托管模式", detail: String(reason.prefix(40)))
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pendingManagedModeRequest = LingShuPendingManagedMode(reason: reason, resume: { cont.resume(returning: $0) })
        }
    }

    /// 主人在弹窗点选:同意=恢复协程让工具去转入托管;不同意=留普通模式。转入动作由工具侧(enter_managed_mode)做。
    func resolveManagedMode(_ approved: Bool) {
        guard let pending = pendingManagedModeRequest else { return }
        pendingManagedModeRequest = nil
        appendTrace(kind: approved ? .route : .warning, actor: "主人",
                    title: approved ? "同意进入托管模式" : "留在普通模式", detail: String(pending.reason.prefix(40)))
        pending.resume(approved)
    }

    /// 四肢:大脑判断要进入托管模式(占屏实时演示/实时互动/接管屏幕)时调用——弹窗征同意,同意即转入托管会话续做。
    func enterManagedModeTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "enter_managed_mode",
            description: "当你判断**接下来要进入「托管模式」**(需要**占屏实时演示** / **与主人实时互动答疑** / **接管屏幕操作**)时调用——会**弹窗征求主人同意**,同意后灵枢本体在位、转入托管会话继续这件事。**普通做事不要调用**(写文件/改代码/查资料/生成 PPT 等都在普通模式完成);**只有真要当面实时演示或实时互动那一刻才调**。reason 写清你要实时做什么 + 关键上下文(如要演示的文件绝对路径)。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"reason\":{\"type\":\"string\",\"description\":\"要实时做什么(展示给主人确认,并作为转入托管后续做的事;含关键上下文如文件绝对路径)\"}},\"required\":[\"reason\"]}"
        ) { [weak self] args in
            guard let self else { return "状态不可用" }
            let reason = (Self.jsonField(args, "reason") ?? args).trimmingCharacters(in: .whitespacesAndNewlines)
            let approved = await self.requestManagedMode(reason: reason)
            guard approved else {
                return "(主人未同意进入托管模式。请改在普通模式下完成,或用不占屏的方式——不要再尝试占屏演示/接管。)"
            }
            await self.goLiveForInteractiveTask(prompt: reason.isEmpty ? "进入托管模式,实时演示/互动" : reason)
            return "(主人已同意进入托管模式。实时演示/互动已转入托管会话进行——你这条到此交接完成,不要再继续动作或重复演示。)"
        }
    }
}
