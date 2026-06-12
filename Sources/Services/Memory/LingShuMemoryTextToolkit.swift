import Foundation

enum LingShuMemoryTextToolkit {
    static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "？", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "：", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "；", with: "")
            .replacingOccurrences(of: ";", with: "")
    }

    static func compactSummary(_ text: String, limit: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.count > limit else { return cleaned }

        let headLimit = max(80, Int(Double(limit) * 0.58))
        let tailLimit = max(60, limit - headLimit - 18)
        return "\(cleaned.prefix(headLimit))\n...记忆已压缩...\n\(cleaned.suffix(tailLimit))"
    }

    static func memoryScore(prompt: String, tags: Set<String>, recordTags: [String], title: String, summary: String) -> Int {
        let normalizedPrompt = normalize(prompt)
        let normalizedTitle = normalize(title)
        let normalizedSummary = normalize(summary)
        let recordTagSet = Set(recordTags)
        var score = tags.intersection(recordTagSet).count * 4

        for tag in recordTags {
            let normalizedTag = normalize(tag)
            if !normalizedTag.isEmpty && normalizedPrompt.contains(normalizedTag) {
                score += 2
            }
        }

        if !normalizedTitle.isEmpty && normalizedPrompt.contains(normalizedTitle) {
            score += 2
        }
        if !normalizedPrompt.isEmpty && normalizedSummary.contains(normalizedPrompt) {
            score += 1
        }
        return score
    }

    static func shouldRecallHistory(for prompt: String) -> Bool {
        let normalized = normalize(prompt)
        let signals = ["继续", "上次", "之前", "历史", "记得", "回到", "刚才", "前面", "这个项目", "当前项目", "当前任务", "上一轮", "刚刚"]
        return signals.contains { normalized.contains($0) }
    }

    /// 明确的任务回溯请求：用户点名要续接某个历史任务（"继续做上次那个PPT"），
    /// 区别于一般的延续语气。强回溯动词 + 历史指代同时出现才算，避免把
    /// "继续说"这类口头语误判成回溯。
    static func isExplicitResumeRequest(_ prompt: String) -> Bool {
        let normalized = normalize(prompt)
        let resumeVerbs = ["继续", "接着做", "接着弄", "回到", "恢复", "续上", "续做", "捡起", "接着推进", "继续执行", "继续推进"]
        let historyReferences = ["上次", "之前", "那个任务", "上回", "昨天", "前几天", "历史任务", "原来", "先前", "之前的", "没做完", "未完成", "做到一半"]
        let hasVerb = resumeVerbs.contains { normalized.contains($0) }
        let hasReference = historyReferences.contains { normalized.contains($0) }
        return hasVerb && hasReference
    }

    static func isEphemeralLocalPrompt(_ prompt: String) -> Bool {
        let normalized = normalize(prompt)
        let ephemeralPrompts = ["你是谁", "你是什么", "你叫什么", "灵枢是谁", "我是谁", "你好", "您好", "在吗", "hello", "hi"]
        return ephemeralPrompts.contains(normalized) || (normalized.contains("你是谁") && normalized.count <= 8)
    }

    static func compressedMemorySummary(previous: String, prompt: String, reply: String, route: CodexRoutePayload?) -> String {
        let routeText: String
        if let route {
            let agents = route.agents.map(\.agent).joined(separator: "、")
            routeText = route.needsAgents ? "本轮进入任务线程：\(agents.isEmpty ? "未列明" : agents)。" : "本轮主线程直接回答。"
        } else {
            routeText = "本轮主线程直接处理。"
        }

        let merged = [
            previous.isEmpty ? nil : "既有摘要：\(previous)",
            "最近用户：\(prompt)",
            "灵枢处理：\(routeText)",
            reply.isEmpty ? nil : "最近回复：\(reply)"
        ]
            .compactMap { $0 }
            .joined(separator: "\n")

        return compactSummary(merged, limit: 680)
    }

    static func memoryStatusText(
        hotMatches: [MainThreadMemoryRecord],
        coldMatches: [ColdMemoryRecord],
        continuity: Bool
    ) -> String {
        if hotMatches.isEmpty && coldMatches.isEmpty {
            return continuity
                ? "用户语义包含续接信号，但热记忆和冷备库暂未命中。"
                : "本轮没有命中主线程历史记忆，按新消息轻量判断。"
        }

        let hot = hotMatches.map { $0.title }.joined(separator: "、")
        let cold = coldMatches.map { $0.title }.joined(separator: "、")
        return "主线程先检索热记忆\(hot.isEmpty ? "未命中" : "命中：\(hot)")；冷备库\(cold.isEmpty ? "未命中" : "命中：\(cold)")。"
    }

    static func mainMemoryTags(from prompt: String) -> [String] {
        tags(
            from: prompt,
            candidates: [
                "灵枢", "xcode", "ios", "mac", "app", "web", "爬虫",
                "需求", "架构", "设计", "开发", "测试", "review", "bug", "版本",
                "登录", "语音", "模型", "agent", "codex", "deepseek", "claude",
                "记忆", "线程", "冷备", "压缩", "哲学", "论文", "课题",
                "规划", "审议", "调度", "权限", "工具", "流程"
            ]
        )
    }

    static func classifyMainThreadMemory(_ prompt: String, isCapabilityCollaboration: Bool) -> String {
        let normalized = normalize(prompt)
        if isCapabilityCollaboration {
            return "软件工程"
        }
        if normalized.contains("哲学") || normalized.contains("意义") || normalized.contains("意识") {
            return "哲学讨论"
        }
        if normalized.contains("论文") || normalized.contains("课题") || normalized.contains("研究") {
            return "研究课题"
        }
        if normalized.contains("记忆") || normalized.contains("线程") || normalized.contains("冷备") {
            return "灵枢机制"
        }
        return "普通对话"
    }

    static func shortMainMemoryTitle(from prompt: String, category: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.count > 18 ? "\(trimmed.prefix(18))..." : trimmed
        return "\(category)：\(body)"
    }

    static func taskTags(from prompt: String) -> [String] {
        tags(
            from: prompt,
            candidates: [
                "灵枢", "xcode", "ios", "mac", "app", "web", "爬虫",
                "需求", "架构", "设计", "开发", "测试", "review", "bug", "版本",
                "登录", "语音", "模型", "agent", "codex", "deepseek", "claude"
            ]
        )
    }

    static func shortTaskTitle(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 22 else { return trimmed }
        return "\(trimmed.prefix(22))..."
    }

    /// 给 FTS5 全文索引/查询用的切词：拉丁词原样小写，中文按字 bigram 展开
    /// （"灵枢项目" → ["灵枢","枢项","项目"]），单字文本退化为 unigram。
    /// unicode61 分词器会把连续汉字当成一个词，必须先切好再入索引。
    static func searchTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var latinWord = ""
        var cjkRun: [Character] = []

        func flushLatin() {
            if !latinWord.isEmpty {
                tokens.append(latinWord.lowercased())
                latinWord = ""
            }
        }
        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            if cjkRun.count == 1 {
                tokens.append(String(cjkRun[0]))
            } else {
                for index in 0..<(cjkRun.count - 1) {
                    tokens.append(String(cjkRun[index]) + String(cjkRun[index + 1]))
                }
            }
            cjkRun = []
        }

        for character in text {
            if isCJK(character) {
                flushLatin()
                cjkRun.append(character)
            } else if character.isLetter || character.isNumber {
                flushCJK()
                latinWord.append(character)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        return tokens
    }

    static func searchableText(_ text: String) -> String {
        searchTokens(text).joined(separator: " ")
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func tags(from prompt: String, candidates: [String]) -> [String] {
        let normalized = prompt
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")

        let matched = candidates.filter { normalized.contains($0.lowercased()) }
        if !matched.isEmpty {
            return Array(Set(matched)).sorted()
        }

        return normalized
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 }
            .prefix(5)
            .map { $0 }
    }
}
