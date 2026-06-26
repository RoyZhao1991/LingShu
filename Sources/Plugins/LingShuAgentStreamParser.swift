import Foundation

/// 解析 claude CLI `--output-format stream-json`(NDJSON 事件流)。
/// **背景**:text 模式只出最终结果、无中间过程,所以流式气泡一直"等到跑完才一次性刷出"。要像 codex 那样看到
/// **中间工具调用 / 每轮摘要**,必须用 stream-json 调,再由本解析器把事件提炼成人能读的过程摘要 + 最终交付文本。
/// 纯函数、不依赖 UI/State,可单测。**不写死 agent**:run 用 `isStreamJSON(argsTemplate)` 判,任何用 stream-json 的 CLI 同一套。
enum LingShuAgentStreamParser {

    /// 是否 stream-json 调用(看 argsTemplate 有没有 "stream-json",不在 run 里写死某个 agent)。
    static func isStreamJSON(_ argsTemplate: [String]) -> Bool {
        argsTemplate.contains("stream-json")
    }

    /// 从累计 NDJSON 提炼"中间过程摘要"(喂流式气泡):assistant 文本直出、tool_use 标成"🔧 工具+关键参数",
    /// result 标成"✓ 收尾"。只看尾部(界定每块开销),取最近 maxLines 条可读事件。
    static func progressSummary(fromStreamJSON raw: String, maxLines: Int = 8) -> String {
        let recent = String(raw.suffix(12000))
        var lines: [String] = []
        for rawLine in recent.split(separator: "\n") {
            guard let obj = parseLine(rawLine), let type = obj["type"] as? String else { continue }
            switch type {
            case "assistant":
                for item in contentItems(obj) {
                    let itype = item["type"] as? String
                    if itype == "text",
                       let t = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        lines.append(String(t.prefix(220)))
                    } else if itype == "tool_use", let name = item["name"] as? String {
                        lines.append("🔧 " + name + summarizeToolInput(item["input"]))
                    }
                }
            case "result":
                if let r = (obj["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
                    lines.append("✓ " + String(r.prefix(220)))
                }
            default: break
            }
        }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// 提取最终交付文本(result 字段)。找不到 → 拼 assistant 文本块;再不行 → 回退原文(别丢东西)。
    static func finalText(fromStreamJSON raw: String) -> String {
        var resultText: String?
        var assistantTexts: [String] = []
        for rawLine in raw.split(separator: "\n") {
            guard let obj = parseLine(rawLine), let type = obj["type"] as? String else { continue }
            if type == "result", let r = obj["result"] as? String {
                resultText = r
            } else if type == "assistant" {
                for item in contentItems(obj) where item["type"] as? String == "text" {
                    if let t = item["text"] as? String { assistantTexts.append(t) }
                }
            }
        }
        if let r = resultText, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return r }
        let joined = assistantTexts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? raw : joined
    }

    // MARK: - 私有

    private static func parseLine(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func contentItems(_ obj: [String: Any]) -> [[String: Any]] {
        guard let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]] else { return [] }
        return content
    }

    private static func summarizeToolInput(_ input: Any?) -> String {
        guard let dict = input as? [String: Any] else { return "" }
        for key in ["command", "file_path", "path", "pattern", "query", "url", "prompt"] {
            if let v = dict[key] as? String, !v.isEmpty {
                return ": " + String(v.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            }
        }
        return ""
    }
}
