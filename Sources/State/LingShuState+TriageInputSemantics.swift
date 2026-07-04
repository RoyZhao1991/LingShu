import Foundation

@MainActor
extension LingShuState {
    /// 带附件输入默认是新的 grounded turn;只有用户明确说"这是给上一件事的补充/回答"时,
    /// 才允许跨过附件保护进入候选线程归属判断。这里判断的是会话指代,不是业务关键词。
    nonisolated static func attachmentInputExplicitlyContinuesPendingThread(_ raw: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(
            LingShuHumanInputEnvelope.userFacingText(from: raw)
        )
        guard !normalized.isEmpty else { return false }
        if normalized.contains("你要的") || normalized.contains("给你的") { return true }
        if ["上一条", "上一个", "上个任务", "之前的任务", "前面的任务", "这个任务", "这件事"].contains(where: { normalized.contains($0) }) {
            return true
        }
        let continuationVerb = ["继续", "补充", "回答", "回复"].contains { normalized.contains($0) }
        let oldContextRef = ["刚才那", "刚才的任务", "刚才的问题", "上面", "之前", "前面"].contains { normalized.contains($0) }
        return continuationVerb && oldContextRef
    }

    /// 本轮输入是否在引入外部证据/本机材料。即使附件托盘没有成功带出,这类输入也不应被上一条
    /// 无关的"缺授权/缺凭据"待答复线程吞掉。
    nonisolated static func inputMentionsGroundedEvidence(_ raw: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(
            LingShuHumanInputEnvelope.userFacingText(from: raw)
        )
        guard !normalized.isEmpty else { return false }
        return [
            "附件", "文件", "路径", "文档", "材料", "上传", "拖入",
            "图片", "截图", "表格", "pdf", "ppt", "pptx", "docx", "xlsx"
        ].contains { normalized.contains($0.lowercased()) }
    }

    /// 待答复问题是否明确要求用户用文件/附件/路径来回答。
    /// 用于所有待用户线程(主会话/自主/派发)的附件归属保护,避免"缺授权/缺凭据"把下一条带附件的新任务吞掉。
    nonisolated static func waitingQuestionAcceptsAttachment(_ raw: String) -> Bool {
        let visible = LingShuHumanInputEnvelope.userFacingText(from: raw)
        let normalized = LingShuMemoryTextToolkit.normalize(visible)
        guard !normalized.isEmpty else { return false }
        return inputMentionsGroundedEvidence(normalized)
    }

    /// 带附件/文件证据的输入是否可以被视为"回答上一条待答复问题"。
    /// 通用规则:
    /// - 用户显式说这是给上一条/这个任务/你要的材料 → 可以续旧线程。
    /// - 旧线程明确要求上传文件,且本轮只是纯提交附件(没有新的动作目标) → 可以续旧线程。
    /// - 用户围绕附件提出了新的动作目标(总结/分析/演示/修改/生成等) → 必须作为新 active turn,避免被无关 pending 问题吞掉。
    nonisolated static func groundedInputCanAnswerPendingQuestion(
        visiblePrompt rawVisiblePrompt: String,
        pendingQuestion rawPendingQuestion: String,
        hasAttachments: Bool
    ) -> Bool {
        guard hasAttachments else { return true }
        let visible = LingShuMemoryTextToolkit.normalize(
            LingShuHumanInputEnvelope.userFacingText(from: rawVisiblePrompt)
        )
        if attachmentInputExplicitlyContinuesPendingThread(visible) { return true }
        guard waitingQuestionAcceptsAttachment(rawPendingQuestion) else { return false }
        return isAttachmentOnlyResponse(visible)
    }

    /// 最新输入是否可以被视为"回答上一条待答复问题"。
    /// 这不是任务路由器,只是一道归属保护:旧 pending 只能接管真正像答案的输入;
    /// 新的完整目标必须回到主线程 active turn,由当前主脑重新理解、规划和调用工具。
    nonisolated static func inputCanAnswerPendingQuestion(
        visiblePrompt rawVisiblePrompt: String,
        pendingQuestion rawPendingQuestion: String,
        hasAttachments: Bool
    ) -> Bool {
        if hasAttachments {
            return groundedInputCanAnswerPendingQuestion(
                visiblePrompt: rawVisiblePrompt,
                pendingQuestion: rawPendingQuestion,
                hasAttachments: hasAttachments
            )
        }
        let visible = LingShuMemoryTextToolkit.normalize(
            LingShuHumanInputEnvelope.userFacingText(from: rawVisiblePrompt)
        )
        let pending = LingShuMemoryTextToolkit.normalize(
            LingShuHumanInputEnvelope.userFacingText(from: rawPendingQuestion)
        )
        guard !visible.isEmpty else { return false }
        if attachmentInputExplicitlyContinuesPendingThread(visible) { return true }
        if pendingRequestsProtectedUserInput(pending) {
            return userInputLooksLikeProtectedUserInputAnswer(visible)
        }
        if concisePendingAnswer(visible) { return true }
        if looksLikeStandaloneNewObjective(visible) { return false }
        return true
    }

    /// 待答复问题是否在等受保护前提:授权、凭据、登录、权限、付款、高风险确认等。
    nonisolated static func pendingRequestsProtectedUserInput(_ raw: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(raw)
        guard !normalized.isEmpty else { return false }
        let asksUser = ["需要你", "请你", "等你", "提供", "授权", "确认", "选择", "输入", "登录", "凭据"].contains { normalized.contains($0) }
        return asksUser && LingShuHumanBoundarySemantics.containsConcreteProtectedBoundary(normalized)
    }

