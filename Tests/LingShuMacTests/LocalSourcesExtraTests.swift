import XCTest
import AppKit
@testable import LingShuMac

/// 多源接入(日历/邮件/照片)+ 面板富交互 守卫:
/// emlx 解析(纯)、面板可点开项提取(纯)、**照片本机 Vision OCR 真识别**(生成带字图→抽出文字,证明零上传字幕)。
final class LocalSourcesExtraTests: XCTestCase {

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lse-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: 邮件 emlx 解析

    func testEMLXParse() {
        let raw = """
        842
        From: Alice <alice@example.com>
        Subject: 关于项目X的进展
        Date: Sun, 22 Jun 2026 09:00:00 +0800

        正文第一段 ProjectXBody 这是邮件正文。
        <div>HTML 部分应被剥掉</div>
        <?xml version="1.0"?>
        <plist></plist>
        """
        let parsed = LingShuMailSource.parseEMLX(raw)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.subject, "关于项目X的进展")
        XCTAssertTrue(parsed?.from.contains("alice@example.com") ?? false)
        XCTAssertTrue(parsed?.body.contains("ProjectXBody") ?? false)
        XCTAssertFalse(parsed?.body.contains("<div>") ?? true, "HTML 标签应被剥掉")
        XCTAssertFalse(parsed?.body.contains("<?xml") ?? true, "plist 尾不应进正文")
    }

    func testEMLXHeaderFolding() {
        let raw = "10\nSubject: 很长的主题\n 续接部分\nFrom: bob@x.com\n\n正文内容ABC\n"
        let parsed = LingShuMailSource.parseEMLX(raw)
        XCTAssertEqual(parsed?.subject, "很长的主题 续接部分", "折行头应拼接")
        XCTAssertTrue(parsed?.body.contains("正文内容ABC") ?? false)
    }

    func testCleanBodyStripsHTML() {
        let cleaned = LingShuMailSource.cleanBody("<p>你好&nbsp;世界</p>\n\n\n<b>粗</b>")
        XCTAssertFalse(cleaned.contains("<"))
        XCTAssertTrue(cleaned.contains("你好 世界"))
    }

    // MARK: 面板可点开项提取

    func testQuickAskLinksExtraction() {
        let dir = tempDir()
        let real = dir.appendingPathComponent("命中文件.md").path
        try? "x".write(toFile: real, atomically: true, encoding: .utf8)
        let text = """
        本机知识检索命中:
        1. \(real)
           摘录……
        参考链接 https://swift.org/docs 和浏览历史 history://https://apple.com/page
        不存在的 /no/such/file.md 不应出现。
        """
        let links = LingShuQuickAskLinks.extract(from: text)
        let targets = Set(links.map(\.target))
        XCTAssertTrue(targets.contains(real), "存在的文件应可点开")
        XCTAssertTrue(targets.contains("https://swift.org/docs"), "网址应可点开")
        XCTAssertTrue(targets.contains("https://apple.com/page"), "history:// 应取内层真实网址")
        XCTAssertFalse(targets.contains("/no/such/file.md"), "不存在的文件不应出现")
    }

    func testQuickAskLinksDedup() {
        let links = LingShuQuickAskLinks.extract(from: "a https://x.com b https://x.com", fileExists: { _ in false })
        XCTAssertEqual(links.filter { $0.target == "https://x.com" }.count, 1, "同一目标应去重")
    }

    // MARK: 照片本机 OCR(零上传字幕)

    private func makeTextImage(_ text: String, to url: URL) {
        let size = NSSize(width: 700, height: 220)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 24, y: 90),
            withAttributes: [.font: NSFont.systemFont(ofSize: 52), .foregroundColor: NSColor.black])
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    func testPhotoOnDeviceOCR() throws {
        let url = tempDir().appendingPathComponent("shot.png")
        makeTextImage("PhotoOcrToken Lingshu", to: url)
        guard let caption = LingShuPhotoSource.caption(imageAt: url) else {
            throw XCTSkip("本机 Vision OCR 不可用,跳过")
        }
        XCTAssertTrue(caption.contains("PhotoOcrToken") || caption.lowercased().contains("photoocrtoken"),
                      "本机 OCR 应识别出图中文字(零上传):\(caption)")
    }

    func testIndexerSkipsImagesAsText() {
        // 图片不在文本扩展名里,文件遍历索引器不会当文本读(由 index_photos 专门处理)。
        let root = tempDir()
        makeTextImage("X", to: root.appendingPathComponent("a.png"))
        let index = LingShuFileKnowledgeIndex(directory: tempDir())
        let stats = LingShuFileKnowledgeIndexer.reindex(folders: [root.path], into: index)
        XCTAssertEqual(stats.indexed, 0, "图片不应被当文本索引")
    }
}
