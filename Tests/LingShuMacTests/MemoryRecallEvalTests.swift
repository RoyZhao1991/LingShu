import XCTest
@testable import LingShuMac

/// M4 召回质量回归测:一个代表性语料 + 一组 (query → 应召回) 用例,守住召回质量随系统演进不退化。
/// 用**纯 `LingShuMemoryGraph.recall`**(不喂向量)做**确定性**断言(精确实体/关键词/图扩展);
/// 语义向量通道的非确定性质量由合成向量单测(MemoryGraphTests)+ E2E 真 embedding 演示覆盖,不在此做脆断言。
final class MemoryRecallEvalTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func n(_ id: String, _ kind: LingShuMemoryNote.Kind, _ title: String,
                   aliases: [String] = [], body: String = "", links: [String] = []) -> LingShuMemoryNote {
        .init(id: id, kind: kind, title: title, aliases: aliases, body: body, links: links, tags: [],
              confidence: 0.8, source: .inference, created: t0, updated: t0, lastVerified: t0, sensitive: false, history: [])
    }

    private lazy var corpus: [LingShuMemoryNote] = [
        n("roy", .person, "Roy Zhao", aliases: ["主人", "灵枢主人"], body: "灵枢的作者,要求始终中文回复", links: ["lingshu"]),
        n("lingshu", .project, "灵枢项目", body: "本地通用智能中枢,大脑+四肢"),
        n("city", .fact, "所在城市", body: "北京"),
        n("lang", .preference, "回复语言", body: "始终用中文"),
        n("interrupt", .preference, "语音打断", body: "灵枢说话时喊灵枢可实时打断"),
        n("memup", .decision, "记忆系统升级", body: "采用 Obsidian 化原子笔记知识图谱"),
        n("aec", .glossary, "AEC", aliases: ["回声消除"], body: "麦克风消掉自己外放声音的技术"),
        n("ppt", .skill, "做PPT", body: "用 DesignKB 生成器产出高质量幻灯片"),
        n("friend", .person, "张三", body: "一个朋友,跟灵枢项目无关"),
        n("cache", .glossary, "前缀缓存", body: "稳定前缀被服务端缓存以省成本")
    ]

    /// 每条:查询 → 期望必须出现在召回结果里的 note id(top-K 内)。
    private let cases: [(query: String, expect: String)] = [
        ("主人是谁", "roy"),                       // 精确别名
        ("灵枢项目是干嘛的", "lingshu"),           // 关键词
        ("现在在哪个城市", "city"),                // 关键词(城市)
        ("回复语言用什么", "lang"),                // 精确标题
        ("AEC 是什么意思", "aec"),                 // 关键词(AEC)
        ("回声消除", "aec"),                       // 别名
        ("前缀缓存怎么省钱", "cache"),             // 关键词
        ("怎么做PPT", "ppt")                       // 关键词(PPT)
    ]

    func testRecallEvalCorpusHitsExpected() {
        var misses: [String] = []
        for c in cases {
            let hits = LingShuMemoryGraph.recall(query: c.query, notes: corpus, limit: 6, now: t0)
            if !hits.contains(where: { $0.id == c.expect }) {
                misses.append("「\(c.query)」期望命中 \(c.expect),实得 [\(hits.map { $0.id }.joined(separator: ","))]")
            }
        }
        XCTAssertTrue(misses.isEmpty, "召回质量回归:\n" + misses.joined(separator: "\n"))
    }

    func testRecallEvalGraphExpansion() {
        // 命中 roy(含 link→lingshu),问"主人"时 lingshu 应被图扩展带出。
        let hits = LingShuMemoryGraph.recall(query: "主人", notes: corpus, limit: 6, now: t0)
        XCTAssertTrue(hits.contains { $0.id == "roy" })
        XCTAssertTrue(hits.contains { $0.id == "lingshu" }, "种子 roy 的链接邻居 lingshu 应被关联召回")
    }

    func testRecallEvalNoFalsePositiveOnUnrelated() {
        // 无关查询不该把整库都拖出来(尤其无关的"张三")。
        let hits = LingShuMemoryGraph.recall(query: "量子纠缠的物理原理", notes: corpus, limit: 6, now: t0)
        XCTAssertFalse(hits.contains { $0.id == "friend" }, "完全无关查询不应召回无关 person")
    }
}
