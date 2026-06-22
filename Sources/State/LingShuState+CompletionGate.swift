import Foundation

/// 通用中枢 P2 真闭环·**防伪完成闸接线**(见方案 + [[LingShuTaskCompletionGate]])。
/// 收尾前的确定性裁决,跑在 `verifyAndContinue` 末尾(主会话/派发/自主共用):
/// 综合「能力缺口(是否未解除阻断/需用户/可自补)+ 能力获取结果 + 回复是否承认无能力 + P3 成功标准达成」
/// 判最终状态。可自补但没试 → **驱动模型真去获取**(有界返工);需用户 → waitingForUser;部分达成 → partial;
/// 仍卡 → blocked。模型口头「完成」推不翻。写 `record.taskOutcome`,`finalizeMainTurn`/编排器据此定 finishTaskRecord 状态。
@MainActor
extension LingShuState {

    /// 收尾闸主流程:先看是否要驱动能力获取(有界),再据完成闸定最终结果文本(降级时如实补尾)。
    func runCompletionGate(session: any LingShuAgentSessioning, result initial: LingShuAgentRunResult,
                           userRequest: String, taskRecordID: String?) async -> LingShuAgentRunResult {
        guard goalSpecEnabled, taskRecordID != nil else { return initial }
        // 模型主动 ask_user/ask_form 提问 = 显式在**等用户**,本身就是诚实的「待用户」:
        // 完成闸不该再给这条问题扣「没能完成/诚实交还」、也不该驱动获取去覆盖它(修"在问你问题、却显示没能完成")。
        // 问题原文(.blocked 的 question)干净交还,状态记 waitingForUser。
        if case .blocked = initial {
            bindTaskOutcome(.init(status: .waitingForUser, reason: "已主动向用户提问,等待回答(非失败)。"), to: taskRecordID)
            return initial
        }
        var result = initial
        var acquireRounds = 0
        // 安全天花板:驱动获取最多 N 轮(每轮 resume 全新预算)。默认 2;P6+ 数值参数槽可一键调(夹在 1–5)/一键回退。
        let acquireCeiling = acquisitionCeilingOverride() ?? 2
        while true {
            if Task.isCancelled || batchInterruptRequested {
                let d = await computeCompletionDecision(taskRecordID: taskRecordID, reply: Self.runResultText(result))
                bindTaskOutcome(d, to: taskRecordID)
                return result
            }
            var decision = await computeCompletionDecision(taskRecordID: taskRecordID, reply: Self.runResultText(result))
            // 可自补的阻断缺口但还没尝试 → 真驱动模型去获取能力再完成(而不是直接交还/伪完成)。
            if decision.status == .needsAcquisition, acquireRounds < acquireCeiling, case .completed = result {
                acquireRounds += 1
                appendTrace(kind: .warning, actor: "能力获取", title: "驱动补齐(第\(acquireRounds)次)", detail: decision.reason)
                appendTaskRecordMessage(taskRecordID, actor: "能力获取", role: "补齐",
                                        kind: .agent, text: "检测到可自补的能力缺口但还没尝试——先去真获取能力(连MCP/找技能/自写组件/浏览器)再完成。")
                result = await session.resume(Self.capabilityAcquisitionGuidance)
                if case .interrupted = result { return result }   // 断网:上抛挂起,别空转
                continue
            }
            // 驱动到顶仍「该去补但没补」→ 诚实降级 blocked(尝试驱动获取但未落实),不当完成。
            if decision.status == .needsAcquisition { decision = .init(status: .blocked, reason: "已提示去补齐能力但仍未落实,任务未完成,诚实交还。") }
            recordAcquisitionOutcome(taskRecordID: taskRecordID)   // 记录补齐过程 + 验证通过的写图谱可复用
            bindTaskOutcome(decision, to: taskRecordID)
            // 降级时**始终**给用户一段干净话(无论本回合是 .completed 还是撞顶/停滞 .maxTurnsReached)——
            // 杜绝把「连续N步只读取…(无输出」这类内部 QA 文本当交付丢给用户(用户反馈"返回值很怪"的根因)。
            if decision.status != .ok {
                let cleaned = honestDeliveryText(decision: decision, original: Self.runResultText(result), taskRecordID: taskRecordID)
                return .completed(text: cleaned)
            }
            return result
        }
    }

