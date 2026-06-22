import XCTest
import SQLite3
import AppKit
import CoreText
@testable import LingShuMac

/// 多源接入 ①(PDF + 浏览器历史)守卫:
/// ① epoch 转换;② 从合成 sqlite 读 Chrome/Safari 历史;③ PDF 真抽取(CoreGraphics 生成带文字 PDF);
/// ④ 文件遍历剪枝**不误删**合成源(history://)。
final class LocalSourcesTests: XCTestCase {

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ls-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: epoch

    func testEpochConversions() {
        // Chrome: 1601 起微秒;13_350_000_000_000_000 → 2024 左右(unix 秒为正、量级对)。
        let chrome = LingShuBrowserHistorySource.chromeUnixTime(13_350_000_000_000_000)
        XCTAssertEqual(chrome, 13_350_000_000_000_000 / 1_000_000 - 11_644_473_600, accuracy: 1)
        XCTAssertGreaterThan(chrome, 1_600_000_000)   // > 2020
        // Safari: 2001 起秒;700_000_000 → +978307200。
        XCTAssertEqual(LingShuBrowserHistorySource.safariUnixTime(700_000_000), 1_678_307_200, accuracy: 1)
    }

    // MARK: Chrome / Safari 合成 db 读取

    private func exec(_ db: OpaquePointer?, _ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    func testChromeHistoryRead() {
        let path = tempDir().appendingPathComponent("History").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        exec(db, "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_time INTEGER)")
        exec(db, "INSERT INTO urls(url,title,last_visit_time) VALUES('https://swift.org','Swift 官网',13350000000000000)")
        exec(db, "INSERT INTO urls(url,title,last_visit_time) VALUES('https://old.com','旧站',13000000000000000)")
        sqlite3_close(db)

        let entries = LingShuBrowserHistorySource.chrome(dbPath: path, limit: 10)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.url, "https://swift.org", "应按最近访问降序")
        XCTAssertEqual(entries.first?.title, "Swift 官网")
        XCTAssertGreaterThan(entries.first!.lastVisit, 1_600_000_000)
    }

    func testSafariHistoryRead() {
        let path = tempDir().appendingPathComponent("History.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        exec(db, "CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT)")
        exec(db, "CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT)")
        exec(db, "INSERT INTO history_items(id,url) VALUES(1,'https://apple.com')")
        exec(db, "INSERT INTO history_visits(history_item,visit_time,title) VALUES(1,700000000.0,'Apple')")
        sqlite3_close(db)

        let entries = LingShuBrowserHistorySource.safari(dbPath: path, limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.url, "https://apple.com")
        XCTAssertEqual(entries.first?.title, "Apple")
        XCTAssertEqual(entries.first?.lastVisit ?? 0, 1_678_307_200, accuracy: 1)
    }

    func testHistoryReadMissingDBReturnsEmpty() {
        XCTAssertTrue(LingShuBrowserHistorySource.chrome(dbPath: "/no/such/History", limit: 5).isEmpty)
    }

    // MARK: PDF 抽取(真生成带文字 PDF)

    private func makeTextPDF(_ text: String, at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 20, y: 150)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    func testPDFTextExtraction() {
        let url = tempDir().appendingPathComponent("note.pdf")
        makeTextPDF("PdfUniqueToken 灵枢PDF抽取测试", at: url)
        let extracted = LingShuDocumentText.extract(from: url)
        XCTAssertNotNil(extracted, "应能从 PDF 抽出文本")
        XCTAssertTrue(extracted?.contains("PdfUniqueToken") ?? false, "抽取内容应含标记:\(extracted ?? "nil")")
    }

    func testIndexerIndexesPDF() {
        let root = tempDir()
        makeTextPDF("ZxcvPdfMarker 文档内容", at: root.appendingPathComponent("doc.pdf"))
        let index = LingShuFileKnowledgeIndex(directory: tempDir())
        let stats = LingShuFileKnowledgeIndexer.reindex(folders: [root.path], into: index)
        XCTAssertEqual(stats.indexed, 1, "PDF 应被索引")
        XCTAssertTrue(index.search(query: "ZxcvPdfMarker", limit: 5).first?.path.hasSuffix("doc.pdf") ?? false)
    }

    // MARK: 剪枝不误删合成源

    func testPruneKeepsSyntheticSources() {
        let root = tempDir()
        try? "alpha".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let index = LingShuFileKnowledgeIndex(directory: tempDir())
        // 一条合成的浏览器历史(非文件路径)。
        index.upsertFile(path: "history://https://example.com", mtime: 1, text: "示例站 example")
        _ = LingShuFileKnowledgeIndexer.reindex(folders: [root.path], into: index)
        XCTAssertNotNil(index.knownMtime(for: "history://https://example.com"))

        // 删掉文件后重索引:文件被剪,但 history:// 合成源必须保留。
        try? FileManager.default.removeItem(at: root.appendingPathComponent("a.md"))
        _ = LingShuFileKnowledgeIndexer.reindex(folders: [root.path], into: index)
        XCTAssertNotNil(index.knownMtime(for: "history://https://example.com"), "剪枝绝不能误删合成源")
        XCTAssertTrue(index.search(query: "example", limit: 5).contains { $0.path.hasPrefix("history://") })
    }
}
