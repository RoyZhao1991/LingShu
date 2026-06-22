import XCTest
@testable import LingShuMac

/// 差距3·apply_patch 事务核纯逻辑守卫:多 hunk 应用、锚定失败整批回滚、新建文件、事务性。
final class PatchApplierTests: XCTestCase {

    private func H(_ f: String, _ o: String, _ n: String) -> LingShuPatchApplier.Hunk {
        .init(file: f, oldString: o, newString: n)
    }

    func testMultiHunkSameFileAppliesSequentially() {
        let store = ["/w/a.swift": "let x = 1\nlet y = 2\nlet z = 3\n"]
        let hunks = [H("/w/a.swift", "let x = 1", "let x = 10"), H("/w/a.swift", "let z = 3", "let z = 30")]
        let r = LingShuPatchApplier.computePlan(hunks: hunks) { store[$0] }
        guard case .success(let changes) = r else { return XCTFail("应成功:\(r)") }
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].newContent, "let x = 10\nlet y = 2\nlet z = 30\n")
        XCTAssertFalse(changes[0].created)
    }

    func testMultiFileApplies() {
        let store = ["/w/a.py": "a=1\n", "/w/b.py": "b=2\n"]
        let hunks = [H("/w/a.py", "a=1", "a=11"), H("/w/b.py", "b=2", "b=22")]
        let r = LingShuPatchApplier.computePlan(hunks: hunks) { store[$0] }
        guard case .success(let changes) = r else { return XCTFail("应成功") }
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(Set(changes.map(\.path)), ["/w/a.py", "/w/b.py"])
    }

    func testOneHunkFailsRollsBackWholeBatch() {
        // 第二个 hunk 定位失败 → 整批 failure(调用方据此一个字节都不写)。
        let store = ["/w/a.py": "a=1\n", "/w/b.py": "b=2\n"]
        let hunks = [H("/w/a.py", "a=1", "a=11"), H("/w/b.py", "NOPE_不存在", "x")]
        let r = LingShuPatchApplier.computePlan(hunks: hunks) { store[$0] }
        guard case .failure(let f) = r else { return XCTFail("应整批失败") }
        if case .hunkFailed(let file, let idx, _) = f {
            XCTAssertEqual(file, "/w/b.py"); XCTAssertEqual(idx, 1)
        } else { XCTFail("应是 hunkFailed:\(f)") }
    }

    func testNewFileCreationViaEmptyOld() {
        let hunks = [H("/w/new.py", "", "print('hi')\n")]
        let r = LingShuPatchApplier.computePlan(hunks: hunks) { _ in nil }   // 文件不存在
        guard case .success(let changes) = r else { return XCTFail("新建应成功") }
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(changes[0].created)
        XCTAssertEqual(changes[0].newContent, "print('hi')\n")
    }

    func testEmptyOldOnExistingNonEmptyFileFails() {
        let store = ["/w/a.py": "already here\n"]
        let r = LingShuPatchApplier.computePlan(hunks: [H("/w/a.py", "", "x")]) { store[$0] }
        guard case .failure = r else { return XCTFail("空 old 改非空文件应失败") }
    }

    func testNotFoundFails() {
        let store = ["/w/a.py": "a=1\n"]
        let r = LingShuPatchApplier.computePlan(hunks: [H("/w/a.py", "doesnotexist", "x")]) { store[$0] }
        guard case .failure(.hunkFailed) = r else { return XCTFail("未找到应失败") }
    }

    func testEmptyPatchFails() {
        let r = LingShuPatchApplier.computePlan(hunks: []) { _ in nil }
        XCTAssertEqual(r, .failure(.emptyPatch))
    }

    func testParseEnvelopeWithAliases() {
        let json = "{\"hunks\":[{\"path\":\"/w/a.py\",\"old_string\":\"a\",\"new_string\":\"b\"},{\"file\":\"/w/c.py\",\"old\":\"\",\"new\":\"x\"}]}"
        let hunks = LingShuPatchApplier.parse(json)
        XCTAssertEqual(hunks?.count, 2)
        XCTAssertEqual(hunks?[0], H("/w/a.py", "a", "b"))
        XCTAssertEqual(hunks?[1], H("/w/c.py", "", "x"))
    }

    func testParseRejectsNonPatch() {
        XCTAssertNil(LingShuPatchApplier.parse("not json"))
        XCTAssertNil(LingShuPatchApplier.parse("{\"foo\":1}"))
    }

    func testFuzzTransactionalityNeverPartialOnFailure() {
        // 属性:只要含一个必失败的 hunk,结果必为 failure(绝不返回部分 changes)。
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let store = ["/w/f.txt": "line1\nline2\nline3\n"]
            var hunks = [H("/w/f.txt", "line1", "X"), H("/w/f.txt", "line2", "Y")]
            // 插入一个保证失败的 hunk 到随机位置
            hunks.insert(H("/w/f.txt", "绝不存在\(UInt8.random(in: 0...255, using: &rng))", "Z"), at: Int.random(in: 0...hunks.count, using: &rng))
            let r = LingShuPatchApplier.computePlan(hunks: hunks) { store[$0] }
            guard case .failure = r else { return XCTFail("含必失败 hunk 时必整批失败") }
        }
    }
}
