import Foundation

extension LingShuState {
    /// 问答线:删除一条**等待中(未执行)**的问答(连同它的问题与答复占位)。**执行中的那条不可删**(线性,删了会断流)。
    func deletePendingChatTurn(bubbleID: UUID) {
        guard pendingChatTurnIDs.contains(bubbleID), bubbleID != executingChatTurnID else { return }
        cancelledChatTurnIDs.insert(bubbleID)              // 轮到执行点会跳过(见 runMainAgentTurn)
        pendingChatTurnIDs.removeAll { $0 == bubbleID }
        // 删答复占位 + 它前面那条用户消息(整条问答删掉)。
        if let idx = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            let userIdx = (idx > 0 && chatMessages[idx - 1].isUser) ? idx - 1 : nil
            chatMessages.remove(at: idx)
            if let userIdx { chatMessages.remove(at: userIdx) }   // userIdx < idx,移除 idx 后仍有效
        }
        appendTrace(kind: .route, actor: "问答队列", title: "删除等待问答", detail: "用户删除一条尚未执行的问答。")
    }

    /// UI:这条答复气泡是否「等待中可删」(已排队问答 且 非执行中)。
    func canDeletePendingChatTurn(_ bubbleID: UUID) -> Bool {
        pendingChatTurnIDs.contains(bubbleID) && bubbleID != executingChatTurnID
    }
}
