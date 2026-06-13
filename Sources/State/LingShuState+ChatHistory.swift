import Foundation

extension LingShuState {
    func loadOlderChatHistoryIfNeeded() {
        guard hasMoreColdChatHistory, !isRestoringChatHistory else { return }

        isRestoringChatHistory = true
        defer { isRestoringChatHistory = false }

        let existingIDs = Set(chatMessages.map(\.id))
        let page = chatHistoryStore.loadColdHistory(
            before: chatMessages.first,
            existingIDs: existingIDs
        )
        hasMoreColdChatHistory = page.hasMoreColdHistory
        persistedConversationDigest = page.contextDigest
        guard !page.messages.isEmpty else { return }

        chatMessages = page.messages + chatMessages
    }

    func restoreChatHistory() {
        isRestoringChatHistory = true
        defer { isRestoringChatHistory = false }

        let page = chatHistoryStore.loadInitialHistory()
        hasMoreColdChatHistory = page.hasMoreColdHistory
        persistedConversationDigest = page.contextDigest
        if !page.messages.isEmpty {
            chatMessages = page.messages
        }
    }

    /// 防抖持久化：流式输出会高频改写 chatMessages，这里合并 0.8 秒内的所有变更，
    /// 只触发一次后台保存。
    func persistChatHistoryIfNeeded() {
        guard !isRestoringChatHistory else { return }
        chatHistoryPersistTask?.cancel()
        chatHistoryPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled else { return }
            self.chatHistoryStore.save(self.chatMessages)
        }
    }

    /// 立即落盘当前对话，跳过防抖窗口。退出前调用。
    func flushChatHistory() {
        chatHistoryPersistTask?.cancel()
        chatHistoryPersistTask = nil
        chatHistoryStore.save(chatMessages)
        chatHistoryStore.flush()
    }
}
