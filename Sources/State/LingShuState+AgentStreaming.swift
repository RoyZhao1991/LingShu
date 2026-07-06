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
        let workDir = agentWorkingDirectory
        // **产出物归属真相源(2026-06-28,影子 git)**:跑前打基线、跑后量 delta——只认本次**真改/新建**的文件,
        // 取代"mtime 足迹/agent 自报",根治共享工作目录里旧文件被串进产出物(见 [[artifact-attribution-shadow-git]])。
        let shadowBaseline = await Task.detached { LingShuShadowGit.baseline(workDir: workDir) }.value
        let result = await LingShuAgentPluginStore.run(
            plugin, objective: objective, workingDirectory: workDir,
            progress: { tail in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let secs = Int(Date().timeIntervalSince(startedAt))
                    self.updateTaskRecordMessageText(rid, messageID: msgID,
                        text: startText + "\n\n⏳ 运行中(\(secs)s):\n" + String(tail.suffix(700)))
                }
            })
        // producedFilesSink 不再传:agent 自报"碰过"的文件会多报(连只 touch 的旧文件都报)→ 不当归属真相,改用跑后影子 delta。
        // 收尾:把这条流式气泡定格成最终结论尾部,并持久化一次。
        let finalText: String
        switch result {
        case .completed(let t): finalText = startText + "\n\n✓ 完成:\n" + String(t.suffix(900))
        case .failure(let f):   finalText = startText + "\n\n✗ 未完成:" + String(f.prefix(300))
        }
        if case .failure = result, LingShuAgentPluginStore.plugin(id: plugin.id)?.isCallableNow != true {
            markAgentPluginCatalogChanged(agentID: plugin.id)
        }
        updateTaskRecordMessageText(rid, messageID: msgID, text: finalText)
        // **跑后量影子 git delta 登记产出物**——归属的唯一真相源,替换原来三条易串台的旧路径(扫盘mtime/agent自报/抽输出路径)。
        if let shadowBaseline {
            let changes = await Task.detached { LingShuShadowGit.delta(since: shadowBaseline) }.value
            registerArtifactsFromShadowDelta(recordID: rid, changes: changes)
        } else if !isStream {
            // 影子 git 不可用(目标非目录/git 缺失)→ 保守退回旧扫盘兜底。
            registerAgentProducedArtifacts(recordID: rid, workingDirectory: workDir, since: startedAt)
            if case .completed(let reply) = result {
                registerAgentArtifactsFromReply(recordID: rid, reply: reply, since: startedAt)
            }
        }
        persistTaskExecutionRecords()
        return result
    }

    /// 按**影子 git delta** 登记产出物(新增→"新增"、修改→"修改";删除不登记)。归属唯一真相源:只认本次真改/新建的文件,
    /// 不再因 agent 在共享工作目录里碰过旧文件就误登(根治坦克文档串进超级玛丽任务,见 [[artifact-attribution-shadow-git]])。
    func registerArtifactsFromShadowDelta(recordID: String, changes: [LingShuShadowGit.FileChange]) {
        for c in changes where c.kind != .deleted && !LingShuShadowGit.isBuildOrCacheNoise(c.path) {
            appendTaskRecordArtifact(recordID, title: (c.path as NSString).lastPathComponent, location: c.path,
                                     producer: "agent产出", operation: c.kind == .added ? .created : .modified)
        }
    }

    /// 从 agent **输出文本**抽它声称写的文件路径,凡**存在且本次运行期间(mtime≥起跑)改动过**就补登产出物。
    /// 覆盖写到工作目录外绝对路径的产物(扫工作目录漏掉的);mtime 闸防止把 agent 只是**读过/提到**的旧文件误登。去重由 append 负责。
    func registerAgentArtifactsFromReply(recordID: String, reply: String, since: Date) {
        let fm = FileManager.default
        let cutoff = since.addingTimeInterval(-1)
        for p in Self.extractFilePaths(from: reply) where fm.fileExists(atPath: p) {
            guard let mtime = (try? fm.attributesOfItem(atPath: p)[.modificationDate]) as? Date, mtime >= cutoff else { continue }
            appendTaskRecordArtifact(recordID, title: (p as NSString).lastPathComponent, location: p, producer: "agent产出", operation: .created)
        }
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
