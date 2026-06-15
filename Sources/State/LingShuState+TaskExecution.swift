import Foundation

@MainActor
extension LingShuState {
    func openTaskRecord(_ recordID: String?) {
        guard let recordID, taskExecutionRecordLookup.contains(where: { $0.id == recordID }) else { return }
        selectedTaskRecordID = recordID
        isTaskRecordPresented = true
    }

    func createTaskExecutionRecord(for prompt: String) -> String {
        let record = LingShuTaskExecutionRecord.create(prompt: prompt)
        taskExecutionJournal.upsert(record, into: &taskExecutionRecords)
        persistTaskExecutionRecords()
        return record.id
    }

    func appendTaskRecordMessage(
        _ recordID: String?,
        actor: String,
        role: String,
        kind: LingShuTaskExecutionMessageKind,
        text: String,
        detail: LingShuTaskExecutionDetail? = nil
    ) {
        guard let recordID,
              let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }

        // 净化(剥模型名泄露 + 裸 tool_calls JSON)走独立模块 LingShuTaskMessageFormatting。
        taskExecutionRecords[index].append(actor: actor, role: role, kind: kind, text: LingShuTaskMessageFormatting.sanitize(text), detail: detail)
        persistTaskExecutionRecords()
    }

    func appendTaskRecordArtifact(
        _ recordID: String?,
        title: String,
        location: String,
        producer: String,
        operation: LingShuArtifactOperation? = nil
    ) {
        guard let recordID,
              let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }

        taskExecutionRecords[index].appendArtifact(title: title, location: location, producer: producer, operation: operation)
        persistTaskExecutionRecords()
    }

    @discardableResult
    func applyTaskRecordRoute(_ recordID: String?, route: CodexRoutePayload) {
        guard let recordID,
              let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }

        let agentNames = route.agents.map(\.agent)
        let summary = route.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        taskExecutionRecords[index].applyRoute(
            needsAgents: route.needsAgents,
            agents: agentNames,
            summary: summary
        )
        persistTaskExecutionRecords()
    }

    func finishTaskRecord(
        _ recordID: String?,
        status: LingShuTaskExecutionStatus,
        summary: String
    ) {
        guard let recordID,
              let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }

        taskExecutionRecords[index].finish(status: status, summary: summary)
        persistTaskExecutionRecords()
        if status == .answered || status == .completed || status == .blocked {
            markTaskSegmentFinished(recordID: recordID, blocked: status == .blocked)
            captureCodeChanges(recordID: recordID)   // 代码任务:抓分支+未提交改动文件,落进记录供右侧面板展示
            DispatchQueue.main.async { [weak self] in
                self?.startNextQueuedTaskIfAvailable()
            }
            // 任务收尾 → 触发 dreaming 离线固化(内部有空闲守卫 + 1h 节流,不打扰当前流程)。
            scheduleDreamingConsolidationIfIdle()
        }
    }

    /// 抓**本任务自己改动**的代码文件(分支 + 未提交文件),落进记录——代码交付的右侧信息块。
    /// 关键:只看本任务 `artifacts` 里的源码文件,**不扫整库**(否则问个时间也列出仓库里一堆历史脏文件)。
    /// 非代码任务(无源码产出物)/ 工作目录非 git 仓 / 本任务文件都已提交 → nil,面板不显示该模块。
    func captureCodeChanges(recordID: String) {
        guard let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let workingDir = codexWorkingDirectory
        // 本任务真正产出/改动的**源码/配置/文档**文件(交付物/素材归"产出物"面板,不算代码改动)。
        let taskCodePaths = taskExecutionRecords[idx].artifacts
            .map(\.location)
            .filter { Self.isCodeLikePath($0) }
        guard !taskCodePaths.isEmpty else { return }   // 非代码任务 → 不抓、不显示(治"问时间也有代码改动")
        Task { @MainActor [weak self] in
            guard let summary = await Self.gitChangeSummary(workingDir: workingDir, limitTo: taskCodePaths) else { return }
            guard let self, let i = self.taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
            self.taskExecutionRecords[i].codeChanges = summary
            self.persistTaskExecutionRecords()
        }
    }

    /// 是否源码/配置/文档类路径(用于把交付物/素材排除在"代码改动"之外)。
    nonisolated static func isCodeLikePath(_ path: String) -> Bool {
        let excludedExts: Set<String> = ["pptx", "potx", "ppt", "jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff",
                                         "pdf", "wav", "mp3", "m4a", "mp4", "mov", "zip", "tar", "gz", "key", "numbers"]
        let ext = (path as NSString).pathExtension.lowercased()
        if excludedExts.contains(ext) { return false }
        if path.contains("/assets/") { return false }
        return true
    }

    /// 候选 git 路径(GUI 应用经 launchd 启动,PATH 极简;/usr/bin/git 是依赖 xcode-select 的 shim,
    /// 在精简环境下可能解析不到真 git → 命令行工具 / Homebrew 真二进制兜底)。
    nonisolated static func gitCandidatePaths() -> [String] {
        ["/usr/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
         "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 跑 git 取分支 + porcelain,**只保留本任务 `limitTo` 的文件**中仍未提交的(已提交的不在 porcelain 里→不计)。
    /// 逐个候选 git 探测,直到某个真的回出仓库判定(绕过失效的 /usr/bin/git shim)。非仓/本任务文件全已提交 → nil。
    nonisolated static func gitChangeSummary(workingDir: String, limitTo taskPaths: [String]) async -> LingShuCodeChangeSummary? {
        var git: String?
        for candidate in gitCandidatePaths() {
            let inside = await runCapturing(candidate, ["-C", workingDir, "rev-parse", "--is-inside-work-tree"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if inside == "true" { git = candidate; break }
            if inside == "false" { return nil }   // 非 git 仓
            // 空输出=该 git 没跑成(shim 失效),试下一个候选
        }
        guard let git else { lingShuControlLog("codeChanges: 所有 git 候选都没跑成"); return nil }
        let topLevel = await runCapturing(git, ["-C", workingDir, "rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topLevel.isEmpty else { return nil }
        let porcelain = await runCapturing(git, ["-C", workingDir, "status", "--porcelain"])
        let allDirty = parseGitPorcelain(porcelain)
        // 只留本任务自己的文件(把 porcelain 的仓库相对路径还原成绝对路径,与 taskPaths 求交)。
        let taskAbs = Set(taskPaths.map { ($0 as NSString).standardizingPath })
        let mine = allDirty.filter { change in
            let abs = (topLevel as NSString).appendingPathComponent(change.path)
            return taskAbs.contains((abs as NSString).standardizingPath)
        }
        guard !mine.isEmpty else { return nil }   // 本任务文件都已提交/干净 → 不显示
        let branch = await runCapturing(git, ["-C", workingDir, "branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let repoName = (topLevel as NSString).lastPathComponent
        lingShuControlLog("codeChanges: 本任务 \(mine.count) 个未提交改动 @\(repoName)/\(branch)")
        return .init(repoName: repoName.isEmpty ? "repo" : repoName,
                     branch: branch.isEmpty ? "(detached HEAD)" : branch,
                     files: Array(mine.prefix(60)))
    }

    /// 解析 `git status --porcelain` 为代码改动文件(纯函数,可测)。
    /// 只留**源码/配置/文档**;交付物/二进制素材(pptx/图片/pdf/音频/压缩包 及 assets 目录)归产出文件面板,不进代码块。
    nonisolated static func parseGitPorcelain(_ porcelain: String) -> [LingShuCodeChangeSummary.Change] {
        let excludedExts: Set<String> = ["pptx", "potx", "ppt", "jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff",
                                         "pdf", "wav", "mp3", "m4a", "mp4", "mov", "zip", "tar", "gz", "key", "numbers"]
        return porcelain
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let s = String(line)
                guard s.count > 3 else { return nil }
                let code = String(s.prefix(2)).trimmingCharacters(in: .whitespaces)
                var path = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))   // git 给含特殊字符的路径加引号
                if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }   // 重命名取新名
                guard !path.isEmpty else { return nil }
                let ext = (path as NSString).pathExtension.lowercased()
                if excludedExts.contains(ext) { return nil }
                if path.hasPrefix("assets/") || path.contains("/assets/") { return nil }
                return .init(status: code, path: path)
            }
    }

    func markTaskSegmentFinished(recordID: String?, blocked: Bool = false) {
        guard let recordID else { return }
        for index in taskThreads.indices {
            taskThreads[index].complete(recordID: recordID, blocked: blocked)
        }
        trimDormantTaskThreads()
    }

    func startNextQueuedTaskIfAvailable(preferredThreadID: String? = nil) {
        let candidateIndex: Int?
        if let preferredThreadID,
           let preferredIndex = taskThreads.firstIndex(where: { $0.id == preferredThreadID && !$0.hasRunningSegment && $0.hasQueuedSegments }) {
            candidateIndex = preferredIndex
        } else {
            candidateIndex = taskThreads.firstIndex(where: { !$0.hasRunningSegment && $0.hasQueuedSegments })
        }

        guard let index = candidateIndex,
              let segment = taskThreads[index].popNextWaitingSegment() else { return }

        let threadID = taskThreads[index].id
        activeTaskThread = taskThreads[index]
        appendTaskRecordMessage(segment.recordID, actor: "任务队列", role: "顺序执行", kind: .router, text: "前序段已完成，现在开始处理该任务线程的下一段。")
        chatMessages.append(.init(speaker: "灵枢", text: "轮到任务队列的下一段了，我继续处理。", isUser: false, taskRecordID: segment.recordID))
        _ = submitTextInput(
            segment.prompt,
            source: .plugin("任务队列"),
            existingTaskRecordID: segment.recordID,
            appendUserMessage: false,
            bypassActiveGate: true,
            forcedThreadID: threadID
        )
    }

    func trimDormantTaskThreads() {
        if taskThreads.count > 24 {
            taskThreads.removeLast(taskThreads.count - 24)
        }
    }

    func persistTaskExecutionRecords() {
        let saved = taskExecutionJournal.saveRecords(taskExecutionRecords)
        if taskExecutionRecords != saved.active {
            taskExecutionRecords = saved.active
        }
        if archivedTaskExecutionRecords != saved.archived {
            archivedTaskExecutionRecords = saved.archived
        }
    }

    func formatElapsed(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }

    /// 任务窗口「Git 工具」侧栏的提交动作:把**本任务自己**改动的文件提交到其所在仓。
    /// 只暂存 codeChanges 里列出的(本任务)文件,生成带任务标题的提交信息;成功后刷新 codeChanges(已提交的不再列出)。
    /// 用户点击触发、只动本任务文件、可 `git reset` 还原——本地可逆动作,不预先弹确认。
    func commitTaskCodeChanges(recordID: String) {
        guard let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }),
              let code = taskExecutionRecords[idx].codeChanges, !code.files.isEmpty else { return }
        let workingDir = codexWorkingDirectory
        let relPaths = code.files.map(\.path)
        let title = taskExecutionRecords[idx].title.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "灵枢:\(title.isEmpty ? "任务改动" : title)"
        appendTaskRecordMessage(recordID, actor: "Git", role: "提交", kind: .router, text: "正在提交本任务的 \(relPaths.count) 个改动…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await Self.gitCommit(workingDir: workingDir, files: relPaths, message: message)
            self.appendTaskRecordMessage(
                recordID, actor: "Git", role: "提交", kind: ok ? .result : .warning,
                text: ok ? "已提交 \(relPaths.count) 个改动:\(message)" : "提交失败——可在终端手动 `git commit`(见控制台日志)。"
            )
            if ok { self.captureCodeChanges(recordID: recordID) }   // 重扫:已提交的从 porcelain 消失 → 面板更新
        }
    }

    /// 在 `workingDir` 所在仓暂存并提交指定(仓库相对路径)文件。成功返回 true。
    nonisolated static func gitCommit(workingDir: String, files: [String], message: String) async -> Bool {
        guard !files.isEmpty, let git = await resolveGit(workingDir: workingDir) else { return false }
        let topLevel = await runCapturing(git, ["-C", workingDir, "rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topLevel.isEmpty else { return false }
        _ = await runCapturing(git, ["-C", topLevel, "add", "--"] + files)
        let commitOut = await runCapturing(git, ["-C", topLevel, "commit", "-m", message])
        if commitOut.contains("nothing to commit") { return false }
        // 验证:这些文件应已从未提交清单消失。
        let after = parseGitPorcelain(await runCapturing(git, ["-C", topLevel, "status", "--porcelain"])).map(\.path)
        let committed = !files.contains { after.contains($0) }
        lingShuControlLog("gitCommit: \(committed ? "已提交" : "未生效") \(files.count) 文件 @\(topLevel)")
        return committed
    }

    /// 在候选 git 里找出能判定 `workingDir` 是工作树的那个(绕过失效的 /usr/bin/git shim);非仓返回 nil。
    nonisolated static func resolveGit(workingDir: String) async -> String? {
        for candidate in gitCandidatePaths() {
            let inside = await runCapturing(candidate, ["-C", workingDir, "rev-parse", "--is-inside-work-tree"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if inside == "true" { return candidate }
            if inside == "false" { return nil }
        }
        return nil
    }
}
