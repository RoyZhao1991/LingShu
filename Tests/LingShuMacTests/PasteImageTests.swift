import XCTest
import AppKit
@testable import LingShuMac

/// 粘贴截图取图守卫:截图到剪贴板是**原始 PNG/TIFF 数据**(不是 NSImage 对象)——老逻辑只 `readObjects([NSImage])`
/// 抓不全 → "截图粘不进附件栏"(Codex/Claude 能、灵枢不能)。`pngFromPasteboard` 要覆盖 PNG / TIFF / NSImage 数据。
final class PasteImageTests: XCTestCase {

    private func sampleImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 6, height: 6))
        img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 6, height: 6).fill(); img.unlockFocus()
        return img
    }

    private func board(_ name: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("lingshu-test-\(name)-\(UUID().uuidString.prefix(6))"))
        pb.clearContents()
        return pb
    }

    /// 截图最常见:剪贴板里是原始 PNG 数据。
    func testExtractsRawPNGData() {
        guard let tiff = sampleImage().tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return XCTFail("造不出 PNG 样本")
        }
        let pb = board("png"); pb.setData(png, forType: .png)
        let out = LingShuInputTextView.pngFromPasteboard(pb)
        XCTAssertNotNil(out, "剪贴板里的原始 PNG 数据应被取到")
        XCTAssertNotNil(out.flatMap { NSBitmapImageRep(data: $0) }, "取到的应是合法 PNG")
    }

    /// 部分来源是 TIFF(系统截图也常给 TIFF)→ 应转成 PNG。
    func testExtractsTIFFAndConvertsToPNG() {
        guard let tiff = sampleImage().tiffRepresentation else { return XCTFail("造不出 TIFF 样本") }
        let pb = board("tiff"); pb.setData(tiff, forType: .tiff)
        XCTAssertNotNil(LingShuInputTextView.pngFromPasteboard(pb), "剪贴板里的 TIFF 应被取到并转 PNG")
    }

    /// 纯文本剪贴板 → 不取图(返回 nil,走默认文本粘贴)。
    func testTextOnlyClipboardReturnsNil() {
        let pb = board("text"); pb.setString("just text", forType: .string)
        XCTAssertNil(LingShuInputTextView.pngFromPasteboard(pb), "纯文本不该被当图片取")
    }
}
