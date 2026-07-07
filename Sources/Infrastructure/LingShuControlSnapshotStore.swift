import Foundation

/// MCP 只读控制面快照。
///
/// 运行面(演示、TTS、长任务、UI)可能会长时间占用 MainActor。MCP 的观测类工具如果也排队等
/// MainActor,外部测试会在任务仍然活着时“失明”。这里把最近一次已知的任务/聊天/轨迹快照复制到
/// 线程安全缓存中,控制服务可先用缓存回答只读请求；写操作和真实执行仍走 MainActor。
final class LingShuControlSnapshotStore: @unchecked Sendable {
    static let shared = LingShuControlSnapshotStore()

    private let lock = NSLock()
    private var taskRecordsPayload = #"{"records":[]}"#
    private var taskDetailPayloads: [String: String] = [:]
    private var chatPayload = #"{"messages":[]}"#
    private var tracePayload = #"{"trace":[]}"#
    private var statusPayload = #"{"cached":true}"#
    private var hasSnapshot = false

    private init() {}

    func update(
        status: [String: Any],
        records: [LingShuTaskExecutionRecord],
        feedback: [String: Bool],
        chat: [ChatMessage],
        trace: [ExecutionTraceEvent]
    ) {
        let recordItems = records.map { recordSummaryPayload($0, feedback: feedback[$0.id]) }
        var details: [String: String] = [:]
        for record in records.prefix(80) {
            details[record.id] = Self.jsonText(taskDetailPayload(record, feedback: feedback[record.id]))
        }

        let nextStatus = status.merging(["cached": true]) { current, _ in current }
        let nextChat = chat.suffix(80).map(Self.chatMessagePayload)
        let nextTrace = trace.suffix(180).map(Self.traceEventPayload)

        lock.lock()
        hasSnapshot = true
        taskRecordsPayload = Self.jsonText(["records": recordItems])
        taskDetailPayloads = details
        chatPayload = Self.jsonText(["messages": Array(nextChat)])
        tracePayload = Self.jsonText(["trace": Array(nextTrace)])
        statusPayload = Self.jsonText(nextStatus)
        lock.unlock()
    }

    func cachedToolText(name: String, arguments: [String: Any]) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard hasSnapshot else { return nil }
        switch name {
        case "lingshu_status":
            return statusPayload
        case "lingshu_task_records":
            return taskRecordsPayload
        case "lingshu_task_detail":
            guard let id = arguments["recordId"] as? String else { return nil }
            return taskDetailPayloads[id]
        case "lingshu_get_chat":
            return chatPayload
        case "lingshu_get_trace":
            return tracePayload
        default:
            return nil
        }
    }

    func cachedJSONRPCResponse(for body: Data) -> Data? {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let method = object["method"] as? String,
            method == "tools/call",
            let params = object["params"] as? [String: Any],
            let name = params["name"] as? String
        else { return nil }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard let text = cachedToolText(name: name, arguments: arguments) else { return nil }
        return Self.rpcReply(id: object["id"], text: text)
    }

    private func recordSummaryPayload(_ record: LingShuTaskExecutionRecord, feedback: Bool?) -> [String: Any] {
        var object: [String: Any] = [
            "id": record.id,
            "title": record.title,
            "promptExcerpt": String(record.prompt.prefix(280)),
            "status": record.status.rawValue,
            "summary": record.summary,
            "updatedAt": ISO8601DateFormatter().string(from: record.updatedAt),
            "messageCount": record.messages.count,
            "artifactCount": record.artifacts.count,
            "artifacts": record.artifacts.map { ["title": $0.title, "location": $0.location] },
            "feedback": feedback.map { $0 ? "up" : "down" } ?? "none"
        ]
        if let commit = record.threadCommit {
            object["threadCommit"] = Self.threadCommitPayload(commit)
        }
        return object
    }

    private func taskDetailPayload(_ record: LingShuTaskExecutionRecord, feedback: Bool?) -> [String: Any] {
        let objective = Self.recordObjective(record)
        var object: [String: Any] = [
            "id": record.id,
            "title": record.title,
            "objective": objective,
            "prompt": record.prompt,
            "status": record.status.rawValue,
            "summary": record.summary,
            "updatedAt": ISO8601DateFormatter().string(from: record.updatedAt),
            "feedback": feedback.map { $0 ? "up" : "down" } ?? "none",
            "plan": record.plan.map { ["title": $0.title, "status": $0.status.rawValue] },
            "roleSlots": record.roleSlots.map(Self.roleSlotPayload),
            "designScore": record.designScore as Any,
            "codeChanges": record.codeChanges.map { code in
                [
                    "repoName": code.repoName,
                    "branch": code.branch,
                    "files": code.files.map { ["status": $0.status, "label": $0.label, "path": $0.path] }
                ]
            } as Any,
            "artifacts": record.artifacts.map {
                ["title": $0.title, "location": $0.location, "operation": ($0.operation ?? .created).rawValue]
            },
            "messages": record.messages.map(Self.taskMessagePayload)
        ]
        if let commit = record.threadCommit {
            object["threadCommit"] = Self.threadCommitPayload(commit)
        }
        return object
    }

    private static func recordObjective(_ record: LingShuTaskExecutionRecord) -> String {
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

    private static func threadCommitPayload(_ commit: LingShuTaskThreadCommit) -> [String: Any] {
        LingShuState.taskThreadCommitPayload(commit)
    }

    private static func taskMessagePayload(_ message: LingShuTaskExecutionMessage) -> [String: Any] {
        var object: [String: Any] = [
            "id": message.id,
            "actor": message.actor,
            "role": message.role,
            "kind": message.kind.rawValue,
            "text": message.text
        ]
        if let detail = message.detail { object["detail"] = detailPayload(detail) }
        if let undone = message.undone { object["undone"] = undone }
        return object
    }

    private static func detailPayload(_ detail: LingShuTaskExecutionDetail) -> [String: Any] {
        switch detail {
        case let .toolCall(tool, summary, arguments):
            return ["type": "toolCall", "tool": tool, "summary": summary, "arguments": arguments]
        case let .toolResult(tool, success, output):
            return ["type": "toolResult", "tool": tool, "success": success, "output": output]
        case let .fileEdit(path, operation, added, removed, diff):
            return ["type": "fileEdit", "path": path, "operation": operation.rawValue, "added": added, "removed": removed, "diff": diff]
        }
    }

    private static func chatMessagePayload(_ message: ChatMessage) -> [String: Any] {
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
                "options": choices.options.map {
                    ["label": $0.label, "detail": $0.detail ?? "", "action": $0.action ?? ""]
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
        return object
    }

    private static func traceEventPayload(_ event: ExecutionTraceEvent) -> [String: Any] {
        [
            "time": event.displayTime,
            "kind": String(describing: event.kind),
            "actor": event.actor,
            "title": event.title,
            "detail": event.detail
        ]
    }

    private static func rpcReply(id: Any?, text: String) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": [
                "content": [["type": "text", "text": text]],
                "isError": false
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
    }

    private static func jsonText(_ payload: Any) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
