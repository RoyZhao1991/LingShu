import Foundation

/// 后台守候 + 完成即续(四肢):大脑给一个「检查命令 + 满足条件 + 满足后要做的事」,灵枢挂到后台
/// 周期性自查、**不阻塞当前对话**,条件一满足就把"继续做那件事"**注入 agent 循环自动续跑**。
/// 常驻 app → 关掉窗口也照样盯、到点自己收尾(进程存活期内)。这就是"自动识别需求 → 无人值守推进"的可靠机制。
struct LingShuBackgroundWatch: Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var checkCommand: String
    var successWhen: String        // 输出里含此子串=满足;空=以命令成功退出为准
    var thenInstruction: String    // 满足后要做的事(自然语言,注入 agent 循环)
    var intervalSeconds: Int
    var deadline: Date
    var createdAt: Date
}

@MainActor
extension LingShuState {

    /// shell 是否已预授权(完全授权会话 / 不需人工确认 / 完整授权独立运行)。
    var shellPreauthorized: Bool {
        developmentPhaseFullAccess || sessionShellAlwaysAllowed || !requireHumanApproval || (autonomousRun.isActive && autonomousRun.permissionLevel == .full)
    }

    /// **派发/派生的隔离子任务的执行策略**:继承父上下文的 shell 预授权。
    /// 根因修复(2026-06-19 实测"演示卡在执行中:跑命令"):派发隔离任务/模型 spawn_task 原写死 `.standard`,
    /// 其 allowShell 公式只认 `sessionShellAlwaysAllowed`,**不认在岗/自主的完整授权**——于是在岗时它跑第一条 shell
    /// (大脑常以"先检查文件是否存在"开场)就 allowShell=false → 弹审批框,而框被全屏演示盖住/无人点 → 永久卡。
    /// 在岗/自主完整授权 → 给 `.autoAllowShell`(与 autonomous 自身一致,危险删改仍走 forceConfirm 强制确认);
    /// 普通模式 → 仍 `.standard`(前台有审批框可点,不会盖住)。
    var dispatchedTaskExecutionPolicy: LingShuAgentExecutionPolicy {
        shellPreauthorized ? .autoAllowShell : .standard
    }

    /// 守候条件是否满足(纯函数可测):有 successWhen 则要命令成功且输出含它;否则以命令成功退出为准。
    nonisolated static func watchConditionMet(commandSucceeded: Bool, output: String, successWhen: String) -> Bool {
        if successWhen.isEmpty { return commandSucceeded }
        return commandSucceeded && output.contains(successWhen)
    }

    func backgroundWatchTools() -> [LingShuAgentTool] {
        [watchUntilTool(), listWatchesTool(), cancelWatchTool()]
    }

    private func watchUntilTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "watch_until",
            description: "后台守候一个长耗时的外部条件,满足后**自动继续**——不必让用户盯着、也不阻塞当前对话。给:要周期性跑的检查命令、判定满足的输出标志、满足后要做的事。典型:'每 2 分钟查公证状态,出现 Accepted 就盖章+重签 app'、'等某构建/下载/部署完成再继续'。满足或超时我会自己把后续动作接上跑完。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"label\":{\"type\":\"string\",\"description\":\"简短描述在守候什么\"},\"check_command\":{\"type\":\"string\",\"description\":\"每次轮询要跑的 shell 命令\"},\"success_when\":{\"type\":\"string\",\"description\":\"(可选)命令输出里出现此子串即视为满足;留空则以命令成功退出为准\"},\"then\":{\"type\":\"string\",\"description\":\"条件满足后要做的事(自然语言,我会自动接着执行)\"},\"interval_seconds\":{\"type\":\"number\",\"description\":\"(可选)轮询间隔秒,默认 120,最小 30\"},\"timeout_minutes\":{\"type\":\"number\",\"description\":\"(可选)最长守候分钟,默认 120\"}},\"required\":[\"label\",\"check_command\",\"then\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            let args = Self.parseArgs(argsJSON)
            let label = (args["label"] ?? "后台守候").trimmingCharacters(in: .whitespacesAndNewlines)
            let cmd = (args["check_command"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let successWhen = args["success_when"] ?? ""
            let then = (args["then"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty, !then.isEmpty else { return "watch_until 需要 check_command 和 then。" }
            let interval = max(30, min(3600, Int(Double(args["interval_seconds"] ?? "") ?? 120) ?? 120))
            let timeoutMin = max(1, min(1440, Int(Double(args["timeout_minutes"] ?? "") ?? 120) ?? 120))
            // 授权:只读检查直接放行;否则一次性审批(后台轮询不每次弹框)。
            let preok = await MainActor.run { self.shellPreauthorized || LingShuShellCommandPolicy.isReadOnly(cmd) }
            var allow = preok
            if !allow {
                let wd = await MainActor.run { self.agentWorkingDirectory }
                let decision = await self.requestShellApproval(command: cmd, workingDirectory: wd, taskRecordID: nil)
                allow = decision != .deny
            }
            guard allow else { return "未授权该后台检查命令,未创建守候。" }
            return await MainActor.run {
                self.startBackgroundWatch(label: label, checkCommand: cmd, successWhen: successWhen, then: then, intervalSeconds: interval, timeoutMinutes: timeoutMin)
                return "已挂起后台守候「\(label)」(每 \(interval)s 查一次,最长 \(timeoutMin) 分钟)。满足条件即自动继续:\(then.prefix(60))。本回合你可以先收尾或做别的,我会在后台盯着、到点自己接着干。"
            }
        }
    }

    private func listWatchesTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "list_watches",
            description: "列出当前在后台守候的任务(在等什么、满足后做什么)。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
        ) { [weak self] _ in
            await MainActor.run {
                guard let self, !self.backgroundWatches.isEmpty else { return "当前没有后台守候。" }
                return "后台守候中:\n" + self.backgroundWatches.map { "- [\($0.id)] \($0.label):满足条件即「\($0.thenInstruction.prefix(40))」" }.joined(separator: "\n")
            }
        }
    }

