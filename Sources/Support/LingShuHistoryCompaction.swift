import Foundation

/// 差距4·**上下文压缩可替换模块**(token 预算 + 分层保留 + 知识图谱无损召回)。
///
/// 设计取向(协议 + 多实现 + 单一切换点):把"历史超预算如何压缩"抽成协议。
/// - 默认 `LingShuMessageCountCompactor` = 经典按消息条数触发整段蒸馏(原行为,零变更兜底)。
/// - 超越 `LingShuLayeredCompactor` = **按 token 预算**触发、**分层保留**(系统/seed 永留 + 最近 N token 逐字 +
///   中段蒸馏 + 不切出孤儿 tool 结果),并把丢弃段的关键事实抽出来交上层 `remember` 进知识图谱 →
///   需要细节时 `recall` 拉回 = **近无损压缩**(CC 的压缩是有损的,这是超越点)。
/// 将来有更好的压缩策略(语义聚类/重要性打分)直接换实现,核心循环不动。纯逻辑、可单测。

/// 压缩结果:新消息序列 + 从丢弃段抽出的"可记忆事实"(交上层写进知识图谱,核心循环不直接依赖 Memory)。
struct LingShuCompactionResult: Sendable {
    let messages: [LingShuAgentMessage]
    /// 丢弃段的关键事实(决策/产出物绝对路径/已确认信息/约束)。上层 factSink 负责 remember。空=无可记。
    let extractedFacts: [String]
}

/// 压缩器对外声明的"容量契约":循环不变量 I6 据此**按实际策略**校验压缩后历史是否在预算内
/// (经典压缩保证条数、token 压缩保证 token——不能用条数去判 token 压缩器,否则误报)。
enum LingShuCompactionBudget: Sendable, Equatable {
    case messageCount(Int)   // 非系统 body 条数上限
    case tokens(Int)         // 非系统 body token 上限
}

/// 历史压缩协议。返回 nil = 未超预算、无需压缩(核心循环据此跳过)。
protocol LingShuHistoryCompacting: Sendable {
    func compact(messages: [LingShuAgentMessage], model: any LingShuAgentModel) async -> LingShuCompactionResult?
    /// 压缩后历史的容量契约(供不变量 I6 按实际策略校验)。
    var budget: LingShuCompactionBudget { get }
}

/// token 粗估器(可替换):不求精确,只为定"预算触发"阈值。中文≈1字1token、ASCII≈4字符1token,取两者加权。
/// 将来接真 tokenizer 直接换这里。
enum LingShuTokenEstimator {
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            // CJK 统一表意文字主区 + 扩展A + 常用假名/韩文:按 1 token/字算。
            if (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7A3).contains(scalar.value) {
                cjk += 1
            } else {
                other += 1
            }
        }
        return cjk + (other + 3) / 4   // 非 CJK 约 4 字符/token,向上取整
    }

    static func estimate(_ message: LingShuAgentMessage) -> Int {
        var total = estimate(message.content)
        for call in message.toolCalls { total += estimate(call.name) + estimate(call.argumentsJSON) }
        total += 4   // 每条消息的角色/结构固定开销
        return total
    }

    static func estimate(_ messages: [LingShuAgentMessage]) -> Int {
        messages.reduce(0) { $0 + estimate($1) }
    }
}

/// 默认实现:经典「按消息条数」整段蒸馏(原 `compactHistoryIfNeeded` 行为的模块化封装,零变更兜底)。
/// 核心循环若未注入压缩器即等价于此(保留内置路径);此类型供需要显式注入经典行为时复用。
struct LingShuMessageCountCompactor: LingShuHistoryCompacting {
    let maxHistoryMessages: Int
    var budget: LingShuCompactionBudget { .messageCount(maxHistoryMessages) }

    func compact(messages: [LingShuAgentMessage], model: any LingShuAgentModel) async -> LingShuCompactionResult? {
        guard maxHistoryMessages > 0 else { return nil }
        let systemCount = messages.prefix { $0.role == .system }.count
        let body = Array(messages[systemCount...])
        guard body.count > maxHistoryMessages else { return nil }
        let keepRecent = max(1, maxHistoryMessages - 1)
        let dropCount = body.count - keepRecent
        guard dropCount >= 2 else {
            // 退化:硬裁剪(不留孤儿 tool 结果)。
            var kept = Array(body.suffix(maxHistoryMessages))
            while let first = kept.first, first.role == .tool { kept.removeFirst() }
            return .init(messages: Array(messages[..<systemCount]) + kept, extractedFacts: [])
        }
        let dropped = Array(body.prefix(dropCount))
        let transcript = dropped.map { "[\($0.role)] " + String($0.content.prefix(1200)) }.joined(separator: "\n")
        let summary = await LingShuCompactionDistiller.distill(transcript: transcript, model: model)
        guard let summary, !summary.isEmpty else {
            var kept = Array(body.suffix(maxHistoryMessages))
            while let first = kept.first, first.role == .tool { kept.removeFirst() }
            return .init(messages: Array(messages[..<systemCount]) + kept, extractedFacts: [])
        }
        var kept = Array(body.suffix(keepRecent))
        while let first = kept.first, first.role == .tool { kept.removeFirst() }
        let summaryMsg = LingShuAgentMessage(role: .user, content: "【前情提要(早前对话已压缩,供你延续)】\n\(summary)")
        return .init(messages: Array(messages[..<systemCount]) + [summaryMsg] + kept, extractedFacts: [])
    }
}

