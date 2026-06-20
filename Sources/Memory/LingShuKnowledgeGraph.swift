import Foundation

/// 记忆 v2 门面:把 vault(磁盘)+ 内存 notes + 图谱召回 + 园丁维护 接成一个对象,供 LingShuState 调。
/// `@MainActor`(与 state 同域,接线简单);重活(召回/园丁)都是纯静态函数,这里只做协调与落盘。
@MainActor
final class LingShuKnowledgeGraph {
    /// 默认库目录:~/Library/Application Support/LingShu/Memory/vault(人/Obsidian 可直接打开)。
    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("LingShu/Memory/vault", isDirectory: true)
    }

    private let vault: LingShuMemoryVault
    private(set) var notes: [LingShuMemoryNote] = []
    /// 本地句向量(NLEmbedding,零网络/隐私安全),给 vault 笔记做语义索引;.md 仍是真相源,向量是可重建的派生索引。
    private let embedder = LingShuLocalTextEmbedding()
    private var vectors: [String: [Double]] = [:]

    init(root: URL = LingShuKnowledgeGraph.defaultRoot) {
        vault = LingShuMemoryVault(root: root)
        vault.ensureDirectories()
        notes = vault.loadAll()
        rebuildVectorIndex()
    }

    var count: Int { notes.count }

    // MARK: - 召回(混合:精确实体 + 关键词 + 语义向量 + 图扩展)

    func recall(_ query: String, limit: Int = 6) -> [LingShuMemoryNote] {
        let queryVector = embedder.vectorWithLanguage(for: query)?.vector ?? []
        return LingShuMemoryGraph.recall(query: query, notes: notes, queryVector: queryVector, noteVectors: vectors, limit: limit)
    }

    /// 给一条 note 算句向量(标题+正文+别名);embedding 不可用则返回空(召回自动退化为关键词+图)。
    private func embed(_ note: LingShuMemoryNote) -> [Double] {
        embedder.vectorWithLanguage(for: "\(note.title)。\(note.body) \(note.aliases.joined(separator: " "))")?.vector ?? []
    }

    /// 重建全量向量索引(从磁盘加载后调一次;懒加载 facade 故不在 app 启动路径上)。
    private func rebuildVectorIndex() {
        vectors.removeAll(keepingCapacity: true)
        for note in notes {
            let v = embed(note)
            if !v.isEmpty { vectors[note.id] = v }
        }
    }

    /// 召回成可读文本(非敏感才出);供 recall_memory 工具 + 每轮自动注入 additive 追加。无命中返回 nil。
    /// **M2 召回反哺**(`reinforceHits`):把召回到的 note 轻度强化(置信微增 + 刷新核验)——被用到的越用越稳,久不召回的随衰减沉底。
    /// 主动调用(recall_memory 工具)reinforce=true;**每轮被动自动注入用 reinforce=false**——否则每轮都强化 top-K
    /// 会让置信虚高、lastVerified 永远新鲜、园丁衰减/剪枝失效。
    func recallText(_ query: String, limit: Int = 6, reinforceHits: Bool = true) -> String? {
        let hits = recall(query, limit: limit).filter { !$0.sensitive }
        guard !hits.isEmpty else { return nil }
        if reinforceHits { reinforce(ids: hits.map { $0.id }) }
        // 召回措辞永远"供参考,自行判断"——知识是决策参考,绝不写成规则/必须(知识纪律,见方案 §3.2/§3.3)。
        return "知识图谱「\(query)」(\(LingShuKnowledgeDiscipline.recallDisclaimer)):\n" + hits.map { note in
            "- [\(note.kind.rawValue)] \(note.title):\(note.body.prefix(120))"
        }.joined(separator: "\n")
    }

    /// M2:强化指定 note(被召回=被用到)。原地更新置信/核验时间并落盘。
    private func reinforce(ids: [String], now: Date = Date()) {
        for id in ids {
            guard let i = notes.firstIndex(where: { $0.id == id }) else { continue }
            notes[i] = LingShuMemoryGardener.reinforce(notes[i], now: now)
            try? vault.save(notes[i])
        }
    }

    // MARK: - 写入(园丁并入 + 落盘)

    @discardableResult
    func remember(_ candidate: LingShuMemoryGardener.Candidate, now: Date = Date()) -> LingShuMemoryGardener.Action {
        let action = LingShuMemoryGardener.integrate(candidate, into: notes, now: now)
        switch action {
        case .create(let note), .update(let note), .conflict(let note, _):
            // conflict 也落盘:别名已并、原值保留(矛盾的新说法不采纳,由调用方上报给用户定夺)。
            upsert(note)
            try? vault.save(note)
            let v = embed(note)                       // 文本变了就重算该 note 的向量(增量,不全量重建)
            if v.isEmpty { vectors.removeValue(forKey: note.id) } else { vectors[note.id] = v }
        case .skip:
            break
        }
        return action
    }

    /// 决策知识种子(方案 P0②):首启把第一个知识包种进图谱(陈述性事实/教训)。幂等——有标记笔记即跳过。
    /// 返回本次新种条数(0 = 已种过)。每条仍走 `remember`(过纪律闸 + 园丁去重),所以重复调用安全。
    @discardableResult
    func seedDecisionKnowledgeIfNeeded(now: Date = Date()) -> Int {
        if notes.contains(where: { $0.title == LingShuSeedKnowledge.markerTitle }) { return 0 }
        var seeded = 0
        for candidate in LingShuSeedKnowledge.candidates {
            if case .create = remember(candidate, now: now) { seeded += 1 }
        }
        _ = remember(LingShuSeedKnowledge.markerCandidate, now: now)   // 落幂等标记
        return seeded
    }

    // MARK: - 维护(由 dreaming 调:衰减 → 补链 → 剪枝归档,带上限护栏)

    /// 返回本次维护的 changelog(供审计/日志)。`maxArchivePerPass` 限制单次归档量(有界增长护栏)。
    @discardableResult
    func tend(now: Date = Date(), maxArchivePerPass: Int = 20) -> String {
        var changes: [String] = []

        // 1. 衰减
        notes = LingShuMemoryGardener.decay(notes, now: now)

        // 2. 补链(未链提及 → 建链)
        let suggestions = LingShuMemoryGardener.suggestLinks(notes)
        if !suggestions.isEmpty {
            for (src, dst) in suggestions {
                if let i = notes.firstIndex(where: { $0.id == src }), !notes[i].links.contains(dst) {
                    notes[i].links.append(dst)
                    try? vault.save(notes[i])
                }
            }
            changes.append("补链 \(suggestions.count) 条")
        }

        // 3. 剪枝归档(有界)
        let (keep, archive) = LingShuMemoryGardener.prune(notes, now: now)
        let toArchive = Array(archive.prefix(maxArchivePerPass))
        if !toArchive.isEmpty {
            for note in toArchive { try? vault.archive(note) }
            let archivedIDs = Set(toArchive.map { $0.id })
            notes = keep + archive.filter { !archivedIDs.contains($0.id) }   // 超上限的留到下次
            changes.append("归档 \(toArchive.count) 条")
        } else {
            notes = keep + archive
        }

        // 衰减后的置信度持久化(被改过的全存一遍,量可控)
        for note in notes { try? vault.save(note) }

        return changes.isEmpty ? "无变更" : changes.joined(separator: "、")
    }

    // MARK: - 内部

    private func upsert(_ note: LingShuMemoryNote) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note }
        else { notes.append(note) }
    }
}
