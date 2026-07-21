import Foundation

@MainActor
extension LingShuState {
    /// 阻断缺口里需用户提供的项,拼成清单(供降级补尾/编排器收尾文案)。
    func capabilityUserAsk(taskRecordID: String?) -> String {
        let gap = gapAnalysis(for: taskRecordID)
        if let oauth = gap?.OAuth?.normalized {
            let detail = [oauth.question, oauth.reason]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !detail.isEmpty {
                return LingShuAgentFailureDiagnosis.sanitizedEvidence(detail, maxLength: 600)
            }
        }
        return (gap?.blockingGaps.filter { Self.isActionableUserGap($0) } ?? [])
            .map { Self.humanizeGapAsk($0) }
            .map { LingShuAgentFailureDiagnosis.sanitizedEvidence($0, maxLength: 240) }
            .joined(separator: ";")
    }

    /// 判断一个「需要用户」缺口是否真是可执行边界。
    nonisolated static func isActionableUserGap(_ gap: LingShuCapabilityGap) -> Bool {
        guard gap.requiresUser else { return false }
        let target = humanGapTarget(gap.missing)
        let evidence = "\(gap.missing) \(gap.fillPath)"
        if LingShuHumanBoundarySemantics.isBareHumanActorTarget(target),
           !LingShuHumanBoundarySemantics.containsConcreteProtectedBoundary(evidence) {
            return false
        }
        return true
    }

    /// 把缺口翻成用户可理解的前提说明。
    nonisolated static func humanizeGapAsk(_ gap: LingShuCapabilityGap) -> String {
        let target = humanGapTarget(gap.missing)
        switch gap.kind {
        case .permission:
            return target.isEmpty ? "对相关账号/服务的授权(登录或给我凭据)" : "对「\(target)」的授权(登录或给我对应凭据)"
        case .funding:
            return target.isEmpty ? "付费/扣款的确认" : "「\(target)」的付费确认"
        case .device:
            return target.isEmpty ? "相关设备/外设的确认与权限" : "「\(target)」的确认与权限"
        case .humanConfirmation:
            return target.isEmpty ? "你的确认或我需要的关键信息" : "你对「\(target)」的确认或必要信息"
        default:
            return target.isEmpty ? gap.missing : "「\(target)」"
        }
    }