/// 超越实现:**token 预算分层压缩 + 知识图谱无损召回**。
/// 触发:非系统正文估算 token 超 `tokenBudget`。保留:① 系统/seed 全留 ② 最近累计 `keepRecentTokens` 内的消息逐字
/// ③ 中段蒸馏成一条滚动「前情提要」 ④ 蒸馏的同时把关键事实抽给 `extractedFacts`(上层 remember)。
/// 不切出孤儿 tool 结果(开头若是 tool 则继续往后丢到完整起点)。蒸馏失败 → 仅硬保留最近段(不卡住)。
struct LingShuLayeredCompactor: LingShuHistoryCompacting {
    /// 非系统正文超此 token 数即触发压缩。
    let tokenBudget: Int
    /// 最近多少 token 的消息逐字保留(从尾部累计)。
    let keepRecentTokens: Int

    init(tokenBudget: Int = 24_000, keepRecentTokens: Int = 8_000) {
        self.tokenBudget = max(1_000, tokenBudget)
        self.keepRecentTokens = max(500, min(keepRecentTokens, max(1_000, tokenBudget - 500)))
    }

    var budget: LingShuCompactionBudget { .tokens(tokenBudget) }

    func compact(messages: [LingShuAgentMessage], model: any LingShuAgentModel) async -> LingShuCompactionResult? {
        let systemCount = messages.prefix { $0.role == .system }.count
        let head = Array(messages[..<systemCount])
        let body = Array(messages[systemCount...])
        guard !body.isEmpty, LingShuTokenEstimator.estimate(body) > tokenBudget else { return nil }

        // 从尾部累计 keepRecentTokens,确定逐字保留段的起点。
        var recentTokens = 0
        var splitIndex = body.count   // [splitIndex, end) 逐字保留
        var i = body.count - 1
        while i >= 0 {
            recentTokens += LingShuTokenEstimator.estimate(body[i])
            if recentTokens > keepRecentTokens { break }
            splitIndex = i
            i -= 1
        }
        // 至少保留最后一条;至少丢两条才值得蒸馏。
        splitIndex = min(splitIndex, body.count - 1)
        let dropped = Array(body[..<splitIndex])
        guard dropped.count >= 2 else { return nil }

        var kept = Array(body[splitIndex...])
        while let first = kept.first, first.role == .tool { kept.removeFirst() }   // 不留孤儿 tool 结果

        let transcript = dropped.map { "[\($0.role)] " + String($0.content.prefix(1500)) }.joined(separator: "\n")
        let distilled = await LingShuCompactionDistiller.distillWithFacts(transcript: transcript, model: model)
        guard let distilled, !distilled.summary.isEmpty else {
            // 蒸馏失败:仅硬保留最近段(降级但不丢正确性,核心循环不卡)。
            return .init(messages: head + kept, extractedFacts: [])
        }
        let summaryMsg = LingShuAgentMessage(role: .user, content: "【前情提要(早前对话已压缩,关键细节已存入记忆可随时 recall)】\n\(distilled.summary)")
        return .init(messages: head + [summaryMsg] + kept, extractedFacts: distilled.facts)
    }
}

/// 蒸馏器(纯封装模型调用):把一段早期 transcript 压成「前情提要」,并(超越版)抽出可入图谱的离散事实。
enum LingShuCompactionDistiller {
    static func distill(transcript: String, model: any LingShuAgentModel) async -> String? {
        let sys = LingShuAgentMessage(role: .system, content: "你是对话压缩器。把下面这段较早的 agent 对话压成简洁【前情提要】:只留对后续推进有用的——关键决策/已产出文件的绝对路径/已确认事实/未决问题/约束。要点式,别复述客套和中间废话。只输出提要正文。")
        let usr = LingShuAgentMessage(role: .user, content: transcript)
        let resp = await model.respond(messages: [sys, usr], tools: [])
        if case .text(let s) = resp {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    struct Distilled: Sendable { let summary: String; let facts: [String] }

    /// 超越版:一次模型调用产出"提要 + 离散事实清单"(事实交上层 remember 进知识图谱,实现近无损)。
    /// 用轻量标记切分(`@@SUMMARY@@` / `@@FACTS@@`),解析失败则退化为纯提要(facts 空)。
    static func distillWithFacts(transcript: String, model: any LingShuAgentModel) async -> Distilled? {
        let sys = LingShuAgentMessage(role: .system, content: """
        你是对话压缩器。把下面这段较早的 agent 对话压缩,输出严格两段:
        @@SUMMARY@@
        <简洁前情提要:关键决策/已产出文件绝对路径/已确认事实/未决问题/约束,要点式>
        @@FACTS@@
        <每行一条可长期复用的离散事实(产出物路径、用户确认的偏好/约束、关键结论);没有就留空>
        只输出这两段,不要别的话。
        """)
        let usr = LingShuAgentMessage(role: .user, content: transcript)
        let resp = await model.respond(messages: [sys, usr], tools: [])
        guard case .text(let raw) = resp else { return nil }
        return parse(raw)
    }

    /// 解析 `@@SUMMARY@@ ... @@FACTS@@ ...` 标记输出。纯逻辑、可单测。
    static func parse(_ raw: String) -> Distilled? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let sRange = text.range(of: "@@SUMMARY@@") else {
            // 无标记:整段当提要(向后兼容)。
            return Distilled(summary: text, facts: [])
        }
        let afterSummary = text[sRange.upperBound...]
        let summary: String
        let facts: [String]
        if let fRange = afterSummary.range(of: "@@FACTS@@") {
            summary = String(afterSummary[..<fRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let factsBlock = String(afterSummary[fRange.upperBound...])
            facts = factsBlock
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*").union(.whitespaces)) }
                .filter { !$0.isEmpty }
        } else {
            summary = afterSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            facts = []
        }
        guard !summary.isEmpty else { return nil }
        return Distilled(summary: summary, facts: facts)
    }
}
