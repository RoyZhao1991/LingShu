import XCTest
@testable import LingShuMac

/// 「产物邻里勘探」通用解(2026-06-28):任务引用了产物文件 → 把它**所在目录的兄弟文件**(尤其源/生成器)喂给 agent,
/// 并注入"改源而非改成品"铁律。根治实测:agent 只点验被告知的文件、从不整列目录、没认出旁边的 `*.gen.py` 源。
final class ArtifactNeighborhoodContextTests: XCTestCase {

    /// 核心:引用某产物 → 上下文必须列出同目录的**源/生成器**(diagram.gen.py),并带"改源"铁律。
    func testSurfacesSiblingSourceAndSourceFirstRule() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neigh-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("diagram.png"))
        try Data("y".utf8).write(to: dir.appendingPathComponent("diagram.gen.py"))   // 源,就在 PNG 旁边

        let ctx = LingShuState.artifactNeighborhoodContext(for: "请把 \(dir.appendingPathComponent("diagram.png").path) 第5页的箭头改成双向")

        XCTAssertTrue(ctx.contains("diagram.png"), "应列出引用的产物")
        XCTAssertTrue(ctx.contains("diagram.gen.py"), "**关键**:同目录的源/生成器必须被列出来(没列就还是认不出源)")
        XCTAssertTrue(ctx.contains("先溯源"), "应注入「先溯源→无法溯源再改/重做」统一范式")
        XCTAssertTrue(ctx.contains("溯源") && ctx.contains("的源很可能是"),
                      "**关键**:应**替它溯源**、把'产物→源'映射直接交到手里(diagram.png → diagram.gen.py),不靠它自己发现")
        // #3:改源后走原管线、别手搓产物
        XCTAssertTrue(ctx.contains("管线") && ctx.contains("别手搓"),
                      "改源后应「用产生它的那条管线重新生成」、别手搓 pptx/手动摆图(根治截断 bug)")
    }

    /// #1:多模态脑「能看就别写像素码」指令——禁止逐像素扫描/比对,引导直接看图。
    func testVisionOverPixelsDirective() {
        let d = LingShuState.visionOverPixelsDirective
        XCTAssertTrue(d.contains("像素") && d.contains("别"), "应禁止逐像素扫描/比对")
        XCTAssertTrue(d.contains("看图") || d.contains("直接\"看\"") || d.contains("用眼睛"), "应引导直接看图、用眼睛")
    }

    /// 溯源要 precise:`X.png` 只配 `X.*` 的源,不串到同目录别的产物的源(`Y.gen.py`)。
    func testTracingIsPreciseNotCrossWired() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neigh-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("diagram.png"))
        try Data("y".utf8).write(to: dir.appendingPathComponent("diagram.gen.py"))   // diagram 的源
        try Data("z".utf8).write(to: dir.appendingPathComponent("arch.gen.py"))       // 别的产物的源,不该被当成 diagram 的源

        let ctx = LingShuState.artifactNeighborhoodContext(for: "改 \(dir.appendingPathComponent("diagram.png").path)")
        // 溯源行里:diagram.png → diagram.gen.py(对),不该把 arch.gen.py 列成 diagram.png 的源
        let tracedLine = ctx.split(separator: "\n").first { $0.contains("的源很可能是") } ?? ""
        XCTAssertTrue(tracedLine.contains("diagram.gen.py"), "diagram.png 的源应是 diagram.gen.py")
        XCTAssertFalse(tracedLine.contains("arch.gen.py"), "不该把 arch.gen.py 串成 diagram.png 的源(溯源要 precise)")
    }

    /// 没引用到存在的文件 → 返回空串(零开销、不注入噪声),不挑场景。
    func testEmptyWhenNoExistingFileReferenced() {
        XCTAssertEqual(LingShuState.artifactNeighborhoodContext(for: "帮我写个排序算法"), "")
        XCTAssertEqual(LingShuState.artifactNeighborhoodContext(for: "改 /Users/nobody/这文件不存在.pptx"), "")
    }
}
