import XCTest
@testable import LingShuMac

/// 已发送附件可重新预览的前提:**临时文件(粘贴图)发送时必须落到稳定目录**,否则被系统清掉后就预览不了。
final class SentAttachmentPersistTests: XCTestCase {

    /// 临时附件 → 复制到 SentAttachments 稳定目录,内容一致(供事后点击重新预览)。
    func testTempAttachmentPersistedForLaterPreview() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString.prefix(6)).png")
        try Data("imgbytes".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let persisted = LingShuState.persistedSentAttachmentPath(tmp)
        XCTAssertTrue(persisted.contains("SentAttachments"), "临时附件应被复制到稳定目录,不能留在会被清的 temp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: persisted), "复制后的文件应存在(供事后预览)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: persisted)), Data("imgbytes".utf8), "内容应一致")
        try? FileManager.default.removeItem(atPath: persisted)
    }

    /// 已是持久路径的(用户上传/拖入的原文件)→ 原样返回,不做多余复制。
    func testPersistentFileReturnedAsIs() throws {
        // 造一个**不在 temp 下**的文件(用 app-support 根下临时子目录模拟原文件位置)
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("LingShuTest-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("我的文档.pptx")
        try Data("x".utf8).write(to: f)

        XCTAssertEqual(LingShuState.persistedSentAttachmentPath(f), f.path, "已持久的原文件应原样返回,不复制")
    }
}
