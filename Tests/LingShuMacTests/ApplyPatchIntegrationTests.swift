import XCTest
@testable import LingShuMac

/// 差距3·apply_patch **真盘集成**(offline,确定性):事务性落盘、失败整批不动盘、工作目录围栏。
/// 比"指望模型在 E2E 里挑 apply_patch"可靠——直接驱动 runApplyPatch 验证磁盘效果。
@MainActor
final class ApplyPatchIntegrationTests: XCTestCase {

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "lingshu-patch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testTransactionalApplyWritesAllFiles() async throws {
        let state = LingShuState()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = dir + "/a.py", b = dir + "/b.py"
        try "a=1\n".write(toFile: a, atomically: true, encoding: .utf8)
        try "b=2\n".write(toFile: b, atomically: true, encoding: .utf8)

        let json = "{\"hunks\":[{\"file\":\"\(a)\",\"old\":\"a=1\",\"new\":\"a=11\"},{\"file\":\"\(b)\",\"old\":\"b=2\",\"new\":\"b=22\"}]}"
        let out = await state.runApplyPatch(argsJSON: json, recordID: nil, workingDirectory: dir)

        XCTAssertTrue(out.contains("成功"), "应报成功:\(out)")
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), "a=11\n")
        XCTAssertEqual(try String(contentsOfFile: b, encoding: .utf8), "b=22\n")
    }

    func testFailureLeavesAllFilesUntouched() async throws {
        let state = LingShuState()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = dir + "/a.py", b = dir + "/b.py"
        try "a=1\n".write(toFile: a, atomically: true, encoding: .utf8)
        try "b=2\n".write(toFile: b, atomically: true, encoding: .utf8)

        // 第二个 hunk 定位失败 → 整批回滚:a 也不能被改(事务性的真盘验证)。
        let json = "{\"hunks\":[{\"file\":\"\(a)\",\"old\":\"a=1\",\"new\":\"a=11\"},{\"file\":\"\(b)\",\"old\":\"不存在的内容\",\"new\":\"x\"}]}"
        let out = await state.runApplyPatch(argsJSON: json, recordID: nil, workingDirectory: dir)

        XCTAssertTrue(out.contains("失败") && out.contains("均未改动"), "应整批失败:\(out)")
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), "a=1\n", "事务回滚:a 不能被改")
        XCTAssertEqual(try String(contentsOfFile: b, encoding: .utf8), "b=2\n", "b 不能被改")
    }

    func testWorkingDirectoryFenceRejectsOutsidePath() async throws {
        let state = LingShuState()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let inside = dir + "/ok.py"
        try "x=1\n".write(toFile: inside, atomically: true, encoding: .utf8)
        let outside = NSTemporaryDirectory() + "lingshu-escape-\(UUID().uuidString).py"
        try "secret\n".write(toFile: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: outside) }

        let json = "{\"hunks\":[{\"file\":\"\(inside)\",\"old\":\"x=1\",\"new\":\"x=2\"},{\"file\":\"\(outside)\",\"old\":\"secret\",\"new\":\"hacked\"}]}"
        let out = await state.runApplyPatch(argsJSON: json, recordID: nil, workingDirectory: dir)

        XCTAssertTrue(out.contains("不在工作目录"), "越界应被围栏拒绝:\(out)")
        XCTAssertEqual(try String(contentsOfFile: inside, encoding: .utf8), "x=1\n", "围栏拒绝=整批不改,inside 也不动")
        XCTAssertEqual(try String(contentsOfFile: outside, encoding: .utf8), "secret\n", "工作目录外文件绝不能被改")
    }

    func testNewFileCreation() async throws {
        let state = LingShuState()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let newFile = dir + "/created.py"
        let json = "{\"hunks\":[{\"file\":\"\(newFile)\",\"old\":\"\",\"new\":\"print('new')\\n\"}]}"
        let out = await state.runApplyPatch(argsJSON: json, recordID: nil, workingDirectory: dir)
        XCTAssertTrue(out.contains("成功"), "新建应成功:\(out)")
        XCTAssertEqual(try String(contentsOfFile: newFile, encoding: .utf8), "print('new')\n")
    }
}