    /// 据 gap / 获取信号 / 承认无能力 / P3 成功标准 计算完成闸裁决(不持久化)。
    func computeCompletionDecision(taskRecordID: String?, reply: String) async -> LingShuCompletionDecision {
        guard goalSpecEnabled, let recordID = taskRecordID,
              let record = taskExecutionRecords.first(where: { $0.id == recordID }) else {
            return .init(status: .ok, reason: "")
        }
        let gap = record.gapAnalysis
        let admits = LingShuTaskCompletionGate.replyAdmitsIncapacity(reply)
        let hasBlocking = gap?.hasBlockingGap ?? false
        let hasCriteria = !(record.goalSpec?.successCriteria.isEmpty ?? true)
        // 快速放行:无阻断缺口、未承认无能力、无成功标准 → 不跑验收,直接 ok(纯对话/常规交付)。
        if !hasBlocking && !admits && !hasCriteria { return .init(status: .ok, reason: "") }

        var someMet = false
        var someUnmet = false
        if hasCriteria {
            let report: LingShuAcceptanceReport
            if let bound = record.acceptanceReport { report = bound }
            else { report = await acceptanceReportForGate(recordID: recordID, reply: reply) }
            someMet = !report.deterministicallyMet.isEmpty
            someUnmet = report.hasDeterministicFailure
        }
        let signals = acquisitionSignals(record: record, requiresUser: gap?.blockingNeedsUser ?? false)
        let inputs = LingShuCompletionInputs(
            hasUnresolvedBlockingGap: hasBlocking,
            unresolvedGapNeedsUser: gap?.blockingNeedsUser ?? false,
            unresolvedGapSelfAcquirable: gap?.blockingSelfAcquirable ?? false,
            acquisition: LingShuCapabilityAcquisition.classify(signals),
            replyAdmitsIncapacity: admits,
            someSuccessCriteriaMet: someMet,
            someSuccessCriteriaUnmet: someUnmet
        )
        return LingShuTaskCompletionGate.decide(inputs)
    }

    /// 据执行记录里的工具事件抽取能力获取信号(纯扫描):是否试过自补、是否成功、补后是否被真实动作工具调通(最小验证)。
    func acquisitionSignals(record: LingShuTaskExecutionRecord, requiresUser: Bool) -> LingShuAcquisitionSignals {
        var attempted = false
        var succeeded = false
        var verified = false
        var sawAcquireSuccess = false
        for m in record.messages {
            switch m.detail {
            case let .toolCall(tool, _, _):
                if Self.isAcquisitionTool(tool) { attempted = true }
            case let .toolResult(tool, ok, _):
                if Self.isAcquisitionTool(tool) {
                    if ok { succeeded = true; sawAcquireSuccess = true }
                } else if ok, sawAcquireSuccess, LingShuOutcomeVerification.isActionTool(tool) {
                    verified = true   // 获取成功后,新能力被一个真实动作工具调通 = 最小验证通过
                }
            default:
                break
            }
        }
        return .init(requiresUser: requiresUser, attemptedSelfAcquire: attempted,
                     acquireSucceeded: succeeded, newCapabilityVerified: verified)
    }

