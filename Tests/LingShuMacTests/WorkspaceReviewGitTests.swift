import XCTest
@testable import LingShuMac

/// 完全版 #8·审查回退**对真 git 仓库**的端到端守卫:改文件→git diff→解析→组装→`git apply --reverse` 真还原。
final class WorkspaceReviewGitTests: XCTestCase {

    private func sh(_ args: [String], _ dir: String? = nil) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
        if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit(); return p.terminationStatus
    }

    func testReviewRevertRoundTripAgainstRealGit() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("无 git") }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wrg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = dir.path
        XCTAssertEqual(sh(["-C", d, "init", "-q"]), 0)
        _ = sh(["-C", d, "config", "user.email", "t@t.com"]); _ = sh(["-C", d, "config", "user.name", "t"])

        let file = dir.appendingPathComponent("a.txt")
        let original = "line1\nline2\nline3\nline4\nline5\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(sh(["-C", d, "add", "-A"]), 0)
        XCTAssertEqual(sh(["-C", d, "commit", "-qm", "init"]), 0)

        // 改两处。
        try "line1\nCHANGED2\nline3\nline4\nCHANGED5\n".write(to: file, atomically: true, encoding: .utf8)

        let diff = LingShuWorkspaceReviewGit.diff(dir: d)
        XCTAssertTrue(diff.contains("CHANGED2"), "git diff 应含改动")
        let files = LingShuWorkspaceReview.parse(unifiedDiff: diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.path, "a.txt")

        // 全部"拒绝"=回退全部:组装(默认 accepted=true 即全部改动)→ apply --reverse。
        let patch = LingShuWorkspaceReview.assembleAcceptedPatch(files)
        XCTAssertTrue(LingShuWorkspaceReviewGit.applyReverse(patch: patch, dir: d), "git apply --reverse 应成功")
        let restored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(restored, original, "回退后文件应还原到提交版本")
    }
}