    private func cancelWatchTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "cancel_watch",
            description: "取消一个后台守候(传 id 或 label)。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"description\":\"守候的 id 或 label\"}},\"required\":[\"id\"]}"
        ) { [weak self] argsJSON in
            let key = (Self.jsonField(argsJSON, "id") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return await MainActor.run {
                guard let self else { return "执行环境不可用" }
                guard let watch = self.backgroundWatches.first(where: { $0.id == key || $0.label == key }) else { return "没找到该守候:\(key)" }
                self.cancelBackgroundWatch(id: watch.id)
                return "已取消后台守候「\(watch.label)」。"
            }
        }
    }

    /// 挂起一个后台守候:周期性跑检查命令,满足即 fireWatch 续跑;到 deadline 仍未满足则超时续跑(交人工)。
    @discardableResult
    func startBackgroundWatch(label: String, checkCommand: String, successWhen: String, then: String, intervalSeconds: Int, timeoutMinutes: Int) -> String {
        let id = "watch-\(UUID().uuidString.prefix(8))"
        let deadline = Date().addingTimeInterval(Double(timeoutMinutes) * 60)
        backgroundWatches.append(.init(id: id, label: label, checkCommand: checkCommand, successWhen: successWhen, thenInstruction: then, intervalSeconds: intervalSeconds, deadline: deadline, createdAt: Date()))
        appendTrace(kind: .runtime, actor: "后台守候", title: "已挂起:\(label)", detail: "每 \(intervalSeconds)s 查;满足即续:\(String(then.prefix(40)))")
        let wd = agentWorkingDirectory
        let executor = toolExecutor
        let nanos = UInt64(intervalSeconds) * 1_000_000_000
        backgroundWatchTasks[id] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if Date() >= deadline { self?.fireWatch(id: id, timedOut: true); return }
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled, let self, self.backgroundWatches.contains(where: { $0.id == id }) else { return }
                let result = await executor.execute(.init(tool: "run_command", arguments: ["command": checkCommand]), workingDirectory: wd, allowShell: true)
                if Self.watchConditionMet(commandSucceeded: result.success, output: result.output, successWhen: successWhen) {
                    self.fireWatch(id: id, timedOut: false)
                    return
                }
            }
        }
        return id
    }

    /// 守候命中(或超时)→ 清掉守候,把"继续做约定的事"注入主 agent 会话自动续跑。
    func fireWatch(id: String, timedOut: Bool) {
        guard let watch = backgroundWatches.first(where: { $0.id == id }) else { return }
        cancelBackgroundWatch(id: id)
        let head = timedOut
            ? "⏱ 后台守候「\(watch.label)」到时仍未满足条件,转为自查 + 决定下一步"
            : "✅ 后台守候「\(watch.label)」条件已满足,自动继续"
        appendTrace(kind: timedOut ? .warning : .result, actor: "后台守候", title: head, detail: String(watch.thenInstruction.prefix(60)))
        let prompt = timedOut
            ? "后台守候「\(watch.label)」已到时限仍未满足条件(success_when=\(watch.successWhen.isEmpty ? "命令成功退出" : watch.successWhen))。请先跑命令查清当前状况,再决定下一步。原定满足后要做的是:\(watch.thenInstruction)"
            : "后台守候「\(watch.label)」的条件已满足。现在执行当初约定的后续动作:\(watch.thenInstruction)"
        let recordID = createTaskExecutionRecord(for: "后台守候续跑:\(watch.label)")
        chatMessages.append(.init(speaker: "灵枢", text: head + "。", isUser: false, taskRecordID: recordID))
        runMainAgentTurn(prompt: prompt, taskRecordID: recordID)
    }

    func cancelBackgroundWatch(id: String) {
        backgroundWatchTasks[id]?.cancel()
        backgroundWatchTasks[id] = nil
        backgroundWatches.removeAll { $0.id == id }
    }

    func cancelAllBackgroundWatches() {
        backgroundWatchTasks.values.forEach { $0.cancel() }
        backgroundWatchTasks.removeAll()
        backgroundWatches.removeAll()
    }
}
