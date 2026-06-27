import Foundation

enum LingShuPrerequisiteChoiceSemantics: Equatable {
    case provided
    case denyOrStop
    case alternative
    case unknown
}

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
            if let authBlock = userAuthorizationBlockIfNeeded(decision: decision, result: result, taskRecordID: taskRecordID) {
                return authBlock
            }
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
        // **根治"部分完成"反复出现(2026-06-27)**:gap 分析常误报"本地文件系统 requiresAuth"这类 .permission gap;
        // 高权限(完整授权/开发全权)下,系统/账号"授权"类视为**已解决**——否则已核验交付+产物在的任务,会因这条
        // 误报的阻断 gap 永远判 partial(实测红黑树/AVL/队列 PPT 全栽在这)。与弹框层 userPrerequisiteChoicePromptIfNeeded
        // 的 .permission 过滤保持一致(决策层 + UI 层同口径)。
        let fullyAuthorized = developmentPhaseFullAccess || autonomousPermissionLevel == .full
        let actionableBlockingGaps = (gap?.blockingGaps ?? []).filter { gap in
            if fullyAuthorized, gap.kind == .permission { return false }
            return !gap.requiresUser || Self.isActionableUserGap(gap)
        }
        let hasBlocking = !actionableBlockingGaps.isEmpty
        let blockingNeedsUser = actionableBlockingGaps.contains { $0.requiresUser }
        let blockingSelfAcquirable = actionableBlockingGaps.contains { $0.selfAcquirable }
        let hasCriteria = !(record.goalSpec?.successCriteria.isEmpty ?? true)
        let taskLike = Self.recordNeedsCompletionGate(record)
        guard taskLike else { return .init(status: .ok, reason: "") }
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
        let signals = acquisitionSignals(record: record, requiresUser: blockingNeedsUser)
        let inputs = LingShuCompletionInputs(
            hasUnresolvedBlockingGap: hasBlocking,
            unresolvedGapNeedsUser: blockingNeedsUser,
            unresolvedGapSelfAcquirable: blockingSelfAcquirable,
            acquisition: LingShuCapabilityAcquisition.classify(signals),
            replyAdmitsIncapacity: admits,
            someSuccessCriteriaMet: someMet,
            someSuccessCriteriaUnmet: someUnmet
        )
        return LingShuTaskCompletionGate.decide(inputs)
    }

    /// 把 P2/P3 完成闸识别出的「需用户授权/前提」升级为真正的 human-in-the-loop UI 事件。
    ///
    /// 之前这类阻断只会进入 `honestDeliveryText` 变成一段普通回复,用户看到"需要授权"却没有弹框。
    /// 这里不写任何设备/服务特例:只要 typed gap 判定为需用户参与,就统一转成 `ask_choice`
    /// 授权卡。用户点选后由 `selectRouteChoice` 按同一条任务续跑,同时解除静态 gap,再由真实执行结果复判。
    func userAuthorizationBlockIfNeeded(decision: LingShuCompletionDecision,
                                        result: LingShuAgentRunResult,
                                        taskRecordID: String?) -> LingShuAgentRunResult? {
        guard [.waitingForUser, .partial, .blocked].contains(decision.status),
              let prompt = userPrerequisiteChoicePromptIfNeeded(
                resultText: Self.runResultText(result),
                taskRecordID: taskRecordID
              ) else { return nil }
        return .blocked(question: Self.askChoiceEnvelope(prompt).encodedPrompt)
    }

    /// 把"需用户前提/授权/凭据/设备确认"统一转成可点击选择卡。
    ///
    /// 这是 human-in-the-loop 的通用边界,不关心具体外部服务:只要 typed gap 或回复文本指向
    /// 真实受保护对象,就给 UI 一个可恢复的选择入口;否则继续保持普通文本,避免把"用户"这种抽象词误当授权对象。
    func userPrerequisiteChoicePromptIfNeeded(resultText: String, taskRecordID: String?) -> LingShuRouteChoicePrompt? {
        guard let recordID = taskRecordID else { return nil }
        let original = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        // **修1(2026-06-27):任务已产出真实产物 → 别再要授权。** 产物在 = 能力本来就够、活已干成。
        // 实测:红黑树PPT已核验交付,却因 gap 残留"本地文件系统授权"又弹授权框、用户授权后还把整份重做了一遍。
        if (taskExecutionRecords.first { $0.id == recordID }?.artifacts ?? [])
            .contains(where: { FileManager.default.fileExists(atPath: $0.location) }) {
            return nil
        }
        // **修2(2026-06-27·权限级别,参考 codex/claude):权限给得够高(完整授权 / 开发全权)→ 系统/账号"授权"类(.permission)
        // gap 视为已授权,不再每次弹框**(真缺凭据要人给 .humanConfirmation、要花钱 .funding、缺硬件 .device 仍问——
        // 授权级别变不出别人的密钥/钱/硬件)。这就是"给的权限够高就不要每次授权"。
        let fullyAuthorized = developmentPhaseFullAccess || autonomousPermissionLevel == .full
        let actionableGaps = (gapAnalysis(for: recordID)?.blockingGaps ?? []).filter { gap in
            guard Self.isActionableUserGap(gap) else { return false }
            if fullyAuthorized, gap.kind == .permission { return false }
            return true
        }
        let hasTypedUserGap = !actionableGaps.isEmpty
        let hasTextUserGate = Self.replyRequestsUserPrerequisite(original)
        guard hasTypedUserGap || hasTextUserGate else { return nil }
        let askFromGap = capabilityUserAsk(taskRecordID: recordID)
        let ask = askFromGap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.humanizePrerequisiteFromReply(original)
            : askFromGap
        guard !ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let visibleContext: String
        if original.isEmpty || Self.looksLikeInternalDump(original) {
            visibleContext = ""
        } else {
            visibleContext = "当前我能做的部分已经推进到这里:\n\(String(original.prefix(260)))\n\n"
        }
        let question = """
        \(visibleContext)这一步需要你授权或提供前提才能继续:
        \(ask)

        你可以点选下一步;如果要给我 token、账号信息、配对码或具体凭据,也可以直接在输入框发给我,我会接着当前任务继续。
        """
        return LingShuRouteChoicePrompt(
            question: question,
            options: [
                .init(label: "确认授权,继续", detail: "我已按上面要求完成授权 / 给了凭据,灵枢继续执行。"),
                .init(label: "暂不授权", detail: "先停在这里,不要继续访问该资源。"),
                .init(label: "改用替代方案", detail: "不走这项授权,让灵枢试只读 / 手动指引等可逆方案。")
            ]
        ).sanitized
    }

    /// Human-in-the-loop 选项语义:不是所有按钮都代表"前提已满足"。
    /// 否定/暂停类选项应收口并释放执行槽;替代方案类选项允许续跑,但必须最小可逆,不能扩大任务作用域。
    nonisolated static func prerequisiteChoiceSemantics(_ option: LingShuRouteChoiceOption) -> LingShuPrerequisiteChoiceSemantics {
        let text = LingShuMemoryTextToolkit.normalize("\(option.label) \(option.detail ?? "")")
        if ["改用替代方案", "替代方案", "只读", "手动指引", "其它可逆方案", "其他可逆方案"].contains(where: { text.contains($0) }) {
            return .alternative
        }
        if ["暂不授权", "不授权", "不提供", "拒绝", "取消", "停止", "停在这里", "不要继续", "以后再说", "稍后"].contains(where: { text.contains($0) }) {
            return .denyOrStop
        }
        if ["确认授权", "已授权", "继续", "已完成授权", "已经授权", "凭据", "token", "apikey", "api_key", "登录好了"].contains(where: { text.contains($0) }) {
            return .provided
        }
        return .unknown
    }

    /// 自由文本续接时是否可视为"用户已经提供/完成了前提"。否定/替代类不能解除静态 gap,
    /// 否则完成闸会把仍缺授权的目标误判为可完成。
    nonisolated static func userInputProvidesPrerequisite(_ text: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(text)
        guard !normalized.isEmpty else { return false }
        if ["暂不授权", "不授权", "不提供", "拒绝", "取消", "停止", "停在这里", "不要继续", "改用替代方案", "替代方案"].contains(where: { normalized.contains($0) }) {
            return false
        }
        return true
    }

    nonisolated static func userInputDeniesPrerequisite(_ text: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(text)
        guard !normalized.isEmpty else { return false }
        if ["改用替代方案", "替代方案"].contains(where: { normalized.contains($0) }) { return false }
        return ["暂不授权", "不授权", "不提供", "拒绝", "取消", "停止", "停在这里", "不要继续", "以后再说", "稍后"].contains {
            normalized.contains($0)
        }
    }

    nonisolated static func framedAlternativePrerequisiteInput(_ answer: String) -> String {
        """
        用户选择改用替代方案:\(answer)

        【替代方案边界】
        只使用本任务已经获得的材料、已验证的本地能力和可逆只读动作;优先最小作用域完成可替代价值。
        禁止把局部任务扩大成全盘/全项目扫描,禁止为替代方案新造无关交付物,禁止把仍缺授权/凭据/物理前提的原目标包装成已完成。
        如果替代路径仍需要受保护前提,请收口说明缺什么并保持任务待用户,不要继续空转。
        """
    }

    func closeDispatchedTaskForDeniedPrerequisite(recordID: String, answer: String, appendChatUser: Bool = true) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeBubbleID = dispatchedTaskBubbles[recordID]
        if recordID == blockedDispatchedRecordID { blockedDispatchedRecordID = nil }
        dispatchedTaskBubbles[recordID] = nil
        if let idx = chatMessages.firstIndex(where: { $0.awaitingInputForRecordID == recordID }) {
            chatMessages[idx].awaitingInputForRecordID = nil
            chatMessages[idx].isLoading = false
            if chatMessages[idx].resolvedChoice == nil { chatMessages[idx].resolvedChoice = text.isEmpty ? "暂不授权" : text }
        }
        if appendChatUser, !text.isEmpty { chatMessages.append(.init(speaker: "你", text: text, isUser: true, taskRecordID: recordID)) }
        appendTaskRecordMessage(recordID, actor: "你", role: "选项答复", kind: .user, text: text.isEmpty ? "暂不授权" : text)
        let summary = "已按你的选择停在这里:需要授权/凭据/物理前提的部分不再继续执行;已有的本地结果保留。之后你补齐前提或在任务记录里继续,我会接回这条任务。"
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "待用户", kind: .warning, text: summary)
        if let activeBubbleID, let idx = chatMessages.firstIndex(where: { $0.id == activeBubbleID }) {
            chatMessages[idx].text = "⏸ \(summary)"
            chatMessages[idx].isLoading = false
            chatMessages[idx].taskRecordID = recordID
        } else {
            chatMessages.append(.init(speaker: "灵枢", text: "⏸ \(summary)", isUser: false, taskRecordID: recordID))
        }
        finishTaskRecord(recordID, status: .waitingForUser, summary: summary)
        pruneInactiveDispatchedTaskBubbles()
        promoteQueuedDispatchIfPossible()
    }

    nonisolated static func askChoiceEnvelope(_ prompt: LingShuRouteChoicePrompt) -> LingShuHumanInputEnvelope {
        let data = (try? JSONEncoder().encode(prompt)) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return LingShuHumanInputEnvelope(tool: "ask_choice", argumentsJSON: json)
    }

    /// 回复文本里明确说"需要授权/凭据/确认"且指向受保护边界时,视为用户前提阻断。
    /// 这是 gap 之外的第二道兜底:有些能力是内置的,只有实际执行到系统/设备/第三方边界时才发现要授权。
    nonisolated static func replyRequestsUserPrerequisite(_ text: String) -> Bool {
        let clean = LingShuReasoningText.stripThinkTags(text)
        let lower = clean.lowercased()
        let asksUser = [
            "需要你", "需要用户", "请授权", "需要授权", "未授权", "没有权限", "没有授权",
            "登录", "凭据", "token", "api key", "apikey", "oauth", "付费", "付款",
            "系统设置", "隐私与安全", "提供前提"
            // 注:删掉"授权后"——它是**描述性**词(如"授权后我能看屏幕"),会把单纯介绍能力的回答误判成需要授权(自检答案踩过)。
        ].contains { lower.contains($0.lowercased()) }
        guard asksUser else { return false }
        return LingShuHumanBoundarySemantics.containsConcreteProtectedBoundary(clean)
    }

    /// 从回复里取一段用户可理解的前提说明。它只做展示,不参与能力判定。
    nonisolated static func humanizePrerequisiteFromReply(_ text: String) -> String {
        let clean = LingShuReasoningText.stripThinkTags(text)
            .replacingOccurrences(of: "\n\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "完成当前目标所需的授权、凭据或设备确认" }
        if let range = clean.range(of: "需要") {
            return String(clean[range.lowerBound...].prefix(220))
        }
        return String(clean.prefix(220))
    }

    /// 完成闸只管「任务交付」,不管普通问答/互动。
    ///
    /// 防伪完成门的文本兜底会扫描「无法/不具备/需要你提供」等承认语;这些词在知识问答里也很常见
    /// (如"HTTP 无状态,无法直接记住用户状态")。因此只有明确 task 目标、带缺口/验收/产出证据的记录才进入闸。
    nonisolated static func recordNeedsCompletionGate(_ record: LingShuTaskExecutionRecord) -> Bool {
        if record.goalSpec?.kind == .task { return true }
        if record.gapAnalysis != nil { return true }
        if !(record.acceptanceChecks?.isEmpty ?? true) { return true }
        if let report = record.acceptanceReport, !report.isEmpty { return true }
        if !record.artifacts.isEmpty { return true }
        return false
    }

    /// 据执行记录里的工具事件抽取能力获取信号(纯扫描):是否试过自补、是否成功、补后是否被真实动作工具调通(最小验证)。
    ///
    /// **防伪但不死板**(2026-06-23 修「自建脚本补齐被误判失败」):除了 `isAcquisitionTool`(author_component/连MCP/找技能…),
    /// 也认**工程师式自补**——写了一个可执行脚本/工具(fileEdit 脚本文件 或 write_file/edit_file 脚本)再用 `run_command` **真跑成功**,
    /// 即视为"补齐了能力且最小验证通过"(这正是模型这次自写 Notion 客户端脚本并跑通 200 的合法路径)。
    /// **防伪护栏不放松**:必须①真写了脚本 ②run_command 真 success(exit0) ③输出无明显失败标记——
    /// 只嘴说完成 / 脚本没跑 / 跑了报错(Traceback/❌/command not found…)都不算,仍走 block。
    func acquisitionSignals(record: LingShuTaskExecutionRecord, requiresUser: Bool) -> LingShuAcquisitionSignals {
        var attempted = false
        var succeeded = false
        var verified = false
        var sawAcquireSuccess = false
        var authoredScript = false   // 工程师式自补:写了可执行脚本/工具
        for m in record.messages {
            switch m.detail {
            case let .toolCall(tool, summary, arguments):
                if Self.isAcquisitionTool(tool) { attempted = true }
                if (tool == "write_file" || tool == "edit_file"), Self.mentionsScriptArtifact(summary + " " + arguments) {
                    attempted = true; authoredScript = true   // 写脚本=尝试自补(真跑成功才升级为已验证)
                }
            case let .fileEdit(path, _, _, _, _):
                if Self.isScriptArtifact(path) { authoredScript = true; attempted = true }   // 写脚本=尝试自补
            case let .toolResult(tool, ok, output):
                if Self.isAcquisitionTool(tool) {
                    if ok { succeeded = true; sawAcquireSuccess = true }
                } else if ok, sawAcquireSuccess, LingShuOutcomeVerification.isActionTool(tool) {
                    verified = true   // 获取成功后,新能力被一个真实动作工具调通 = 最小验证通过
                }
                // 工程师式自补的最小验证:自写脚本 + run_command 真跑成功(且输出无失败标记)。
                if ok, tool == "run_command", authoredScript, !Self.runOutputLooksFailed(output) {
                    attempted = true; succeeded = true; verified = true
                }
            default:
                break
            }
        }
        return .init(requiresUser: requiresUser, attemptedSelfAcquire: attempted,
                     acquireSucceeded: succeeded, newCapabilityVerified: verified)
    }

    /// 文本是否提到可执行脚本工件(供 write_file/edit_file 参数判"是不是在写脚本/工具")。
    nonisolated static func mentionsScriptArtifact(_ text: String) -> Bool {
        isScriptArtifact(text)
    }

    /// 路径/文本是否指向**可执行脚本**(自建能力的载体)。只认通用脚本扩展,零领域。
    nonisolated static func isScriptArtifact(_ text: String) -> Bool {
        let t = text.lowercased()
        let exts = [".py", ".js", ".mjs", ".ts", ".tsx", ".jsx", ".sh", ".rb", ".go", ".rs", ".php", ".pl", ".swift"]
        return exts.contains { t.contains($0) }
    }

    /// run_command 输出是否含**明显失败标记**(防伪:脚本吞异常仍 exit0 时,据输出兜住)。保守只认强失败信号。
    nonisolated static func runOutputLooksFailed(_ output: String) -> Bool {
        let markers = ["traceback (most recent call last)", "command not found", "no such file or directory",
                       "modulenotfounderror", "❌", "exception:", "fatal error", "permission denied",
                       "connection refused", "401 unauthorized", "403 forbidden", "500 internal"]
        let o = output.lowercased()
        return markers.contains { o.contains($0) }
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
        // 自补且最小验证通过 → 把这些**可自补阻断缺口标 resolved**:记录不再挂"未解除阻断缺口",
        // 完成闸/续接/收尾文案据此一致(不再把真做成的任务展示成"没能完成")。
        if outcome == .acquiredVerified, var analysis = taskExecutionRecords[idx].gapAnalysis {
            var changed = false
            for i in analysis.gaps.indices where analysis.gaps[i].blocking && analysis.gaps[i].selfAcquirable && !analysis.gaps[i].resolved {
                analysis.gaps[i].resolved = true; changed = true
            }
            if changed { taskExecutionRecords[idx].gapAnalysis = analysis }
        }
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

}
