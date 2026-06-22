import Foundation

/// 长期记忆 + 本机知识的**统一召回**(从 LingShuState+AgentBackbone 拆出,守 ≤500 行架构守卫)。
/// `recall_memory` 工具经 #4 记忆门面 `LingShuMemoryMerge` 把【知识图谱】与【本机文件索引】两源归一去重排序。
@MainActor
extension LingShuState {

    /// recall_memory:让模型主动召回——既查长期记忆知识图谱(事实/任务/偏好),也查本机文件索引(opt-in 的本地资料)。
    func recallMemoryTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "recall_memory",
            description: "从灵枢长期记忆召回与某主题相关的内容:既查【知识图谱】(历史事实/任务/偏好),也查【本机知识索引】(你已 opt-in 的本地文件/文档/代码)——两源归一去重后按相关性返回。当前对话里没有、但你怀疑记过或本机有资料时用。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"要召回的主题/关键词\"}},\"required\":[\"query\"]}"
        ) { [weak self] argumentsJSON in
            let query = (Self.jsonField(argumentsJSON, "query") ?? argumentsJSON).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return "查询为空。" }
            // #4 记忆门面:多源召回(知识图谱 + 本机文件索引)→ LingShuMemoryMerge 归一去重排序成一份结果。
            // 图谱在主 actor 取;本机索引搜索放后台(避免阻塞 UI,与 recall_local 同款)。
            let (graphNotes, index): ([LingShuMemoryNote], LingShuFileKnowledgeIndex?) = await MainActor.run { [weak self] in
                guard let self else { return ([], nil) }
                return (self.knowledgeGraph.recall(query, limit: 6), self.localKnowledgeIndex)
            }
            let localHits = index == nil ? [] : await Task.detached { index!.search(query: query, limit: 6) }.value
            let merged = LingShuMemoryMerge.merge([
                graphNotes.enumerated().map { i, n in
                    LingShuUnifiedMemoryHit(source: "graph", title: n.title,
                                            snippet: String(n.body.prefix(240)),
                                            score: 0.5 + n.confidence * 0.5 - Double(i) * 0.001) },
                localHits.map { h in
                    LingShuUnifiedMemoryHit(source: "local-files", title: (h.path as NSString).lastPathComponent,
                                            snippet: h.snippet.replacingOccurrences(of: "\n", with: " "),
                                            score: min(h.score, 1.0)) }
            ], limit: 8)
            guard !merged.isEmpty else { return "记忆中没找到与「\(query)」相关的内容。" }
            return "长期记忆 + 本机知识召回(相关性降序,共 \(merged.count) 条):\n"
                + merged.map { "[\($0.source)] \($0.title):\($0.snippet.prefix(180))" }.joined(separator: "\n")
        }
    }

    /// 仅图谱文本召回(保留的便捷 helper:单源、同步,供需要纯长期记忆文本的路径)。
    func recallMemoryText(for query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "查询为空。" }
        guard let graphText = knowledgeGraph.recallText(q) else {
            return "记忆中没找到与「\(q)」相关的内容。"
        }
        return graphText
    }
}
