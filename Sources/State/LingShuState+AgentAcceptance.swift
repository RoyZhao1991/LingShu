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
    /// `trustReplyClaim`:是否允许"回复文本声称产出文件"(`replyClaimsArtifact`)作为验收触发的兜底。
    /// 一次性/派发/自主执行路径=true(捕获 run_command 产出却没自动登记的真文件);**常驻在岗路径=false**——
    /// 在岗轻量/对话/演示回合(导航/答疑/讲解)重活都派发给隔离 session 各自验收、自己几乎不直接产交付物,
    /// 其回复一提到既有文件就被 `replyClaimsArtifact` 误触发验收 → maker 无新文件可改 → 空转停滞("讲解完处理中卡很久")。
    /// `useCheckerSession`:true 时 checker 用**独立 agent 会话**(`runCheckerSession`,maker≠checker 两条独立 session)
    /// 而非一次性复核调用。派发任务(默认本地脑 maker)由此满足「LOOP 必须有两个独立角色 session」。
    /// `skipReview`:true 时**跳过内部审查员复核**(只做撞顶恢复 + 完成闸)——派发任务的 checker 由外部统一接管
    /// (agent checker 或独立 checker 会话),避免「内部审查员 + 外部 checker」双重验收。
    func verifyAndContinue(session: any LingShuAgentSessioning, result initial: LingShuAgentRunResult, userRequest: String, taskRecordID: String?, artifactBaseline: Int = 0, trustReplyClaim: Bool = true, useCheckerSession: Bool = false, skipReview: Bool = false) async -> LingShuAgentRunResult {
        // **嵌套循环已自带逐阶段验收(maker≠checker)+ 大 LOOP 终验,外层别再重复验收(2026-06-19 修"任务完成后自发起'修正'流水线")**:
        // `.nested` 的会话内部每个任务阶段都过了 `driveNestedStageAcceptance`(=本函数,传内层 classic 会话);其聚合结果再被这里
        // 重复验收 → verifier 对聚合挑刺 → `session.resume(返工)` → 嵌套会话又规划一条全新"修正"流水线(实测主前台空发指令自发做事)。
        // 故对 `LingShuNestedAgentSession` 直接返回;per-stage 验收传的是内层 `LingShuAgentSession`,不命中此分支、照常验收。
        if session is LingShuNestedAgentSession { return initial }
        // 撞顶恢复(执行恢复力核心):一段推进用满 per-run 安全天花板却还没收尾,**不是失败**——
        // 若任务确有在制品(已落产出物 / 动过工具),把它当检查点,补一段全新预算让它接着做完 / 把崩溃修到跑通。
        let result = await recoverFromExhaustionIfNeeded(session: session, result: initial, taskRecordID: taskRecordID)
        // skipReview:checker 由外部统一接管(agent / 独立 checker 会话)→ 这里不再跑内部审查员,避免双重验收。
        let verified = skipReview ? result : await runVerificationLoop(session: session, result: result, userRequest: userRequest, taskRecordID: taskRecordID, artifactBaseline: artifactBaseline, trustReplyClaim: trustReplyClaim, useCheckerSession: useCheckerSession)
        // **收尾兜底(2026-06-21,清分系统实测根因)**:模型最后一步若是个静默 `run_command`(输出写进文件、stdout 为空),
        // 收尾回复会退化成「✓ run_command:（无输出，退出码 0）」——任务真做完了、产出物也在,却把"无输出"丢给用户。
        // 检测到这种占位收尾 + 任务确有产出物 → 用 `composeDeliveryMessage` 据产出物补一段像样的交付说明。
        var settled = verified
        if case .completed(let text) = verified,
           Self.isPlaceholderDelivery(text),
           currentArtifactCount(taskRecordID) > 0 {
            let composed = await composeDeliveryMessage(userRequest: userRequest, makerText: text, taskRecordID: taskRecordID)
            settled = .completed(text: composed)
        }
        // 通用中枢 P2 真闭环·**防伪完成闸**(根因修复):据能力缺口/获取结果/承认无能力/成功标准判最终状态,
        // 可自补未试→驱动获取;需用户→waitingForUser;部分→partial;仍卡→blocked。模型口头「完成」推不翻。
        return await runCompletionGate(session: session, result: settled, userRequest: userRequest, taskRecordID: taskRecordID)
    }

    /// 本回合是否在"给主人看/演示"(互动):**预览正开着** 或 本回合**调过 `open_preview`/`present_fullscreen`**。
    /// 演示是互动、不是文件交付,不跑产出物验收返工(否则做PPT+演示的回合因新落了PPT触发验收→挑刺返工卡住演示+误显「结果验证」)。
    /// **关键:必须含 `open_preview`**(2026-06-19 实测根因)——打开 PPT 走的是 `open_preview`,只认 `present_fullscreen` 会漏掉
    /// "已 open_preview 开了 PPT、还没/来不及进全屏就触发验收"的情况,导致"PPT 打开后卡在结果验证"。
    func turnDidPresent(_ taskRecordID: String?) -> Bool {
        if previewController.isPresented { return true }   // 预览正开着=正在给主人看/演示(互动)
        guard let record = taskExecutionRecords.first(where: { $0.id == taskRecordID }) else { return false }
        return record.messages.contains { msg in
            if case let .toolCall(tool, _, _) = msg.detail {
                return tool == "present_fullscreen" || tool == "open_preview"
            }
            return false
        }
    }

    /// 某记录当前**真实存在**的产出物数(供验收门取基线 / 判增量)。
    func currentArtifactCount(_ taskRecordID: String?) -> Int {
        (taskExecutionRecords.first { $0.id == taskRecordID }?.artifacts ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.location) }.count
    }

    /// 交付物里是否含**真·源码文件**(决定验收门要不要死磕正确性):有 → 代码交付(测试/运行门死磕);
    /// 全是 PPT/文档/数据(.pptx/.docx/.md/.json…)→ 非代码交付,主观设计意见不无限返工(给时间预算)。
    func deliverableHasCodeArtifact(_ taskRecordID: String?) -> Bool {
        let codeExts: Set<String> = ["swift", "py", "js", "ts", "jsx", "tsx", "go", "rs", "java", "kt",
                                     "c", "cpp", "cc", "h", "hpp", "m", "rb", "php", "cs", "sh", "html", "css", "vue"]
        return (taskExecutionRecords.first { $0.id == taskRecordID }?.artifacts ?? [])
            .contains { codeExts.contains(($0.location as NSString).pathExtension.lowercased()) }
    }

    /// 撞顶恢复:对「推进耗尽 per-run 天花板但未收尾」的结果,有界地补预算续跑(每次 resume = 全新 maxTurns)。
    /// 只对**确有在制品**且非「原地打转(反复尝试同一动作)」的撞顶恢复——后者补预算也无用,留给后续诚实交还。
    private func recoverFromExhaustionIfNeeded(session: any LingShuAgentSessioning, result initial: LingShuAgentRunResult, taskRecordID: String?) async -> LingShuAgentRunResult {
        let recoverCeiling = 2   // 安全天花板:每次 resume 已是全新 maxTurns(80–120),2 次即极大总预算
        var result = initial
        var recovered = 0
        while recovered < recoverCeiling, case .maxTurnsReached(let lastText) = result {
            if Task.isCancelled || batchInterruptRequested { break }   // 收到唤醒词/打断 → 停止补预算续跑,整个流程都可打断
            if lastText.contains("反复尝试") { break }            // 原地打转的诚实交还,不补预算
            guard taskHasInProgressWork(taskRecordID) else { break } // 无在制品(纯对话耗尽等)不恢复
            recovered += 1
            recordBrainFallback("撞顶续跑(框架补预算兜底)")   // 大脑评分:触发兜底 −1
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
    private func runVerificationLoop(session: any LingShuAgentSessioning, result initial: LingShuAgentRunResult, userRequest: String, taskRecordID: String?, artifactBaseline: Int = 0, trustReplyClaim: Bool = true, useCheckerSession: Bool = false) async -> LingShuAgentRunResult {
        var result = initial
        // 触发验收门的可靠信号:**本回合真有【新】产出物落盘**(write_file 自动登记)——比抠回复动词稳得多
        // (旧的只认"已生成/已写入"会漏掉"已交付"这类措辞,导致验收形同虚设);
        // 用 artifactBaseline 只看**本回合相对开始时的增量**,避免常驻会话残留旧产出物把"演示/答疑"等纯动作回合误拖进验收。
        // 纯闲聊/自我介绍/演示不【新】写文件→不触发,省 token 且不误触。回复显式声称产出文件也触发。
        let producedRealArtifacts = currentArtifactCount(taskRecordID) > artifactBaseline
        // `replyClaimsArtifact`(看回复文本"已保存…路径")是兜底:捕获 run_command 产出却没自动登记的真文件。
        // 但它**会被"回复里提到既有文件"误触发**。常驻在岗的轻量/对话/演示回合(导航/答疑/讲解)重活都派发给隔离
        // session 各自验收、自己几乎不直接产交付物——其回复一提到文件就误进验收 → maker 无新文件可改 → 空转停滞
        // ("讲解完处理中卡很久",2026-06-19 实测根因)。故常驻路径 `trustReplyClaim=false`:只在**本回合真落了新登记
        // 产出物**(producedRealArtifacts)时才验收;一次性/派发/自主执行路径保留兜底。
        let claimsArtifact = trustReplyClaim && Self.replyClaimsArtifact(Self.runResultText(result))
        // P3:task 型 GoalSpec 带成功标准时,即便模型没落文件/没声称路径,也必须跑验收。
        // 否则「口头说完成但没产物」会绕过文件/命令确定性硬门。
        let hasGoalAcceptance = shouldRunGoalAcceptance(taskRecordID: taskRecordID)
        // **演示类回合不跑产出物验收(2026-06-19 实测根因"做PPT+演示卡在验收中")**:用过 `present_fullscreen`(占屏放映)
        // 的回合本质是**互动/演示、不是文件交付**。即使顺手做了 PPT(producedRealArtifacts=true)也别验收——否则 verifier
        // 对 PPT 挑刺"需修正"→返工循环,把正在演示的回合卡在「结果验证」、还误导主人(演示≠交付一个待 QA 的文件)。
        // 要单独 QA 这个 PPT,主人会另说"检查一下这个PPT"(那才是纯文件交付的工作型回合)。
        if turnDidPresent(taskRecordID) { return result }
        // 动作型任务也要过专家验收:有**真实动作工具成功执行**(控设备/操作电脑/控外设/浏览器…非读取元工具)
        // 但没产文件的回合(如"开灯""下单到真平台")原来不触发验收 → 真做没做到没人核实。现一并送审。
        // (注:run_command/curl 属元工具不计入——纯命令脚本壳无法确定性核实真实世界效果,需经真连接器/动作工具才计。)
        let didRealAction = taskHadActionToolSuccess(taskRecordID: taskRecordID)
        guard case .completed = result,
              producedRealArtifacts || claimsArtifact || didRealAction || hasGoalAcceptance else { return result }
        setLoopPhase(.verifying)   // 本体/状态栏显示「结果验证」(独立 verifier 核对产出物)
        let verifyCeiling = 8   // 安全天花板,非目标位
        // **非代码交付的返工时间预算(2026-06-17,防"PPT卡几分钟")**:PPT/文档这类没有确定性测试门的交付,
        // verifier 给的是**主观设计意见**(每轮还不一样),不会触发"停滞"判定 → 会一直返工到 8 轮,叠加云端慢时
        // 拖成几分钟、看着像卡死。所以:**非代码交付**一旦已有真产出物,返工总时长超预算就交付现有版本,不再死磕。
        // 代码交付不设此预算——它有确定性测试/运行门,正确性要死磕到底。
        let nonCodeDeliverable = !deliverableHasCodeArtifact(taskRecordID)
        let revisionDeadline = Date().addingTimeInterval(120)
        var round = 0
        var lastArtifactCount = -1
        var lastCritique = ""
        while round < verifyCeiling {
            // **验收全程可被唤醒词/打断中止(用户定调 2026-06-19:整个流程都该能打断)**:收到打断(batchInterruptRequested,
            // 唤醒词 barge 会置)或回合被取消(Task.isCancelled,命令打断会 cancel)→ 立刻停验收、交还当前结果。
            // 否则 `verifyAgentDeliverable` 是模型调用、循环不查打断,会一直转到停滞=**卡在"结果验证"喊唤醒词也打不断**。
            if Task.isCancelled || batchInterruptRequested {
                appendTrace(kind: .warning, actor: "验收", title: "打断中止验收", detail: "收到唤醒词/打断,停止验收返工,交还当前结果。")
                setLoopPhase(.idle)
                return result
            }
            // **checker = 独立会话(useCheckerSession)还是一次性复核调用**:派发任务(默认本地脑 maker)走独立 checker 会话,
            // 让 maker / checker 是两条独立 session、两个独立角色——主会话/自主等其它路径仍用原复核调用(行为不变)。
            let (passed, critique) = useCheckerSession
                ? await runCheckerSession(recordID: taskRecordID ?? "", objective: userRequest, makerText: Self.runResultText(result))
                : await verifyAgentDeliverable(userRequest: userRequest, reply: Self.runResultText(result), taskRecordID: taskRecordID)
            // **验收时模型通道故障 ≠ 验收驳回(根因修:坦克大战验收超时被误判需修正→异常)**:checker 的判词若是模型故障标记
            // (超时/网络/限流/5xx),那是基础设施故障、不是真的"产出需修正"——当 `.interrupted` 暂停、等通道恢复自动续验,
            // 绝不当需修正去返工、更不该把任务判异常(产物其实已落地)。不可恢复(鉴权/额度)才上抛交还。
            if !passed, let failure = LingShuModelServiceFailure.decodeReason(critique), failure.shouldAutoResume {
                appendTaskRecordMessage(taskRecordID, actor: "审查员", role: "验收暂停(模型通道故障)", kind: .warning,
                                        text: "🧑‍⚖️ 验收时\(failure.userFacingMessage)（不是产出需修正,产物已落地;通道恢复后自动重验)。")
                appendTrace(kind: .warning, actor: "验收", title: "验收遇模型通道故障·暂停待续", detail: failure.userFacingMessage)
                return .interrupted(reason: critique)
            }
            // **差距6·可见 checker**:把独立审查官(maker≠checker)从"藏在验收门里"提成**任务时间线里的命名角色卡**——
            // 主人能看到「审查员」这个独立角色每轮的裁决(通过/需修正+理由),而不是只有一句隐形"验收通过"。对标 Codex 的命名 CHECKER。
            appendTaskRecordMessage(taskRecordID, actor: "审查员", role: passed ? "审查·通过" : "审查·需修正(第\(round + 1)轮)",
                                    kind: passed ? .result : .agent,
                                    text: passed ? "🧑‍⚖️ 独立审查:✅ 通过——产出物达标(真实落盘 + 内容/版式/代码门核对无误)。"
                                                 : "🧑‍⚖️ 独立审查:⚠️ 需修正 — \(String(critique.prefix(400)))")
            if passed {
                appendTrace(kind: .result, actor: "审查员", title: "通过", detail: "独立 CHECKER 核对产出物达标。")
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
            // 非代码交付 + 已有真产出物 + 返工超时预算 → 别再为主观设计意见死磕,交付当前版本(用户更要"快出东西")。
            if nonCodeDeliverable, round > 0, artifactCount > artifactBaseline, Date() > revisionDeadline {
                appendTrace(kind: .result, actor: "验收", title: "返工超预算·交付现有版本", detail: "非代码交付(如PPT)已多轮打磨且超时,先交付当前版本,避免无限返工。")
                let delivery = await composeDeliveryMessage(userRequest: userRequest, makerText: Self.runResultText(result), taskRecordID: taskRecordID)
                // **修 1b(2026-06-27)**:超预算交付,但本轮审查员**仍有异议**(passed=false 才会走到这里)→ 别静默"已完成",
                // 如实把未决意见带给用户(否则用户看到"已完成"+时间线里"不通过"自相矛盾、否决被悄悄吞掉)。
                let note = critique.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ""
                    : "\n\n(说明:已多轮打磨并交付当前版本;审查员仍保留意见——\(critique.prefix(160))。要我继续按这条改就说一声。)"
                return .completed(text: delivery + note)
            }
            if round > 0, artifactCount <= lastArtifactCount, critique.prefix(120) == lastCritique.prefix(120) {
                recordBrainFallback("验收停滞交还(脑没救回来)")   // 大脑评分:触发兜底 −1
                appendTrace(kind: .warning, actor: "验收", title: "停滞交还", detail: "连续未通过且无新进展,交还用户。")
                return .maxTurnsReached(lastText: Self.runResultText(result) + "\n\n（验收一直没通过且我已无新进展:\(critique.prefix(160))。先停下交还——需要你的判断或补充信息。）")
            }
            if round == 3 { recordBrainFallback("验收升级到确定性兜底(Rung2)") }   // 大脑评分:升到最重脚手架=触发兜底 −1
            appendTrace(kind: .warning, actor: "验收", title: "未通过(第\(round + 1)轮,继续修)", detail: String(critique.prefix(80)))
            // 升级阶梯并入验收门(方案 §2):验收不过不再"原样重试",而是按返工轮次**逐级加厚脚手架**
            // (Rung0 原样意见 → Rung1 结构化引导 → Rung2 切确定性兜底)。强脑通常 round 0 就过。
            result = await session.resume(LingShuCapabilityEscalation.revisionGuidance(round: round, critique: critique))
            round += 1
            lastArtifactCount = artifactCount
            lastCritique = critique
            // 修复轮里网络中断:别在断网时空转验证,原样上抛 .interrupted 让上层挂起、等重连续跑。
            if case .interrupted = result { return result }
        }
        return result
    }
}
