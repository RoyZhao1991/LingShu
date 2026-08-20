import Foundation

/// UI/账本展示层的模型文本清洗。
/// 流程控制仍只读取严格 JSON；这里仅负责把违规混合输出里的 `reply` 提取成用户可见文本。
enum LingShuVisibleModelText {
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        final class Entry: NSObject {
            let value: String
            init(_ value: String) { self.value = value }
        }

        let values: NSCache<NSString, Entry> = {
            let cache = NSCache<NSString, Entry>()
            cache.countLimit = 384
            cache.totalCostLimit = 8 * 1_024 * 1_024
            return cache
        }()
    }

    static func clean(_ raw: String) -> String {
        let key = raw as NSString
        if let cached = cache.values.object(forKey: key) {
            return cached.value
        }
        let value = cleanUncached(raw)
        cache.values.setObject(Cache.Entry(value), forKey: key, cost: raw.utf8.count)
        return value
    }

    private static func cleanUncached(_ raw: String) -> String {
        // Checker 硬驳回不能被展示层的“从混合输出提取 reply”逻辑吃掉。
        // 否则内部状态是未通过，用户却只会看到 Maker 原先的“已完成”自述。
        if LingShuVerificationFailure.isMarked(raw) {
            let body = String(raw.dropFirst(LingShuVerificationFailure.prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let visibleBody = clean(body)
            return visibleBody.isEmpty
                ? LingShuVerificationFailure.prefix
                : LingShuVerificationFailure.prefix + "\n" + visibleBody
        }
        let visible = LingShuStructuredModelOutput.visibleText(from: raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.isEmpty, visible != original { return visible }
        if let reply = bestEffortReply(from: original), !reply.isEmpty { return reply }
        if let progress = readablePrefixBeforeInternalPayload(from: original) { return progress }
        if let legacy = legacyRolePipelineSummary(from: original) { return legacy }
        return visible.isEmpty ? original : visible
    }

    /// 工具事件偶尔会被错误投影成“可读进展 + 原始参数 JSON”。主对话只保留前面的
    /// 自然语言；原始 payload 仍留在任务执行记录中。这里只处理宿主明确加过
    /// `[truncated]` 的内部明细，避免把用户正常要求展示的 JSON 示例误删。
    private static func readablePrefixBeforeInternalPayload(from raw: String) -> String? {
        let candidates = ["\n{", "\n["].compactMap { marker -> String.Index? in
            raw.range(of: marker)?.lowerBound
        }
        guard let payloadStart = candidates.min(),
              payloadStart > raw.startIndex else { return nil }

        let prefix = raw[..<payloadStart]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return nil }

        let payload = String(raw[payloadStart...])
        let internalMarkers = [
            "\"file_name\"", "\"slides\"", "\"layout\"", "\"theme\"",
            "\"tool_calls\"", "\"arguments\"", "\"recursive\"", "\"command\""
        ]
        let markerCount = internalMarkers.reduce(into: 0) { count, marker in
            if payload.contains(marker) { count += 1 }
        }
        guard payload.contains("[truncated]"), markerCount >= 1 else { return nil }
        return prefix
    }

    /// 模型偶尔在长回复中把最终 JSON 截断。流程层仍然拒绝这种无效协议,
    /// 但展示层可以安全地从开头明确的 `reply` 字符串里恢复已经生成的正文。
    private static func bestEffortReply(from raw: String) -> String? {
        var candidate = LingShuReasoningText.stripThinkTags(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            guard let newline = candidate.firstIndex(of: "\n") else { return nil }
            candidate = String(candidate[candidate.index(after: newline)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard candidate.hasPrefix("{") else { return nil }
        guard let keyRange = candidate.range(
            of: #"\"reply\"\s*:\s*\""#,
            options: .regularExpression
        ), candidate.distance(from: candidate.startIndex, to: keyRange.lowerBound) < 80 else { return nil }

        let valueStart = keyRange.upperBound
        let valueEnd = bestEffortReplyValueEnd(in: candidate, from: valueStart)

        var encodedBody = String(candidate[valueStart..<valueEnd])
        if encodedBody.hasSuffix("\\") { encodedBody.removeLast() }
        guard !encodedBody.isEmpty else { return nil }
        let literal = "\"" + encodedBody + "\""
        if let data = "[\(literal)]".data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String],
           let decoded = array.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !decoded.isEmpty {
            return decoded
        }
        return encodedBody
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 部分兼容模型会把 reply 正文中的中文引号内容直接写成 `"示例"`，却忘记在 JSON
    /// 字符串里转义，导致整个对象无效。此时不能把正文遇到的第一个 `"` 当作结束；只有
    /// 后面确实接着结构协议字段或对象结束时，才认定它是 reply 的闭合引号。
    private static func bestEffortReplyValueEnd(in text: String, from start: String.Index) -> String.Index {
        var cursor = start
        var escaped = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"", closesReplyValue(at: cursor, in: text) {
                return cursor
            }
            cursor = text.index(after: cursor)
        }
        return text.endIndex
    }

    private static func closesReplyValue(at quote: String.Index, in text: String) -> Bool {
        var cursor = text.index(after: quote)
        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else { return true }
        if text[cursor] == "}" { return true }
        guard text[cursor] == "," else { return false }

        cursor = text.index(after: cursor)
        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }
        let tail = text[cursor...]
        let protocolKeys = [
            "\"completion\"", "\"user_input\"", "\"userInput\"",
            "\"inability\"", "\"OAuth\"", "\"oauth\""
        ]
        return protocolKeys.contains { tail.hasPrefix($0) }
    }

    /// 旧版本曾把管线内部结果的末尾 500 字符直接塞进主气泡,留下从中间截断的 checker JSON。
    /// 历史记录不改盘上原文,只在展示时迁移成清晰的流程/状态摘要。
    private static func legacyRolePipelineSummary(from raw: String) -> String? {
        let legacyPrefix = "🔧 已规划角色管线:"
        guard raw.hasPrefix(legacyPrefix) else { return nil }

        let firstLine = raw.components(separatedBy: "\n").first ?? raw
        let route = String(firstLine.dropFirst(legacyPrefix.count))
            .replacingOccurrences(of: "\\(([^()]+)\\)", with: "（$1）", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var sections = ["🔧 **协作流程**\n\(route)"]

        let statuses: [(marker: String, display: String)] = [
            ("✅ 管线完成,评审通过、已交付。", "✅ **已完成并通过验收**"),
            ("✅ 续跑完成,评审通过、已交付。", "✅ **续跑完成并通过验收**"),
            ("⚠️ 评审未通过,已交还(未交付,需修正后重验)。", "⚠️ **尚未通过验收,任务未交付**"),
            ("⚠️ 续跑后评审仍未通过,需再修。", "⚠️ **续跑尚未通过验收**"),
            ("⏹ 已停止。", "⏹ **已停止**")
        ]
        guard let status = statuses.first(where: { raw.contains($0.marker) }) else { return nil }
        sections.append(status.display)

        let paths = LingShuLocalPathDetector.existingFilePaths(in: raw)
        if !paths.isEmpty {
            sections.append("**产出物**\n" + paths.prefix(4).map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}
