import Foundation

struct LingShuPreparedMainThreadMemory {
    let context: MainThreadMemoryContext
    let mainMemoryStatus: String
    let coldMemoryStatus: String
    let traceTitle: String
    let traceDetail: String
}

/// 任务匹配置信度：高=直接续接；中=必须二次确认；无=按新任务。
enum LingShuTaskMatchConfidence: Equatable, Sendable {
    case high
    case medium
    case none
}

/// 可供用户挑选的续接候选（语义近似命中）。
struct LingShuTaskResumeCandidate: Equatable, Sendable {
    let taskID: String?
    let title: String
    let summary: String
    let updatedAt: Date
    let matchedBy: String
}

struct LingShuTaskMemoryLookup {
    let taskID: String
    let memoryStatus: String
    let restored: Bool
    let hotMatch: TaskMemoryRecord?
    let coldMatch: ColdMemoryRecord?
    var confidence: LingShuTaskMatchConfidence = .none
    var candidates: [LingShuTaskResumeCandidate] = []
    var explicitResume: Bool = false

    var traceTitle: String {
        hotMatch == nil && coldMatch == nil ? "创建线程" : "恢复记忆"
    }

    var traceDetail: String {
        hotMatch.map { "主线程判断无法直接处理，命中热执行记忆：\($0.summary)" }
            ?? coldMatch.map { "主线程判断无法直接处理，从冷备库恢复：\($0.summary)" }
            ?? "主线程判断无法直接处理，创建任务线程 \(taskID)。"
    }
}

struct LingShuExecutionMemoryHint {
    let text: String
    let runtimeMemoryStatus: String?
    let traceTitle: String
    let traceDetail: String
}

final class LingShuMemoryService {
    let repository: LingShuMemoryRepository
    /// 内嵌 RAG 语义库（SQLite + FTS5 + 本地句向量）：关键词标签匹配之外的
    /// 语义检索层，"上周让你查的那件事"这类指代靠它召回。
    let semanticStore: LingShuSemanticMemoryStore

    init(
        repository: LingShuMemoryRepository = LingShuMemoryRepository(),
        semanticStore: LingShuSemanticMemoryStore = LingShuSemanticMemoryStore()
    ) {
        self.repository = repository
        self.semanticStore = semanticStore
        semanticStore.warmUp()
    }

    func prepareMainThreadMemory(for prompt: String) -> LingShuPreparedMainThreadMemory {
        maintainMainThreadMemoryStore()

        let tags = Set(LingShuMemoryTextToolkit.mainMemoryTags(from: prompt))
        let continuity = LingShuMemoryTextToolkit.shouldRecallHistory(for: prompt)
        let hotRecords = repository.loadMainThreadRecords()
            .map { (record: $0, score: LingShuMemoryTextToolkit.memoryScore(prompt: prompt, tags: tags, recordTags: $0.tags, title: $0.title, summary: $0.summary)) }
            .filter { $0.score > 0 || continuity }
            .sorted {
                if $0.score == $1.score {
                    return $0.record.updatedAt > $1.record.updatedAt
                }
                return $0.score > $1.score
            }
            .prefix(3)
            .map { $0.record }

        let coldRecords = searchColdMemory(for: prompt, tags: tags, shouldSearch: continuity || !tags.isEmpty || hotRecords.isEmpty)
        let hotMatches = Array(hotRecords)
        let coldMatches = mergeSemanticMatches(
            into: coldRecords,
            prompt: prompt,
            existingTitles: Set(hotRecords.map(\.title) + coldRecords.map(\.title))
        )
        let shouldLoadHistory = !hotMatches.isEmpty || !coldMatches.isEmpty || continuity
        let status = LingShuMemoryTextToolkit.memoryStatusText(hotMatches: hotMatches, coldMatches: coldMatches, continuity: continuity)

        let context = MainThreadMemoryContext(
            hotMatches: hotMatches,
            coldMatches: coldMatches,
            shouldLoadHistory: shouldLoadHistory,
            status: status
        )

        return .init(
            context: context,
            mainMemoryStatus: hotMatches.first.map { "命中 \($0.title)" } ?? (continuity ? "热记忆无命中" : "本轮无需加载"),
            coldMemoryStatus: coldMatches.first.map { "命中 \($0.title)" } ?? "冷备无命中",
            traceTitle: shouldLoadHistory ? "记忆命中" : "轻量通过",
            traceDetail: status
        )
    }

