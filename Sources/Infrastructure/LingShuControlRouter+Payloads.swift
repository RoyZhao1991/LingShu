import Foundation

/// `LingShuControlRouter` 的**只读载荷序列化**(从主文件拆出,2026-06-21):
/// 把内部状态序列化成 MCP/JSON-RPC 响应里的字典(status/ledger/task/chat/trace)。
/// 纯读取无副作用,与主文件的「路由分发 + 工具执行」职责分离,主文件保持在 ≤800 行硬阈值内(`ArchitectureGuardTests` 守)。
extension LingShuControlRouter {

    func ledgerPayload() async -> [[String: Any]] {
        await state.agentOrchestrator.ledger().map { entry in
            [
                "id": entry.id,
                "objective": entry.objective,
                "status": entry.status.rawValue,
                "summary": entry.summary,
                "blockedOn": entry.blockedOn ?? ""
            ]
        }
    }

    /// P6+ 无界自进化:各槽位的变体清单 + 活跃标记 + **运行时实际生效值**(证明切换/回退真热影响行为,非纸面)。
    func moduleVariantsPayload() -> [String: Any] {
        let reg = state.moduleRegistry()
        let slots = LingShuModuleSlots.all.map { slot -> [String: Any] in
            let activeID = reg.activeVariant(slotID: slot)?.id ?? ""
            let variants = reg.variants(slotID: slot).map { v -> [String: Any] in
                ["id": v.id, "label": v.label, "source": v.source,
                 "active": v.id == activeID, "payload": String(v.payload.prefix(160))]
            }
            return ["slotID": slot, "label": LingShuModuleSlots.label(slot), "activeVariantId": activeID, "variants": variants]
        }
        return [
            "slots": slots,
            // 运行时实际消费到的值(切换/回退后这里立刻变 = 热生效证据)。
            "effective": [
                "executionStrategy": String(state.executionStrategyAddendum().prefix(120)),
                "persona": String(state.personaStrategyAddendum().prefix(120)),
                "acquisitionCeiling": state.acquisitionCeilingOverride() ?? 2,
                "guidanceComposer": type(of: state.activeGuidanceComposer()).key,
                "assembledGuidanceSample": String(state.assembledExecutionGuidance(base: nil, taskRecordID: nil).prefix(160))
            ]
        ]
    }

    func statusPayload() -> [String: Any] {
        [
            "coreState": state.coreStateDisplay,
            "loopPhase": state.loopPhase.rawValue,   // 理解中/规划中/执行中/验收中(空=空闲)
            "loopVariant": state.agentLoopVariant.rawValue,   // classic=经典连续 / nested=嵌套分阶段
            "loopInvariantViolations": LingShuLoopInvariantTelemetry.total,   // 循环不变量累计违反数(架网遥测;soak/真机断言恒为0)
            "developmentFullAccess": state.developmentPhaseFullAccess,   // 开发阶段全权(系统授权门直接放行;发布版关=人工授权)
            "goalSpecEnabled": state.goalSpecEnabled,   // P1 目标认知:新顶层目标先结构化理解(默认开;配置入口 lingshu_set_goalspec)
            "selfEvolutionEnabled": state.selfEvolutionEnabled,   // P6 自我进化总开关(默认关;高风险,UI 开启需风险确认;配置入口 lingshu_set_self_evolution)
            "trustScore": state.trustScore,             // 系统就绪度(模型连通/通道就绪/近期验收合成)
            "brainScore": ["score": state.brainScore.score, "completed": state.brainScore.completed, "fallbacks": state.brainScore.fallbacks, "brain": state.brainScore.brainID],   // 顶栏「脑力」:自主完成+1/兜底−1/换脑归零
            "missionTitle": state.missionTitle,
            "missionStatus": state.missionStatus,
            "autonomousPhase": state.autonomousRun.phase.rawValue,
            "autonomousObjective": state.autonomousRun.objective,
            "autonomousStatusLine": state.autonomousRun.statusLine,
            "standingPersonOnDuty": state.isStandingPersonOnDuty,
            "autoReactArmed": state.autonomousAutoReactArmed,
            "perceptionDigest": state.perceptionDigest,
            "perceptionDebug": state.perceptionDebugLine,
            "voiceListening": state.isListening,
            "voiceWake": state.voiceWakeListeningEnabled,
            "micSilentWarning": state.voiceManager?.micSilentWarning ?? "",   // 非空=麦克风没进音(权限/设备)
            "micLastInputAgoSec": state.voiceManager.map { Int(Date().timeIntervalSince($0.lastInputBufferAt)) } ?? -1,
            "previewState": [
                "isPresented": state.previewController.isPresented,
                "slideshow": state.previewController.slideshow,   // true=全屏演示模式
                "pageIndex": state.previewController.pageIndex,
                "pageCount": state.previewController.pageCount,
                "title": state.previewController.title
            ],
            "recentSpoken": Array(state.recentSpokenLines.suffix(14)),   // 演示文字稿(核验对得上画面)
            "chatCount": state.chatMessages.count,
            "taskRecordCount": state.taskExecutionRecords.count,
            "queuedDispatchCount": state.queuedDispatchTasks.count,   // 信息池(可见任务队列)等待条数——任务线串行的可见溢出
            "activeDispatchedCount": state.activeTaskThreadRecordIDs.count,   // 当前在跑/在途的子线程数(与主对话气泡解耦)
            "unreadTaskThreadCount": state.unreadTaskThreadRecordIDs.count,
            "pendingChatTurnCount": state.pendingChatTurnIDs.count,   // 问答线已排队的问答数(等待中可删)
            "globalTaskThreadLedger": state.globalTaskThreadLedgerPayload(limit: 10),
            "recentTaskRecords": state.taskExecutionRecords.prefix(8).map { record in
                [
                    "title": record.title,
                    "status": record.status.rawValue,
                    "artifactCount": record.artifacts.count,
                    "artifacts": record.artifacts.map { $0.location }
                ]
            }
        ]
    }

