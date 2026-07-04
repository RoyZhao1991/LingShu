import Foundation

@MainActor
extension LingShuState {
    /// 只读观察/发现类任务的证据收口:
    /// 用户要的是“看一眼/查一下/列出来/分类说明”,且执行记录里已有只读探测证据、回复也给出了实质结论时,
    /// 不再把它拖进交付物验收/返工循环。写文件、同步外部系统、控制设备等变更类目标不会命中这里。
    func readOnlyObservationDeliveryCanFinish(recordID: String?, userRequest: String, reply: String) -> Bool {
        guard let recordID, let record = taskExecutionRecords.first(where: { $0.id == recordID }) else { return false }
        return Self.readOnlyObservationDeliveryCanFinish(record: record, userRequest: userRequest, reply: reply)
    }

    /// 答复型回合的结构收口:
    /// 有些控制面模型会把“解释一下/提醒一句/告诉我”误拆成 task + successCriteria,随后触发验收返工,
    /// 导致普通问答堵住串行队列。这里不靠领域关键词放行,只看**事实结构**:
    /// 用户没有要求改变外部状态/落产物,记录里也没有文件改动、真实动作或变更型命令,且回复已经是实质回答。
    /// 满足这些条件时,这轮的交付物就是“回答本身”,不再进入 maker/checker 验收循环。
    func answerOnlyDeliveryCanFinish(recordID: String?, userRequest: String, reply: String) -> Bool {
        guard let recordID, let record = taskExecutionRecords.first(where: { $0.id == recordID }) else { return false }
        return Self.answerOnlyDeliveryCanFinish(record: record, userRequest: userRequest, reply: reply)
    }

    nonisolated static func answerOnlyDeliveryCanFinish(record: LingShuTaskExecutionRecord, userRequest: String, reply: String) -> Bool {
        let spec = record.goalSpec
        let requestText = [
            userRequest,
            record.prompt,
            spec?.objective ?? "",
            (spec?.constraints ?? []).joined(separator: " "),
            (spec?.successCriteria ?? []).joined(separator: " ")
        ].joined(separator: " ")
        guard !looksLikeMutatingDeliveryIntent(requestText) else { return false }
        if record.gapAnalysis?.OAuth?.normalized != nil { return false }
        if let structured = LingShuStructuredModelOutput.parse(reply),
           structured.OAuth?.normalized != nil || structured.declaresIncomplete {
            return false
        }
        guard !recordHasAnswerOnlyBlockingExecutionEvidence(record) else { return false }
        guard replyIsSubstantiveAnswer(reply) else { return false }
        return true
    }

    nonisolated static func readOnlyObservationDeliveryCanFinish(record: LingShuTaskExecutionRecord, userRequest: String, reply: String) -> Bool {
        let spec = record.goalSpec
        let requestText = [
            userRequest,
            record.prompt,
            spec?.objective ?? "",
            (spec?.constraints ?? []).joined(separator: " "),
            (spec?.successCriteria ?? []).joined(separator: " ")
        ].joined(separator: " ")
        guard looksLikeReadOnlyObservationIntent(requestText) else { return false }
        guard !looksLikeMutatingDeliveryIntent(requestText) else { return false }
        if record.gapAnalysis?.OAuth?.normalized != nil { return false }
        if let structured = LingShuStructuredModelOutput.parse(reply),
           structured.OAuth?.normalized != nil || structured.declaresIncomplete {
            return false
        }
        guard recordHasReadOnlyObservationEvidence(record) else { return false }
        guard replyIsSubstantiveObservationAnswer(reply) else { return false }
        return true
    }

    nonisolated static func replyIsSubstantiveAnswer(_ reply: String) -> Bool {
        let visible = LingShuHumanInputEnvelope.userFacingText(from: LingShuReasoningText.stripThinkTags(reply))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard visible.count >= 8 else { return false }
        if looksLikeInternalDump(visible) { return false }
        if visible.contains("已发起工具调用") || visible.contains("等待工具") { return false }
        if visible.hasPrefix("需要你") || visible.hasPrefix("请你") { return false }
        return true
    }

    nonisolated static func recordHasAnswerOnlyBlockingExecutionEvidence(_ record: LingShuTaskExecutionRecord) -> Bool {
        if !record.artifacts.isEmpty { return true }
        var pendingRunCommand = ""
        for message in record.messages {
            switch message.detail {
            case .fileEdit:
                return true
            case let .toolCall(tool, summary, arguments):
                if tool == "run_command" {
                    pendingRunCommand = summary + " " + arguments
                    if !commandLooksReadOnlyObservationProbe(pendingRunCommand) { return true }
                } else if tool == "write_file" || tool == "edit_file" {
                    return true
                } else if LingShuOutcomeVerification.isActionTool(tool) {
                    return true
                }
            case let .toolResult(tool, success, _):
                if tool == "run_command" {
                    defer { pendingRunCommand = "" }
                    if success, !commandLooksReadOnlyObservationProbe(pendingRunCommand) { return true }
                } else if tool == "write_file" || tool == "edit_file" {
                    if success { return true }
                } else if success, LingShuOutcomeVerification.isActionTool(tool) {
                    return true
                }
            default:
                break
            }
        }
        return false
    }

