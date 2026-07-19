import Foundation

/// 本机知识索引·**文件知识索引**(第一刀:文件/文档/代码)。
///
/// 隐私模型(用户拍板):**全本地、零上传**——用系统 `LingShuLocalTextEmbedding`(NLEmbedding,零网络)给逐块算向量,
/// 检索只在本地做;只有大脑生成答案时,由 `recall_local` 工具把**检索到的片段**作为工具结果带进上下文(=云端脑只见确认片段,
/// 不是整库)。索引哪些目录由用户 opt-in(consent at folder level)。
///
/// 复用现成 on-device embedding,不重造;混合排序=向量余弦(同语种)+ 关键词子串兜底(embedding 不可用/跨语种时仍可用)。
/// JSON 本地持久化(派生索引,源文件才是真相)。增量:按文件 mtime 跳过未变。线程安全:串行队列。
struct LingShuKnowledgeChunk: Codable, Sendable, Equatable {
    let path: String
    let idx: Int
    let text: String
    let vector: [Double]
    let lang: String
    let mtime: Double
}

struct LingShuKnowledgeHit: Sendable, Equatable {
    let path: String
    let snippet: String
    let score: Double
}

final class LingShuFileKnowledgeIndex: @unchecked Sendable {
    static let defaultDirectory = LingShuRuntimeEnvironment.homeDirectory
        .appendingPathComponent("Library/Application Support/LingShu/Knowledge", isDirectory: true)

    private let queue = DispatchQueue(label: "lingshu.file-knowledge")
    private let embedding = LingShuLocalTextEmbedding()
    private let storeURL: URL
    private let hitsURL: URL
    private let maxChunks: Int

    private var chunks: [LingShuKnowledgeChunk] = []
    private var fileMtime: [String: Double] = [:]
    /// 召回热度(差距②·dreaming 蒸馏):path → 被 recall_local 命中次数。独立文件存,与主索引解耦免迁移。
    private var hits: [String: Int] = [:]

    init(directory: URL = LingShuFileKnowledgeIndex.defaultDirectory, maxChunks: Int = 50_000) {
        self.maxChunks = maxChunks
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("file-knowledge.json")
        hitsURL = directory.appendingPathComponent("file-knowledge-hits.json")
        queue.sync { load(); loadHits() }
    }

    var chunkCount: Int { queue.sync { chunks.count } }
    var indexedFileCount: Int { queue.sync { fileMtime.count } }
    func knownMtime(for path: String) -> Double? { queue.sync { fileMtime[path] } }
    func indexedPaths() -> Set<String> { queue.sync { Set(fileMtime.keys) } }

    /// (重新)索引一个文件:删旧块→切块→逐块算向量→入库→记 mtime。空文本=只删旧+记 mtime。
    func upsertFile(path: String, mtime: Double, text: String) {
        let pieces = LingShuTextChunker.chunk(text)
        queue.sync {
            chunks.removeAll { $0.path == path }
            for (i, piece) in pieces.enumerated() {
                let v = embedding.vectorWithLanguage(for: piece)
                chunks.append(.init(path: path, idx: i, text: piece,
                                    vector: v?.vector ?? [], lang: v?.language ?? "", mtime: mtime))
            }
            fileMtime[path] = mtime
            if chunks.count > maxChunks { chunks.removeFirst(chunks.count - maxChunks) }
            save()
        }
    }

    /// 删除一个文件的全部块(文件被删/移出索引目录时)。
    func removeFile(path: String) {
        queue.sync {
            chunks.removeAll { $0.path == path }
            fileMtime[path] = nil
            save()
        }
    }

    /// 删除某目录(前缀)下的全部索引(取消某个 opt-in 目录时)。
    func removeUnder(prefix: String) {
        queue.sync {
            chunks.removeAll { $0.path.hasPrefix(prefix) }
            for key in fileMtime.keys where key.hasPrefix(prefix) { fileMtime[key] = nil }
            save()
        }
    }

