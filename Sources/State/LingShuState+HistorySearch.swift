import Foundation

extension LingShuState {
    func searchConversationHistory(
        keyword: String,
        scope: LingShuHistorySearchScope = .all,
        limit: Int = 80
    ) -> [LingShuHistorySearchHit] {
        let archivedRecords = mergeArchivedTaskRecords(
            archivedTaskExecutionRecords,
            taskExecutionJournal.loadArchivedRecords()
        )
        return LingShuConversationHistorySearch.search(
            keyword: keyword,
            scope: scope,
            hotChat: chatMessages,
            coldChat: chatHistoryStore.loadAllColdHistory(),
            hotTaskRecords: taskExecutionRecords,
            coldTaskRecords: archivedRecords,
            limit: limit
        )
    }

    private func mergeArchivedTaskRecords(
        _ current: [LingShuTaskExecutionRecord],
        _ latest: [LingShuTaskExecutionRecord]
    ) -> [LingShuTaskExecutionRecord] {
        var seen = Set<String>()
        return (current + latest)
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.id).inserted }
    }
}
