import Foundation

/// 验收 + 执行恢复力子域:agent 收尾后「驱动到验收通过」的统一循环(主会话 / 自主运行 / 隔离子任务共用)。
/// 从 AgentBackbone 拆出(各管一段):这里只管「撞顶恢复 + 多轮验收 + 停滞交还」的编排,
/// 单次「看 + 核」的验证器 `verifyAgentDeliverable` 在 [LingShuState+DeliveryReview.swift](LingShuState+DeliveryReview.swift)。
@MainActor
extension LingShuState {

    /// 验收门(maker≠checker):**目标(验收通过)是唯一成功停止位**。先做撞顶恢复(执行恢复力),再跑验收主循环。
    /// 一直续跑直到通过;只有「maker 一轮没有任何新进展(盘上产出物没增、意见还和上轮实质相同)」=停滞才诚实交还,
    /// 不再用固定轮数封顶。`verifyCeiling`/`recoverCeiling` 只是防失控的高位安全天花板,正常远到不了。
    /// `artifactBaseline`:本回合**开始前**该记录已存在的产出物数——只有本回合**新产出**(count > baseline)
    /// 或回复显式声称产出文件,才触发验收门。常驻在岗会话复用同一条记录、跨回合累积产出物:不给基线的话,
    /// 第一次做完 PPT 后,后续"演示/讲解/答疑"等纯动作/对话回合会因记录里**残留**着那个 PPT 而被误判为
    /// "有产出物"→空转验收→停滞交还(实测:让"演示PPT"卡在验收里根本没去演示)。主会话/隔离子任务用一次性
    /// 记录,基线 0 即原行为。
    func verifyAndContinue(session: LingShuAgentSession, result initial: LingShuAgentRunResult, userRequest: String, taskRecordID: String?, artifactBaseline: Int = 0) async -> LingShuAgentRunResult {
        // 撞顶恢复(执行恢复力核心):一段推进用满 per-run 安全天花板却还没收尾,**不是失败**——
        // 若任务确有在制品(已落产出物 / 动过工具),把它当检查点,补一段全新预算让它接着做完 / 把崩溃修到跑通。
        let result = await recoverFromExhaustionIfNeeded(session: session, result: initial, taskRecordID: taskRecordID)
        return await runVerificationLoop(session: session, result: result, userRequest: userRequest, taskRecordID: taskRecordID, artifactBaseline: artifactBaseline)
    }

