import Foundation

@MainActor
extension LingShuState {
    /// 给隔离子任务的一段执行打产物基线。外部 agent 已走 ShadowGit；本地隔离会话也必须同口径，
    /// 否则脚本静默生成的 docx/pptx/pdf 等不会经过 write_file，收尾清单就漏项。
    func prepareSubtaskArtifactDelta(subID: String, recordID: String?, workingDirectory: String? = nil) async {
        let dir = (workingDirectory ?? agentSubTaskWorkingDirectories[subID] ?? agentWorkingDirectory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return }
        agentSubTaskWorkingDirectories[subID] = dir
        if let recordID {
            agentSubTaskArtifactCountBaselines[subID] = currentArtifactCount(recordID)
        }
        let baseline = await Task.detached { LingShuShadowGit.baseline(workDir: dir) }.value
        if let baseline {
            agentSubTaskArtifactBaselines[subID] = baseline
        } else {
            agentSubTaskArtifactBaselines.removeValue(forKey: subID)
        }
    }

    /// 消费本段影子 git delta，把新增/修改文件登记到当前任务 record.artifacts。
    func registerSubtaskArtifactsFromGitDelta(subID: String) async {
        guard let recordID = agentSubTaskRecords[subID],
              let baseline = agentSubTaskArtifactBaselines.removeValue(forKey: subID) else { return }
        let changes = await Task.detached { LingShuShadowGit.delta(since: baseline) }.value
        registerArtifactsFromShadowDelta(recordID: recordID, changes: changes)
    }

    /// 取出本段执行前的产物数量，用于验收门判断“本轮是否真的有新产物”。
    func takeSubtaskArtifactCountBaseline(subID: String, recordID: String?) -> Int {
        if let value = agentSubTaskArtifactCountBaselines.removeValue(forKey: subID) { return value }
        return currentArtifactCount(recordID)
    }

    /// 包住一段 maker 续跑:续跑前打 shadow git 基线,续跑后登记本段新增/修改的真实文件。
    ///
    /// 首轮子任务会在派发前打基线,但验收返工/撞顶恢复是在同一隔离会话里继续 `resume`。
    /// 若返工轮才生成 docx/pptx/pdf 等二进制交付物,只登记首轮 delta 会漏进右侧产出物清单。
    /// 所以每一段续跑都要独立量一次 delta。
    func resumeSessionRegisteringArtifactDelta(
        _ session: any LingShuAgentSessioning,
        prompt: String,
        taskRecordID: String?
    ) async -> LingShuAgentRunResult {
        let workDir = artifactDeltaWorkingDirectory(for: taskRecordID)
        let startedAt = Date()
        let baseline = await Task.detached { LingShuShadowGit.baseline(workDir: workDir) }.value
        let result = await session.resume(prompt)
        guard let taskRecordID else { return result }
        if let baseline {
            let changes = await Task.detached { LingShuShadowGit.delta(since: baseline) }.value
            registerArtifactsFromShadowDelta(recordID: taskRecordID, changes: changes)
        } else {
            registerAgentProducedArtifacts(recordID: taskRecordID, workingDirectory: workDir, since: startedAt)
            if case .completed(let reply) = result {
                registerAgentArtifactsFromReply(recordID: taskRecordID, reply: reply, since: startedAt)
            }
        }
        return result
    }

    /// 启动/收尾兜底:把任务文本中明确提到、且真实存在于本任务可信目录内的文件补进产物清单。
    ///
    /// 主真相源仍是 shadow git delta；这只修复历史记录或极少数续跑边界漏登记。
    /// 为避免旧任务串台,不接受任意存在路径:必须位于任务工作目录、默认 Workspace,
    /// 或本任务已登记产物所在目录内。
    @discardableResult
    func reconcileTaskRecordArtifactsFromMentionedExistingFiles(recordID: String, producer: String = "任务收尾补登") -> Int {
        guard let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return 0 }
        let record = taskExecutionRecords[index]
        let allText = ([record.summary] + record.messages.map(\.text))
            .joined(separator: "\n")
        let trustedBases = trustedArtifactBaseDirectories(recordID: recordID, record: record)
        guard !trustedBases.isEmpty else { return 0 }

