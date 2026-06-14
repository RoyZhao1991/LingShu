import Foundation

/// 联网搜索子域:agent 的 web_search 工具与无密钥 DuckDuckGo 抽取。
/// 从 LingShuState+AgentBackbone 拆出,守住单文件聚焦一类职责。纯网络/解析,无需 MainActor。
@MainActor
extension LingShuState {

    /// 联网搜索工具:让模型不受知识库时效限制,可查实时/最新信息。
    nonisolated static func webSearchTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "web_search",
            description: "联网搜索实时/最新信息(突破模型知识库时效)。返回前几条结果的标题、摘要、链接。需要最新事实、新闻、行情、文档时调用。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"搜索关键词\"}},\"required\":[\"query\"]}"
        ) { argsJSON in
            let query = jsonField(argsJSON, "query") ?? argsJSON
            return await performWebSearch(query)
        }
    }

    /// 用 DuckDuckGo HTML 做无密钥联网搜索,抽取前 5 条结果(标题/摘要/链接)。
    /// 注:可平滑替换为高质量付费搜索 API(改这一处即可),接口与工具不变。
    nonisolated static func performWebSearch(_ query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "搜索词为空。" }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return "搜索 URL 构造失败。"
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) LingShu/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return "搜索结果解码失败。" }
            let results = extractSearchResults(from: html, limit: 5)
            if results.isEmpty { return "联网搜索「\(trimmed)」没有解析到结果(可能被限流,可换词重试)。" }
            return "联网搜索「\(trimmed)」结果:\n" + results.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        } catch {
            return "联网搜索失败:\(error.localizedDescription)"
        }
    }

    private nonisolated static func extractSearchResults(from html: String, limit: Int) -> [String] {
        // DDG html:结果标题在 class="result__a"…>标题</a>,摘要在 class="result__snippet"…>摘要</a>。
        let titles = matches(in: html, pattern: "result__a[^>]*>(.*?)</a>")
        let snippets = matches(in: html, pattern: "result__snippet[^>]*>(.*?)</a>")
        var out: [String] = []
        for i in 0..<min(limit, titles.count) {
            let title = stripTags(titles[i])
            let snippet = i < snippets.count ? stripTags(snippets[i]) : ""
            guard !title.isEmpty else { continue }
            out.append(snippet.isEmpty ? title : "\(title) —— \(snippet)")
        }
        return out
    }

    private nonisolated static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    private nonisolated static func stripTags(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return noTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