    /// 某记录当前**真实存在**的产出物数(供验收门取基线 / 判增量)。
    func currentArtifactCount(_ taskRecordID: String?) -> Int {
        (taskExecutionRecords.first { $0.id == taskRecordID }?.artifacts ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.location) }.count
    }

    /// 撞顶恢复:对「推进耗尽 per-run 天花板但未收尾」的结果,有界地补预算续跑(每次 resume = 全新 maxTurns)。
    /// 只对**确有在制品**且非「原地打转(反复尝试同一动作)」的撞顶恢复——后者补预算也无用,留给后续诚实交还。
    private func recoverFromExhaustionIfNeeded(session: LingShuAgentSession, result initial: LingShuAgentRunResult, taskRecordID: String?) async -> LingShuAgentRunResult {
        let recoverCeiling = 2   // 安全天花板:每次 resume 已是全新 maxTurns(80–120),2 次即极大总预算
        var result = initial
        var recovered = 0
        while recovered < recoverCeiling, case .maxTurnsReached(let lastText) = result {
            if lastText.contains("反复尝试") { break }            // 原地打转的诚实交还,不补预算
            guard taskHasInProgressWork(taskRecordID) else { break } // 无在制品(纯对话耗尽等)不恢复
            recovered += 1
            appendTrace(kind: .warning, actor: "执行恢复", title: "撞顶续跑(第\(recovered)次)", detail: "推进用满一段预算未收尾,补预算继续完成/修复,不当失败。")
            result = await session.resume("你这一段推进用满了预算但还没给出最终结果——这不是失败,继续干。请把没做完的部分做完;如果程序还报错/崩溃,就一路修到它能正常构建、运行、跑通(测试全绿、运行不崩),然后用一句话交付结果 + 产出物绝对路径。")
        }
        return result
    }

    /// 任务是否确有「在制品」:已落真实产出物,或记录里有过工具动作(写文件/跑命令)。用于判断撞顶值不值得补预算恢复。
    private func taskHasInProgressWork(_ taskRecordID: String?) -> Bool {
        guard let record = taskExecutionRecords.first(where: { $0.id == taskRecordID }) else { return false }
        if record.artifacts.contains(where: { FileManager.default.fileExists(atPath: $0.location) }) { return true }
        return record.messages.contains { message in
            switch message.detail {
            case .toolCall, .fileEdit: return true
            default: return false
            }
        }
    }

    /// 验收门主循环(maker≠checker):**目标(验收通过)是唯一成功停止位**,一直续跑直到通过;
    /// 只有「maker 一轮无新进展(产出物没增、意见与上轮实质相同)」=停滞才诚实交还。`verifyCeiling` 只是高位安全天花板。
    private func runVerificationLoop(session: LingShuAgentSession, result initial: LingShuAgentRunResult, userRequest: String, taskRecordID: String?, artifactBaseline: Int = 0) async -> LingShuAgentRunResult {
        var result = initial
        // 触发验收门的可靠信号:**本回合真有【新】产出物落盘**(write_file 自动登记)——比抠回复动词稳得多
        // (旧的只认"已生成/已写入"会漏掉"已交付"这类措辞,导致验收形同虚设);
        // 用 artifactBaseline 只看**本回合相对开始时的增量**,避免常驻会话残留旧产出物把"演示/答疑"等纯动作回合误拖进验收。
        // 纯闲聊/自我介绍/演示不【新】写文件→不触发,省 token 且不误触。回复显式声称产出文件也触发。
        let producedRealArtifacts = currentArtifactCount(taskRecordID) > artifactBaseline
        guard case .completed = result,
              producedRealArtifacts || Self.replyClaimsArtifact(Self.runResultText(result)) else { return result }
        let verifyCeiling = 8   // 安全天花板,非目标位
        var round = 0
        var lastArtifactCount = -1
        var lastCritique = ""
        while round < verifyCeiling {
            let (passed, critique) = await verifyAgentDeliverable(userRequest: userRequest, reply: Self.runResultText(result), taskRecordID: taskRecordID)
            if passed {
                appendTrace(kind: .result, actor: "验收", title: "通过", detail: "独立 verifier 核对产出物达标。")
                // 经过返工(round>0)才通过:maker 最后一轮文本是"逐条修正"的内部 QA 记录,
                // 直接抛给用户就成了"驴唇不对马嘴"。把交付话术与返工文本解耦——另生成一句干净的面向用户交付说明。
                if round > 0 {
                    let delivery = await composeDeliveryMessage(userRequest: userRequest, makerText: Self.runResultText(result), taskRecordID: taskRecordID)
                    return .completed(text: delivery)
                }
                return result
            }
            // 停滞判定:这一轮 maker 没产出新文件,且验收意见与上轮实质相同 → 在原地打转,诚实交还。
            let artifactCount = (taskExecutionRecords.first { $0.id == taskRecordID }?.artifacts ?? [])
                .filter { FileManager.default.fileExists(atPath: $0.location) }.count
            if round > 0, artifactCount <= lastArtifactCount, critique.prefix(120) == lastCritique.prefix(120) {
                appendTrace(kind: .warning, actor: "验收", title: "停滞交还", detail: "连续未通过且无新进展,交还用户。")
                return .maxTurnsReached(lastText: Self.runResultText(result) + "\n\n（验收一直没通过且我已无新进展:\(critique.prefix(160))。先停下交还——需要你的判断或补充信息。）")
            }
            round += 1
            lastArtifactCount = artifactCount
            lastCritique = critique
            appendTrace(kind: .warning, actor: "验收", title: "未通过(第\(round)轮,继续修)", detail: String(critique.prefix(80)))
            result = await session.resume("验收未通过,逐条意见如下:\n\(critique)\n请真正用 write_file/run_command 修正,确保你声称的产出物在硬盘真实存在,再重新交付。")
            // 修复轮里网络中断:别在断网时空转验证,原样上抛 .interrupted 让上层挂起、等重连续跑。
            if case .interrupted = result { return result }
        }
        return result
    }
}
