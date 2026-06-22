import XCTest
@testable import LingShuMac

/// 通用增量入库管线守卫(源增量化的通用机制核心):
/// upsert 变化项 / 按 owns 只剪本源不误删别源 / stillExists 防误删 / 各源 scan 的增量跳过。
final class LocalKnowledgeIngestTests: XCTestCase {

    private func tempIndex() -> LingShuFileKnowledgeIndex {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lki-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return LingShuFileKnowledgeIndex(directory: d)
    }

    // MARK: 通用入库 upsert + 按归属剪枝

    func testIngestUpsertsChangedAndPrunesOwnedAbsent() {
        let index = tempIndex()
        // 预置:一条日历 + 一条浏览历史(不同源)。
        index.upsertFile(path: "calendar://e1", mtime: 1, text: "旧会议")
        index.upsertFile(path: "history://https://a.com", mtime: 1, text: "网页")

        // 日历源本次扫描:e1 变了(mtime 2)、e1 仍在;新增 e2。浏览历史不归日历管。
        var scan = LingShuKnowledgeScan()
        scan.seenPaths = ["calendar://e1", "calendar://e2"]
        scan.changed = [.init(path: "calendar://e1", mtime: 2, text: "新会议"),
                        .init(path: "calendar://e2", mtime: 2, text: "另一个会")]
        let r = LingShuKnowledgeIngest.ingest(scan, owns: LingShuCalendarSource.owns, into: index)
        XCTAssertEqual(r.indexed, 2)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(index.knownMtime(for: "calendar://e1"), 2, "变化项应更新")
        XCTAssertNotNil(index.knownMtime(for: "calendar://e2"))
        XCTAssertNotNil(index.knownMtime(for: "history://https://a.com"), "别源条目绝不能被日历入库动到")
    }

    func testIngestPrunesOwnedDeletedButNotOtherSources() {
        let index = tempIndex()
        index.upsertFile(path: "calendar://e1", mtime: 1, text: "会议")
        index.upsertFile(path: "history://https://a.com", mtime: 1, text: "网页")
        // 日历本次扫描为空(事件都删了)→ 应剪掉 calendar://e1,但 history:// 保留。
        let r = LingShuKnowledgeIngest.ingest(LingShuKnowledgeScan(), owns: LingShuCalendarSource.owns, into: index)
        XCTAssertEqual(r.removed, 1)
        XCTAssertNil(index.knownMtime(for: "calendar://e1"))
        XCTAssertNotNil(index.knownMtime(for: "history://https://a.com"), "浏览历史不归日历,不能被剪")
    }

    func testIngestStillExistsGuardsAgainstFalsePrune() {
        let index = tempIndex()
        let real = NSTemporaryDirectory() + "lki-real-\(UUID().uuidString).md"
        try? "x".write(toFile: real, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: real) }
        index.upsertFile(path: real, mtime: 1, text: "内容")
        // 文件源本次没扫到它(比如目录临时没传),但文件还在 → stillExists=fileExists 兜底,不误删。
        let r = LingShuKnowledgeIngest.ingest(LingShuKnowledgeScan(), owns: LingShuFileKnowledgeIndexer.owns,
                                              stillExists: { FileManager.default.fileExists(atPath: $0) }, into: index)
        XCTAssertEqual(r.removed, 0)
        XCTAssertNotNil(index.knownMtime(for: real), "文件还在,不该误删")
    }

    func testFileOwnsExcludesImagesPhotoOwnsImages() {
        XCTAssertTrue(LingShuFileKnowledgeIndexer.owns("/x/a.md"))
        XCTAssertFalse(LingShuFileKnowledgeIndexer.owns("/x/a.png"), "图片归照片源,不归文件源")
        XCTAssertTrue(LingShuPhotoSource.owns("/x/a.png"))
        XCTAssertFalse(LingShuPhotoSource.owns("/x/a.md"))
        XCTAssertFalse(LingShuFileKnowledgeIndexer.owns("history://x"))
        XCTAssertTrue(LingShuCalendarSource.owns("calendar://1"))
        XCTAssertTrue(LingShuMailSource.owns("mail:///p"))
        XCTAssertTrue(LingShuBrowserHistorySource.owns("history://u"))
    }

    // MARK: 文件源 scan 增量跳过

    func testFileScanSkipsUnchangedByMtime() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lki-scan-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("a.md")
        try? "alpha".write(to: f, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: f.path)
        // 已知该路径 mtime=1000 → scan 应跳过(changed 空),但 seenPaths 仍含它。
        let scan = LingShuFileKnowledgeIndexer.scan(folders: [dir.path], knownMtime: { _ in 1000 })
        XCTAssertTrue(scan.changed.isEmpty, "mtime 未变应跳过抽取")
        XCTAssertEqual(scan.seenPaths.count, 1, "仍应把文件计入 seenPaths(供剪枝)")
        XCTAssertTrue(scan.seenPaths.first?.hasSuffix("a.md") ?? false)
        // 未知 mtime → 应纳入 changed。
        let scan2 = LingShuFileKnowledgeIndexer.scan(folders: [dir.path], knownMtime: { _ in nil })
        XCTAssertEqual(scan2.changed.count, 1)
    }
}