    /// 一条任务的 codex 式执行时间线 + 产出物 + 反馈(供 MCP inspect,免点开窗口看卡片)。
    func taskDetailPayload(recordID: String) -> [String: Any]? {
        guard let record = state.taskExecutionRecordLookup.first(where: { $0.id == recordID }) else { return nil }
        let objective = recordObjective(record)
        var object: [String: Any] = [
            "id": record.id,
            "title": record.title,
            "objective": objective,
            "prompt": record.prompt,
            "status": record.status.rawValue,
            "isTerminal": record.status.isTerminal,
            "isSuccessful": record.status.isSuccessfulCompletion,
            "isResumable": record.status.isResumableUnfinished,
            "summary": record.summary,
            "feedback": state.taskRecordFeedback[record.id].map { $0 ? "up" : "down" } ?? "none",
            "plan": record.plan.map { ["title": $0.title, "status": $0.status.rawValue] },
            "roleSlots": record.roleSlots.map(Self.roleSlotPayload),
            "designScore": record.designScore as Any,
            "codeChanges": record.codeChanges.map { cc in
                ["repoName": cc.repoName, "branch": cc.branch,
                 "files": cc.files.map { ["status": $0.status, "label": $0.label, "path": $0.path] }]
            } as Any,
            "artifacts": record.artifacts.map { ["title": $0.title, "location": $0.location, "operation": ($0.operation ?? .created).rawValue] },
            "messages": record.messages.map { message -> [String: Any] in
                var object: [String: Any] = ["id": message.id, "actor": message.actor, "role": message.role, "kind": message.kind.rawValue, "text": message.text]
                if let detail = message.detail { object["detail"] = Self.detailPayload(detail) }
                if let undone = message.undone { object["undone"] = undone }
                return object
            }
        ]
        if let commit = record.threadCommit {
            object["threadCommit"] = LingShuState.taskThreadCommitPayload(commit)
        }
        return object
    }

    private func recordObjective(_ record: LingShuTaskExecutionRecord) -> String {
        let goal = record.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { return goal }
        let specObjective = record.goalSpec?.objective.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !specObjective.isEmpty { return specObjective }
        return record.title
    }