    /// 取缺口的人读对象:剥掉内部动词前缀。
    nonisolated static func humanGapTarget(_ missing: String) -> String {
        guard let colon = missing.firstIndex(of: ":") else { return missing.trimmingCharacters(in: .whitespaces) }
        let prefix = String(missing[..<colon])
        if prefix.contains(".") || prefix.range(of: "^[a-z_]+$", options: .regularExpression) != nil {
            return String(missing[missing.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return missing.trimmingCharacters(in: .whitespaces)
    }

    /// 据记录已绑的 taskOutcome 给收尾文案补诚实尾巴。
    func outcomeAwareSummary(recordID: String?, base: String) -> String {
        let visibleBase = LingShuVisibleModelText.clean(base)
        guard let recordID, let outcome = taskExecutionRecords.first(where: { $0.id == recordID })?.taskOutcome else { return visibleBase }
        let ask = capabilityUserAsk(taskRecordID: recordID)
        switch outcome {
        case .waitingForUser:
            return visibleBase + "\n\n⏸ 最后一步我没法独自完成,需要你:\(ask.isEmpty ? "提供必要的授权/凭据" : ask)。给到我就接着完成。"
        case .partial:
            return visibleBase + (ask.isEmpty ? "" : "\n\n⚠️ 还差需要你:\(ask)。")
        default:
            return visibleBase
        }
    }

    /// 降级时给用户一段干净的诚实话。
    func honestDeliveryText(decision: LingShuCompletionDecision, original: String, taskRecordID: String?) -> String {
        guard decision.status != .ok else { return original }
        let ask = capabilityUserAsk(taskRecordID: taskRecordID)
        let objective = goalSpec(for: taskRecordID)?.objective ?? ""
        let goalRef = objective.isEmpty ? "这件事" : "「\(objective)」"
        let dump = Self.looksLikeInternalDump(original)
        let visibleOriginal = LingShuStructuredModelOutput.visibleText(from: original)
        let clean = dump ? "" : visibleOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
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

    nonisolated static func looksLikeInternalDump(_ text: String) -> Bool {
        if isPlaceholderDelivery(text) { return true }
        if text.contains("（无输出") || text.contains("(无输出") { return true }
        if text.contains("反复尝试") { return true }
        if text.contains("步") && (text.contains("只在读取") || text.contains("没能动手") || text.contains("判断不清")) { return true }
        return false
    }

    nonisolated static func finishStatus(for outcome: LingShuCompletionStatus?, fallback: LingShuTaskExecutionStatus) -> LingShuTaskExecutionStatus {
        switch outcome {
        case .partial: return .partial
        case .waitingForUser: return .waitingForUser
        case .blocked, .needsAcquisition: return .blocked
        case .ok, .none: return fallback
        }
    }

    /// Agent Loop 的运行结果是主线程终态的硬下限：产物存在不代表验收通过。
    /// Completion Gate 可以把完成结果进一步降级，但不能把 maxTurnsReached 反向提升为已完成。
    nonisolated static func runResultFallbackStatus(
        for result: LingShuAgentRunResult,
        record: LingShuTaskExecutionRecord?
    ) -> LingShuTaskExecutionStatus {
        switch result {
        case .completed:
            return defaultSuccessStatus(for: record)
        case .blocked:
            return .waitingForUser
        case .maxTurnsReached:
            return .needsRevision
        case .interrupted:
            return .suspended
        }
    }

    /// 成功终态的默认语义：纯问答才是「已直接回答」；只要记录已经出现任务型结构证据,
    /// 成功收尾就应归入「已完成」。这里不看用户文本关键词,只看 GoalSpec、产物、验收和工具事实。
    nonisolated static func defaultSuccessStatus(for record: LingShuTaskExecutionRecord?) -> LingShuTaskExecutionStatus {
        guard let record else { return .answered }
        if record.goalSpec?.isReplyOnlyOutput == true { return .answered }
        if record.goalSpec?.kind == .task { return .completed }
        if !record.artifacts.isEmpty { return .completed }
        if !(record.acceptanceChecks?.isEmpty ?? true) { return .completed }
        if let report = record.acceptanceReport, !report.isEmpty { return .completed }
        if record.messages.contains(where: hasSuccessfulStructuredActionEvidence) { return .completed }
        return .answered
    }

    private nonisolated static func hasSuccessfulStructuredActionEvidence(_ message: LingShuTaskExecutionMessage) -> Bool {
        guard let detail = message.detail else { return false }
        switch detail {
        case .toolResult(_, let success, _):
            return success
        case .fileEdit:
            return true
        case .toolCall:
            return false
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

    func capabilityResumePreamble(recordID: String?) -> String {
        let asked = capabilityUserAsk(taskRecordID: recordID)
        let bridge = asked.isEmpty
            ? "【续接·重要】你刚才因缺少某项能力卡住、向用户要了它。**用户这条回复很可能就是你要的那个东西**——把它当作你要的凭据/信息直接用上,别再当陌生输入、别再问同一件事。"
            : "【续接·重要】你刚才卡在缺:\(asked)。**用户这条回复很可能就是它**(比如他粘贴的就是你要的 token/ID/凭据)——把它当作你要的那个东西**直接用上完成任务**,别再当陌生输入、别再重复追问同一件事。需要的话用 remember_credential 把凭据存起来下次复用。"
        return bridge + "\n" + Self.capabilityResumeGuidance
    }

    static let capabilityResumeGuidance = """
    【续接指引】你刚才因缺少某项能力卡住、请用户补充。现在用户回应了,据此推进——**用你这条任务会话真正有的手段**,别只 grep/读文件然后说做不了,也别一条命令反复试:
    - 他**给了所需的凭据/授权/信息** → 直接用上,把任务做完。
    - 他让你**「自己想办法」、或指出本机已装了可用的应用** → 真去试**可行**路径:① 要操作**本机桌面应用**(如已装的 Notion 客户端)→ **调 `enter_managed_mode`** 申请接管屏幕(写清要做什么),经主人同意后由托管接手用界面把事做完——你**不能**直接 screen_capture/click(那是托管会话的能力);② 或用**内置浏览器**打开该服务网页端登录操作;③ 或用 `author_component` 自写一个接其本地接口/命令行的小工具。试完做最小验证确认真生效。
    - 上述路径**真的都走不通**(必须的凭据/授权他也给不了、又不肯让你接管屏幕)→ 用 ask_user 一句话说清"我能用X方式做,但需要你Y",**别假装完成、别空转重试一堆命令**。
    """

    static let capabilityAcquisitionGuidance = """
    你刚才遇到一个**可以自己补齐**的能力缺口,但还没真去补就想收尾——这不行。现在**真去获取这条能力,再完成任务**:
    - 先 list_capabilities / 看已连 MCP 有没有现成的;没有就:用 discover_skill 联网找现成技能装上,或用 author_component 据公开 API 文档自写一个工具(沙箱+安全门后即可用),或用内置浏览器登录网页端直接操作。
    - 补到能力后**真调用它做一次**(最小验证:确实连得通/能执行/结果可回读),确认可用再完成任务。
    - 如果这条能力**确实依赖你拿不到的东西**(账号凭据/OAuth/付费/物理设备),就用 ask_user 明确告诉用户「需要你提供什么、我拿到后怎么做完」,**不要假装完成,也不要无谓重试**。
    """
}
