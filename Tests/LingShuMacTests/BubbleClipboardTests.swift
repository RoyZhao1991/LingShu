import AppKit
import XCTest
@testable import LingShuMac

final class BubbleClipboardTests: XCTestCase {
    func testPlainCopyIncludesTextAndExistingAttachmentFiles() throws {
        let first = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-copy-first-\(UUID().uuidString).txt")
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-copy-second-\(UUID().uuidString).txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let pasteboard = NSPasteboard(name: .init("BubbleClipboardTests.\(UUID().uuidString)"))
        let copiedCount = LingShuBubbleClipboard.copyPlainText(
            fromMarkdown: "**Read these files**",
            attachmentPaths: [first.path, second.path],
            to: pasteboard
        )

        XCTAssertEqual(copiedCount, 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "Read these files")
        let copiedURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        XCTAssertEqual(Set(copiedURLs?.map(\.standardizedFileURL) ?? []), Set([first, second]))
    }

    func testPlainCopySkipsMissingAttachmentWithoutLosingText() {
        let pasteboard = NSPasteboard(name: .init("BubbleClipboardTests.\(UUID().uuidString)"))
        let copiedCount = LingShuBubbleClipboard.copyPlainText(
            fromMarkdown: "message",
            attachmentPaths: ["/tmp/lingshu-missing-\(UUID().uuidString).txt"],
            to: pasteboard
        )

        XCTAssertEqual(copiedCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "message")
    }

    func testMarkdownCopyDoesNotAttachFiles() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-copy-markdown-\(UUID().uuidString).txt")
        try Data("attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let pasteboard = NSPasteboard(name: .init("BubbleClipboardTests.\(UUID().uuidString)"))
        LingShuBubbleClipboard.copyMarkdown("# Heading", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "# Heading")
        XCTAssertEqual(
            pasteboard.string(forType: NSPasteboard.PasteboardType("public.markdown")),
            "# Heading"
        )
        let copiedURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        XCTAssertTrue(copiedURLs?.isEmpty ?? true)
    }

    @MainActor
    func testCopiedBubblePastesTextAndAllAttachmentsIntoComposer() throws {
        let first = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-copy-paste-first-\(UUID().uuidString).docx")
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-copy-paste-second-\(UUID().uuidString).html")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let pasteboard = NSPasteboard(name: .init("BubbleClipboardPasteRoundTrip.\(UUID().uuidString)"))
        LingShuBubbleClipboard.copyPlainText(
            fromMarkdown: "读取这些文档",
            attachmentPaths: [first.path, second.path],
            to: pasteboard
        )

        let textView = LingShuInputTextView(frame: .zero)
        var receivedURLs: [URL] = []
        textView.onDropFiles = { receivedURLs = $0 }

        XCTAssertTrue(textView.ingestPasteboard(pasteboard))
        XCTAssertEqual(textView.string, "读取这些文档")
        XCTAssertEqual(
            Set(receivedURLs.map(\.standardizedFileURL)),
            Set([first.standardizedFileURL, second.standardizedFileURL])
        )
    }

    @MainActor
    func testPastingFilesOnlyDoesNotInsertTheirPathsAsText() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-file-only-paste-\(UUID().uuidString).pdf")
        try Data("attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let pasteboard = NSPasteboard(name: .init("BubbleClipboardFileOnly.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([file as NSURL]))

        let textView = LingShuInputTextView(frame: .zero)
        var receivedURLs: [URL] = []
        textView.onDropFiles = { receivedURLs = $0 }

        XCTAssertTrue(textView.ingestPasteboard(pasteboard))
        XCTAssertEqual(textView.string, "")
        XCTAssertEqual(receivedURLs.map(\.standardizedFileURL), [file.standardizedFileURL])
    }
}