    /// 记录能力获取过程到任务记录(typed acquisitionAttempts,供记忆复用 + 审计)+ 验证通过的写入图谱可复用。
    /// 据 gap 的可自补阻断缺口 × 获取信号:notAttempted 不记;否则给每条自补缺口记一次尝试,acquiredVerified 的写图谱。
    func recordAcquisitionOutcome(taskRecordID: String?) {
        guard let recordID = taskRecordID,
              let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let record = taskExecutionRecords[idx]
        guard let gap = record.gapAnalysis else { return }
        let selfGaps = gap.blockingGaps.filter { $0.selfAcquirable }
        guard !selfGaps.isEmpty else { return }
        let signals = acquisitionSignals(record: record, requiresUser: gap.blockingNeedsUser)
        let outcome = LingShuCapabilityAcquisition.classify(signals)
        guard outcome != .notAttempted else { return }
        let paths = acquisitionPathsUsed(record: record)
        let pathLabel = paths.isEmpty ? "self_acquire" : paths.joined(separator: "+")
        var attempts = record.acquisitionAttempts ?? []
        for g in selfGaps {
            // 幂等:同能力 + 同结果不重复记。
            if attempts.contains(where: { $0.capability == g.missing && $0.outcome == outcome }) { continue }
            attempts.append(.init(capability: g.missing, path: pathLabel, outcome: outcome,
                                  evidence: outcome == .acquiredVerified ? "补齐后新能力被真实动作工具调通(最小验证)" : "尝试补齐"))
            if outcome == .acquiredVerified {
                upsertAcquiredCapability(id: "authored:\(g.missing.prefix(40))", verb: nil,
                                         description: g.missing, source: "authored", minVerified: true)
            }
        }
        taskExecutionRecords[idx].acquisitionAttempts = attempts
        persistTaskExecutionRecords()
    }

    /// 续接优先恢复目标(spec 第14条):最近更新的**可续未竟**记录(blocked/partial/waitingForUser/suspended/补齐中)。
    /// 纯函数,可单测;供「继续」类输入优先恢复历史任务而非新建无关任务。
    nonisolated static func pickResumeTarget(from records: [LingShuTaskExecutionRecord]) -> String? {
        records.filter { $0.status.isResumableUnfinished }
               .max(by: { $0.updatedAt < $1.updatedAt })?.id
    }

