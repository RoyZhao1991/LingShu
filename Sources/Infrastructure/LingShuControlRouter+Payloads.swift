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

    func statusPayload() -> [String: Any] {
        [
            "coreState": state.coreStateDisplay,
            "loopPhase": state.loopPhase.rawValue,   // 理解中/规划中/执行中/验收中(空=空闲)
            "loopVariant": state.agentLoopVariant.rawValue,   // classic=经典连续 / nested=嵌套分阶段
            "loopInvariantViolations": LingShuLoopInvariantTelemetry.total,   // 循环不变量累计违反数(架网遥测;soak/真机断言恒为0)
            "developmentFullAccess": state.developmentPhaseFullAccess,   // 开发阶段全权(系统授权门直接放行;发布版关=人工授权)
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
        return [
            "id": record.id,
            "title": record.title,
            "status": record.status.rawValue,
            "summary": record.summary,
            "feedback": state.taskRecordFeedback[record.id].map { $0 ? "up" : "down" } ?? "none",
            "plan": record.plan.map { ["title": $0.title, "status": $0.status.rawValue] },
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
            [
                "speaker": message.speaker,
                "text": message.text,
                "isUser": message.isUser,
                "isLoading": message.isLoading,
                "choices": message.choices?.options.map(\.label) ?? [],
                "createdAt": ISO8601DateFormatter().string(from: message.createdAt)
            ]
        }
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