    @discardableResult
    func rememberMainThreadTurn(
        prompt: String,
        reply: String,
        route: LingShuRoutePayload? = nil,
        isCapabilityCollaboration: Bool
    ) -> String? {
        guard shouldPersistMainThreadMemory(
            prompt: prompt,
            reply: reply,
            route: route,
            isCapabilityCollaboration: isCapabilityCollaboration
        ) else { return nil }

        let tags = LingShuMemoryTextToolkit.mainMemoryTags(from: "\(prompt)\n\(reply)")
        guard !tags.isEmpty else { return nil }

        let category = LingShuMemoryTextToolkit.classifyMainThreadMemory(prompt, isCapabilityCollaboration: isCapabilityCollaboration)
        let title = LingShuMemoryTextToolkit.shortMainMemoryTitle(from: prompt, category: category)
        var records = repository.loadMainThreadRecords()
        let now = Date()

        if let index = findMainThreadMemoryIndex(in: records, prompt: prompt, tags: tags, category: category) {
            records[index].title = title
            records[index].summary = LingShuMemoryTextToolkit.compressedMemorySummary(
                previous: records[index].summary,
                prompt: prompt,
                reply: reply,
                route: route
            )
            records[index].lastPrompt = prompt
            records[index].category = category
            records[index].tags = Array(Set(records[index].tags + tags)).sorted()
            records[index].messageCount += 1
            records[index].updatedAt = now
            if records[index].summary.count > 720 || records[index].messageCount % 6 == 0 {
                records[index].summary = compactSummaryText(records[index].summary, limit: 620)
                records[index].compressedAt = now
            }
        } else {
            records.insert(
                .init(
                    id: "main-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(6))",
                    title: title,
                    summary: LingShuMemoryTextToolkit.compressedMemorySummary(previous: "", prompt: prompt, reply: reply, route: route),
                    lastPrompt: prompt,
                    category: category,
                    tags: tags,
                    messageCount: 1,
                    createdAt: now,
                    updatedAt: now,
                    compressedAt: nil
                ),
                at: 0
            )
        }

        compactAndArchiveMainThreadRecords(&records)
        repository.saveMainThreadRecords(records)

        // 同步写入语义库：反思摘要而非原文，向量化后供跨会话语义召回。
        let summary = records.first(where: { $0.title == title })?.summary
            ?? LingShuMemoryTextToolkit.compressedMemorySummary(previous: "", prompt: prompt, reply: reply, route: route)
        semanticStore.remember(
            kind: category,
            title: title,
            content: summary,
            tags: tags,
            importance: (route?.needsAgents == true || isCapabilityCollaboration) ? 0.7 : 0.5
        )
        return title
    }

    /// 语义库召回并入冷备命中通道：来源标记「语义记忆」，标题去重，总量限 3。
    private func mergeSemanticMatches(
        into coldRecords: [ColdMemoryRecord],
        prompt: String,
        existingTitles: Set<String>
    ) -> [ColdMemoryRecord] {
        let semanticHits = semanticStore.recall(query: prompt, limit: 3)
            .filter { !existingTitles.contains($0.entry.title) }
            .map { hit in
                ColdMemoryRecord(
                    id: hit.entry.id,
                    source: "语义记忆",
                    title: hit.entry.title,
                    summary: hit.entry.content,
                    lastPrompt: "",
                    category: hit.entry.kind,
                    tags: hit.entry.tags,
                    archivedAt: hit.entry.updatedAt,
                    updatedAt: hit.entry.updatedAt
                )
            }
        return Array((coldRecords + semanticHits).prefix(3))
    }

    /// 任务回溯三层匹配：①关键字标签精确层 ②语义库检索层（全文+向量 RRF）③融合定置信度。
    /// 高置信直接续接；中置信由上层发选择卡二次确认；明确回溯但未精确命中时，

    /// 语义库里的任务召回：按 kind=任务执行过滤，从 task: 标签解析 taskID，按任务去重。
    /// 要求词面锚点（全文命中）——纯向量单路命中对本地向量模型不可靠（无关中文短句也会

