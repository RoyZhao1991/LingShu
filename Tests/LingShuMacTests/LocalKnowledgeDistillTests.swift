import XCTest
@testable import LingShuMac

/// ②·dreaming 蒸馏高频本机知识进图谱:① 索引召回热度统计(record/top/clear)② 蒸馏器编排(注入 distill/remember)。
final class LocalKnowledgeDistillTests: XCTestCase {

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lkd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeIndex() -> LingShuFileKnowledgeIndex {
        let index = LingShuFileKnowledgeIndex(directory: tempDir())
        index.upsertFile(path: "/x/hot.md", mtime: 1, text: "灵枢内部代号 ZephyrFox,负责人赵阳,这是高频被问的内容。")
        index.upsertFile(path: "/x/cold.md", mtime: 1, text: "很少被问的边角内容。")
        return index
    }

    // MARK: 召回热度

    func testRecordTopClearHits() {
        let index = makeIndex()
        index.recordHits(["/x/hot.md", "/x/hot.md", "/x/hot.md"])
        index.recordHits(["/x/cold.md"])
        XCTAssertEqual(index.hitCount(for: "/x/hot.md"), 3)
        let top = index.topRecalled(minHits: 3, limit: 5)
        XCTAssertEqual(top.count, 1, "只有 hot.md 达到 3 次")
        XCTAssertEqual(top.first?.path, "/x/hot.md")
        XCTAssertTrue(top.first?.text.contains("ZephyrFox") ?? false, "应取该文件的代表内容")
        index.clearHits(for: ["/x/hot.md"])
        XCTAssertEqual(index.hitCount(for: "/x/hot.md"), 0, "蒸馏后清计数")
        XCTAssertTrue(index.topRecalled(minHits: 3, limit: 5).isEmpty)
    }

    func testHitsPersist() {
        let dir = tempDir()
        do {
            let index = LingShuFileKnowledgeIndex(directory: dir)
            index.upsertFile(path: "/x/a.md", mtime: 1, text: "content")
            index.recordHits(["/x/a.md", "/x/a.md"])
        }
        let reopened = LingShuFileKnowledgeIndex(directory: dir)
        XCTAssertEqual(reopened.hitCount(for: "/x/a.md"), 2, "热度应跨实例持久")
    }

    // MARK: 蒸馏器编排

    private actor FactCollector { var facts: [String] = []; func add(_ f: String) { facts.append(f) } }

    func testDistillerExtractsAndRemembersAndClears() async {
        let index = makeIndex()
        index.recordHits(Array(repeating: "/x/hot.md", count: 4))   // 达阈值
        let collector = FactCollector()

        let added = await LingShuLocalKnowledgeDistiller.run(
            index: index, minHits: 3, limit: 5,
            distill: { _ in "灵枢内部代号是 ZephyrFox\n负责人是赵阳\n太短" },   // 第三条<6字符会被丢
            remember: { fact in await collector.add(fact) }
        )
        XCTAssertEqual(added, 2, "两条合格事实(第三条太短被滤)")
        let facts = await collector.facts
        XCTAssertTrue(facts.contains("灵枢内部代号是 ZephyrFox"))
        XCTAssertTrue(facts.contains("负责人是赵阳"))
        // 蒸馏过应清热度,避免重蒸。
        XCTAssertEqual(index.hitCount(for: "/x/hot.md"), 0)
    }

    func testDistillerNoHotContentNoOp() async {
        let index = makeIndex()   // 没记任何 hits
        let collector = FactCollector()
        let added = await LingShuLocalKnowledgeDistiller.run(
            index: index, minHits: 3,
            distill: { _ in "不该被调用" },
            remember: { f in await collector.add(f) }
        )
        XCTAssertEqual(added, 0)
        let facts = await collector.facts
        XCTAssertTrue(facts.isEmpty)
    }

    func testParseFactsStripsBulletsAndShort() {
        let parsed = LingShuLocalKnowledgeDistiller.parseFacts("- 事实一很完整\n• 事实二也完整\n短\n* 事实三完整内容", max: 5)
        XCTAssertEqual(parsed, ["事实一很完整", "事实二也完整", "事实三完整内容"])
    }
}
