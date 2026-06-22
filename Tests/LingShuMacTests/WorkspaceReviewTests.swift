import XCTest
@testable import LingShuMac

/// 完全版 #8·编辑-审查闭环模型核守卫:diff 解析成文件+hunk、逐块接受、组装已接受补丁、汇总。
/// + #1 续接策略的会话签名/干净追加判定(适配器据此决定原生续接 vs 降级)。
final class WorkspaceReviewTests: XCTestCase {

    private let sampleDiff = """
    diff --git a/foo.swift b/foo.swift
    index 111..222 100644
    --- a/foo.swift
    +++ b/foo.swift
    @@ -1,3 +1,4 @@
     let a = 1
    -let b = 2
    +let b = 3
    +let c = 4
     let d = 5
    @@ -10,2 +11,2 @@
     x
    -y
    +z
    diff --git a/bar.md b/bar.md
    --- a/bar.md
    +++ b/bar.md
    @@ -1 +1,2 @@
     # 标题
    +正文
    """

    func testParseFilesAndHunks() {
        let files = LingShuWorkspaceReview.parse(unifiedDiff: sampleDiff)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].path, "foo.swift")
        XCTAssertEqual(files[0].hunks.count, 2, "foo.swift 应 2 个 hunk")
        XCTAssertEqual(files[1].path, "bar.md")
        XCTAssertEqual(files[1].hunks.count, 1)
        // hunk 内的增删行分类。
        XCTAssertEqual(files[0].hunks[0].added, 2)
        XCTAssertEqual(files[0].hunks[0].removed, 1)
    }

    func testSummary() {
        let files = LingShuWorkspaceReview.parse(unifiedDiff: sampleDiff)
        let s = LingShuWorkspaceReview.summary(files)
        XCTAssertEqual(s.files, 2)
        XCTAssertEqual(s.acceptedHunks, 3, "默认全接受")
        XCTAssertEqual(s.added, 4)   // foo: 2+1, bar: 1
        XCTAssertEqual(s.removed, 2)
    }

    func testAssembleOnlyAcceptedHunks() {
        var files = LingShuWorkspaceReview.parse(unifiedDiff: sampleDiff)
        // 拒掉 foo 的第二个 hunk + 整个 bar 文件。
        files[0].hunks[1].accepted = false
        files[1].hunks[0].accepted = false
        let patch = LingShuWorkspaceReview.assembleAcceptedPatch(files)
        XCTAssertTrue(patch.contains("foo.swift"), "foo 仍在(第一个 hunk 接受)")
        XCTAssertTrue(patch.contains("let c = 4"), "接受的 hunk 内容在")
        XCTAssertFalse(patch.contains("+z"), "被拒的 foo 第二 hunk 不在")
        XCTAssertFalse(patch.contains("bar.md"), "整文件被拒应跳过")
    }

    func testParseNonDiffIsEmpty() {
        XCTAssertTrue(LingShuWorkspaceReview.parse(unifiedDiff: "这不是 diff\n随便写的").isEmpty)
    }

    // MARK: #1 续接策略的签名/干净追加

    func testCleanContinuationDetection() {
        let m1 = LingShuAgentMessage(role: .user, content: "你好")
        let m2 = LingShuAgentMessage(role: .assistant, content: "在")
        let m3 = LingShuAgentMessage(role: .user, content: "继续")
        let prev = LingShuModelChannelStrategy.signature([m1, m2])
        let appended = LingShuModelChannelStrategy.signature([m1, m2, m3])
        XCTAssertTrue(LingShuModelChannelStrategy.isCleanContinuation(previous: prev, current: appended), "纯追加=干净续接")
        // 压缩:早段被换成摘要 → 前缀变 → 非干净。
        let compacted = LingShuModelChannelStrategy.signature([LingShuAgentMessage(role: .user, content: "【前情提要】…"), m3])
        XCTAssertFalse(LingShuModelChannelStrategy.isCleanContinuation(previous: prev, current: compacted), "改写早段=非干净→应降级")
        // token:native 才带 id。
        XCTAssertEqual(LingShuModelChannelStrategy.continuationToken(mode: .native, lastResponseId: "resp_1"), "resp_1")
        XCTAssertNil(LingShuModelChannelStrategy.continuationToken(mode: .prefixStable, lastResponseId: "resp_1"))
    }
}
