import Foundation

@MainActor
extension LingShuState {
    /// 主会话回合收尾(正常完成 / 重连续跑后完成共用):填回气泡 + 落记录 + 记忆。
    func finalizeMainTurn(result: LingShuAgentRunResult, bubbleID: UUID, recordID: String?, prompt: String, startedAt: Date) {
        if renderHumanInputBlockIfNeeded(result: result, bubbleID: bubbleID, recordID: recordID, prompt: prompt, startedAt: startedAt) {
            return
        }
        let rawText = Self.runResultText(result)
        // 收尾与历史气泡共用同一个展示清洗器。除了完整结构化 JSON，模型在协议尾部
        // 追加用时或中途截断时也能正确处理字符串里的转义引号，避免回复停在首个 \" 前。
        let visibleRawText = LingShuVisibleModelText.clean(rawText)
        let text = normalizeFinalVisibleInteractionText(visibleRawText, prompt: prompt, recordID: recordID)
        // 回复末尾加总用时(极简语音模式不加——会被 TTS 念出来,且那是纯对话)。记录/记忆仍存干净 text。
        let elapsed = Date().timeIntervalSince(startedAt)
        let displayText = isMinimalVoiceMode ? text : "\(text)\n\n⏱ 总用时 \(Self.formatElapsed(elapsed))"
        if let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            // 流式收尾:早读过则补念尾句 + 打去重标记(防根视图把整段再念一遍=双声线);没早读过则 no-op。
            concludeStreamedSpeech(for: bubbleID, streamedText: chatMessages[index].text)
            structuredStreamVisibilityFilters.removeValue(forKey: bubbleID)
            chatMessages[index].text = displayText
            chatMessages[index].isLoading = false
            chatMessages[index].taskRecordID = recordID
            if case .blocked = result { chatMessages[index].choices = LingShuChoiceParsing.parse(text) }
        }
        lingShuControlLog("agent: 回合完成 bubbleID=\(bubbleID.uuidString.prefix(8)) prompt「\(prompt.prefix(20))」→ reply「\(String(text.prefix(40)))」")
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "答复", kind: .result, text: text)
        appendTrace(kind: .result, actor: "Agent循环", title: "主会话答复", detail: String(text.prefix(60)))
        let record = taskExecutionRecords.first { $0.id == recordID }
        let outcome = record?.taskOutcome
        let fallback = Self.runResultFallbackStatus(for: result, record: record)
        let finalStatus = Self.finishStatus(for: outcome, fallback: fallback)
        finishTaskRecord(recordID, status: finalStatus, summary: text)
        if case .blocked = result { pendingMainQuestionRecordID = recordID } else { pendingMainQuestionRecordID = nil }
        // 未通过 Checker 的产物可以保留在任务记录中供返工，但不进入“最近已交付”记忆。
        if finalStatus.isSuccessfulCompletion {
            recordDeliverable(recordID: recordID, title: prompt, summary: text)
        }
        rememberMainThreadTurn(prompt: prompt, reply: text)
    }
}