    /// 用户这句话是否像在回答受保护前提,而不是开启一个新目标。
    nonisolated static func userInputLooksLikeProtectedUserInputAnswer(_ raw: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(raw)
        guard !normalized.isEmpty else { return false }
        if looksLikeStandaloneNewObjective(normalized) { return false }
        let answerSignals = [
            "同意", "允许", "授权", "确认", "可以", "继续", "已登录", "已授权", "给你", "这是",
            "token", "api key", "apikey", "凭据", "账号", "密码", "拒绝", "不同意", "不授权",
            "暂不", "取消", "换方案", "替代方案"
        ]
        if answerSignals.contains(where: { normalized.contains($0) }) { return true }
        return normalized.count <= 16 && !looksLikeStandaloneNewObjective(normalized)
    }

    /// 短答通常是回答上一条问题。较长的完整目标继续交给独立目标判断。
    nonisolated static func concisePendingAnswer(_ raw: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(raw)
        guard !normalized.isEmpty else { return false }
        if normalized.count <= 18 { return true }
        let shortOptionPrefixes = ["第一个", "第二个", "第三个", "方案一", "方案二", "方案三", "选一", "选二", "选三"]
        return normalized.count <= 40 && shortOptionPrefixes.contains { normalized.contains($0) }
    }

    /// 判断一条输入是否像新的完整目标。这里不把它派给任何固定能力,只用于避免旧 pending 错接。
    nonisolated static func looksLikeStandaloneNewObjective(_ raw: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(raw)
        guard !normalized.isEmpty else { return false }
        if normalized.contains("?") || normalized.contains("？") { return true }
        let objectiveSignals = [
            "帮我", "给我", "看看", "查一下", "查找", "搜索", "扫描", "发现", "分类",
            "总结", "分析", "介绍", "讲解", "解释", "说明", "演示", "预览",
            "生成", "制作", "创建", "写", "修改", "修复", "运行", "测试",
            "打开", "关闭", "同步", "读取", "提取", "翻译", "对比", "计算",
            "回答", "回复", "说"
        ]
        let hasObjectiveSignal = objectiveSignals.contains { normalized.contains($0) }
        let hasConstraint = ["只做", "不要", "必须", "最后", "并且", "然后", "告诉我", "返回"].contains { normalized.contains($0) }
        return hasObjectiveSignal && (normalized.count > 18 || hasConstraint)
    }

    /// "只是在交材料"的可见输入。它不是业务关键词路由,只用于判断是否可把附件视为上一条问题的答案。
    nonisolated static func isAttachmentOnlyResponse(_ raw: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(
            LingShuHumanInputEnvelope.userFacingText(from: raw)
        )
        guard !normalized.isEmpty else { return true }
        let stripped = normalized
            .replacingOccurrences(of: "已上传", with: "")
            .replacingOccurrences(of: "上传了", with: "")
            .replacingOccurrences(of: "个文件", with: "")
            .replacingOccurrences(of: "文件", with: "")
            .replacingOccurrences(of: "附件", with: "")
            .replacingOccurrences(of: "请按上述落地交付", with: "")
            .replacingOccurrences(of: "请按上述文件落地交付", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return true }
        let actionVerbs = [
            "总结", "分析", "介绍", "讲解", "演示", "预览", "修改", "生成", "制作", "创建",
            "写", "整理", "提取", "翻译", "对比", "检查", "查找", "回答", "说明"
        ]
        return !actionVerbs.contains { stripped.contains($0) }
    }

    private struct ContextResolverRoutePayload: Decodable {
        let route: String
        let thread: String?
        let confidence: String?
    }

    /// 解析大脑自报的置信度(没报/未知 → medium 中性)。
    nonisolated static func parseConfidence(_ raw: String?) -> DispatchConfidence {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high": return .high
        case "low": return .low
        default: return .medium
        }
    }

    /// 兼容旧测试入口:只接受完整 JSON 对象,禁止从普通文本里"捞字段"。
    nonisolated static func parseConfidence(_ norm: String) -> DispatchConfidence {
        guard let data = norm.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ContextResolverRoutePayload.self, from: data) else {
            return .medium
        }
        return parseConfidence(payload.confidence)
    }

    private nonisolated static func decodeContextResolverPayload(_ raw: String) -> ContextResolverRoutePayload? {
        let text = LingShuReasoningText.stripThinkTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"), text.hasSuffix("}"), let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ContextResolverRoutePayload.self, from: data)
    }

    /// 解析上下文归属模型输出。只接受完整 JSON + high confidence + 合法候选线程;其它全部回到主脑。
    nonisolated static func parseContextResolverDecision(_ raw: String, threads: [TriageThread]) -> DispatchDecision {
        guard let payload = decodeContextResolverPayload(raw) else {
            return DispatchDecision(kind: .chat, goal: nil, replyRecordID: nil, confidence: .medium)
        }
        let confidence = parseConfidence(payload.confidence)
        guard payload.route.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "reply",
              confidence == .high else {
            return DispatchDecision(kind: .chat, goal: nil, replyRecordID: nil, confidence: confidence)
        }
        let label = (payload.thread ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let thread = threads.first(where: { $0.label.uppercased() == label }) else {
            return DispatchDecision(kind: .chat, goal: nil, replyRecordID: nil, confidence: .low)
        }
        return DispatchDecision(kind: .reply, goal: nil, replyRecordID: thread.recordID, confidence: .high)
    }
}
