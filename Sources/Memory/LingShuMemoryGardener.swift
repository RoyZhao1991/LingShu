import Foundation

/// 知识图谱的「园丁」——自维护的纯决策逻辑(吸收 Obsidian 的"整理"理念,但自动化 + 带护栏)。
/// 抽取由调用方(dreaming + LLM)完成并喂进 `Candidate`;这里只做**确定性**的归一/合并/矛盾消解/衰减/剪枝/补链,
/// 所以可完整单测、可预测、不依赖模型。
enum LingShuMemoryGardener {

    /// 一条待并入的候选事实(由对话蒸馏而来)。
    struct Candidate: Sendable, Equatable {
        var kind: LingShuMemoryNote.Kind
        var title: String
        var aliases: [String] = []
        var body: String = ""
        var source: LingShuMemoryNote.Source = .inference
        var confidence: Double = 0.6
        var sensitive: Bool = false
    }

    /// 并入决策结果(调用方据此落盘:create 写新文件 / update 覆写 / conflict 上报待定)。
    enum Action: Equatable {
        case create(LingShuMemoryNote)
        case update(LingShuMemoryNote)
        /// M5 矛盾上报:两条**等权且都来自用户明说**的事实互相矛盾——不静默择一,保留原值 + 把冲突的新说法上报给用户定夺。
        case conflict(LingShuMemoryNote, incoming: String)
        case skip(String)
    }

    /// M2 召回反哺:一条 note 被召回(=被用到)→ 置信微增 + 刷新核验时间(抵消衰减)。久不被召回的自然沉底。
    static func reinforce(_ note: LingShuMemoryNote, now: Date = Date(), bump: Double = 0.02) -> LingShuMemoryNote {
        var n = note
        n.confidence = min(1, n.confidence + bump)
        n.lastVerified = now
        return n
    }

    /// 把候选并入图谱:① 隐私/空值护栏 ② 别名归一到已有 note(命中=update,否则=create)
    /// ③ 矛盾消解:正文不同且来源不弱于原 note → 替换、旧结论入 history;再次确认则别名合并 + 置信微增。
    static func integrate(
        _ candidate: Candidate,
        into notes: [LingShuMemoryNote],
        now: Date = Date(),
        makeID: (String) -> String = LingShuMemoryGardener.defaultID
    ) -> Action {
        // —— 硬护栏 ——
        if candidate.sensitive { return .skip("敏感内容拒入(隐私红线)") }
        let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .skip("空标题") }

        // —— 归一:标题或任一别名命中已有 note ——
        let hitID = LingShuMemoryGraph.resolve(name: title, in: notes)
            ?? candidate.aliases.lazy.compactMap { LingShuMemoryGraph.resolve(name: $0, in: notes) }.first
        if let hitID, var note = notes.first(where: { $0.id == hitID }) {
            // 合并别名(把候选标题/别名都纳入,排除与正式标题重名)
            let incoming = ([title] + candidate.aliases).filter { LingShuMemoryGraph.norm($0) != LingShuMemoryGraph.norm(note.title) }
            note.aliases = dedup(note.aliases + incoming)
            // 矛盾消解
            let newBody = candidate.body.trimmingCharacters(in: .whitespacesAndNewlines)
            note.updated = now
            note.lastVerified = now
            if newBody.isEmpty || LingShuMemoryGraph.norm(newBody) == LingShuMemoryGraph.norm(note.body) {
                note.confidence = min(1, note.confidence + 0.05)   // 同结论再次确认 → 置信微增
                return .update(note)
            }
            // 正文冲突:按 来源权威 + 等权时新旧 裁决
            if candidate.source.weight > note.source.weight {
                if !note.body.isEmpty { note.history.append("[\(iso(note.updated))] \(note.body)") }
                note.body = newBody; note.source = candidate.source
                note.confidence = max(note.confidence, candidate.confidence)
                return .update(note)
            }
            if candidate.source.weight < note.source.weight {
                return .update(note)   // 更弱来源不得覆盖更权威结论(仅刷新核验)
            }
            // 等权冲突:都用户明说 → **不静默择一,上报待定**(M5);否则(都推断/都工具)取较新候选、旧入 history
            if candidate.source == .userExplicit {
                return .conflict(note, incoming: newBody)
            }
            if !note.body.isEmpty { note.history.append("[\(iso(note.updated))] \(note.body)") }
            note.body = newBody; note.source = candidate.source
            note.confidence = max(note.confidence, candidate.confidence)
            return .update(note)
        }

        // —— 新建 ——
        let note = LingShuMemoryNote(
            id: makeID(title),
            kind: candidate.kind,
            title: title,
            aliases: dedup(candidate.aliases),
            body: candidate.body.trimmingCharacters(in: .whitespacesAndNewlines),
            links: [],
            tags: [],
            confidence: candidate.confidence,
            source: candidate.source,
            created: now,
            updated: now,
            lastVerified: now,
            sensitive: false,
            history: []
        )
        return .create(note)
    }

    /// 置信度衰减:长期未核验的 note 置信随时间指数下降(半衰期默认 30 天)。返回更新后的全集。
    static func decay(_ notes: [LingShuMemoryNote], now: Date = Date(), halfLifeDays: Double = 30) -> [LingShuMemoryNote] {
        notes.map { note in
            var n = note
            let days = now.timeIntervalSince(n.lastVerified) / 86_400
            if days > halfLifeDays {
                n.confidence = max(0, n.confidence * pow(0.5, days / halfLifeDays))
            }
            return n
        }
    }

    /// 剪枝:置信过低且长期未核验 → 归档(keep / archive 分离;调用方把 archive 移到 archive/,不删可还原)。
    static func prune(
        _ notes: [LingShuMemoryNote],
        now: Date = Date(),
        minConfidence: Double = 0.15,
        maxAgeDays: Double = 120
    ) -> (keep: [LingShuMemoryNote], archive: [LingShuMemoryNote]) {
        var keep: [LingShuMemoryNote] = []
        var archive: [LingShuMemoryNote] = []
        for note in notes {
            let days = now.timeIntervalSince(note.lastVerified) / 86_400
            if note.confidence < minConfidence && days > maxAgeDays { archive.append(note) }
            else { keep.append(note) }
        }
        return (keep, archive)
    }

    /// 补链:扫"未链提及"——某 note 正文提到了另一 note 的标题/别名却没建链 → 建议 (src→dst)。让图谱自生长。
    static func suggestLinks(_ notes: [LingShuMemoryNote]) -> [(src: String, dst: String)] {
        var out: [(String, String)] = []
        for note in notes {
            let bodyNorm = LingShuMemoryGraph.norm(note.body)
            guard !bodyNorm.isEmpty else { continue }
            for other in notes where other.id != note.id && !note.links.contains(other.id) {
                let names = ([other.title] + other.aliases).filter { $0.count >= 2 }
                if names.contains(where: { bodyNorm.contains(LingShuMemoryGraph.norm($0)) }) {
                    out.append((note.id, other.id))
                }
            }
        }
        return out
    }

    // MARK: - 工具

    static func defaultID(_ title: String) -> String {
        let slug = title.lowercased()
            .map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
            .split(separator: "-").joined(separator: "-")
        let base = slug.isEmpty ? "note" : String(slug.prefix(40))
        return "\(base)-\(UUID().uuidString.prefix(6).lowercased())"
    }

    private static func dedup(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for item in items {
            let t = item.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = LingShuMemoryGraph.norm(t)
            guard !t.isEmpty, !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(t)
        }
        return out
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