        // Absolute paths remain supported for compatibility. Privacy-safe delivery replies commonly expose
        // filenames only, so resolve those names against trusted task directories instead of requiring the
        // model to reveal a local absolute path. User-authored messages are deliberately excluded from this
        // second pass: requesting an old filename must not make that old file a new task artifact.
        let deliveredText = ([record.summary] + record.messages.filter { $0.kind != .user }.map(\.text))
            .joined(separator: "\n")
        let absolutePaths = LingShuLocalPathDetector.existingFilePaths(in: allText)
        let filenamePaths = existingTrustedFilesMentionedByName(in: deliveredText, trustedBases: trustedBases)
        let paths = uniquePaths(absolutePaths + filenamePaths)
        guard !paths.isEmpty else { return 0 }

        var knownCanonicalPaths = Set(record.artifacts.map { canonicalArtifactPath($0.location) })
        var added = 0
        for path in paths where shouldBackfillMentionedArtifact(path, trustedBases: trustedBases) {
            guard knownCanonicalPaths.insert(canonicalArtifactPath(path)).inserted else { continue }
            let before = taskExecutionRecords[index].artifacts.count
            taskExecutionRecords[index].appendArtifact(
                title: (path as NSString).lastPathComponent,
                location: path,
                producer: producer,
                operation: .created
            )
            if taskExecutionRecords[index].artifacts.count > before {
                added += 1
            }
        }
        return added
    }

    @discardableResult
    func reconcileAllTaskRecordArtifactsFromMentionedExistingFiles() -> Int {
        let ids = taskExecutionRecords.map(\.id)
        return ids.reduce(0) { total, id in
            total + reconcileTaskRecordArtifactsFromMentionedExistingFiles(recordID: id, producer: "历史补登")
        }
    }

    private func artifactDeltaWorkingDirectory(for recordID: String?) -> String {
        if let recordID,
           let subID = agentSubTaskRecords.first(where: { $0.value == recordID })?.key,
           let dir = agentSubTaskWorkingDirectories[subID]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return dir
        }
        let override = currentAgentWorkingDirectoryOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty { return override }
        return agentWorkingDirectory
    }

    private func trustedArtifactBaseDirectories(recordID: String, record: LingShuTaskExecutionRecord) -> [String] {
        var bases: [String] = []
        var seen = Set<String>()

        func addDirectory(_ path: String) {
            let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            var isDir = ObjCBool(false)
            if FileManager.default.fileExists(atPath: cleaned, isDirectory: &isDir), isDir.boolValue {
                let canonical = URL(fileURLWithPath: cleaned).resolvingSymlinksInPath().standardizedFileURL.path
                if seen.insert(canonical).inserted { bases.append(canonical) }
            }
        }

        // Existing artifacts provide the strongest record-specific location signal, especially during
        // launch-time repair after ephemeral subtask maps have been discarded.
        for artifact in record.artifacts where artifact.location.hasPrefix("/") {
            addDirectory((artifact.location as NSString).deletingLastPathComponent)
        }
        addDirectory(artifactDeltaWorkingDirectory(for: recordID))
        addDirectory(agentWorkingDirectory)
        addDirectory(Self.defaultWorkspaceDirectory)
        return bases
    }

    private func existingTrustedFilesMentionedByName(in text: String, trustedBases: [String]) -> [String] {
        guard !text.isEmpty else { return [] }
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        var paths: [String] = []
        var resolvedNames = Set<String>()

        for base in trustedBases {
            let baseURL = URL(fileURLWithPath: base, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files {
                let name = file.lastPathComponent
                guard !resolvedNames.contains(name),
                      text.range(of: name, options: .literal) != nil,
                      let values = try? file.resourceValues(forKeys: resourceKeys),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else { continue }
                // Keep the caller-visible path spelling (for example /var versus /private/var) so it
                // de-duplicates with artifacts already recorded by tools. The trust check below resolves
                // symlinks independently before comparing directory boundaries.
                let path = file.standardizedFileURL.path
                if shouldBackfillMentionedArtifact(path, trustedBases: trustedBases) {
                    paths.append(path)
                    resolvedNames.insert(name)
                }
            }
        }
        return uniquePaths(paths)
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert(canonicalArtifactPath($0)).inserted }
    }

    private func canonicalArtifactPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func shouldBackfillMentionedArtifact(_ path: String, trustedBases: [String]) -> Bool {
        guard !LingShuShadowGit.isBuildOrCacheNoise(path) else { return false }
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return false }
        let std = url.resolvingSymlinksInPath().standardizedFileURL.path
        return trustedBases.contains { base in
            let trusted = URL(fileURLWithPath: base).resolvingSymlinksInPath().standardizedFileURL.path
            return std == trusted || std.hasPrefix(trusted.hasSuffix("/") ? trusted : trusted + "/")
        }
    }
}
