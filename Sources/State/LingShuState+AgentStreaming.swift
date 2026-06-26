import Foundation

/// **统一 agent 流式范式(用户定调 2026-06-26:所有 agent 接入都流式,没流式的别干等,体验太差)**。
/// 任何把活外包给已注册 agent(codex / claude / …)且产出要进任务时间线的地方,都走 `runAgentStreamingToRecord`——
/// 它先落一条"执行中"参与方气泡,**边跑边把 agent 的输出尾部更新进同一条气泡**(对齐 codex/claude 的流式体验),
/// 不再静默干等到跑完才一次性出结果。角色管线 / 独立 checker / maker 返工都接它。
@MainActor
extension LingShuState {

    /// 按 ID 更新任务记录里某条消息的文本(流式增量更新同一条气泡用;不每块持久化,收尾再存,免高频写盘)。
    func updateTaskRecordMessageText(_ recordID: String?, messageID: String?, text: String) {
        guard let recordID, let messageID,
              let i = taskExecutionRecords.firstIndex(where: { $0.id == recordID }),
              let j = taskExecutionRecords[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        taskExecutionRecords[i].messages[j].text = LingShuTaskMessageFormatting.sanitize(text)
    }

    /// 跑一个 agent 并**流式**把进展更新进任务时间线的一条参与方气泡;收尾把最终输出落定。返回 agent 执行结果。
    func runAgentStreamingToRecord(_ plugin: LingShuAgentPlugin, objective: String, recordID rid: String,
                                   actor: String, role: String, startText: String)
        async -> LingShuAgentPluginStore.AgentRunResult {
        appendTaskRecordMessage(rid, actor: actor, role: role, kind: .agent, text: startText)
        let msgID = taskExecutionRecords.first(where: { $0.id == rid })?.messages.last?.id
        let startedAt = Date()
        let isStream = LingShuAgentStreamParser.isStreamJSON(plugin.argsTemplate)
        let result = await LingShuAgentPluginStore.run(
            plugin, objective: objective, workingDirectory: agentWorkingDirectory,
            progress: { tail in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let secs = Int(Date().timeIntervalSince(startedAt))
                    self.updateTaskRecordMessageText(rid, messageID: msgID,
                        text: startText + "\n\n⏳ 运行中(\(secs)s):\n" + String(tail.suffix(700)))
                }
            },
            producedFilesSink: { files in
                Task { @MainActor [weak self] in self?.registerAgentTouchedFiles(recordID: rid, paths: files) }
            })
        // 收尾:把这条流式气泡定格成最终结论尾部,并持久化一次。
        let finalText: String
        switch result {
        case .completed(let t): finalText = startText + "\n\n✓ 完成:\n" + String(t.suffix(900))
        case .failure(let f):   finalText = startText + "\n\n✗ 未完成:" + String(f.prefix(300))
        }
        updateTaskRecordMessageText(rid, messageID: msgID, text: finalText)
        // **产出物补登(2026-06-26)**:agent CLI 用自己的工具写文件、绕过灵枢 write_file → 不会自动进产出物列表。
        // stream-json(claude)已由 producedFilesSink **精确**登记(只认它 tool_use 真写过的文件,根治共享目录串台);
        // 非 stream(codex/text)拿不到 tool_use,回退**扫工作目录 mtime**(本次运行期间真新建/改动的文件)。
        if !isStream {
            registerAgentProducedArtifacts(recordID: rid, workingDirectory: agentWorkingDirectory, since: startedAt)
        }
        persistTaskExecutionRecords()
        return result
    }

    /// 登记 agent **真碰过的文件**(来自 stream-json tool_use)为产出物,并**刷新其 mtime**——
    /// 用户定调(2026-06-26):改已有项目必须在原项目里做、不隔离目录;就算是已有产出物,处理时也迭代一下修改时间,
    /// 这样无论文件是本次新建、还是改了已有项目里的旧文件,都被一致认作本任务产出 + 兼容下游 mtime 逻辑。
    func registerAgentTouchedFiles(recordID: String, paths: [String]) {
        let fm = FileManager.default
        var any = false
        for p in paths where fm.fileExists(atPath: p) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: p)   // 迭代修改时间,保持兼容
            appendTaskRecordArtifact(recordID, title: (p as NSString).lastPathComponent, location: p,
                                     producer: "agent产出", operation: .created)
            any = true
        }
        if any { persistTaskExecutionRecords() }
    }

    /// 扫 `workingDirectory`,把【`since` 之后真新建/改动】的交付型文件补登进产出物(去重由 appendArtifact 负责)。
    /// agent(claude/codex…)用自己的工具/Bash 写文件不经灵枢 write_file,只能靠运行后扫盘 + mtime 认本次产出。
    /// 跳过依赖/构建/缓存目录,有安全上限,避免把 node_modules 之类塞进产出物。
    func registerAgentProducedArtifacts(recordID: String, workingDirectory: String, since: Date) {
        let fm = FileManager.default
        let dir = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty, fm.fileExists(atPath: dir) else { return }
        let skip: Set<String> = [".git", ".build", "node_modules", "__pycache__", ".venv", "venv",
                                 "dist", "build", "target", ".pytest_cache", ".idea", ".next", ".cache", "DerivedData"]
        guard let en = fm.enumerator(at: URL(fileURLWithPath: dir),
                                     includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return }
        let cutoff = since.addingTimeInterval(-1)   // 1s 容差,对齐 run_command 补登
        var count = 0
        for case let url as URL in en {
            if skip.contains(url.lastPathComponent) { en.skipDescendants(); continue }
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  vals.isRegularFile == true, let mtime = vals.contentModificationDate, mtime >= cutoff else { continue }
            appendTaskRecordArtifact(recordID, title: url.lastPathComponent, location: url.path,
                                     producer: "agent产出", operation: .created)
            count += 1
            if count >= 50 { break }   // 安全上限
        }
    }
}
