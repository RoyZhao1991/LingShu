import XCTest
@testable import LingShuMac

/// Vault 磁盘 IO + 门面(LingShuKnowledgeGraph)活体测试:存盘/加载/归档/跨实例持久/召回/并入/维护。
@MainActor
final class MemoryVaultTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lingshu-vault-test-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func note(_ id: String, _ title: String, kind: LingShuMemoryNote.Kind = .fact, confidence: Double = 0.8, verified: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> LingShuMemoryNote {
        .init(id: id, kind: kind, title: title, aliases: [], body: "正文 \(title)", links: [], tags: [],
              confidence: confidence, source: .inference, created: verified, updated: verified, lastVerified: verified, sensitive: false, history: [])
    }

    func testVaultSaveLoadRoundTrip() throws {
        let vault = LingShuMemoryVault(root: root)
        vault.ensureDirectories()
        let n = note("roy", "Roy Zhao", kind: .person)
        try vault.save(n)
        let loaded = vault.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, n, "存盘再读应无损")
    }

    func testVaultArchiveRemovesFromActive() throws {
        let vault = LingShuMemoryVault(root: root)
        vault.ensureDirectories()
        let n = note("old", "陈旧")
        try vault.save(n)
        XCTAssertEqual(vault.loadAll().count, 1)
        try vault.archive(n)
        XCTAssertEqual(vault.loadAll().count, 0, "归档后不再出现在活跃集")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("archive/old.md").path), "归档文件仍在(可还原)")
    }

    func testFacadeRememberThenRecall() {
        let kg = LingShuKnowledgeGraph(root: root)
        kg.remember(.init(kind: .preference, title: "回复语言", body: "始终中文", source: .userExplicit, confidence: 0.95))
        let hits = kg.recall("回复语言用什么")
        XCTAssertEqual(hits.first?.title, "回复语言")
    }

    func testFacadeMergesByAliasNoDuplicate() {
        let kg = LingShuKnowledgeGraph(root: root)
        kg.remember(.init(kind: .person, title: "Roy Zhao", aliases: ["灵枢"], body: "主人", source: .userExplicit, confidence: 0.9))
        // "林叔"近音 → 应归并,不新增 person。
        kg.remember(.init(kind: .person, title: "林叔", body: "主人", source: .inference, confidence: 0.5))
        XCTAssertEqual(kg.count, 1, "近音误识别应归并到同一 person,不重复")
        XCTAssertTrue(kg.notes.first?.aliases.contains("林叔") ?? false)
    }

    func testFacadePersistsAcrossReinit() {
        do {
            let kg = LingShuKnowledgeGraph(root: root)
            kg.remember(.init(kind: .fact, title: "所在城市", body: "北京", source: .userExplicit, confidence: 0.9))
        }
        let kg2 = LingShuKnowledgeGraph(root: root)   // 新实例从磁盘恢复
        XCTAssertEqual(kg2.recall("城市").first?.body, "北京", "跨实例(模拟重启)应持久")
    }

    func testFacadeTendArchivesStale() {
        let kg = LingShuKnowledgeGraph(root: root)
        // 直接放一条很旧很低置信的 note 到磁盘,再让 tend 归档。
        let vault = LingShuMemoryVault(root: root)
        vault.ensureDirectories()
        try? vault.save(note("stale", "该归档", confidence: 0.05, verified: Date(timeIntervalSince1970: 1_000_000_000)))
        let kg2 = LingShuKnowledgeGraph(root: root)
        _ = kg2.tend(now: Date())
        XCTAssertFalse(kg2.notes.contains { $0.id == "stale" }, "陈旧低置信应被 tend 归档")
        _ = kg   // 静默未使用告警
    }

    func testFacadeSensitiveRejected() {
        let kg = LingShuKnowledgeGraph(root: root)
        kg.remember(.init(kind: .fact, title: "敏感", body: "x", sensitive: true))
        XCTAssertEqual(kg.count, 0, "敏感内容不入库(隐私红线)")
    }

    func testFacadeClearAllRemovesNotesAndCanReuseVault() {
        let kg = LingShuKnowledgeGraph(root: root)
        kg.remember(.init(kind: .preference, title: "回复语言", body: "中文", source: .userExplicit, confidence: 0.9))
        XCTAssertEqual(kg.count, 1)

        kg.clearAll()
        XCTAssertEqual(kg.count, 0)
        XCTAssertTrue(kg.recall("回复语言").isEmpty, "清空后不应召回旧知识")

        kg.remember(.init(kind: .preference, title: "输出风格", body: "简洁", source: .userExplicit, confidence: 0.9))
        XCTAssertEqual(kg.recall("输出风格").first?.body, "简洁", "清空后 vault 仍应可继续使用")
    }

    func testRecallTextReinforcesHitNotes() {
        // M2:经 recallText(=recall_memory 工具路径)召回 → 命中 note 置信增 + 核验刷新。
        let kg = LingShuKnowledgeGraph(root: root)
        kg.remember(.init(kind: .preference, title: "回复语言", body: "中文", source: .userExplicit, confidence: 0.5))
        let before = kg.notes.first { $0.title == "回复语言" }!
        _ = kg.recallText("回复语言")
        let after = kg.notes.first { $0.title == "回复语言" }!
        XCTAssertGreaterThan(after.confidence, before.confidence, "召回应强化置信(越用越稳)")
        XCTAssertGreaterThanOrEqual(after.lastVerified, before.lastVerified, "召回应刷新核验时间")
    }
}