    func executionMemoryHint(for prompt: String) -> LingShuExecutionMemoryHint {
        var records = repository.loadTaskRecords()
        compactAndArchiveTaskRecords(&records)
        repository.saveTaskRecords(records)

        let tags = Set(LingShuMemoryTextToolkit.taskTags(from: prompt))
        let hotMatches = records
            .map { (record: $0, score: LingShuMemoryTextToolkit.memoryScore(prompt: prompt, tags: tags, recordTags: $0.tags, title: $0.title, summary: $0.summary)) }
            .filter { $0.score > 0 || LingShuMemoryTextToolkit.shouldRecallHistory(for: prompt) }
            .sorted {
                if $0.score == $1.score {
                    return $0.record.updatedAt > $1.record.updatedAt
                }
                return $0.score > $1.score
            }
            .prefix(3)
            .map { $0.record }

        let coldMatches = searchColdMemory(for: prompt, tags: tags, shouldSearch: !tags.isEmpty || LingShuMemoryTextToolkit.shouldRecallHistory(for: prompt))
            .filter { $0.source == "执行线程" || $0.category.contains("任务执行") || $0.category.contains("软件工程") }
            .prefix(3)
            .map { $0 }

        if hotMatches.isEmpty && coldMatches.isEmpty {
            return .init(
                text: "未命中执行记忆；按新任务启动。",
                runtimeMemoryStatus: "执行记忆未命中，按新任务启动。",
                traceTitle: "未命中",
                traceDetail: "热执行记忆和冷备库均未命中，本轮按新任务启动。"
            )
        }

        let hotText = hotMatches.map { record in
            "- 热执行记忆：\(record.title)；状态：\(record.status)；标签：\(record.tags.joined(separator: "、"))；摘要：\(record.summary)"
        }.joined(separator: "\n")
        let coldText = coldMatches.map { record in
            "- 冷备执行记忆：\(record.title)；来源：\(record.source)；标签：\(record.tags.joined(separator: "、"))；摘要：\(record.summary)"
        }.joined(separator: "\n")
        let memoryText = [hotText, coldText].filter { !$0.isEmpty }.joined(separator: "\n")
        let runtimeMemoryStatus = hotMatches.first.map { "执行记忆命中：\($0.title)" }
            ?? coldMatches.first.map { "冷备命中：\($0.title)" }

        return .init(
            text: memoryText,
            runtimeMemoryStatus: runtimeMemoryStatus,
            traceTitle: "已加载",
            traceDetail: compactSummaryText(memoryText, limit: 420)
        )
    }

    func rememberTask(prompt: String, status: String, summary: String, taskID: String, taskRecordID: String? = nil) {
        let tags = LingShuMemoryTextToolkit.taskTags(from: prompt)
        guard !tags.isEmpty else { return }

        let clippedSummary = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
        let title = LingShuMemoryTextToolkit.shortTaskTitle(from: prompt)
        var records = repository.loadTaskRecords()
        let resolvedID = taskID.hasPrefix("task-") ? taskID : "task-\(Int(Date().timeIntervalSince1970))"

        if let index = records.firstIndex(where: { $0.id == resolvedID }) {
            records[index].title = title
            records[index].summary = clippedSummary
            records[index].lastPrompt = prompt
            records[index].status = status
            records[index].tags = tags
            if let taskRecordID {
                records[index].executionRecordID = taskRecordID
            }
            records[index].updatedAt = Date()
        } else {
            records.insert(
                .init(
                    id: resolvedID,
                    title: title,
                    summary: clippedSummary.isEmpty ? "本轮任务已完成。" : clippedSummary,
                    lastPrompt: prompt,
                    status: status,
                    tags: tags,
                    executionRecordID: taskRecordID,
                    updatedAt: Date()
                ),
                at: 0
            )
        }

        compactAndArchiveTaskRecords(&records)
        repository.saveTaskRecords(records)

        // task: 标签携带任务线程 ID——语义召回后才能找回对应任务续接。
        semanticStore.remember(
            kind: "任务执行",
            title: title,
            content: "状态：\(status)。\(clippedSummary.isEmpty ? "本轮任务已完成。" : clippedSummary)",
            tags: tags + ["task:\(resolvedID)"],
            importance: 0.6
        )
    }

    func normalizeMemoryText(_ text: String) -> String {
        LingShuMemoryTextToolkit.normalize(text)
    }

    func compactSummaryText(_ text: String, limit: Int) -> String {
        LingShuMemoryTextToolkit.compactSummary(text, limit: limit)
    }

    private func maintainMainThreadMemoryStore() {
        var records = repository.loadMainThreadRecords()
        compactAndArchiveMainThreadRecords(&records)
        repository.saveMainThreadRecords(records)
    }

