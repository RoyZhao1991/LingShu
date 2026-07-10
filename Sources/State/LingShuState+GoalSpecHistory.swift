import Foundation

actor LingShuGoalSpecHistorySupportBox {
    private var lines: [String] = []

    func append(_ newLines: [String]) {
        lines.append(contentsOf: newLines)
    }

    func snapshot() -> [String] {
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }
}

struct LingShuGoalSpecHistorySearchResult {
    let text: String
    let supportLines: [String]
}

@MainActor
extension LingShuState {

    func goalSpecHistorySearchPayload(
        query rawQuery: String,
        scope rawScope: String,
        excludingCurrentRawPrompt rawPrompt: String,
        limit: Int
    ) -> LingShuGoalSpecHistorySearchResult {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = rawScope.isEmpty ? "all" : rawScope
        let includeKeyword = ["all", "search", "chat", "task"].contains(scope)
        let includeChat = ["all", "recent", "chat"].contains(scope)
        let includeTask = ["all", "task"].contains(scope)
        let includeMemory = ["all", "memory"].contains(scope)
        let formatter = ISO8601DateFormatter()
        var supportLines: [String] = []

        func clipped(_ text: String, maxLength: Int = 1200) -> String {
            let cleaned = LingShuState.compactForModelContext(text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count > maxLength else { return cleaned }
            return String(cleaned.prefix(maxLength)) + "…（节选）"
        }

        func addSupport(_ label: String, _ text: String) {
            let clean = clipped(text, maxLength: 1800)
            guard !clean.isEmpty else { return }
            supportLines.append("\(label): \(clean)")
        }

        func chatEntry(_ message: ChatMessage, source: String) -> [String: Any]? {
            let text = clipped(message.text)
            guard !text.isEmpty else { return nil }
            let role = message.isUser ? "user" : "assistant"
            addSupport("\(source) \(role)", text)
            var entry: [String: Any] = [
                "source": source,
                "role": role,
                "speaker": message.speaker,
                "text": text,
                "created_at": formatter.string(from: message.createdAt)
            ]
            if let taskRecordID = message.taskRecordID {
                entry["task_record_id"] = taskRecordID
            }
            if let names = message.attachmentNames, !names.isEmpty {
                entry["attachments"] = names
            }
            return entry
        }

        func taskEntry(_ record: LingShuTaskExecutionRecord, source: String) -> [String: Any] {
            let prompt = clipped(record.prompt, maxLength: 900)
            let summary = clipped(record.summary, maxLength: 900)
            let goal = clipped(record.goal, maxLength: 600)
            let timeline = record.messages.suffix(5).map { message -> [String: Any] in
                [
                    "actor": message.actor,
                    "role": message.role,
                    "kind": message.kind.rawValue,
                    "text": clipped(message.text, maxLength: 600)
                ]
            }
            addSupport("\(source) task prompt", prompt)
            addSupport("\(source) task summary", summary)
            if !goal.isEmpty { addSupport("\(source) task goal", goal) }
            for message in record.messages.suffix(5) {
                addSupport("\(source) task \(message.actor)/\(message.role)", message.text)
            }
            var entry: [String: Any] = [
                "source": source,
                "record_id": record.id,
                "title": record.title,
                "prompt": prompt,
                "status": record.status.rawValue,
                "summary": summary,
                "updated_at": formatter.string(from: record.updatedAt),
                "timeline": timeline
            ]
            if !goal.isEmpty { entry["goal"] = goal }
            if let goalSpec = record.goalSpec {
                entry["goal_spec_summary"] = goalSpec.summary
                addSupport("\(source) task goal_spec", goalSpec.summary)
            }
            if !record.artifacts.isEmpty {
                entry["artifacts"] = record.artifacts.prefix(5).map {
                    [
                        "title": $0.title,
                        "location": $0.location,
                        "producer": $0.producer
                    ]
                }
            }
            return entry
        }

        func memoryEntry(_ title: String, category: String, summary: String, tags: [String], source: String, updatedAt: Date) -> [String: Any] {
            let cleanSummary = clipped(summary, maxLength: 900)
            addSupport("\(source) memory \(title)", cleanSummary)
            return [
                "source": source,
                "title": title,
                "category": category,
                "summary": cleanSummary,
                "tags": tags,
                "updated_at": formatter.string(from: updatedAt)
            ]
        }

        var sections: [String: Any] = [:]
        var keywordHits: [LingShuHistorySearchHit] = []
        if includeKeyword, !query.isEmpty {
            keywordHits = searchConversationHistory(keyword: query, scope: .all, limit: limit)
            sections["keyword_hits"] = keywordHits.map { hit -> [String: Any] in
                addSupport("\(hit.source.label) hit \(hit.title)", hit.snippet)
                var entry: [String: Any] = [
                    "source": hit.source.label,
                    "title": hit.title,
                    "snippet": hit.snippet,
                    "score": hit.score,
                    "timestamp": formatter.string(from: hit.timestamp)
                ]
                if let recordID = hit.recordID { entry["record_id"] = recordID }
                if let messageID = hit.messageID { entry["message_id"] = messageID }
                return entry
            }
        }

        if includeChat {
            let hotRecent = activeTurnGoalSpecForegroundMessages(excludingCurrentRawPrompt: rawPrompt)
                .suffix(max(limit * 3, 12))
                .compactMap { chatEntry($0, source: "hot_chat_recent") }
            let hotIDs = Set(chatMessages.map(\.id))
            let coldRecent = chatHistoryStore.loadAllColdHistory()
                .filter { !hotIDs.contains($0.id) }
                .prefix(max(limit * 2, 8))
                .sorted { $0.createdAt < $1.createdAt }
                .compactMap { chatEntry($0, source: "cold_chat_recent") }
            sections["recent_conversation"] = hotRecent
            sections["cold_conversation"] = coldRecent
        }

        if includeTask {
            let archived = taskExecutionJournal.loadArchivedRecords()
            var seenRecords = Set<String>()
            let allRecords = (taskExecutionRecords + archivedTaskExecutionRecords + archived)
                .filter { seenRecords.insert($0.id).inserted }
                .sorted { $0.updatedAt > $1.updatedAt }
            var selected: [LingShuTaskExecutionRecord] = []
            let hitRecordIDs = keywordHits.compactMap(\.recordID)
            for id in hitRecordIDs {
                if let record = allRecords.first(where: { $0.id == id }),
                   !selected.contains(where: { $0.id == record.id }) {
                    selected.append(record)
                }
            }
            for record in allRecords where selected.count < limit {
                guard !selected.contains(where: { $0.id == record.id }) else { continue }
                selected.append(record)
            }
            sections["task_records"] = selected.prefix(limit).map { taskEntry($0, source: "task_history") }
        }

        if includeMemory {
            let memory = memoryService.prepareMainThreadMemory(for: query.isEmpty ? rawPrompt : query)
            let hot = memory.context.hotMatches.prefix(limit).map {
                memoryEntry($0.title, category: $0.category, summary: $0.summary, tags: $0.tags, source: "hot_main_memory", updatedAt: $0.updatedAt)
            }
            let cold = memory.context.coldMatches.prefix(limit).map {
                memoryEntry($0.title, category: $0.category, summary: $0.summary, tags: $0.tags, source: "cold_main_memory", updatedAt: $0.updatedAt)
            }
            sections["main_thread_memory"] = ["hot": Array(hot), "cold": Array(cold), "status": memory.context.status]
        }

        let payload: [String: Any] = [
            "type": "lingshu_goal_history_search_result",
            "query": query,
            "scope": scope,
            "limit_per_section": limit,
            "instruction": "Use these entries only as candidate evidence for GoalSpec reference resolution. Quote exact text from text/prompt/summary/snippet fields in reference_evidence.",
            "sections": sections
        ]
        let text: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let encoded = String(data: data, encoding: .utf8) {
            text = encoded
        } else {
            text = "历史检索结果编码失败。"
        }
        return LingShuGoalSpecHistorySearchResult(text: text, supportLines: supportLines)
    }
}
