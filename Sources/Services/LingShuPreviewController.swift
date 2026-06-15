import Foundation
import PDFKit
import AppKit

/// 文件预览中枢——灵枢的"眼睛+手":在 app 内打开 PPT/PDF/Word/Excel,大脑用四肢工具翻页/滚动。
/// 快速实现取向:**一切 → PDF(office 文件经 soffice 转)→ PDFKit `PDFView`**,翻页/滚动都在本进程内确定性控制,
/// 不去 GUI 自动化外部应用(脆弱)。这同时打通"独立演讲"的视觉(开稿+翻页)与"拖动预览文档"。
@MainActor
final class LingShuPreviewController: ObservableObject {
    @Published var isPresented = false
    /// 全屏演示模式(WPS 演示式:单页满屏 + 翻页,隐藏 chrome)。
    @Published var slideshow = false
    @Published private(set) var title = ""
    @Published private(set) var pageCount = 0
    @Published private(set) var pageIndex = 0
    /// 文档变更号:PDFView 据此知道要重载文档(声明式同步)。
    @Published private(set) var revision = 0
    private(set) var document: PDFDocument?
    /// 由 PDFView 表示层注入,供滚动/翻页的命令式控制(声明式同步页码 + 命令式滚动各取所长)。
    weak var pdfView: PDFView?

    /// 打开文件预览(office 文件转 PDF)。返回给大脑的说明(含页数 + 怎么翻)。
    func open(path: String) async -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.fileExists(atPath: trimmed) else { return "文件不存在:\(trimmed)" }
        let url = URL(fileURLWithPath: trimmed)
        let ext = url.pathExtension.lowercased()
        let pdfPath: String
        if ext == "pdf" {
            pdfPath = trimmed
        } else {
            guard let converted = await Self.convertToPDF(trimmed) else {
                return "无法预览「\(url.lastPathComponent)」(转 PDF 失败,确认装了 LibreOffice)。"
            }
            pdfPath = converted
        }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else {
            return "无法加载预览:\(pdfPath)"
        }
        document = doc
        title = url.lastPathComponent
        pageCount = doc.pageCount
        pageIndex = 0
        revision += 1
        isPresented = true
        return "已打开预览「\(title)」,共 \(pageCount) 页,当前第 1 页。翻页:preview_next/preview_prev/preview_goto;长文档滚动:preview_scroll。演示时边 speak 讲、边 preview_next 翻。"
    }

    func next() -> String { goto(pageIndex + 1) }
    func prev() -> String { goto(pageIndex - 1) }

    func goto(_ index: Int) -> String {
        guard let document, pageCount > 0 else { return "还没打开任何预览,先 open_preview。" }
        let clamped = max(0, min(index, pageCount - 1))
        pageIndex = clamped
        if let page = document.page(at: clamped) { pdfView?.go(to: page) }
        return "已到第 \(clamped + 1)/\(pageCount) 页。"
    }

    /// 滚动当前预览(长文档/Excel 拖动浏览)。lines>0 向下、<0 向上。
    func scroll(lines: Int) -> String {
        guard pdfView != nil else { return "预览未就绪。" }
        let n = abs(lines)
        for _ in 0..<max(1, n) {
            if lines >= 0 { pdfView?.scrollLineDown(nil) } else { pdfView?.scrollLineUp(nil) }
        }
        return "已\(lines >= 0 ? "向下" : "向上")滚动 \(max(1, n)) 行。"
    }

    /// 进入/退出全屏演示(WPS 演示式)。进入前确保已打开预览。
    func setSlideshow(_ on: Bool) -> String {
        guard document != nil else { return "还没打开预览,先 open_preview 再全屏演示。" }
        slideshow = on
        return on ? "已进入全屏演示(单页满屏);preview_next/preview_prev 翻页,close_preview 退出。" : "已退出全屏演示。"
    }

    func close() -> String {
        isPresented = false
        slideshow = false
        document = nil
        title = ""
        pageCount = 0
        pageIndex = 0
        return "已关闭预览。"
    }

    /// office 文件 → PDF(soffice headless,独立 profile 避锁)。失败 nil。
    private nonisolated static func convertToPDF(_ path: String) async -> String? {
        let soffice = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        guard FileManager.default.isExecutableFile(atPath: soffice) else { return nil }
        let outDir = NSTemporaryDirectory() + "lingshu-preview-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let profile = "file://\(outDir)/profile"
        _ = await LingShuState.runCapturing(soffice, ["-env:UserInstallation=\(profile)", "--headless", "--convert-to", "pdf", "--outdir", outDir, path], timeout: 90)
        let pdf = outDir + "/" + ((path as NSString).lastPathComponent as NSString).deletingPathExtension + ".pdf"
        return FileManager.default.fileExists(atPath: pdf) ? pdf : nil
    }
}