    private func compactAndArchiveMainThreadRecords(_ records: inout [MainThreadMemoryRecord]) {
        let now = Date()
        for index in records.indices {
            if records[index].summary.count > 720 || records[index].messageCount >= 8 {
                records[index].summary = compactSummaryText(records[index].summary, limit: 620)
                records[index].compressedAt = now
            }
        }

        let cutoff = now.addingTimeInterval(-45 * 24 * 60 * 60)
        let sortedRecords = records.sorted { $0.updatedAt > $1.updatedAt }
        var hotRecords: [MainThreadMemoryRecord] = []
        var archived: [ColdMemoryRecord] = []

        for (index, record) in sortedRecords.enumerated() {
            if index >= 32 || record.updatedAt < cutoff {
                archived.append(
                    .init(
                        id: "cold-main-\(record.id)",
                        source: "主线程",
                        title: record.title,
                        summary: compactSummaryText(record.summary, limit: 620),
                        lastPrompt: record.lastPrompt,
                        category: record.category,
                        tags: record.tags,
                        archivedAt: now,
                        updatedAt: record.updatedAt
                    )
                )
            } else {
                hotRecords.append(record)
            }
        }

        records = hotRecords
        appendColdMemoryRecords(archived)
    }

    private func compactAndArchiveTaskRecords(_ records: inout [TaskMemoryRecord]) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-45 * 24 * 60 * 60)
        let sortedRecords = records.sorted { $0.updatedAt > $1.updatedAt }
        var hotRecords: [TaskMemoryRecord] = []
        var archived: [ColdMemoryRecord] = []

        for (index, record) in sortedRecords.enumerated() {
            if index >= 40 || record.updatedAt < cutoff {
                archived.append(
                    .init(
                        id: "cold-exec-\(record.id)",
                        source: "执行线程",
                        title: record.title,
                        summary: compactSummaryText(record.summary, limit: 620),
                        lastPrompt: record.lastPrompt,
                        category: "任务执行",
                        tags: record.tags,
                        archivedAt: now,
                        updatedAt: record.updatedAt
                    )
                )
            } else {
                var compacted = record
                if compacted.summary.count > 720 {
                    compacted.summary = compactSummaryText(compacted.summary, limit: 620)
                }
                hotRecords.append(compacted)
            }
        }

        records = hotRecords
        appendColdMemoryRecords(archived)
    }

    private func appendColdMemoryRecords(_ recordsToArchive: [ColdMemoryRecord]) {
        guard !recordsToArchive.isEmpty else { return }

        var records = repository.loadColdRecords()
        for record in recordsToArchive {
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else {
                records.append(record)
            }
        }

        records = records
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(240)
            .map { $0 }
        repository.saveColdRecords(records)
    }

    func searchColdMemory(for prompt: String, tags: Set<String>, shouldSearch: Bool) -> [ColdMemoryRecord] {
        guard shouldSearch else { return [] }

        return repository.loadColdRecords()
            .map { (record: $0, score: LingShuMemoryTextToolkit.memoryScore(prompt: prompt, tags: tags, recordTags: $0.tags, title: $0.title, summary: $0.summary)) }
            .filter { $0.score > 0 || LingShuMemoryTextToolkit.shouldRecallHistory(for: prompt) }
            .sorted {
                if $0.score == $1.score {
                    return $0.record.updatedAt > $1.record.updatedAt
                }
                return $0.score > $1.score
            }
            .prefix(3)
            .map { $0.record }
    }

    private func shouldPersistMainThreadMemory(
        prompt: String,
        reply: String,
        route: LingShuRoutePayload?,
        isCapabilityCollaboration: Bool
    ) -> Bool {
        if LingShuMemoryTextToolkit.isEphemeralLocalPrompt(prompt) && prompt.count <= 8 {
            return false
        }

        if route?.needsAgents == true || isCapabilityCollaboration {
            return true
        }

        return prompt.count >= 12 || reply.count >= 80 || LingShuMemoryTextToolkit.shouldRecallHistory(for: prompt)
    }

    private func findMainThreadMemoryIndex(in records: [MainThreadMemoryRecord], prompt: String, tags: [String], category: String) -> Int? {
        let tagSet = Set(tags)
        return records
            .enumerated()
            .map { (index: $0.offset, record: $0.element, score: LingShuMemoryTextToolkit.memoryScore(prompt: prompt, tags: tagSet, recordTags: $0.element.tags, title: $0.element.title, summary: $0.element.summary)) }
            .filter { $0.record.category == category && $0.score > 0 }
            .sorted {
                if $0.score == $1.score {
                    return $0.record.updatedAt > $1.record.updatedAt
                }
                return $0.score > $1.score
            }
            .first?
            .index
    }

}