    /// 用户回应能力缺口后:把**需用户提供**的阻断缺口标记为已解除(用户已给凭据/已指路),
    /// 让完成闸不再据它再问,转而据本回合**真实结果**判定(成功→ok、仍不行→honest blocked),根治"给了 token 仍循环再问"。
    func resolveUserProvidedGaps(recordID: String?) {
        guard let recordID, let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }),
              var gap = taskExecutionRecords[idx].gapAnalysis else { return }
        var changed = false
        for i in gap.gaps.indices where gap.gaps[i].blocking && gap.gaps[i].requiresUser && !gap.gaps[i].resolved {
            gap.gaps[i].resolved = true
            changed = true
        }
        guard changed else { return }
        taskExecutionRecords[idx].gapAnalysis = gap
        taskExecutionRecords[idx].taskOutcome = nil   // 清旧裁决,据续接后的真实结果重判
        persistTaskExecutionRecords()
        appendTrace(kind: .system, actor: "能力评估", title: "缺口已解除(用户已回应)",
                    detail: "用户已回应所需前提→据本回合真实结果判完成与否,不再重复追问同一件事。")
    }

    /// 本任务记录里成功用过的获取型工具名(供记忆"试了哪些补齐路径")。
    func acquisitionPathsUsed(record: LingShuTaskExecutionRecord) -> [String] {
        var paths: [String] = []
        for m in record.messages {
            if case let .toolResult(tool, ok, _) = m.detail, ok, Self.isAcquisitionTool(tool), !paths.contains(tool) {
                paths.append(tool)
            }
        }
        return paths
    }

    /// 获取型工具(自补能力的手段)。browser*/navigate 也算(登录网页端操作是合法获取路径)。
    nonisolated static func isAcquisitionTool(_ name: String) -> Bool {
        let set: Set<String> = ["author_component", "discover_skill", "acquire_resource", "discover_devices", "apply_skill"]
        return set.contains(name) || name.hasPrefix("browser") || name == "navigate" || name == "connect_mcp"
    }

    /// 按需算一次 P3 验收报告供完成闸用(无已绑报告时;realFiles = 记录产出物 ∪ 回复提到且盘上存在的文件)。
    private func acceptanceReportForGate(recordID: String, reply: String) async -> LingShuAcceptanceReport {
        var realPaths = Set((taskExecutionRecords.first { $0.id == recordID }?.artifacts ?? []).map(\.location))
        for p in Self.extractFilePaths(from: reply) { realPaths.insert(p) }
        let realFiles = realPaths.filter { FileManager.default.fileExists(atPath: $0) }.sorted()
        return await acceptanceReport(taskRecordID: recordID, realFiles: realFiles)
    }

    /// 把完成闸裁决写进记录(typed)+ 落痕(非 ok 走 warning)。
    func bindTaskOutcome(_ decision: LingShuCompletionDecision, to recordID: String?) {
        guard let recordID, let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        guard taskExecutionRecords[idx].taskOutcome != decision.status else { return }
        taskExecutionRecords[idx].taskOutcome = decision.status
        persistTaskExecutionRecords()
        if decision.status != .ok {
            appendTrace(kind: .warning, actor: "完成闸", title: Self.completionStatusLabel(decision.status), detail: decision.reason)
        }
    }

    /// 阻断缺口里需用户提供的项,拼成「需要你:…」清单(供降级补尾/编排器收尾文案)。
    func capabilityUserAsk(taskRecordID: String?) -> String {
        let gap = gapAnalysis(for: taskRecordID)
        return (gap?.blockingGaps.filter { $0.requiresUser } ?? [])
            .map { "「\($0.missing)」(\($0.fillPath))" }.joined(separator: "、")
    }

    /// 据记录已绑的 taskOutcome 给收尾文案补诚实尾巴(编排器 .failed/.blocked 收尾时用):
    /// waitingForUser→说需要你什么;partial→部分完成;其余原样。
    func outcomeAwareSummary(recordID: String?, base: String) -> String {
        guard let recordID, let outcome = taskExecutionRecords.first(where: { $0.id == recordID })?.taskOutcome else { return base }
        let ask = capabilityUserAsk(taskRecordID: recordID)
        switch outcome {
        case .waitingForUser:
            return base + "\n\n⏸ 最后一步我没法独自完成,需要你:\(ask.isEmpty ? "提供必要的授权/凭据" : ask)。给到我就接着完成。"
        case .partial:
            return base + (ask.isEmpty ? "" : "\n\n⚠️ 还差需要你:\(ask)。")
        default:
            return base
        }
    }

    /// 降级时给用户一段**干净**的诚实话:waitingForUser 直接说要什么(不掺内部停滞文本)、partial 说部分、blocked 说卡哪。
    /// 原文若是内部 QA/停滞占位(「连续N步只读取」「(无输出」等)→ 不展示原文、换成干净话;原文是真内容才保留 + 补尾。
    func honestDeliveryText(decision: LingShuCompletionDecision, original: String, taskRecordID: String?) -> String {
        guard decision.status != .ok else { return original }
        let ask = capabilityUserAsk(taskRecordID: taskRecordID)
        let objective = goalSpec(for: taskRecordID)?.objective ?? ""
        let goalRef = objective.isEmpty ? "这件事" : "「\(objective)」"
        let dump = Self.looksLikeInternalDump(original)
        let clean = dump ? "" : original.trimmingCharacters(in: .whitespacesAndNewlines)
        switch decision.status {
        case .waitingForUser:
            let need = ask.isEmpty ? "完成它所需的授权/凭据" : ask
            return "⏸ 这一步我得先拿到你这边的东西才能继续——需要你给我:\(need)。给到我就接着把\(goalRef)做完。"
        case .partial:
            let head = clean.isEmpty ? "有一部分已经做好了。" : clean
            return head + "\n\n⚠️ \(decision.reason)" + (ask.isEmpty ? "" : " 还需要你:\(ask)。")
        case .blocked:
            if clean.isEmpty { return "⚠️ 我卡在\(goalRef)上没能自己解决:\(decision.reason)" }
            return clean + "\n\n⚠️ 没能完成:\(decision.reason)"
        case .needsAcquisition, .ok:
            return original
        }
    }

    /// 文本是否内部 QA/停滞占位(不该作为交付丢给用户):占位收尾、「(无输出」、「连续N步只读取…判断不清」、「反复尝试」。
    nonisolated static func looksLikeInternalDump(_ text: String) -> Bool {
        if isPlaceholderDelivery(text) { return true }
        if text.contains("（无输出") || text.contains("(无输出") { return true }
        if text.contains("反复尝试") { return true }
        if text.contains("步") && (text.contains("只在读取") || text.contains("没能动手") || text.contains("判断不清")) { return true }
        return false
    }

    /// 完成闸状态 → finishTaskRecord 状态映射(ok/nil 用 fallback:主会话=answered、派发=completed)。
    nonisolated static func finishStatus(for outcome: LingShuCompletionStatus?, fallback: LingShuTaskExecutionStatus) -> LingShuTaskExecutionStatus {
        switch outcome {
        case .partial: return .partial
        case .waitingForUser: return .waitingForUser
        case .blocked, .needsAcquisition: return .blocked
        case .ok, .none: return fallback
        }
    }

    nonisolated static func completionStatusLabel(_ s: LingShuCompletionStatus) -> String {
        switch s {
        case .ok: return "通过"
        case .needsAcquisition: return "需先补齐能力"
        case .waitingForUser: return "待用户(防伪完成)"
        case .partial: return "部分完成(防伪完成)"
        case .blocked: return "未完成·诚实交还(防伪完成)"
        }
    }

    /// 续接「能力缺口」时的**动态**引导:显式把用户这条回复和"你之前要的东西"挂上钩(修「给了 token 没识别出是 token、没和上文联系」),
    /// 再接通用续接指引。带上之前向用户要的具体项,让模型把用户回复当作那个东西直接用上。
    func capabilityResumePreamble(recordID: String?) -> String {
        let asked = capabilityUserAsk(taskRecordID: recordID)
        let bridge = asked.isEmpty
            ? "【续接·重要】你刚才因缺少某项能力卡住、向用户要了它。**用户这条回复很可能就是你要的那个东西**——把它当作你要的凭据/信息直接用上,别再当陌生输入、别再问同一件事。"
            : "【续接·重要】你刚才卡在缺:\(asked)。**用户这条回复很可能就是它**(比如他粘贴的就是你要的 token/ID/凭据)——把它当作你要的那个东西**直接用上完成任务**,别再当陌生输入、别再重复追问同一件事。需要的话用 remember_credential 把凭据存起来下次复用。"
        return bridge + "\n" + Self.capabilityResumeGuidance
    }

    /// 用户回应「能力缺口」卡住时的续接引导:真去试**本会话可用**的替代路径,别只 grep/读文件就说做不了,也别空转。
    static let capabilityResumeGuidance = """
    【续接指引】你刚才因缺少某项能力卡住、请用户补充。现在用户回应了,据此推进——**用你这条任务会话真正有的手段**,别只 grep/读文件然后说做不了,也别一条命令反复试:
    - 他**给了所需的凭据/授权/信息** → 直接用上,把任务做完。
    - 他让你**「自己想办法」、或指出本机已装了可用的应用** → 真去试**可行**路径:① 要操作**本机桌面应用**(如已装的 Notion 客户端)→ **调 `enter_managed_mode`** 申请接管屏幕(写清要做什么),经主人同意后由托管接手用界面把事做完——你**不能**直接 screen_capture/click(那是托管会话的能力);② 或用**内置浏览器**打开该服务网页端登录操作;③ 或用 `author_component` 自写一个接其本地接口/命令行的小工具。试完做最小验证确认真生效。
    - 上述路径**真的都走不通**(必须的凭据/授权他也给不了、又不肯让你接管屏幕)→ 用 ask_user 一句话说清"我能用X方式做,但需要你Y",**别假装完成、别空转重试一堆命令**。
    """

    /// 驱动能力获取的引导(自补未试时 resume 用):真去获取 + 最小验证 + 真不行才 ask_user,不许伪完成。
    static let capabilityAcquisitionGuidance = """
    你刚才遇到一个**可以自己补齐**的能力缺口,但还没真去补就想收尾——这不行。现在**真去获取这条能力,再完成任务**:
    - 先 list_capabilities / 看已连 MCP 有没有现成的;没有就:用 discover_skill 联网找现成技能装上,或用 author_component 据公开 API 文档自写一个工具(沙箱+安全门后即可用),或用内置浏览器登录网页端直接操作。
    - 补到能力后**真调用它做一次**(最小验证:确实连得通/能执行/结果可回读),确认可用再完成任务。
    - 如果这条能力**确实依赖你拿不到的东西**(账号凭据/OAuth/付费/物理设备),就用 ask_user 明确告诉用户「需要你提供什么、我拿到后怎么做完」,**不要假装完成,也不要无谓重试**。
    """
}
