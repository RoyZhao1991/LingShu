import Foundation

/// 朗读内容决策:任务型交付 vs 对话/汇报型,决定 TTS 念全文还是只念简短摘要。
/// 取向(按用户要求):任务型交付的回复又长又常中英混杂(路径/代码/英文),整段念出来又乱又长——
/// 只念一句简短摘要汇报即可;对话型/汇报型是干净中文正文,念全文。
@MainActor
extension LingShuState {

    /// 决定一条回复"该朗读什么":任务型 → 简短口播摘要;对话/汇报型 → 全文。
    func spokenReplyText(for message: ChatMessage) async -> String {
        guard isTaskDeliveryReply(message) else { return message.text }   // 对话/汇报 → 全文
        return await briefSpokenSummary(for: message)                      // 任务型 → 简短摘要
    }

    /// 是否"任务型交付"回复:① 本回合记录真有产出物(需 state)② 文本信号(纯函数,见下)。
    func isTaskDeliveryReply(_ message: ChatMessage) -> Bool {
        if let id = message.taskRecordID,
           let record = taskExecutionRecords.first(where: { $0.id == id }),
           record.artifacts.contains(where: { FileManager.default.fileExists(atPath: $0.location) }) {
            return true
        }
        return Self.replyLooksLikeTaskDelivery(message.text)
    }

    /// 纯文本信号判定"像任务交付报告"(可单测):声称产出文件 / 含代码块 / 含绝对文件路径。
    /// 这类回复长且常中英混杂(路径/代码),朗读全文又乱又长 → 只念摘要。
    nonisolated static func replyLooksLikeTaskDelivery(_ text: String) -> Bool {
        if replyClaimsArtifact(text) { return true }
        if text.contains("```") { return true }
        if text.range(of: "/[\\w./~-]+\\.(pptx|docx|xlsx|pdf|html?|md|csv|py|json|sh)",
                      options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return false
    }

    /// 任务型交付 → 一句中文口播摘要(只说做完了什么/产出物大概是什么,不念路径/英文/代码)。失败回退兜底句。
    func briefSpokenSummary(for message: ChatMessage) async -> String {
        let prompt = """
        把下面的"任务交付报告"压成一句**中文口播摘要**(28 字内):只说做完了什么、产出物大概是什么,
        **不要念文件路径、英文、代码、长数字、文件体积**(那些朗读出来很乱)。直接给摘要,无前后缀。
        交付报告:
        \(message.text.prefix(1200))
        """
        let summarizer = LingShuAgentSession(
            id: "speak-\(UUID().uuidString.prefix(6))",
            system: "你是口播摘要器,只输出一句干净、适合朗读的中文摘要,不含路径/英文/代码。",
            tools: [],
            model: makeAgentModelAdapter(),
            maxTurns: 1
        )
        if case .completed(let text) = await summarizer.send(prompt) {
            let cleaned = LingShuReasoningText.stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return "任务完成,产出物已就绪,详情看文字。"
    }
}