    nonisolated static func looksLikeReadOnlyObservationIntent(_ text: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(text)
        guard !normalized.isEmpty else { return false }
        let observationSignals = [
            "看看", "看一下", "查一下", "查询", "搜索", "检索", "找一下", "找出", "发现",
            "扫描", "列出", "分类", "识别", "盘点", "统计", "确认一下", "告诉我",
            "有哪些", "是什么", "在不在", "是否存在", "摘要", "总结", "观察", "只读",
            "inspect", "observe", "discover", "scan", "list", "classify", "search", "find",
            "query", "summarize", "tell me", "what is", "whether"
        ]
        return observationSignals.contains { normalized.contains($0) }
    }

    nonisolated static func looksLikeMutatingDeliveryIntent(_ text: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(text)
        guard !normalized.isEmpty else { return false }
        let mutatingSignals = [
            "生成", "制作", "创建", "新建", "写入", "写一个", "保存", "修改", "删除", "移动",
            "复制", "同步", "上传", "发布", "发送", "连接到", "接入", "登录", "下单", "付款",
            "打开", "关闭", "启动", "停止", "运行", "安装", "部署", "控制", "操作", "投屏到",
            "演示", "播放", "create", "generate", "write", "save", "modify", "delete", "sync",
            "upload", "publish", "send", "connect", "login", "run", "install", "deploy",
            "control", "operate", "present", "play"
        ]
        return mutatingSignals.contains { normalized.contains($0) }
    }

    nonisolated static func replyIsSubstantiveObservationAnswer(_ reply: String) -> Bool {
        let visible = LingShuHumanInputEnvelope.userFacingText(from: LingShuReasoningText.stripThinkTags(reply))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard visible.count >= 18 else { return false }
        if looksLikeInternalDump(visible) { return false }
        if visible.contains("已发起工具调用") || visible.contains("等待工具") { return false }
        if visible.hasPrefix("需要你") || visible.hasPrefix("请你") { return false }
        return true
    }

    nonisolated static func recordHasReadOnlyObservationEvidence(_ record: LingShuTaskExecutionRecord) -> Bool {
        var pendingRunCommand = ""
        for message in record.messages {
            switch message.detail {
            case let .toolCall(tool, summary, arguments):
                if tool == "run_command" {
                    pendingRunCommand = summary + " " + arguments
                } else if observationReadTool(tool) {
                    // 工具调用本身不算证据,等待后续成功结果确认。
                    continue
                }
            case let .toolResult(tool, success, output):
                guard success, !runOutputLooksFailed(output) else {
                    if tool == "run_command" { pendingRunCommand = "" }
                    continue
                }
                if tool == "run_command" {
                    defer { pendingRunCommand = "" }
                    if commandLooksReadOnlyObservationProbe(pendingRunCommand) { return true }
                } else if observationReadTool(tool) {
                    return true
                }
            default:
                break
            }
        }
        return false
    }

    nonisolated static func observationReadTool(_ tool: String) -> Bool {
        let t = tool.lowercased()
        let exact: Set<String> = [
            "discover_devices", "recall_local", "search_local", "read_local", "read_file",
            "list_directory", "list_files", "fetch_url", "web_search", "browser_read",
            "screen_capture", "perceive", "list_capabilities", "self_inspect", "time",
            "location", "list_credentials", "inspect_ui", "list_ui_elements"
        ]
        if exact.contains(t) { return true }
        return t.hasPrefix("read_") || t.hasPrefix("list_") || t.hasPrefix("search_")
            || t.hasPrefix("inspect_") || t.hasPrefix("discover_") || t.hasPrefix("recall_")
            || t.hasPrefix("index_query")
    }

    nonisolated static func commandLooksReadOnlyObservationProbe(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if LingShuShellCommandPolicy.isReadOnly(trimmed) { return true }
        let lowered = trimmed.lowercased()
        let unsafeMarkers = [
            ">", ">>", " rm ", " rmdir", " mv ", " cp ", " dd ", " tee ", " ln ",
            " mkdir", " touch", " chmod", " chown", " sudo", " kill", " pkill",
            " shutdown", " reboot", " install", " uninstall", " curl", " wget",
            " scp", " rsync", " ssh", " open ", " osascript"
        ]
        if unsafeMarkers.contains(where: { lowered.contains($0) || lowered.hasPrefix($0.trimmingCharacters(in: .whitespaces)) }) {
            return false
        }
        let mutationOptions = [
            " -set", "--set", " set-", " add", " remove", " delete", " erase", " enable",
            " disable", " start", " stop", " restart", " write", " apply", " create"
        ]
        if mutationOptions.contains(where: { lowered.contains($0) }) { return false }
        let observationHeads: Set<String> = [
            "arp", "dns-sd", "system_profiler", "ioreg", "ifconfig", "ipconfig", "networksetup",
            "scutil", "lpstat", "pmset", "profiles", "mdfind", "mdls", "netstat", "lsof"
        ]
        let segments = lowered.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { segment in
            guard let head = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return false }
            return observationHeads.contains(String(head)) || LingShuShellCommandPolicy.isReadOnly(segment)
        }
    }
}
