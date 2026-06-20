import Foundation

/// 朗读内容决策:任务型交付 vs 对话/汇报型,决定 TTS 念全文还是只念简短摘要。
/// 取向(按用户要求):任务型交付的回复又长又常中英混杂(路径/代码/英文),整段念出来又乱又长——
/// 只念一句简短摘要汇报即可;对话型/汇报型是干净中文正文,念全文。
@MainActor
extension LingShuState {

    /// 记录最近念出口的话(环形缓冲,封顶 40 条):供 MCP 核验"演示文字稿"是否对得上幻灯片内容。
    /// **演示时给每句标注【念这句时画面真实显示的页号】**(读 pdfView.currentPage,非 pageIndex 变量)——
    /// `lingshu_status.recentSpoken` 直接呈现"[屏显第6页] …第10页…",**语音报的页码 vs 真实画面页是否对齐一眼可见**
    /// (用户洞察:TTS 念的本质是文字,抓出来配真实页号即可客观判脱节,不用音频/肉眼)。
    func recordSpokenLine(_ text: String) {
        let line = previewController.isPresented ? "[屏显第\(previewController.displayedPageNumber)页] \(text)" : text
        recentSpokenLines.append(line)
        if recentSpokenLines.count > 40 { recentSpokenLines.removeFirst(recentSpokenLines.count - 40) }
    }

    /// 灵枢最近说/回复的若干句,供回声判定(语音输入若是这些的回声 → 丢弃,防自激循环)。
    func recentSpokenForEcho() -> [String] {
        var out = Array(recentSpokenLines.suffix(6))
        out += chatMessages.filter { !$0.isUser }.suffix(5).map { $0.text }
        return out
    }

    /// 网络中断/重连类提示的统一播报兜底(**写死,不调模型**):断网时根本调不动大模型来生成摘要,
    /// 旧逻辑会走 briefSpokenSummary→模型失败→回退"任务完成"(误报)。所有 🌐 开头的网络状态消息都念这一句。
    static let networkInterruptSpokenLine = "网络异常中断,我正在重试,网络恢复后会继续执行。"
    static let networkResumedSpokenLine = "网络已恢复,正在接着把任务跑完。"

    /// 是否网络状态提示(断网暂停 / 重试 / 重连续跑)。这类消息一律走写死播报,不调模型(断网时也调不动)。
    nonisolated static func isNetworkStatusNotice(_ text: String) -> Bool {
        text.hasPrefix("🌐") || text.hasPrefix("🔄") || text.contains("网络中断") || text.contains("网络异常")
    }

    /// 决定一条回复"该朗读什么":网络状态 → 写死兜底句(不调模型);任务型 → 简短口播摘要;对话/汇报型 → 全文。
    /// **铁律(用户要求 2026-06-19):任何回复都绝不念文件路径**——路径朗读出来又长又乱、毫无意义。
    func spokenReplyText(for message: ChatMessage) async -> String {
        // 断网/重连提示:写死播报,绝不调模型(没网调不动,且会误回退"任务完成")。
        if Self.isNetworkStatusNotice(message.text) {
            return message.text.hasPrefix("🔄") || message.text.contains("恢复")
                ? Self.networkResumedSpokenLine
                : Self.networkInterruptSpokenLine
        }
        // 先确定性剥掉文件路径(行 + 行内),所有回复都不念路径。
        let pathFree = Self.strippedOfFilePaths(message.text)
        // 带格式的内容(列表/编号/**/代码/表格)→ 念概要、不念格式(用户要求):前导散文 + "详情看屏幕",剥掉所有标记。
        guard isTaskDeliveryReply(message) else { return LingShuSpokenText.concise(pathFree) }   // 对话/汇报 → 概要化(已去路径)
        // 任务交付:去路径后若已足够简短,概要化后直接念;仍很长才走模型口播摘要。
        if pathFree.count <= 140 { return LingShuSpokenText.concise(pathFree) }
        return await briefSpokenSummary(for: message)
    }

    /// 朗读用:确定性剥掉绝对文件路径(整行是路径项→删行;行内夹路径→抹成空)。纯函数可单测。
    /// 路径=连续 ≥2 段 `/xxx` 且带扩展名,如 `/tmp/lingshu-p2-proj/Account.swift`、`/Users/.../a.pptx`。
    nonisolated static func strippedOfFilePaths(_ text: String) -> String {
        let pathPattern = "(/[\\w.~%+-]+){2,}\\.[A-Za-z0-9]{1,6}"
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        for line in lines {
            // 整行去掉路径后看剩什么。
            let withoutPaths = line.replacingOccurrences(of: pathPattern, with: "", options: [.regularExpression])
            // 这一行原本含路径,且去掉路径+列表符号/破折号后基本没剩有效内容 → 整行丢弃(纯路径条目)。
            let residue = withoutPaths
                .replacingOccurrences(of: "[`*\\-—:：()()\\s]", with: "", options: [.regularExpression])
            if line != withoutPaths && residue.isEmpty { continue }     // 纯路径行,删
            out.append(withoutPaths)                                    // 否则保留(行内路径已抹)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否"任务型交付"回复:**只按回复文本信号判**(纯函数,见下)。
    /// **不再看"记录里有没有产出物"(2026-06-19 修自主模式"对比回复没念出来")**:常驻在岗复用同一条记录、跨回合累积旧产出物
    /// (如之前做的那个 PPT),用它判会把**本回合的纯对话回复**(如"和豆包/Cursor 的区别")误判成任务交付 → 只念一句摘要 →
    /// 自主模式下主人看不到聊天框、又只听到摘要 = 既没看到也没听到。改为只认回复文本本身像不像交付(声称产文件/含代码/路径)。
    func isTaskDeliveryReply(_ message: ChatMessage) -> Bool {
        Self.replyLooksLikeTaskDelivery(message.text)
    }

    /// 纯文本信号判定"像任务交付报告"(可单测):声称产出文件 / 含代码块 / 含绝对文件路径。
    /// 这类回复长且常中英混杂(路径/代码),朗读全文又乱又长 → 只念摘要。
    nonisolated static func replyLooksLikeTaskDelivery(_ text: String) -> Bool {
        if replyClaimsArtifact(text) { return true }
        if text.contains("```") { return true }
        if text.range(of: "/[\\w./~-]+\\.(pptx|docx|xlsx|pdf|html?|md|csv|py|json|sh|swift|ts|js|go|rs|java|kt|c|cpp|h|rb|php|txt)",
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
