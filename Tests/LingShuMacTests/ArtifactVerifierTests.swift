import XCTest
@testable import LingShuMac

/// 完全版 #3·产出物验收注册表守卫:类型识别 + 各类型确定性验收(文档长度/数据合法/图片可解码/通用存在非空)+ 批量调度。
final class ArtifactVerifierTests: XCTestCase {

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("av-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func write(_ dir: URL, _ name: String, _ content: String) -> String {
        let p = dir.appendingPathComponent(name).path
        try? content.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    func testKindDetection() {
        XCTAssertEqual(LingShuArtifactKindDetector.kind(forPath: "/x/a.swift"), .code)
        XCTAssertEqual(LingShuArtifactKindDetector.kind(forPath: "/x/a.pptx"), .ppt)
        XCTAssertEqual(LingShuArtifactKindDetector.kind(forPath: "/x/a.pdf"), .pdf)
        XCTAssertEqual(LingShuArtifactKindDetector.kind(forPath: "/x/a.md"), .markdown)
        XCTAssertEqual(LingShuArtifactKindDetector.kind(forPath: "/x/a.json"), .data)
        XCTAssertEqual(LingShuArtifactKindDetector.kind(forPath: "/x/a.png"), .image)
        XCTAssertEqual(LingShuArtifactKindDetector.kind(forPath: "/x/a.xyz"), .generic)
    }

    func testGenericMissingAndEmpty() {
        let reg = LingShuArtifactVerifierRegistry.shared
        XCTAssertFalse(reg.verify(path: "/no/such/file.bin").passed, "不存在应不过")
        let dir = tempDir()
        let empty = dir.appendingPathComponent("e.bin").path
        FileManager.default.createFile(atPath: empty, contents: Data())
        XCTAssertFalse(reg.verify(path: empty).passed, "空文件应不过")
    }

    func testDocumentMinLength() {
        let reg = LingShuArtifactVerifierRegistry.shared
        let dir = tempDir()
        let short = write(dir, "short.md", "标题")          // <20 字
        let full = write(dir, "full.md", String(repeating: "正文内容很充实。", count: 5))
        XCTAssertFalse(reg.verify(path: short).passed, "正文过短应判空交付")
        XCTAssertTrue(reg.verify(path: full).passed)
    }

    func testDataFormat() {
        let reg = LingShuArtifactVerifierRegistry.shared
        let dir = tempDir()
        XCTAssertTrue(reg.verify(path: write(dir, "ok.json", "{\"a\":1}")).passed)
        XCTAssertFalse(reg.verify(path: write(dir, "bad.json", "{不是json")).passed)
        XCTAssertTrue(reg.verify(path: write(dir, "ok.csv", "h1,h2\n1,2")).passed)
        XCTAssertFalse(reg.verify(path: write(dir, "bad.csv", "只有表头")).passed)
    }

    func testImageDecodable() {
        let reg = LingShuArtifactVerifierRegistry.shared
        let dir = tempDir()
        // 假图片(改扩展名的文本)应不过。
        XCTAssertFalse(reg.verify(path: write(dir, "fake.png", "这不是图片")).passed)
    }

    func testVerifyAllBatch() {
        let reg = LingShuArtifactVerifierRegistry.shared
        let dir = tempDir()
        let good = write(dir, "good.md", String(repeating: "内容充实的文档。", count: 4))
        let bad = write(dir, "bad.json", "{坏的")
        let (allPassed, verdicts) = reg.verifyAll(paths: [good, bad])
        XCTAssertFalse(allPassed)
        XCTAssertEqual(verdicts.count, 2)
        XCTAssertEqual(verdicts.first { !$0.passed }?.kind, .data)
    }
}
