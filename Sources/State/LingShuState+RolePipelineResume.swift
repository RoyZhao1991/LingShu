import Foundation

/// **角色管线孤儿续跑(用户定调 2026-06-28:重派续跑·复用产物)**。
/// inline 角色管线(@Claude→@Codex 这种)是直接 Task 跑的、**死了不留断点**:app 重启 / 模型通道超时后会留下一条
/// 卡在「执行中」的僵尸记录(灵枢主线程已回待命、没人驱动它)。这里检测这类孤儿,**复用工作目录里已有的产物**、
/// 重派同一组 agent 续跑到完成,而不是卡死或简单收口成"部分完成"。触发:① app 启动扫描(重启孤儿)② 看门狗(运行中超时孤儿)。
@MainActor
extension LingShuState {

    /// 这条记录是不是**角色管线**任务——据它启动时发出的唯一 router 消息「派生角色管线子线程」判定。精确、不挑场景、不误伤普通派发任务。
    func isRolePipelineRecord(_ record: LingShuTaskExecutionRecord) -> Bool {
        record.messages.contains { $0.text.contains("派生角色管线子线程") }
    }

    /// 重建这条管线用过的 agent:从**参与方**(非灵枢/你/系统)名映射到已注册的 agent 插件(精确续跑要靠它们,如 Claude→claude、Codex→codex)。
    func rolePipelineAgents(for record: LingShuTaskExecutionRecord) -> [(id: String, name: String)] {
        let plugins = LingShuAgentPluginStore.load()
        if !record.roleSlots.isEmpty {
            var slotted: [(id: String, name: String)] = []
            for slot in record.roleSlots {
                guard let agentID = slot.agentID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !agentID.isEmpty,
                      let plugin = plugins.first(where: { $0.id.caseInsensitiveCompare(agentID) == .orderedSame }),
                      !slotted.contains(where: { $0.id == plugin.id }) else { continue }
                slotted.append((id: plugin.id, name: slot.agentName))
            }
            if !slotted.isEmpty { return slotted }
        }
        let skip: Set<String> = ["你", "灵枢", "系统", "用户", "需求方", "中枢", ""]
        var out: [(id: String, name: String)] = []
        for raw in record.participants {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !skip.contains(name),
                  let p = plugins.first(where: { $0.id.caseInsensitiveCompare(name) == .orderedSame }),
                  !out.contains(where: { $0.id == p.id }) else { continue }
            out.append((id: p.id, name: name))
        }
        return out
    }

