import Foundation

/// 联网搜索子域:agent 的 web_search 工具与无密钥 DuckDuckGo 抽取。
/// 从 LingShuState+AgentBackbone 拆出,守住单文件聚焦一类职责。纯网络/解析,无需 MainActor。
@MainActor
extension LingShuState {

    /// 联网搜索工具:让模型不受知识库时效限制,可查实时/最新信息。
    /// **2026-06-27 修**:无密钥 DDG 抓取已被搜索引擎封死(返回空),改优先走 **OpenRouter web 插件**(真实时结果+来源),
    /// 没配 OpenRouter key 才回退 DDG。读 self 凭据库里的 openrouter key(故改为实例方法)。
    func webSearchTool() -> LingShuAgentTool {
        let orKey = credentialStore.apiKey(forProvider: "openrouter") ?? ""
        return LingShuAgentTool(
            name: "web_search",
            description: "联网搜索实时/最新信息(突破模型知识库时效)。返回最新事实摘要 + 来源链接。需要最新事实、新闻、行情、产品对比、现状时调用。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"搜索关键词\"}},\"required\":[\"query\"]}"
        ) { argsJSON in
            let query = Self.jsonField(argsJSON, "query") ?? argsJSON
            return await Self.performWebSearch(query, openRouterKey: orKey)
        }
    }

    /// 便宜分类:回答这句话需不需要**联网查最新/实时信息**(会随时间变=YES)。供确定性查证兜底用——
    /// 不靠模型自觉调 web_search(它判不准也不一定调),系统先判、会变就预取注入。**拿不准当作会变(YES)**。
    func questionNeedsFreshInfo(_ question: String) async -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return false }
        let sys = """
        判断回答下面这句话是否需要**联网查最新/实时信息**,只输出一个词:YES 或 NO。
        YES(答案会随时间变):汇率/股价/天气/价格、最新进展/版本/排名、产品或工具对比(谁更强/支持什么,如 codex vs claude)、现状、某公司或产品的最新动态、近期事件…
        NO:铁定不随时间变的理论/定义/数学/算法/已定历史(光速、定义、排序原理、勾股定理);或根本不是事实问题(闲聊/打招呼/让你写代码做任务)。
        拿不准会不会变 → 当作会变,输出 YES。
        """
        let session = LingShuAgentSession(id: "fresh-\(UUID().uuidString.prefix(6))",
                                          system: sys, tools: [], model: controlPlaneModelAdapter(.triage), maxTurns: 1)
        guard case .completed(let raw) = await session.send(q) else { return false }
        let cleaned = LingShuReasoningText.stripThinkTags(raw).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return cleaned.hasPrefix("YES") || (cleaned.contains("YES") && !cleaned.contains("NO"))
    }

    /// 联网搜索:优先 OpenRouter web 插件(真实时+来源,无密钥 DDG 已被封),没 key 回退 DDG。
    nonisolated static func performWebSearch(_ query: String, openRouterKey: String = "") async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "搜索词为空。" }
        if !openRouterKey.isEmpty, let viaOR = await openRouterWebSearch(trimmed, key: openRouterKey) {
            return viaOR
        }
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

    /// 用 **OpenRouter 的 web 插件**做联网搜索:它服务端先搜网页、把结果喂模型,返回带**真实时数据 + 来源链接**的摘要。
    /// 无密钥 DDG 抓取已被搜索引擎封死(返回空),这是当前真正能用的搜索路径。返回 nil = 没拿到(调用方回退 DDG)。
    nonisolated static func openRouterWebSearch(_ query: String, key: String) async -> String? {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 40
        // 省钱:搜索包装用便宜模型(deepseek-chat,只需汇总搜索结果,不必上 Kimi)+ 结果数 5→3(OpenRouter 按结果收费)。
        let body: [String: Any] = [
            "model": "deepseek/deepseek-chat",
            "plugins": [["id": "web", "max_results": 3]],
            "messages": [["role": "user", "content": "联网搜索并用中文简要汇总关于「\(query)」的**最新**信息:给关键事实/数字/日期,别凭记忆。"]],
            "max_tokens": 600
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data
        guard let (respData, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = (msg["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return nil }
        var out = "联网搜索「\(query)」结果(实时):\n" + content
        if let ann = msg["annotations"] as? [[String: Any]] {
            let urls = ann.compactMap { ($0["url_citation"] as? [String: Any])?["url"] as? String }.prefix(5)
            if !urls.isEmpty { out += "\n\n来源:\n" + urls.map { "- \($0)" }.joined(separator: "\n") }
        }
        return out
    }

    /// 联网搜索返回**结果真实 URL**(供 acquire_resource 抓资源用)。DDG 结果链接常是 `/l/?uddg=<编码真链>`,这里解出真链。
    nonisolated static func webSearchLinks(_ query: String, limit: Int = 8) async -> [URL] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) LingShu/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else { return [] }
        var urls: [URL] = []
        var seen = Set<String>()
        for href in matches(in: html, pattern: "result__a[^>]*href=\"([^\"]+)\"").prefix(limit * 2) {
            let real = decodeDDGRedirect(href)
            guard let u = URL(string: real), (u.scheme == "http" || u.scheme == "https"), !seen.contains(u.absoluteString) else { continue }
            seen.insert(u.absoluteString)
            urls.append(u)
            if urls.count >= limit { break }
        }
        return urls
    }

    private nonisolated static func decodeDDGRedirect(_ href: String) -> String {
        if let r = href.range(of: "uddg=") {
            let after = String(href[r.upperBound...])
            let enc = after.split(separator: "&").first.map(String.init) ?? after
            if let dec = enc.removingPercentEncoding { return dec }
        }
        if href.hasPrefix("//") { return "https:" + href }
        return href
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
