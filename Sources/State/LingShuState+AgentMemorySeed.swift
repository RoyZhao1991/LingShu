import Foundation

/// 主会话**跨会话记忆 seed**子域(从 LingShuState+AgentBackbone.swift 拆出,保后者聚焦"骨干接线"+守 500 行架构闸)。
/// 记忆归一:跨会话只喂【蒸馏摘要】、不原样回放历史助手输出(断"旧错误自述被模仿"的 seed 污染);会话内当轮仍走 verbatim 上下文。
@MainActor
extension LingShuState {

    /// 记忆归一:跨会话只喂【蒸馏摘要】、不原样回放历史助手输出(断"旧错误自述被模仿"的 seed 污染);会话内当轮仍走 verbatim 上下文。
    func seededDistilledMemory() async -> [LingShuAgentMessage] {
        var seed: [LingShuAgentMessage] = []
        // 跨 app 重启:确保最近产出物从增量存储恢复到内存,主会话首轮即知悉(让重启后"运行起来"也接得上)。
        if recentDeliverables.isEmpty {
            let restored = await deliverableStore.all()
            if recentDeliverables.isEmpty { recentDeliverables = Array(restored.suffix(8)) }
        }
        let distilled = await distillConversationMemory()
        if !distilled.isEmpty {
            seed.append(.init(role: .system, content: "【跨会话记忆(已蒸馏,供延续上下文,不要逐条复述、不要照搬其中措辞)】\n\(distilled)"))
        }
        // 最近产出物上下文:主会话也知悉,"运行起来/继续"留主线程时同样接得上(跨重启从增量存储恢复)。
        let deliverCtx = recentDeliverablesContext()
        if !deliverCtx.isEmpty { seed.append(.init(role: .system, content: deliverCtx)) }
        seed.append(identityAnchorMessage())
        return seed
    }

    /// 身份锚点(最近性最强),压过任何历史里"由 MiniMax 开发"的旧错误自述。
    func identityAnchorMessage() -> LingShuAgentMessage {
        .init(role: .system, content: "身份提醒(最高优先级):你是灵枢,由 Roy Zhao 开发。你是**贾维斯式的通用私人助理**,不是编程工具——**遇到含糊、没给明确任务的输入,按通才接住**(出谋划策/查证研究/规划/操作设备/打理生活与工作),主动问清要达成什么或给个方向,**绝不缩回「你想让我写什么代码」**。**不提底层用什么模型**(可替换、与身份无关)。被问身份只答:'我是灵枢,由 Roy Zhao 打造。'")
    }

    /// 本地工作记忆闭环:显式“记住/记录”与紧随其后的“刚才说的 X 是什么”不必占用远端强脑。
    /// 这是主线程能力,不是领域模板:只处理明确记忆意图和明确短程召回,复杂历史检索仍交给 recall_memory/强脑。
    func localWorkingMemoryAnswer(for prompt: String) -> String? {
        if let fact = Self.explicitLocalMemoryFact(from: prompt) {
            rememberLocalWorkingFact(fact, prompt: prompt)
            return "已记录。"
        }
        return recallLocalWorkingFact(for: prompt)
    }