    private static func roleSlotPayload(_ slot: LingShuTaskRoleSlot) -> [String: Any] {
        [
            "id": slot.id,
            "roleID": slot.roleID,
            "roleTitle": slot.roleTitle,
            "agentID": slot.agentID as Any,
            "agentName": slot.agentName,
            "semanticRole": slot.semanticRole,
            "status": slot.status.rawValue
        ]
    }

    /// 结构化消息载荷序列化(toolCall/toolResult/fileEdit)——让 MCP 端能拿到命令/输出/diff 原文。
    static func detailPayload(_ detail: LingShuTaskExecutionDetail) -> [String: Any] {
        switch detail {
        case let .toolCall(tool, summary, arguments):
            return ["type": "toolCall", "tool": tool, "summary": summary, "arguments": arguments]
        case let .toolResult(tool, success, output):
            return ["type": "toolResult", "tool": tool, "success": success, "output": output]
        case let .fileEdit(path, operation, added, removed, diff):
            return ["type": "fileEdit", "path": path, "operation": operation.rawValue, "added": added, "removed": removed, "diff": diff]
        }
    }

    func chatPayload(limit: Int) -> [[String: Any]] {
        state.chatMessages.suffix(max(1, limit)).map { message in
            var object: [String: Any] = [
                "id": message.id.uuidString,
                "speaker": message.speaker,
                "text": message.text,
                "isUser": message.isUser,
                "isLoading": message.isLoading,
                "createdAt": ISO8601DateFormatter().string(from: message.createdAt)
            ]
            if let taskRecordID = message.taskRecordID { object["taskRecordID"] = taskRecordID }
            if let awaitingInputForRecordID = message.awaitingInputForRecordID { object["awaitingInputForRecordID"] = awaitingInputForRecordID }
            if let choices = message.choices {
                object["choices"] = [
                    "question": choices.question,
                    "options": choices.options.map { option in
                        [
                            "label": option.label,
                            "detail": option.detail ?? "",
                            "action": option.action ?? ""
                        ]
                    }
                ]
            } else {
                object["choices"] = []
            }
            if let form = message.form {
                object["form"] = [
                    "title": form.title,
                    "fields": form.fields.map { field in
                        [
                            "key": field.key,
                            "question": field.question,
                            "options": field.options
                        ] as [String: Any]
                    }
                ] as [String: Any]
            }
            if let formAnswers = message.formAnswers { object["formAnswers"] = formAnswers }
            if let resolvedChoice = message.resolvedChoice { object["resolvedChoice"] = resolvedChoice }
            if let attachmentNames = message.attachmentNames, !attachmentNames.isEmpty { object["attachmentNames"] = attachmentNames }
            if let thinkingPreview = message.thinkingPreview, !thinkingPreview.isEmpty { object["thinkingPreview"] = thinkingPreview }
            if let interaction = message.humanInteraction {
                object["humanInteraction"] = Self.humanInteractionPayload(interaction)
            }
            return object
        }
    }

    private static func humanInteractionPayload(_ request: LingShuHumanInteractionRequest) -> [String: Any] {
        var object: [String: Any] = [
            "id": request.id,
            "kind": request.kind.rawValue,
            "title": request.title,
            "prompt": request.prompt,
            "payload": request.payload,
            "options": request.options.map {
                ["id": $0.id, "label": $0.label, "detail": $0.detail, "value": $0.value]
            },
            "materials": request.displayMaterials.map {
                [
                    "id": $0.id,
                    "kind": $0.kind.rawValue,
                    "title": $0.title,
                    "value": $0.value,
                    "mimeType": $0.mimeType ?? ""
                ]
            }
        ]
        if let source = request.source { object["source"] = source }
        if let probe = request.completionProbe {
            object["completionProbe"] = [
                "kind": probe.kind.rawValue,
                "target": probe.target,
                "expectedStatus": probe.expectedStatus as Any,
                "intervalSeconds": probe.intervalSeconds,
                "timeoutSeconds": probe.timeoutSeconds
            ]
        }
        return object
    }

    func tracePayload(limit: Int) -> [[String: Any]] {
        state.executionTrace.suffix(max(1, limit)).map { event in
            [
                "time": event.displayTime,
                "kind": String(describing: event.kind),
                "actor": event.actor,
                "title": event.title,
                "detail": event.detail
            ]
        }
    }
}
