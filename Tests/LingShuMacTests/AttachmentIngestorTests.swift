import XCTest
@testable import LingShuMac

final class AttachmentIngestorTests: XCTestCase {
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
