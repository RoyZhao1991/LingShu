import Foundation
import NaturalLanguage
import SQLite3

/// 语义记忆条目：事实、偏好、承诺、对话主题、任务结论的最小持久单元。
struct LingShuSemanticMemoryEntry: Identifiable, Equatable, Sendable {
    var id: String
    var kind: String
    var title: String
    var content: String
    var tags: [String]
    var importance: Double
    var createdAt: Date
    var updatedAt: Date
}

/// 一次语义检索的命中：条目 + 融合得分 + 命中途径（向量/全文/两者）。
struct LingShuSemanticMemoryHit: Equatable, Sendable {
    var entry: LingShuSemanticMemoryEntry
    var score: Double
    var matchedBy: String
}

/// 本地文本向量化。优先用系统 NLEmbedding 句向量（中文/英文按主导语种选择），
/// 不可用时返回 nil——检索自动退化为纯全文模式。中英向量空间不互通，
/// 跨语种比较没有意义，因此向量带语种标记，只在同语种内做余弦。
final class LingShuLocalTextEmbedding: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [NLLanguage: NLEmbedding?] = [:]

    func vectorWithLanguage(for text: String) -> (vector: [Double], language: String)? {
        let language = dominantLanguage(of: text)
        guard let embedding = embedding(for: language),
              let vector = embedding.vector(for: normalizedSentence(text)) else {
            return nil
        }
        return (vector, language.rawValue)
    }

    static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        let denominator = (lhsNorm.squareRoot() * rhsNorm.squareRoot())
        return denominator > 0 ? dot / denominator : 0
    }

    private func dominantLanguage(of text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(280)))
        let language = recognizer.dominantLanguage ?? .simplifiedChinese
        // 句向量只内建了有限语种；中文方言/未识别统一走简体中文，其余走英文。
        if language == .simplifiedChinese || language == .traditionalChinese {
            return .simplifiedChinese
        }
        return .english
    }

    private func embedding(for language: NLLanguage) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[language] {
            return cached
        }
        let loaded = NLEmbedding.sentenceEmbedding(for: language)
        cache[language] = loaded
        return loaded
    }

    /// 向量化前剥离会话填充词：「帮我/麻烦/一下/我想…」这类无信息量词是中文幽灵相似度的主要来源。
    /// 只剥多字安全填充词，不动单字（避免误伤"目的""申请"里的"的""请"）。剥光了则退回原文。
    private static let embeddingFillerPhrases = [
        "帮我", "帮忙", "麻烦你", "麻烦", "请问", "一下", "我想要", "我想",
        "你能不能", "你可以", "可以帮", "然后", "另外", "顺便", "就是说", "对了"
    ]

    private func normalizedSentence(_ text: String) -> String {
        var sentence = text.replacingOccurrences(of: "\n", with: " ")
        for phrase in Self.embeddingFillerPhrases {
            sentence = sentence.replacingOccurrences(of: phrase, with: "")
        }
        let cleaned = sentence.trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? text : cleaned).prefix(480))
    }
}

/// 内嵌式 RAG 记忆库：SQLite（FTS5 全文索引 + 向量 BLOB）单文件落在本机，
/// 零外部进程、零网络依赖——承担 Redis/向量库在服务器世界里的角色。
/// 检索是混合式的：FTS5（中文按字 bigram 切词）与句向量余弦各自排序，
/// 倒数排名融合（RRF）后输出，谁可用用谁，互为兜底。
final class LingShuSemanticMemoryStore: @unchecked Sendable {
    static let defaultDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LingShu/Memory", isDirectory: true)

