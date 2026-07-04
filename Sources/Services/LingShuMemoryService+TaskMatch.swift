import Foundation

/// 任务回溯的三层语义匹配（精确标签层 + 语义检索层 + 融合定置信度）。
/// 从 LingShuMemoryService 主文件拆出，保持单文件聚焦一类记忆职责。
extension LingShuMemoryService {

    /// 已废弃:裸"继续/下一步"不再由记忆层凭文本匹配任务。
    /// 调用方应让主脑结合最近上下文输出结构化续接决策。
    func ambiguousTaskResumeLookup(for prompt: String) -> LingShuTaskMemoryLookup? {
        guard LingShuMemoryTextToolkit.isAmbiguousTaskResumeRequest(prompt) else { return nil }

        let records = repository.loadTaskRecords()
            .filter(Self.isContinuableTaskRecord)
            .sorted { $0.updatedAt > $1.updatedAt }
        guard let first = records.first else { return nil }

        let candidates = records.prefix(3).map { record in
            LingShuTaskResumeCandidate(
                taskID: record.id,
                title: record.title,
                summary: record.summary,
                updatedAt: record.updatedAt,
                matchedBy: "未完成任务"
            )
        }
        let hasSingleCandidate = records.count == 1

        return .init(
            taskID: first.id,
            memoryStatus: hasSingleCandidate
                ? "模糊续接指令命中一个可继续任务：\(first.title)"
                : "模糊续接指令命中多个可继续任务，等待用户选择。",
            restored: hasSingleCandidate,
            hotMatch: hasSingleCandidate ? first : nil,
            coldMatch: nil,
            confidence: hasSingleCandidate ? .high : .medium,
            candidates: Array(candidates),
            explicitResume: true
        )
    }

    /// candidates 携带 top3 语义近似任务供用户挑选。
    func taskMemoryLookup(for prompt: String) -> LingShuTaskMemoryLookup {
        let tags = Set(LingShuMemoryTextToolkit.taskTags(from: prompt))
        let explicitResume = LingShuMemoryTextToolkit.isExplicitResumeRequest(prompt)
        let hotRecords = repository.loadTaskRecords()

        // ① 精确层：标签交集计数（不再"一个泛词重叠就续接"）。
        let bestExact = hotRecords
            .map { (record: $0, overlap: Set($0.tags).intersection(tags).count) }
            .filter { $0.overlap > 0 }
            .sorted {
                if $0.overlap == $1.overlap { return $0.record.updatedAt > $1.record.updatedAt }
                return $0.overlap > $1.overlap
            }
            .first

        // ② 语义层：语义库召回任务条目，经 task: 标签解析回 taskID。
        let semanticCandidates = semanticTaskCandidates(for: prompt, limit: 4)

        // ③ 融合定置信度。
        var confidence: LingShuTaskMatchConfidence = .none
        var hotMatch: TaskMemoryRecord?
        if let bestExact {
            let semanticAgrees = semanticCandidates.first?.taskID == bestExact.record.id
            if bestExact.overlap >= 2 || semanticAgrees {
                confidence = .high
                hotMatch = bestExact.record
            } else {
                confidence = .medium
                hotMatch = bestExact.record
            }
        } else if let top = semanticCandidates.first {
            // 仅语义命中：双路（全文+向量）一致视为高置信，单路必须确认。
            if top.matchedBy.contains("+"), let taskID = top.taskID,
               let record = hotRecords.first(where: { $0.id == taskID }) {
                confidence = .high
                hotMatch = record
            } else {
                confidence = .medium
            }
        }

        let coldMatch = (hotMatch == nil && confidence == .none)
            ? searchColdMemory(for: prompt, tags: tags, shouldSearch: !tags.isEmpty || LingShuMemoryTextToolkit.shouldRecallHistory(for: prompt))
                .first { $0.source == "执行线程" || $0.category.contains("任务执行") || $0.category.contains("能力协作") || $0.category.contains("软件工程") }
            : nil
        if coldMatch != nil && confidence == .none {
            confidence = .medium
        }

        // 候选列表：精确命中排前，语义近似补足，去重，最多 3 个。
        var candidates: [LingShuTaskResumeCandidate] = []
        if let hotMatch {
            candidates.append(.init(taskID: hotMatch.id, title: hotMatch.title, summary: hotMatch.summary, updatedAt: hotMatch.updatedAt, matchedBy: "关键字"))
        }
        for candidate in semanticCandidates where !candidates.contains(where: { $0.taskID == candidate.taskID && candidate.taskID != nil }) {
            candidates.append(candidate)
        }
        if let coldMatch {
            candidates.append(.init(taskID: nil, title: coldMatch.title, summary: coldMatch.summary, updatedAt: coldMatch.updatedAt, matchedBy: "冷备"))
        }
        candidates = Array(candidates.prefix(3))

        let resolvedHot = confidence == .high ? hotMatch : (confidence == .medium ? hotMatch : nil)
        let taskID = resolvedHot?.id ?? coldMatch.map { "task-\($0.id)" } ?? "task-\(Int(Date().timeIntervalSince1970))"
        let memoryStatus: String
        switch confidence {
        case .high:
            memoryStatus = "语义匹配高置信，续接：\(resolvedHot?.title ?? taskID)"
        case .medium:
            memoryStatus = "命中疑似历史任务（置信不足，待用户确认）：\(candidates.first?.title ?? "未知")"
        case .none:
            memoryStatus = explicitResume ? "明确回溯但未命中历史任务。" : "未命中历史任务，创建新任务线程。"
        }

        return .init(
            taskID: taskID,
            memoryStatus: memoryStatus,
            restored: confidence == .high,
            hotMatch: confidence == .high ? resolvedHot : nil,
            coldMatch: confidence == .high ? coldMatch : nil,
            confidence: confidence,
            candidates: candidates,
            explicitResume: explicitResume
        )
    }

    /// 有幽灵相似度），不足以触发用户确认；换措辞的召回靠 bigram 跨措辞命中，仍走全文路。
    private func semanticTaskCandidates(for prompt: String, limit: Int) -> [LingShuTaskResumeCandidate] {
        var seen = Set<String>()
        return semanticStore.recall(query: prompt, limit: 8)
            .filter { $0.entry.kind == "任务执行" && $0.matchedBy.contains("全文") }
            .compactMap { hit -> LingShuTaskResumeCandidate? in
                let taskID = hit.entry.tags.first(where: { $0.hasPrefix("task:") }).map { String($0.dropFirst(5)) }
                let dedupeKey = taskID ?? hit.entry.id
                guard seen.insert(dedupeKey).inserted else { return nil }
                return .init(
                    taskID: taskID,
                    title: hit.entry.title,
                    summary: String(hit.entry.content.prefix(120)),
                    updatedAt: hit.entry.updatedAt,
                    matchedBy: hit.matchedBy
                )
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func isContinuableTaskRecord(_ record: TaskMemoryRecord) -> Bool {
        let status = LingShuMemoryTextToolkit.normalize(record.status)
        let summary = LingShuMemoryTextToolkit.normalize(record.summary)
        let nextStepSignals = [
            "未完成", "没完成", "待", "下一步", "继续", "需要", "建议",
            "验证", "修复", "风险", "阻断", "排队", "进行中", "inprogress",
            "queued", "planned", "blocked", "todo"
        ]
        let hasNextStep = nextStepSignals.contains { summary.contains($0) || status.contains($0) }
        let finishedSignals = ["completed", "delivered", "answered", "done", "已完成", "已交付", "完成", "交付"]

        if finishedSignals.contains(where: { status.contains($0) }) {
            return hasNextStep
        }
        return true
    }
}
