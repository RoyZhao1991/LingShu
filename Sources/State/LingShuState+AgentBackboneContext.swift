import Foundation

@MainActor
extension LingShuState {
    /// 新回合边界:主会话是常驻的,历史上下文会自然存在;每一轮仍必须明确"这次只处理最新输入"。
    /// 这里不做关键词续接判断;“继续/下一步/回到某事”只能作为主脑结构化判断的输入证据,
    /// 不能在工具层直接抬升为历史任务或旧目标。
    nonisolated static func turnBoundaryGuidance(for prompt: String, base: String?) -> String {
        let trimmedBase = base?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = prompt
        let boundary = """
        【当前回合边界】
        只回答或处理下面这条最新输入。主会话上下文会自然存在:如果最新输入是在延续刚才的普通对话,就沿着最近上下文继续;如果最新输入是在要求续接某个旧任务、旧材料或未完成目标,必须由主脑基于完整上下文作出结构化续接决策。历史对话、旧任务、队列残留和自动召回内容只作背景参考;不要凭某个词直接续跑旧任务,不要把无关旧任务混进本轮答复。
        """
        return [trimmedBase, boundary]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    /// 当前正在"给人看/讲/答疑"时,把可见材料上下文显式放回本轮。
    /// 这是通用交互态,不绑定 PPT:任何预览中的文档、网页、表格、图片都应能支撑追问/翻页/继续。
    func currentVisibleInteractionGuidance(for prompt: String) -> String? {
        guard previewController.isPresented else { return nil }
        let title = previewController.title.isEmpty ? "当前材料" : previewController.title
        let page = previewController.displayedPageNumber
        let total = previewController.pageCount > 0 ? "\(previewController.pageCount)" : "连续页面"
        let mode = previewController.slideshow ? "全屏演示中" : "普通预览中"
        let isQuestion = LingShuInteractionFulfillment.isQuestionLike(prompt)
        let currentPageText: String
        if previewController.isHTML {
            currentPageText = "当前材料是网页/连续预览,需要时用 preview_document_text 或 preview_scroll 获取实际正文。"
        } else {
            currentPageText = previewController.pageText(max(0, page - 1))
        }
        let documentContext = visibleDocumentContextForGuidance(currentPage: page)
        let spoken = recentSpokenLines.suffix(4)
            .map { LingShuInteractionFulfillment.cleanSpokenLine($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return """
        【当前可视交互上下文】
        灵枢现在正打开材料「\(title)」,\(mode),当前第 \(page)/\(total) 页。用户此轮若在问"刚才/这页/继续/下一页/老师提问/答疑/收尾",默认就是围绕这个可视材料继续互动,不要重新生成材料、不要切到无关旧任务。
        \(isQuestion ? "本轮输入更像提问/答疑:最终回复必须直接回答用户的问题,先给结论,再用材料里的目标、流程、角色、证据或交付闭环说明理由;不要只复述当前页摘要,不要只写状态。" : "")
        \(currentPageText.isEmpty ? "" : "当前页可读内容:\n\(String(currentPageText.prefix(1200)))")
        \(documentContext.isEmpty ? "" : "当前材料可读内容摘录:\n\(documentContext)")
        \(spoken.isEmpty ? "" : "最近已经口头讲过:\n\(String(spoken.prefix(1200)))")

        交互铁律:
        - 答疑必须把**实质答案**写进最终回复;如果用 speak 朗读,聊天最终回复也要包含同一实质内容,不能只写"已完成答疑/等待后续问题"。
        - 继续演示/汇报时,保持同一上下文:preview_document_text 读实际内容,用 speak 讲,用 preview_next/preview_scroll 推进;需要占屏连续演示就进入/保持自主模式。
        - 收尾/退出时明确关闭预览或退出全屏,并用一句话确认。
        """
    }

    /// 给可视材料追问使用的轻量正文摘录。只提供事实上下文,不决定答案、不绑定文件类型或题材。
    func visibleDocumentContextForGuidance(currentPage: Int, maxPages: Int = 6, maxChars: Int = 2_800) -> String {
        guard !previewController.isHTML, previewController.pageCount > 0 else { return "" }
        let total = previewController.pageCount
        let currentIndex = min(max(currentPage - 1, 0), total - 1)
        var indices: [Int] = [currentIndex]
        for idx in 0..<total where indices.count < maxPages {
            if !indices.contains(idx) { indices.append(idx) }
        }
        indices.sort()

        var remaining = maxChars
        var parts: [String] = []
        for idx in indices where remaining > 0 {
            let text = previewController.pageText(idx)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let chunk = "第 \(idx + 1) 页:\n\(String(text.prefix(min(600, remaining))))"
            parts.append(chunk)
            remaining -= chunk.count
        }
        return parts.joined(separator: "\n---\n")
    }
}