    private let queue = DispatchQueue(label: "lingshu.semantic-memory")
    private let embedding = LingShuLocalTextEmbedding()
    private var database: OpaquePointer?
    private let databaseURL: URL

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL = LingShuSemanticMemoryStore.defaultDirectory) {
        databaseURL = directory.appendingPathComponent("semantic-memory.sqlite3")
        queue.sync {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            openAndMigrate()
        }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    /// 预热：后台触发一次向量模型加载，避免首条消息的检索被模型加载卡住。
    func warmUp() {
        queue.async { [embedding] in
            _ = embedding.vectorWithLanguage(for: "预热")
        }
    }

    var count: Int {
        queue.sync {
            scalarInt("SELECT COUNT(*) FROM memories") ?? 0
        }
    }

    func count(kind: String) -> Int {
        queue.sync {
            scalarInt("SELECT COUNT(*) FROM memories WHERE kind = ?", bindings: [.text(kind)]) ?? 0
        }
    }

    /// 写入或更新一条语义记忆。同 kind + title 视为同一条目（更新内容并保鲜），
    /// 内容向量与全文索引同步更新。
    @discardableResult
    func remember(
        kind: String,
        title: String,
        content: String,
        tags: [String] = [],
        importance: Double = 0.5
    ) -> String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedContent.isEmpty else { return nil }

        return queue.sync {
            guard database != nil else { return nil }
            let now = Date().timeIntervalSince1970
            let existingID = firstColumnText(
                "SELECT id FROM memories WHERE kind = ? AND title = ? LIMIT 1",
                bindings: [kind, trimmedTitle]
            )
            let id = existingID ?? "sem-\(Int(now))-\(UUID().uuidString.prefix(8))"
            let vector = embedding.vectorWithLanguage(for: "\(trimmedTitle)\n\(trimmedContent)")
            let searchText = LingShuMemoryTextToolkit.searchableText("\(trimmedTitle) \(trimmedContent) \(tags.joined(separator: " "))")

            execute(
                """
                INSERT INTO memories (id, kind, title, content, tags, importance, created_at, updated_at, embedding, embedding_lang)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    content = excluded.content,
                    tags = excluded.tags,
                    importance = MAX(memories.importance, excluded.importance),
                    updated_at = excluded.updated_at,
                    embedding = excluded.embedding,
                    embedding_lang = excluded.embedding_lang
                """,
                bindings: [
                    .text(id), .text(kind), .text(trimmedTitle), .text(trimmedContent),
                    .text(tags.joined(separator: ",")), .double(importance),
                    .double(now), .double(now),
                    vector.map { .blob(Self.encodeVector($0.vector)) } ?? .null,
                    vector.map { .text($0.language) } ?? .null
                ]
            )
            execute("DELETE FROM memories_fts WHERE id = ?", bindings: [.text(id)])
            execute(
                "INSERT INTO memories_fts (id, search_text) VALUES (?, ?)",
                bindings: [.text(id), .text(searchText)]
            )
            pruneIfNeeded()
            return id
        }
    }

    /// 混合语义检索：FTS5 与向量余弦分别取序，RRF 融合，附带轻微的新近加成。
    func recall(query: String, limit: Int = 4) -> [LingShuSemanticMemoryHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return queue.sync {
            guard database != nil else { return [] }

            let ftsRanked = fullTextRankedIDs(query: trimmed, limit: 24)
            let vectorRanked = vectorRankedIDs(query: trimmed, limit: 24)
            guard !ftsRanked.isEmpty || !vectorRanked.isEmpty else { return [] }

            // 倒数排名融合：两路命中谁都不需要分数归一化。
            var fused: [String: (score: Double, sources: Set<String>)] = [:]
            for (rank, id) in ftsRanked.enumerated() {
                fused[id, default: (0, [])].score += 1.0 / Double(60 + rank)
                fused[id]?.sources.insert("全文")
            }
            for (rank, id) in vectorRanked.enumerated() {
                fused[id, default: (0, [])].score += 1.0 / Double(60 + rank)
                fused[id]?.sources.insert("向量")
            }

            let now = Date().timeIntervalSince1970
            return fused
                .compactMap { id, value -> LingShuSemanticMemoryHit? in
                    guard let entry = loadEntry(id: id) else { return nil }
                    let ageDays = max(0, now - entry.updatedAt.timeIntervalSince1970) / 86_400
                    let recencyBoost = 0.002 / (1 + ageDays / 14)
                    let importanceBoost = entry.importance * 0.002
                    return .init(
                        entry: entry,
                        score: value.score + recencyBoost + importanceBoost,
                        matchedBy: value.sources.sorted().joined(separator: "+")
                    )
                }
                .sorted { $0.score > $1.score }
                .prefix(limit)
                .map { $0 }
        }
    }

    /// 全部条目（按更新时间倒序），供调试/测试/后续记忆面板使用。
    func recentEntries(limit: Int = 50) -> [LingShuSemanticMemoryEntry] {
        queue.sync {
            var statement: OpaquePointer?
            var entries: [LingShuSemanticMemoryEntry] = []
            guard sqlite3_prepare_v2(database, "SELECT id FROM memories ORDER BY updated_at DESC LIMIT ?", -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 0),
                   let entry = loadEntry(id: String(cString: cString)) {
                    entries.append(entry)
                }
            }
            return entries
        }
    }

    func clearAll() {
        queue.sync {
            execute("DELETE FROM memories_fts")
            execute("DELETE FROM memories")
        }
    }

    // MARK: - 检索两路

    private func fullTextRankedIDs(query: String, limit: Int) -> [String] {
        let tokens = LingShuMemoryTextToolkit.searchTokens(query)
        guard !tokens.isEmpty else { return [] }
        let matchQuery = tokens
            .prefix(24)
            .map { "\"\($0)\"" }
            .joined(separator: " OR ")

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id FROM memories_fts WHERE memories_fts MATCH ? ORDER BY bm25(memories_fts) LIMIT ?",
            -1, &statement, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, matchQuery, -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                ids.append(String(cString: cString))
            }
        }
        return ids
    }

    /// 本地 NLEmbedding 对无关中文短句有"幽灵相似度"（虚高余弦）。两道闸门压制：
    /// ① 太短的查询不信任向量，交给全文路；② 抬高余弦阈值，短查询再加一档。
    private static let minVectorSimilarity = 0.45

    private func vectorRankedIDs(query: String, limit: Int) -> [String] {
        let queryLength = query.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard queryLength >= 3, let queryVector = embedding.vectorWithLanguage(for: query) else { return [] }
        let threshold = queryLength < 12 ? Self.minVectorSimilarity + 0.1 : Self.minVectorSimilarity

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id, embedding FROM memories WHERE embedding IS NOT NULL AND embedding_lang = ? ORDER BY updated_at DESC LIMIT 512",
            -1, &statement, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, queryVector.language, -1, Self.transient)

        var scored: [(id: String, similarity: Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idCString = sqlite3_column_text(statement, 0),
                  let blob = sqlite3_column_blob(statement, 1) else { continue }
            let byteCount = Int(sqlite3_column_bytes(statement, 1))
            let data = Data(bytes: blob, count: byteCount)
            let vector = Self.decodeVector(data)
            let similarity = LingShuLocalTextEmbedding.cosineSimilarity(queryVector.vector, vector)
            if similarity >= threshold {
                scored.append((String(cString: idCString), similarity))
            }
        }
        return scored
            .sorted { $0.similarity > $1.similarity }
            .prefix(limit)
            .map(\.id)
    }

    // MARK: - 存储底座

    private func openAndMigrate() {
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            database = nil
            return
        }

        execute("PRAGMA journal_mode = WAL")
        execute(
            """
            CREATE TABLE IF NOT EXISTS memories (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL DEFAULT '',
                importance REAL NOT NULL DEFAULT 0.5,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                embedding BLOB,
                embedding_lang TEXT
            )
            """
        )
        execute("CREATE INDEX IF NOT EXISTS idx_memories_updated ON memories(updated_at DESC)")
        // 中文没有空格分词，写入前已按字 bigram 预切；unicode61 直接按空格成词即可。
        execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
                id UNINDEXED,
                search_text,
                tokenize = 'unicode61'
            )
            """
        )
    }

    private func pruneIfNeeded() {
        guard let total = scalarInt("SELECT COUNT(*) FROM memories"), total > 2400 else { return }
        // 超量时淘汰「重要性低 × 最久未更新」的尾部，保留 2000 条。
        execute(
            """
            DELETE FROM memories WHERE id IN (
                SELECT id FROM memories
                ORDER BY importance ASC, updated_at ASC
                LIMIT \(total - 2000)
            )
            """
        )
        execute("DELETE FROM memories_fts WHERE id NOT IN (SELECT id FROM memories)")
    }

    private func loadEntry(id: String) -> LingShuSemanticMemoryEntry? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id, kind, title, content, tags, importance, created_at, updated_at FROM memories WHERE id = ?",
            -1, &statement, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        func text(_ index: Int32) -> String {
            sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
        }
        let tags = text(4).split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return .init(
            id: text(0),
            kind: text(1),
            title: text(2),
            content: text(3),
            tags: tags,
            importance: sqlite3_column_double(statement, 5),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        )
    }

    // MARK: - SQLite 小工具

    private enum Binding {
        case text(String)
        case double(Double)
        case blob(Data)
        case null
    }

    private func execute(_ sql: String, bindings: [Binding] = []) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        sqlite3_step(statement)
    }

    private func execute(_ sql: String, bindings: [String]) {
        execute(sql, bindings: bindings.map { Binding.text($0) })
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer?) {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .double(let value):
                sqlite3_bind_double(statement, index, value)
            case .blob(let data):
                data.withUnsafeBytes { buffer in
                    _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }
    }

    private func firstColumnText(_ sql: String, bindings: [String]) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(bindings.map { Binding.text($0) }, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let cString = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: cString)
    }

    private func scalarInt(_ sql: String) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func scalarInt(_ sql: String, bindings: [Binding]) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func encodeVector(_ vector: [Double]) -> Data {
        let floats = vector.map(Float.init)
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decodeVector(_ data: Data) -> [Double] {
        let count = data.count / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats.map(Double.init)
    }
}