    /// 宿主侧确定性捷径只看用户真正说出的指令,不能把附件正文/系统拼接上下文当作用户意图。
    /// 例如"演示这个 PPT"随附的文档正文里可能出现"记录一下",那只是素材内容,不应触发本地记忆写入。
    nonisolated static func visibleUserInstructionForDeterministicRouting(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = ["\n\n用户指令：\n", "\n\n用户指令:\n"]
        for marker in markers {
            if let range = trimmed.range(of: marker, options: [.backwards]) {
                return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    func rememberLocalWorkingFact(_ fact: String, prompt: String) {
        let clean = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        localWorkingFacts.append(clean)
        if localWorkingFacts.count > 40 { localWorkingFacts.removeFirst(localWorkingFacts.count - 40) }
        let kind: LingShuMemoryNote.Kind = LingShuMemoryTextToolkit.normalize(prompt).contains("偏好") ? .preference : .fact
        _ = knowledgeGraph.remember(.init(
            kind: kind,
            title: Self.localMemoryTitle(for: clean),
            aliases: Self.localMemoryAliases(for: clean),
            body: clean,
            source: .userExplicit,
            confidence: 0.92
        ))
    }

    func recallLocalWorkingFact(for prompt: String) -> String? {
        let normalized = LingShuMemoryTextToolkit.normalize(prompt)
        guard ["刚才", "刚刚", "之前", "记得", "我说的"].contains(where: { normalized.contains($0) }) else { return nil }
        let sources = (localWorkingFacts.reversed() + chatMessages.reversed().compactMap { $0.isUser ? $0.text : nil })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sources.isEmpty else { return nil }

        if normalized.contains("代号"),
           let value = Self.valueAfterKeyword(in: sources, keyword: "代号") {
            return value
        }
        if let key = Self.recallKeyword(from: prompt),
           let value = Self.valueAfterKeyword(in: sources, keyword: key) {
            return value
        }
        if normalized.contains("记住什么") || normalized.contains("记录什么") || normalized.contains("说了什么") {
            return sources.first
        }
        return nil
    }

    nonisolated static func explicitLocalMemoryFact(from prompt: String) -> String? {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let prefixes = [
            "请你记住", "请帮我记住", "请记住", "帮我记住", "记住一个临时偏好", "记住一个偏好",
            "记住", "帮我记录一下", "请记录一下", "记录一下", "记一下", "保存一个偏好"
        ]
        let normalized = LingShuMemoryTextToolkit.normalize(text)
        let normalizedPrefixes = prefixes.map { LingShuMemoryTextToolkit.normalize($0) }
        guard normalizedPrefixes.contains(where: { normalized.hasPrefix($0) }) else { return nil }

        for prefix in prefixes where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        if let range = text.range(of: #"^[\s:：,，。-]+"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        let stopMarkers = ["只回复已记录", "回复已记录", "只回答已记录", "不用解释"]
        for marker in stopMarkers {
            if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while ["。", "，", ",", ".", "；", ";"].contains(String(text.last ?? "\0")) {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    nonisolated static func recallKeyword(from prompt: String) -> String? {
        let patterns = [
            #"我说的(.+?)是什么"#,
            #"刚才(.+?)是什么"#,
            #"之前(.+?)是什么"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = prompt as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let match = regex.firstMatch(in: prompt, range: range),
                  match.numberOfRanges > 1 else { continue }
            let value = ns.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "的", with: "")
                .replacingOccurrences(of: "刚才", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    nonisolated static func valueAfterKeyword(in texts: [String], keyword: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: keyword)
        let pattern = "\(escaped)\\s*(?:是|为|=|:|：)\\s*([^。\\n，,；;]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for text in texts {
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 {
                let value = ns.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            if text.contains(keyword) { return text }
        }
        return nil
    }

    nonisolated static func localMemoryTitle(for fact: String) -> String {
        if let code = valueAfterKeyword(in: [fact], keyword: "代号") {
            return "用户记忆：代号 \(String(code.prefix(24)))"
        }
        return "用户记忆：\(String(fact.prefix(32)))"
    }

    nonisolated static func localMemoryAliases(for fact: String) -> [String] {
        var aliases: [String] = []
        if fact.contains("代号") { aliases.append("代号") }
        if fact.contains("偏好") { aliases.append("偏好") }
        return aliases
    }

    /// 用模型把近期对话(含旧压缩摘要)蒸馏成简洁要点记忆——提炼而非复述,断开污染。
    func distillConversationMemory() async -> String {
        var lines: [String] = []
        let digest = persistedConversationDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !digest.isEmpty { lines.append("更早摘要:\(digest.prefix(600))") }
        let visibleHistory: ArraySlice<ChatMessage>
        if let answerID = executingChatTurnID,
           let answerIndex = chatMessages.firstIndex(where: { $0.id == answerID }) {
            // 当前答复气泡之前那条通常就是本轮用户输入。构造“跨会话记忆 seed”时不把本轮输入、
            // 更不把它后面排队的未来输入纳入摘要;当前请求会由 send() 单独追加。
            let cutoff = (answerIndex > 0 && chatMessages[answerIndex - 1].isUser) ? answerIndex - 1 : answerIndex
            visibleHistory = chatMessages.prefix(cutoff)
        } else {
            visibleHistory = chatMessages[...]
        }
        let queuedAnswerIDs = Set(pendingChatTurnIDs)
        let recent = visibleHistory
            .filter { !queuedAnswerIDs.contains($0.id) }
            .filter { !$0.isLoading && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(24)
        for message in recent {
            lines.append("\(message.isUser ? "用户" : "灵枢"):\(message.text.prefix(400))")
        }
        guard !lines.isEmpty else { return "" }
        let prompt = """
        把下面对话压成简洁"记忆"供后续会话延续(提炼要点、不要原样复述,150 字内):
        - 用户是谁 / 偏好 / 明确要求
        - 已完成的事(含产出物文件路径)
        - 未决 / 待办项
        - 已澄清的关键结论(如身份口径等)
        对话:
        \(lines.joined(separator: "\n"))
        """
        let summarizer = LingShuAgentSession(
            id: "distill-\(UUID().uuidString.prefix(6))",
            system: "你是记忆蒸馏器,只输出提炼后的要点摘要,不寒暄、不复述原文。",
            tools: [],
            model: makeAgentModelAdapter(),
            maxTurns: 1
        )
        let result = await summarizer.send(prompt)
        if case .completed(let text) = result {
            return LingShuReasoningText.stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}