    /// 本地检索:向量余弦(同语种)+ 关键词子串兜底;按文件折叠到最佳块;返回 top-K。
    func search(query: String, limit: Int = 6) -> [LingShuKnowledgeHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return queue.sync {
            guard !chunks.isEmpty else { return [] }
            let qv = embedding.vectorWithLanguage(for: q)
            let terms = LingShuFileKnowledgeIndex.keywords(q)
            let ql = q.lowercased()
            let scored: [(LingShuKnowledgeChunk, Double)] = chunks.map { c in
                var score = 0.0
                if let qv, !c.vector.isEmpty, c.lang == qv.language {
                    score += LingShuLocalTextEmbedding.cosineSimilarity(qv.vector, c.vector)   // 语义,0…1
                }
                let lower = c.text.lowercased()
                // **整串精确匹配=强信号**:特定 token/短语(如唯一编号、文件名)直接命中,不被海量向量噪声淹没
                // (大索引下的实测修:1440 文件时查唯一 token 曾排不进前列)。再叠每词命中加权。
                if lower.contains(ql) { score += 1.0 }
                let hits = terms.filter { lower.contains($0) }.count
                if hits > 0 { score += 0.3 * Double(hits) }
                return (c, score)
            }
            // 折叠到每个文件的最佳块,再排序取 top-K。
            var bestPerFile: [String: (LingShuKnowledgeChunk, Double)] = [:]
            for (c, s) in scored where s > 0 {
                if let cur = bestPerFile[c.path], cur.1 >= s { continue }
                bestPerFile[c.path] = (c, s)
            }
            return bestPerFile.values.sorted { $0.1 > $1.1 }.prefix(limit).map { (c, s) in
                LingShuKnowledgeHit(path: c.path, snippet: String(c.text.prefix(500)), score: s)
            }
        }
    }

    // MARK: - 召回热度(dreaming 蒸馏高频本机知识进图谱)

    /// 记录一次召回命中(recall_local 返回的 path)→ 计数+1。
    func recordHits(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        queue.sync {
            for p in paths { hits[p, default: 0] += 1 }
            if hits.count > 10_000 {
                let kept = hits.sorted { $0.value > $1.value }.prefix(5_000).map { ($0.key, $0.value) }
                hits = Dictionary(kept, uniquingKeysWith: { a, _ in a })
            }
            saveHits()
        }
    }

    /// 取被召回最多的若干文件(≥minHits 次)及其代表内容(该文件最长的块=信息最多)。
    func topRecalled(minHits: Int = 3, limit: Int = 5) -> [(path: String, text: String, hits: Int)] {
        queue.sync {
            hits.filter { $0.value >= minHits }.sorted { $0.value > $1.value }.prefix(limit).compactMap { entry in
                let best = chunks.filter { $0.path == entry.key }.max(by: { $0.text.count < $1.text.count })?.text
                guard let best, !best.isEmpty else { return nil }
                return (path: entry.key, text: best, hits: entry.value)
            }
        }
    }

    /// 蒸馏过的清计数(避免每次 dreaming 重蒸同一批)。
    func clearHits(for paths: [String]) {
        queue.sync { for p in paths { hits[p] = nil }; saveHits() }
    }

    func hitCount(for path: String) -> Int { queue.sync { hits[path] ?? 0 } }

    private func loadHits() {
        guard let data = try? Data(contentsOf: hitsURL),
              let h = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        hits = h
    }
    private func saveHits() {
        guard let data = try? JSONEncoder().encode(hits) else { return }
        try? data.write(to: hitsURL, options: .atomic)
    }

    /// 关键词切分(纯逻辑):英文按非字母数字切(≥2 字符)、CJK 单字。
    static func keywords(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        func flush() { if cur.count >= 2 { out.append(cur) }; cur = "" }
        for ch in s.lowercased() {
            if let sc = ch.unicodeScalars.first, sc.value >= 0x3400 { flush(); out.append(String(ch)) }
            else if ch.isLetter || ch.isNumber { cur.append(ch) }
            else { flush() }
        }
        flush()
        return out
    }

    // MARK: - 持久化(JSON,派生索引)

    private struct Persisted: Codable { var chunks: [LingShuKnowledgeChunk]; var fileMtime: [String: Double] }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        chunks = p.chunks
        fileMtime = p.fileMtime
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Persisted(chunks: chunks, fileMtime: fileMtime)) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
