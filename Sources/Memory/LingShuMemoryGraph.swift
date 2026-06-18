import Foundation

/// 记忆图谱的纯逻辑:**别名归一**(治同音污染)与**召回**(精确实体命中 + 关键词重叠 + 顺链关联扩展)。
/// 全部静态纯函数,操作传入的 `[LingShuMemoryNote]`,不持有状态——可完整单测。
enum LingShuMemoryGraph {

    /// 归一化:去空白/标点、转小写。用于精确比对。
    static func norm(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    /// 把一个名字解析到已有 note 的 id:① 精确(标题/别名归一相等)② 读音模糊(复用唤醒词的拼音模糊键,
    /// 这样"刘叔/林叔/灵枢"这类同音/近音都归到同一个 person,根治记错名污染)。找不到返回 nil。
    static func resolve(name: String, in notes: [LingShuMemoryNote]) -> String? {
        let target = norm(name)
        guard !target.isEmpty else { return nil }
        for note in notes where norm(note.title) == target || note.aliases.contains(where: { norm($0) == target }) {
            return note.id
        }
        let keys = LingShuWakeWordMatcher.fuzzyPinyinKeys(name)
        guard !keys.isEmpty else { return nil }
        for note in notes {
            let candidates = [note.title] + note.aliases
            if candidates.contains(where: { LingShuWakeWordMatcher.fuzzyPinyinKeys($0) == keys }) {
                return note.id
            }
        }
        return nil
    }

    /// 分词:ASCII 词整体成 token,CJK 单字各成 token(够做重叠度,不引中文分词库)。
    static func tokens(_ s: String) -> Set<String> {
        var out: Set<String> = []
        var word = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                if ch.isASCII { word.append(ch) }
                else { if !word.isEmpty { out.insert(word); word = "" }; out.insert(String(ch)) }
            } else if !word.isEmpty { out.insert(word); word = "" }
        }
        if !word.isEmpty { out.insert(word) }
        return out
    }

    /// 新鲜度系数(0.5~1.0):越近被核验越高,半衰期 ~60 天。
    static func freshness(_ note: LingShuMemoryNote, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(note.lastVerified) / 86_400)
        return 0.5 + 0.5 * pow(0.5, days / 60)
    }

    /// 两向量余弦相似度(纯,自含,不依赖外部 embedding 类——保持本层可独立单测)。
    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// 召回(混合检索):返回与 query 最相关的 notes(按 命中分 × (0.5+置信) × 新鲜度 排序)。
    /// 通道:① 精确实体(query 含标题/别名,+5)② 关键词重叠(+重叠数)③ **语义向量余弦**(治"换种说法/问得模糊",
    /// 无关键词重叠也召回)④ 种子的链接邻居关联扩展(+1.5)。queryVector/noteVectors 为空则退化为①②④(行为不变)。
    static func recall(
        query: String,
        notes: [LingShuMemoryNote],
        queryVector: [Double] = [],
        noteVectors: [String: [Double]] = [:],
        limit: Int = 6,
        now: Date = Date()
    ) -> [LingShuMemoryNote] {
        guard !notes.isEmpty else { return [] }
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let qNorm = norm(query)
        let qTokens = tokens(query)
        var score: [String: Double] = [:]

        for note in notes {
            let names = ([note.title] + note.aliases).filter { !$0.isEmpty }
            if names.contains(where: { qNorm.contains(norm($0)) }) {
                score[note.id, default: 0] += 5
            }
            let hay = tokens(note.title + " " + note.body + " " + note.tags.joined(separator: " ") + " " + note.aliases.joined(separator: " "))
            let overlap = qTokens.intersection(hay).count
            if overlap > 0 { score[note.id, default: 0] += Double(overlap) }
        }

        // 语义通道:query 与 note 向量余弦相近 → 即便无关键词重叠也召回。阈值 0.35 滤噪,权重 4 与关键词量级可比、低于精确实体(5)。
        if !queryVector.isEmpty {
            for note in notes {
                guard let vec = noteVectors[note.id], !vec.isEmpty else { continue }
                let sim = cosine(queryVector, vec)
                if sim > 0.35 { score[note.id, default: 0] += sim * 4 }
            }
        }

        // 图扩展:对已命中的种子,沿 links 把邻居也拉进来(关联召回)。
        for seedID in Array(score.keys) {
            guard let seed = byID[seedID] else { continue }
            for linkID in seed.links where byID[linkID] != nil {
                score[linkID, default: 0] += 1.5
            }
        }

        let ranked = score.compactMap { (id, raw) -> (LingShuMemoryNote, Double)? in
            guard let note = byID[id], raw > 0 else { return nil }
            return (note, raw * (0.5 + note.confidence) * freshness(note, now: now))
        }
        .sorted { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.0.updated > rhs.0.updated   // 同分按更新时间,稳定可测
        }
        return Array(ranked.prefix(limit).map { $0.0 })
    }
}
