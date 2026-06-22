import Foundation

/// 完全版 #4·**记忆门面(合并核)**(纯逻辑、可测)。
///
/// 不大爆炸重写现有 5 套存储(知识图谱/语义库/文件索引/聊天/WAL),而是给"统一召回"一个门面:
/// 各后端各自召回 → 在这里**归一 + 去重 + 排序**成一份结果。加新后端 = 多喂一组 hits,合并逻辑不变。
struct LingShuUnifiedMemoryHit: Sendable, Equatable {
    let source: String     // graph / semantic / local-files / chat
    let title: String
    let snippet: String
    let score: Double
}

enum LingShuMemoryMerge {
    /// 合并多源召回:按分数降序,按 (source|title) 去重,取 top-K。纯逻辑。
    static func merge(_ groups: [[LingShuUnifiedMemoryHit]], limit: Int = 8) -> [LingShuUnifiedMemoryHit] {
        var seen = Set<String>()
        var out: [LingShuUnifiedMemoryHit] = []
        for h in groups.flatMap({ $0 }).sorted(by: { $0.score > $1.score }) {
            let key = "\(h.source)|\(h.title)"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(h)
            if out.count >= limit { break }
        }
        return out
    }
}
