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
        guard !page.messages.isEmpty else { return }

        chatMessages = page.messages + chatMessages
    }

    func restoreChatHistory() {
        isRestoringChatHistory = true
        defer { isRestoringChatHistory = false }

        let page = chatHistoryStore.loadInitialHistory()
        hasMoreColdChatHistory = page.hasMoreColdHistory
        if !page.messages.isEmpty {
            chatMessages = page.messages
        }
    }

    func persistChatHistoryIfNeeded() {
        guard !isRestoringChatHistory else { return }
        chatHistoryStore.save(chatMessages)
    }
}
