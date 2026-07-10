import Foundation

/// UI/账本展示层的模型文本清洗。
/// 流程控制仍只读取严格 JSON；这里仅负责把违规混合输出里的 `reply` 提取成用户可见文本。
enum LingShuVisibleModelText {
    static func clean(_ raw: String) -> String {
        let visible = LingShuStructuredModelOutput.visibleText(from: raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.isEmpty, visible != original { return visible }
        if let reply = bestEffortReply(from: original), !reply.isEmpty { return reply }
        if let legacy = legacyRolePipelineSummary(from: original) { return legacy }
        return visible.isEmpty ? original : visible
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
        var cursor = valueStart
        var escaped = false
        var valueEnd = candidate.endIndex
        while cursor < candidate.endIndex {
            let character = candidate[cursor]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                valueEnd = cursor
                break
            }
            cursor = candidate.index(after: cursor)
        }

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
