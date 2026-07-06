import XCTest
@testable import LingShuMac

/// 记忆 v2(Obsidian 化知识图谱)单测:模型往返 / 别名归一(治同音污染)/ 双通道召回 / 园丁自维护。
final class MemoryGraphTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)   // 整秒,markdown 往返稳定

    private func note(
        _ id: String, kind: LingShuMemoryNote.Kind = .fact, title: String, aliases: [String] = [],
        body: String = "", links: [String] = [], confidence: Double = 0.8,
        source: LingShuMemoryNote.Source = .inference, verified: Date? = nil, sensitive: Bool = false
    ) -> LingShuMemoryNote {
        .init(id: id, kind: kind, title: title, aliases: aliases, body: body, links: links, tags: [],
              confidence: confidence, source: source, created: t0, updated: t0, lastVerified: verified ?? t0,
              sensitive: sensitive, history: [])
    }

    // MARK: - ① 模型 Markdown 往返

    func testMarkdownRoundTrip() {
        let original = note("roy-zhao", kind: .person, title: "Roy Zhao", aliases: ["刘叔", "灵枢主人"],
                            body: "灵枢的主人。要求中文回复。链接 [[lingshu-project]]。", links: ["lingshu-project"],
                            confidence: 0.95, source: .userExplicit)
        guard let parsed = LingShuMemoryNote.parse(original.markdown()) else { return XCTFail("解析失败") }
        XCTAssertEqual(parsed, original, "Markdown 序列化应无损往返")
    }

    func testParseHistorySection() {
        var n = note("p", title: "项目X", body: "现状结论")
        n.history = ["[旧] 之前的错误结论"]
        guard let parsed = LingShuMemoryNote.parse(n.markdown()) else { return XCTFail() }
        XCTAssertEqual(parsed.history, ["[旧] 之前的错误结论"])
    }

    // MARK: - ② 别名归一(同音污染根治)

    func testResolveByExactAlias() {
        let notes = [note("roy", kind: .person, title: "Roy Zhao", aliases: ["主人"])]
        XCTAssertEqual(LingShuMemoryGraph.resolve(name: "主人", in: notes), "roy")
    }

    func testResolveHomophonePollution() {
        // 主人 person:别名含正式"灵枢" + 已知 ASR 怪体"刘叔"(显式别名)。
        // "林叔"(lín shū)是"灵枢"(líng shū)的**真近音** → 靠拼音模糊自动归一;
        // "刘叔"(liú)拼音并不近,不靠规则强并(防误合并),而是作为显式别名归一。
        let notes = [note("roy", kind: .person, title: "Roy Zhao", aliases: ["灵枢", "刘叔"])]
        XCTAssertEqual(LingShuMemoryGraph.resolve(name: "林叔", in: notes), "roy", "林叔≈灵枢 读音自动归一")
        XCTAssertEqual(LingShuMemoryGraph.resolve(name: "刘叔", in: notes), "roy", "刘叔=显式别名归一")
    }

    func testResolveMissReturnsNil() {
        let notes = [note("roy", kind: .person, title: "Roy Zhao")]
        XCTAssertNil(LingShuMemoryGraph.resolve(name: "完全无关的东西", in: notes))
    }

    // MARK: - ③ 召回(精确命中 / 关键词 / 图扩展)

    func testRecallExactEntityRanksTop() {
        let notes = [
            note("roy", kind: .person, title: "Roy Zhao", body: "主人", confidence: 0.9),
            note("x", title: "无关", body: "随便", confidence: 0.9)
        ]
        let hits = LingShuMemoryGraph.recall(query: "Roy Zhao 喜欢什么", notes: notes, now: t0)
        XCTAssertEqual(hits.first?.id, "roy", "query 含实体名 → 该 note 排第一")
    }

    func testRecallGraphExpansionPullsNeighbor() {
        // 命中 roy(含链接到 proj);proj 本身 query 不命中,但应被图扩展拉进来。
        let notes = [
            note("roy", kind: .person, title: "Roy Zhao", body: "主人", links: ["proj"], confidence: 0.9),
            note("proj", kind: .project, title: "深海项目", body: "保密内容", confidence: 0.9)
        ]
        let hits = LingShuMemoryGraph.recall(query: "Roy Zhao", notes: notes, now: t0)
        XCTAssertTrue(hits.contains { $0.id == "proj" }, "种子的链接邻居应被关联召回")
    }

    func testRecallEmptyOnNoMatch() {
        let notes = [note("a", title: "苹果", body: "水果")]
        XCTAssertTrue(LingShuMemoryGraph.recall(query: "量子色动力学", notes: notes, now: t0).isEmpty)
    }

    // MARK: - ③.5 语义向量通道(用合成向量确定性验证机制,不依赖 NLEmbedding 真模型)

    func testCosineHelper() {
        XCTAssertEqual(LingShuMemoryGraph.cosine([1, 0], [1, 0]), 1.0, accuracy: 0.001)
        XCTAssertEqual(LingShuMemoryGraph.cosine([1, 0], [0, 1]), 0.0, accuracy: 0.001)
        XCTAssertEqual(LingShuMemoryGraph.cosine([], []), 0.0)
        XCTAssertEqual(LingShuMemoryGraph.cosine([1, 2], [1]), 0.0, "维度不一致返回 0")
    }

    func testRecallVectorChannelSemanticSeed() {
        // query 与两条 note 都**无关键词重叠**;只靠向量:A 与 query 同向(高余弦)→召回,B 正交→不召回。
        let a = note("a", title: "甲", body: "内容甲")
        let b = note("b", title: "乙", body: "内容乙")
        let hits = LingShuMemoryGraph.recall(
            query: "完全不搭边的查询", notes: [a, b],
            queryVector: [1, 0, 0], noteVectors: ["a": [0.9, 0.1, 0.0], "b": [0.0, 1.0, 0.0]], now: t0)
        XCTAssertEqual(hits.first?.id, "a", "语义相近(高余弦)应召回并排前")
        XCTAssertFalse(hits.contains { $0.id == "b" }, "语义正交不召回")
    }

    func testRecallVectorSeedExpandsGraph() {
        // 向量命中的种子,其链接邻居也应被关联召回(语义 + 图谱结合)。
        let a = note("a", title: "甲", body: "x", links: ["b"])
        let b = note("b", title: "乙", body: "y")
        let hits = LingShuMemoryGraph.recall(
            query: "无关", notes: [a, b], queryVector: [1, 0], noteVectors: ["a": [1, 0]], now: t0)
        XCTAssertTrue(hits.contains { $0.id == "b" }, "向量种子的链接邻居被关联召回")
    }

    func testRecallVectorEmptyFallsBackToKeyword() {
        // 不给向量(embedding 不可用场景)→ 退化为关键词+图,行为不变。
        let notes = [note("a", title: "苹果", body: "一种水果")]
        let hits = LingShuMemoryGraph.recall(query: "苹果", notes: notes, queryVector: [], noteVectors: [:], now: t0)
        XCTAssertEqual(hits.first?.id, "a")
    }

    // MARK: - ④ 园丁:并入 / 矛盾消解 / 衰减 / 剪枝 / 补链

    func testIntegrateCreatesWhenNew() {
        let action = LingShuMemoryGardener.integrate(
            .init(kind: .preference, title: "回复语言", body: "始终中文", source: .userExplicit, confidence: 0.9),
            into: [], now: t0)
        guard case .create(let n) = action else { return XCTFail("应新建") }
        XCTAssertEqual(n.title, "回复语言")
        XCTAssertEqual(n.source, .userExplicit)
    }

    func testAdmissionAcceptsStableUserPreference() {
        let action = LingShuMemoryGardener.integrate(
            .init(kind: .preference, title: "回复语言", body: "用户明确要求默认使用中文回复。", source: .userExplicit, confidence: 0.9),
            into: [], now: t0)
        guard case .create(let n) = action else { return XCTFail("用户明说的稳定偏好应进入知识图谱") }
        XCTAssertEqual(n.kind, .preference)
    }

    func testAdmissionRejectsLowConfidenceInferenceFact() {
        let action = LingShuMemoryGardener.integrate(
            .init(kind: .fact, title: "用两句话介绍自己", body: "经验:目标「用两句话介绍自己」(interaction)结果=已直接回答。", source: .inference, confidence: 0.55),
            into: [], now: t0)
        guard case .skip(let reason) = action else { return XCTFail("低证据推断/普通问答流水账不应进入知识图谱") }
        XCTAssertTrue(reason.contains("置信度不足") || reason.contains("流水账") || reason.contains("推断"))
    }

    func testAdmissionAcceptsToolObservedDurableFact() {
        let action = LingShuMemoryGardener.integrate(
            .init(kind: .fact, title: "语义记忆数据库路径",
                  body: "语义记忆数据库位于本机应用支持目录的 LingShu/Memory/semantic-memory.sqlite3。",
                  source: .tool, confidence: 0.82),
            into: [], now: t0)
        guard case .create(let n) = action else { return XCTFail("工具确认的稳定事实应进入知识图谱") }
        XCTAssertEqual(n.source, .tool)
    }

    func testIntegrateMergesByAliasNotDuplicate() {
        let existing = [note("roy", kind: .person, title: "Roy Zhao", aliases: ["灵枢"], body: "主人")]
        // 误识别的"林叔"作为候选 → 应归并到 roy(update),不新建第二个 person。
        let action = LingShuMemoryGardener.integrate(
            .init(kind: .person, title: "林叔", body: "主人", source: .inference, confidence: 0.5),
            into: existing, now: t0)
        guard case .update(let n) = action else { return XCTFail("应归并 update 而非新建") }
        XCTAssertEqual(n.id, "roy")
        XCTAssertTrue(n.aliases.contains("林叔"), "新别名应并入")
    }

    func testContradictionAuthoritativeWinsOldGoesHistory() {
        let existing = [note("city", title: "所在城市", body: "上海", confidence: 0.6, source: .inference)]
        // 用户明说"北京"(更权威)→ 覆盖,旧值入 history。
        let action = LingShuMemoryGardener.integrate(
            .init(kind: .fact, title: "所在城市", body: "北京", source: .userExplicit, confidence: 0.9),
            into: existing, now: t0)
        guard case .update(let n) = action else { return XCTFail() }
        XCTAssertEqual(n.body, "北京")
        XCTAssertTrue(n.history.contains { $0.contains("上海") }, "被推翻的旧结论应入 history")
    }

    func testContradictionWeakerSourceDoesNotOverride() {
        let existing = [note("city", title: "所在城市", body: "北京", confidence: 0.9, source: .userExplicit)]
        let action = LingShuMemoryGardener.integrate(
            .init(kind: .fact, title: "所在城市", body: "上海", source: .inference, confidence: 0.5),
            into: existing, now: t0)
        guard case .update(let n) = action else { return XCTFail() }
        XCTAssertEqual(n.body, "北京", "更弱来源不得覆盖更权威结论")
    }

    func testSensitiveCandidateRejected() {
        let action = LingShuMemoryGardener.integrate(
            .init(kind: .fact, title: "某敏感事实", body: "x", sensitive: true), into: [], now: t0)
        guard case .skip = action else { return XCTFail("敏感内容必须拒入") }
    }

    func testEmptyTitleRejected() {
        let action = LingShuMemoryGardener.integrate(.init(kind: .fact, title: "  "), into: [], now: t0)
        guard case .skip = action else { return XCTFail("空标题拒入") }
    }

    func testDecayLowersStaleConfidence() {
        let old = note("a", title: "陈旧事实", confidence: 0.8, verified: t0)
        let later = t0.addingTimeInterval(90 * 86_400)   // 90 天后
        let decayed = LingShuMemoryGardener.decay([old], now: later, halfLifeDays: 30)
        XCTAssertLessThan(decayed[0].confidence, 0.8, "长期未核验应衰减")
    }

    func testPruneArchivesStaleLowConfidence() {
        let stale = note("a", title: "该归档", confidence: 0.1, verified: t0)
        let fresh = note("b", title: "保留", confidence: 0.9, verified: t0)
        let later = t0.addingTimeInterval(200 * 86_400)
        let result = LingShuMemoryGardener.prune([stale, fresh], now: later)
        XCTAssertEqual(result.archive.map { $0.id }, ["a"])
        XCTAssertEqual(result.keep.map { $0.id }, ["b"])
    }

    func testSuggestLinksFindsUnlinkedMention() {
        let notes = [
            note("roy", kind: .person, title: "Roy Zhao", body: "在做 深海项目 这个东西"),
            note("proj", kind: .project, title: "深海项目", body: "保密")
        ]
        let links = LingShuMemoryGardener.suggestLinks(notes)
        XCTAssertTrue(links.contains { $0.src == "roy" && $0.dst == "proj" }, "正文提到却未链 → 应建议补链")
    }

    func testSuggestLinksSkipsExisting() {
        let notes = [
            note("roy", kind: .person, title: "Roy Zhao", body: "在做 深海项目", links: ["proj"]),
            note("proj", kind: .project, title: "深海项目", body: "保密")
        ]
        XCTAssertTrue(LingShuMemoryGardener.suggestLinks(notes).isEmpty, "已链不重复建议")
    }

    // MARK: - ⑤ dreaming 抽取 JSON 容错解析

    func testParseCandidatesFromFencedJSON() {
        let raw = """
        好的,这是抽取结果:
        ```json
        [{"kind":"person","title":"Roy Zhao","aliases":["主人"],"body":"灵枢的作者","source":"user-explicit","confidence":0.95,"sensitive":false},
         {"kind":"preference","title":"回复语言","body":"始终中文","source":"user-explicit","confidence":0.9}]
        ```
        以上。
        """
        let cands = LingShuState.parseKnowledgeCandidates(raw)
        XCTAssertEqual(cands.count, 2)
        XCTAssertEqual(cands.first?.title, "Roy Zhao")
        XCTAssertEqual(cands.first?.source, .userExplicit)
        XCTAssertEqual(cands.last?.body, "始终中文")
    }

    func testParseCandidatesEmptyAndGarbage() {
        XCTAssertTrue(LingShuState.parseKnowledgeCandidates("没有可记的,返回 []").isEmpty)
        XCTAssertTrue(LingShuState.parseKnowledgeCandidates("完全不是 JSON").isEmpty)
        XCTAssertTrue(LingShuState.parseKnowledgeCandidates("[{\"kind\":\"person\"}]").isEmpty, "缺 title 应丢弃")
    }

    // MARK: - ⑥ M2 召回反哺 + M5 矛盾上报(园丁)

    func testReinforceBumpsConfidenceAndRefreshes() {
        let later = t0.addingTimeInterval(1000)
        let r = LingShuMemoryGardener.reinforce(note("a", title: "x", confidence: 0.8), now: later, bump: 0.05)
        XCTAssertEqual(r.confidence, 0.85, accuracy: 0.001)
        XCTAssertEqual(r.lastVerified, later)
    }

    func testReinforceCapsAtOne() {
        XCTAssertEqual(LingShuMemoryGardener.reinforce(note("a", title: "x", confidence: 0.99), bump: 0.5).confidence, 1.0, accuracy: 0.001)
    }

    func testConflictEqualUserExplicitSurfaces() {
        // 两条都「用户明说」却矛盾 → 不静默择一,上报待定,保留原值。
        let existing = [note("city", title: "所在城市", body: "北京", confidence: 0.9, source: .userExplicit)]
        let action = LingShuMemoryGardener.integrate(
            .init(kind: .fact, title: "所在城市", body: "上海", source: .userExplicit, confidence: 0.9),
            into: existing, now: t0)
        guard case .conflict(let n, let incoming) = action else { return XCTFail("等权用户矛盾应 .conflict") }
        XCTAssertEqual(n.body, "北京", "保留原值不静默覆盖")
        XCTAssertEqual(incoming, "上海")
    }

    func testEqualWeightInferenceTakesNewer() {
        // 等权但都是推断(非用户)→ 取较新候选,旧入 history,不上报。
        let existing = [note("city", title: "所在城市", body: "上海", confidence: 0.6, source: .inference)]
        let action = LingShuMemoryGardener.integrate(
            .init(kind: .fact, title: "所在城市", body: "北京", source: .inference, confidence: 0.7),
            into: existing, now: t0)
        guard case .update(let n) = action else { return XCTFail("等权推断应 update 取新") }
        XCTAssertEqual(n.body, "北京")
        XCTAssertTrue(n.history.contains { $0.contains("上海") })
    }
}
