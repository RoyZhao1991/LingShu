import Foundation

@MainActor
extension LingShuState {
    func longCommandTools(
        recordIDProvider: @escaping @MainActor @Sendable () -> String?,
        baseAllowShell: Bool,
        defaultWorkingDirectory: String,
        workingDirectoryOverride: String?
    ) -> [LingShuAgentTool] {
        [
            recordedAgentTool(startLongCommandTool(recordIDProvider: recordIDProvider, baseAllowShell: baseAllowShell, defaultWorkingDirectory: defaultWorkingDirectory, workingDirectoryOverride: workingDirectoryOverride), recordIDProvider: recordIDProvider),
            recordedAgentTool(checkLongCommandTool(recordIDProvider: recordIDProvider), recordIDProvider: recordIDProvider),
            recordedAgentTool(cancelLongCommandTool(recordIDProvider: recordIDProvider), recordIDProvider: recordIDProvider),
            recordedAgentTool(listLongCommandsTool(), recordIDProvider: recordIDProvider)
        ]
    }

    private func startLongCommandTool(
        recordIDProvider: @escaping @MainActor @Sendable () -> String?,
        baseAllowShell: Bool,
        defaultWorkingDirectory: String,
        workingDirectoryOverride: String?
    ) -> LingShuAgentTool {
        LingShuAgentTool(
            name: "start_long_command",
            description: "启动一个由灵枢宿主托管的长命令，返回 job_id；用于预计超过普通命令窗口的构建、测试、格式转换、下载、服务启动、批处理。不要手写 `&`、`sleep`、`tail` 循环来守候长命令；相同工作目录+命令正在运行时会复用已有 job，不会重复启动。默认 completion_mode=wait_for_exit：任务完成闸会等命令终态并把结果回灌后再允许交付。只有明确需要持续运行且进程本身不退出的服务才传 background。后续可用 check_long_command 查询，用 cancel_long_command 停止。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"要执行的 shell 命令\"},\"label\":{\"type\":\"string\",\"description\":\"可读任务名\"},\"timeout_seconds\":{\"type\":\"number\",\"description\":\"最长允许运行秒数，默认 3600，范围 30 到 86400\"},\"completion_mode\":{\"type\":\"string\",\"enum\":[\"wait_for_exit\",\"background\"],\"description\":\"默认 wait_for_exit；仅常驻服务使用 background\"}},\"required\":[\"command\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            let args = Self.parseArgs(argsJSON)
            let command = (args["command"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return "start_long_command 需要 command。" }
            if LingShuCommandSafety.isDangerous(command) {
                return "命令命中危险操作黑名单，拒绝执行。"
            }

            let workingDirectory = await MainActor.run {
                self.effectiveAgentWorkingDirectory(override: workingDirectoryOverride, fallback: defaultWorkingDirectory)
            }
            let systemSensitive = LingShuShellCommandPolicy.touchesSystemSensitivePath(command)
            var allow = await MainActor.run {
                baseAllowShell || self.sessionShellAlwaysAllowed || self.shellPreauthorized
            }
            if LingShuShellCommandPolicy.isReadOnly(command), !systemSensitive {
                allow = true
            } else if !allow || systemSensitive {
                let decision = await requestShellApproval(
                    command: command,
                    workingDirectory: workingDirectory,
                    taskRecordID: nil,
                    forceConfirm: systemSensitive
                )
                allow = decision != .deny
            }
            guard allow else {
                return "用户已拒绝本次长命令执行。"
            }

            let timeout = Double(args["timeout_seconds"] ?? "")
            let completionMode = args["completion_mode"] == "background" ? "background" : "wait_for_exit"
            return await MainActor.run {
                let snapshot = self.longCommandRegistry.start(
                    command: command,
                    workingDirectory: workingDirectory,
                    label: args["label"],
                    timeoutSeconds: timeout
                )
                let recordID = recordIDProvider()
                if completionMode == "wait_for_exit", !snapshot.status.isTerminal, let recordID {
                    self.awaitedLongCommandJobIDsByRecord[recordID, default: []].insert(snapshot.id)
                }
                self.appendTaskRecordMessage(
                    recordID,
                    actor: "长命令",
                    role: "已托管",
                    kind: .agent,
                    text: "\(snapshot.reusedExisting ? "复用" : "启动") \(snapshot.label) · \(snapshot.id)",
                    detail: .toolResult(tool: "start_long_command", success: snapshot.status == .running, output: snapshot.modelText)
                )
                return snapshot.modelText
            }
        }
    }

    private func checkLongCommandTool(
        recordIDProvider: @escaping @MainActor @Sendable () -> String?
    ) -> LingShuAgentTool {
        LingShuAgentTool(
            name: "check_long_command",
            description: "查询 start_long_command 返回的 job_id 当前状态与最近日志。长命令未完成时应查询它，而不是重复启动同一命令。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"job_id\":{\"type\":\"string\",\"description\":\"start_long_command 返回的 job_id\"}},\"required\":[\"job_id\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            let id = (Self.jsonField(argsJSON, "job_id") ?? Self.jsonField(argsJSON, "id") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return "check_long_command 需要 job_id。" }
            return await MainActor.run {
                guard let snapshot = self.longCommandRegistry.snapshot(id: id) else { return "没找到长命令 job:\(id)" }
                if snapshot.status.isTerminal, let recordID = recordIDProvider() {
                    self.removeAwaitedLongCommand(id, recordID: recordID)
                }
                return snapshot.modelText
            }
        }
    }

    private func cancelLongCommandTool(
        recordIDProvider: @escaping @MainActor @Sendable () -> String?
    ) -> LingShuAgentTool {
        LingShuAgentTool(
            name: "cancel_long_command",
            description: "取消一个由 start_long_command 启动的长命令 job，会终止其进程树并保留现有日志。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"job_id\":{\"type\":\"string\",\"description\":\"start_long_command 返回的 job_id\"}},\"required\":[\"job_id\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            let id = (Self.jsonField(argsJSON, "job_id") ?? Self.jsonField(argsJSON, "id") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return "cancel_long_command 需要 job_id。" }
            return await MainActor.run {
                guard let snapshot = self.longCommandRegistry.cancel(id: id) else { return "没找到长命令 job:\(id)" }
                if snapshot.status.isTerminal, let recordID = recordIDProvider() {
                    self.removeAwaitedLongCommand(id, recordID: recordID)
                }
                return snapshot.modelText
            }
        }
    }

    private func listLongCommandsTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "list_long_commands",
            description: "列出当前会话中灵枢宿主托管过的长命令 job，用于恢复上下文、查找正在运行或刚完成的长任务。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
        ) { [weak self] _ in
            guard let self else { return "执行环境不可用" }
            return await MainActor.run {
                let snapshots = self.longCommandRegistry.snapshots()
                guard !snapshots.isEmpty else { return "当前没有长命令 job。" }
                return snapshots.map { snap in
                    "- \(snap.id) [\(snap.status.rawValue)] \(snap.label) · 用时 \(String(format: "%.1f", snap.durationSeconds))s · \(snap.logPath)"
                }.joined(separator: "\n")
            }
        }
    }
}
