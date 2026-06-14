import XCTest
@testable import LingShuMac

final class AttachmentIngestorTests: XCTestCase {
    func testDroppedFilePathDetection() throws {
        // 拖入文件落成路径文本 → 整框=存在的绝对路径才识别为附件路径;正文/不存在的路径不误转。
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ling-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f1 = dir.appendingPathComponent("九曜守灵_导演本_1.docx")   // 中文名 + 下划线
        let f2 = dir.appendingPathComponent("a b.txt")                  // 含空格
        try "x".write(to: f1, atomically: true, encoding: .utf8)
        try "y".write(to: f2, atomically: true, encoding: .utf8)

        XCTAssertEqual(LingShuState.droppedFilePaths(in: f1.path), [f1.path], "单个存在文件路径 → 识别")
        XCTAssertEqual(LingShuState.droppedFilePaths(in: "\(f1.path)\n\(f2.path)").count, 2, "多行多文件 → 全识别")
        XCTAssertTrue(LingShuState.droppedFilePaths(in: "看看这个 \(f1.path) 文件").isEmpty, "正文里顺带的路径 → 不误转")
        XCTAssertTrue(LingShuState.droppedFilePaths(in: "/Users/example/Downloads/不存在.docx").isEmpty, "不存在的路径 → 不转")
        XCTAssertTrue(LingShuState.droppedFilePaths(in: "随便聊聊").isEmpty, "普通文字 → 不转")
    }

    func testKindDetectionByExtension() {
        XCTAssertEqual(LingShuAttachmentIngestor.kind(forExtension: "png"), .image)
        XCTAssertEqual(LingShuAttachmentIngestor.kind(forExtension: "JPEG"), .image)
        XCTAssertEqual(LingShuAttachmentIngestor.kind(forExtension: "pptx"), .presentation)
        XCTAssertEqual(LingShuAttachmentIngestor.kind(forExtension: "pdf"), .document)
        XCTAssertEqual(LingShuAttachmentIngestor.kind(forExtension: "md"), .text)
        XCTAssertEqual(LingShuAttachmentIngestor.kind(forExtension: "zip"), .other)
    }

    func testIngestTextFileExtractsContent() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ls-attach-\(UUID().uuidString).md")
        try "# 标题\n这是正文内容".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ingestor = LingShuAttachmentIngestor(perceptionClient: nil)
        let attachment = await ingestor.ingest(fileURL: tmp)

        XCTAssertEqual(attachment.kind, .text)
        XCTAssertTrue(attachment.extractedContext.contains("这是正文内容"))
        XCTAssertNil(attachment.status)
        XCTAssertGreaterThan(attachment.byteCount, 0)
    }

    func testIngestEmptyFileReportsStatus() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ls-empty-\(UUID().uuidString).txt")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ingestor = LingShuAttachmentIngestor(perceptionClient: nil)
        let attachment = await ingestor.ingest(fileURL: tmp)
        XCTAssertNotNil(attachment.status)
        XCTAssertEqual(attachment.byteCount, 0)
    }

    func testImageWithoutPerceptionClientIsRegisteredNotParsed() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ls-img-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ingestor = LingShuAttachmentIngestor(perceptionClient: nil)
        let attachment = await ingestor.ingest(fileURL: tmp)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertTrue(attachment.extractedContext.isEmpty)
        XCTAssertNotNil(attachment.status)
    }
}