    /// 续跑一条中断的角色管线孤儿——**在原记录上原地续跑**(用户定调 2026-06-28:续接不能丢之前的执行记录和上下文):
    /// 复活成执行中、**保留全部历史**,把**上一轮的 maker 交付 + 评审官意见**当承接上下文喂给重派的角色(别从头重做、别丢反馈)。
    func resumeOrphanedRolePipeline(_ record: LingShuTaskExecutionRecord) async {
        let rid = record.id
        guard !resumedOrphanRecordIDs.contains(rid) else { return }   // 一会话内同一条不重复续(防 re-dispatch 死循环)
        resumedOrphanRecordIDs.insert(rid)
        let agents = rolePipelineAgents(for: record)
        guard !agents.isEmpty else {
            finishTaskRecord(rid, status: .needsRevision, summary: "执行中断、未能重建协作 agent,未交付——可手动重发续跑。")
            return
        }
        // **原地续跑**:复活成执行中(留全部历史),建可见气泡、打开记录窗口。
        if let i = taskExecutionRecords.firstIndex(where: { $0.id == rid }) {
            taskExecutionRecords[i].status = .running
            taskExecutionRecords[i].updatedAt = Date()
        }
        livePipelineRecordIDs.insert(rid)
        defer { livePipelineRecordIDs.remove(rid) }
        let bubble = ChatMessage(speaker: "灵枢", text: "🔧 中断续跑:接着上次的进度把它做完…", isUser: false, isLoading: true, taskRecordID: rid)
        chatMessages.append(bubble)
        dispatchedTaskBubbles[rid] = bubble.id
        openTaskRecord(rid)
        appendTaskRecordMessage(rid, actor: "系统", role: "自动续跑·上岗", kind: .router,
            text: "中断续跑:接着上次进度,复用已有产物 + **承接上一轮 maker 交付和评审官意见**继续做(历史都在本记录里,没丢)。")
        lastPipelineAgents = agents.map { LingShuRoleAgentRef(id: $0.id, name: $0.name) }
        lastPipelineTask = record.prompt
        let priorContext = rolePipelinePriorContext(record)
        let base = record.goal.isEmpty ? record.prompt : record.goal
        let arts = record.artifacts.map { ($0.location as NSString).lastPathComponent }.filter { !$0.isEmpty }
        let resumeTask = base + "\n\n【续跑·别从头重做】上次这个任务跑到一半被打断了(app重启 / 模型通道超时)。"
            + (arts.isEmpty ? "" : "工作目录已有产物:\(arts.joined(separator: "、"))。")
            + "**承接上次的进度和评审意见**继续做、过验收,绝不推翻重来。"
        appendTrace(kind: .route, actor: "续跑", title: "角色管线·原地续跑", detail: "复用产物+上轮上下文,重派 " + agents.map(\.name).joined(separator: "→"))
        let steps = await planRolePipeline(task: resumeTask, agents: agents)
        guard steps.count >= 2 else {
            finishTaskRecord(rid, status: .needsRevision, summary: "续跑重排角色失败,未交付——可手动重发。")
            if let i = chatMessages.firstIndex(where: { $0.id == bubble.id }) { chatMessages[i].isLoading = false; chatMessages[i].text = "续跑重排角色失败,可手动重发。" }
            return
        }
        bindRolePipelineSlots(steps, recordID: rid)
        mirrorRolePipelinePlan(steps, recordID: rid)
        if let i = chatMessages.firstIndex(where: { $0.id == bubble.id }) {
            chatMessages[i].text = "🔧 续跑:" + steps.map { "\($0.roleTitle)(\($0.agentName ?? "灵枢"))" }.joined(separator: " → ")
        }
        let (result, passed) = await runRolePipeline(recordID: rid, task: resumeTask, steps: steps, initialPrior: priorContext)
        finishTaskRecord(rid, status: passed ? .verified : .needsRevision,
            summary: (passed ? "续跑评审通过、已交付:" : "续跑评审未通过(需修正后重验):") + steps.map(\.roleTitle).joined(separator: "→"))
        if let i = chatMessages.firstIndex(where: { $0.id == bubble.id }) {
            chatMessages[i].isLoading = false
            chatMessages[i].text = (passed ? "✅ 续跑完成,评审通过、已交付。\n" : "⚠️ 续跑后评审仍未通过,需再修。\n") + String(result.suffix(400))
        }
    }

    /// 提取上一轮承接上下文:最后的 maker 交付 + 评审官意见(给续跑的角色当 `prior`,别丢上下文)。
    func rolePipelinePriorContext(_ record: LingShuTaskExecutionRecord) -> String {
        let delivery = record.messages.last { $0.role.contains("交付") || $0.role.contains("产出") }?.text ?? ""
        let review = record.messages.last { $0.role.contains("评审") || $0.role.contains("验收") || $0.role.contains("修正") }?.text ?? ""
        var ctx = ""
        if !delivery.isEmpty { ctx += "【上次「开发方」的交付(承接它继续,别推翻重来)】\n\(delivery.prefix(1800))\n\n" }
        if !review.isEmpty { ctx += "【上次「评审官」的意见(还没修完的,接着修这些)】\n\(review.prefix(1800))" }
        return ctx
    }

    /// **启动续跑**:启动清理把所有「执行中」僵尸压成 .suspended 前,已先挑出其中的**角色管线**孤儿(app 重启留下的),
    /// 这里延迟一会儿(等启动稳定)逐条复用产物续跑。
    func resumeOrphanedRolePipelinesOnLaunch(_ orphans: [LingShuTaskExecutionRecord]) {
        guard !orphans.isEmpty else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // 等启动稳定(别和正常加载/网络探测抢)
            guard let self else { return }
            self.appendTrace(kind: .route, actor: "续跑", title: "启动续跑", detail: "发现 \(orphans.count) 条中断的角色管线,复用产物自动续跑。")
            for o in orphans { await self.resumeOrphanedRolePipeline(o) }   // 串行(角色管线本就一条一条跑)
        }
    }
}
