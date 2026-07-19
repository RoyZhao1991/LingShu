import Foundation
import PDFKit
import AppKit
import WebKit

/// 文件预览中枢——灵枢的"眼睛+手":在 app 内打开 PPT/PDF/Word/Excel,大脑用四肢工具翻页/滚动。
/// 快速实现取向:**一切 → PDF(office 文件经 soffice 转)→ PDFKit `PDFView`**,翻页/滚动都在本进程内确定性控制,
/// 不去 GUI 自动化外部应用(脆弱)。这同时打通"独立演讲"的视觉(开稿+翻页)与"拖动预览文档"。
@MainActor
final class LingShuPreviewController: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var openedAt: Date?
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
    /// **HTML 富页面模式(2026-06-20)**:HTML 经 soffice 转 PDF 会丢 JS/CSS(粒子背景/交互卡片)→ 改用 app 内 WKWebView
    /// 原样渲染,滚动走 JS(确定性、免浏览器焦点/辅助功能)。`isHTML` 时视图层渲染 WKWebView 而非 PDFView。
    @Published private(set) var isHTML = false
    private(set) var htmlURL: URL?
    /// 由 WKWebView 表示层注入,供 JS 滚动/取正文。
    weak var webView: WKWebView?

    /// **用户手动关掉演示窗的回调**(由根视图接到 `abortActiveFlow`):关窗=明确"我不要了",
    /// 必须把在飞的演示/批量流程彻底中断,否则大脑那条回合的下一步又 open/present 把窗弹回来(用户实测 Bug 2026-06-19)。
    var onUserClosedWindow: (() -> Void)?
    /// **防自动重弹抑制窗**:`abortActiveFlow` 设为 now+数秒。此窗内任何 `open`/进全屏一律拒绝——
    /// 挡住"关窗瞬间批量还有一步在飞、把预览又拉起来"的竞态(根治"手动退出后它又自己把 PPT 弹出来")。
    var suppressAutoReopenUntil: Date = .distantPast

    /// **真实正在显示的页号(1-indexed)**:从 PDFView 的 currentPage 读(不是 pageIndex 变量)。
    /// 用于客观核验"语音/回复报的页码 vs 画面真实页"是否对齐(pdfView 没绑定时回退 pageIndex+1)。
    var displayedPageNumber: Int {
        if isHTML { return 1 }   // HTML 是连续滚动页、无页号概念
        if let document, let cur = pdfView?.currentPage {
            let actualIndex = document.index(for: cur)
            if actualIndex >= 0, actualIndex < max(1, document.pageCount) {
                return actualIndex + 1
            }
        }
        return safeDisplayPageNumber(for: pageIndex)
    }

    /// 打开文件预览(office 文件转 PDF)。返回给大脑的说明(含页数 + 怎么翻)。
    func open(path: String) async -> String {
        if Date() < suppressAutoReopenUntil {
            return "(用户刚手动关闭了演示窗、已中断本流程——本次打开已忽略。除非用户重新明确要求,别再打开/演示。)"
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.fileExists(atPath: trimmed) else { return "文件不存在:\(trimmed)" }
        let url = URL(fileURLWithPath: trimmed)
        let ext = url.pathExtension.lowercased()
        // HTML 富页面 → app 内 WKWebView 原样渲染(不转 PDF,保住 CSS/JS),滚动走 JS。
        if ext == "html" || ext == "htm" {
            isHTML = true
            htmlURL = url
            document = nil
            title = url.lastPathComponent
            pageCount = 0
            pageIndex = 0
            revision += 1
            isPresented = true
            openedAt = Date()
            return "已在 app 内打开网页「\(title)」(WKWebView 原样渲染,CSS/JS 都在)。**演示讲解流程**:present_fullscreen(true) 进全屏 → 用 `preview_scroll` 往下滚(正数下滚/负数上滚,我会平滑滚动)逐屏讲、`preview_document_text` 可一次取整页正文照着讲 → 讲完 present_fullscreen(false) 退出。**别去浏览器、别用计算机控制滚**——就在这个预览窗里滚最稳。"
        }
        let pdfPath: String
        isHTML = false
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
        openedAt = Date()
        return "已打开预览「\(title)」,共 \(pageCount) 页,当前第 1 页。正式演讲请先 present_fullscreen 进全屏演示模式,再逐页 speak 讲、preview_next 翻;长文档用 preview_scroll。\n\(pageContentBlock(0))"
    }

    func next() -> String { isHTML ? scrollViewport(down: true) : goto(pageIndex + 1) }
    func prev() -> String { isHTML ? scrollViewport(down: false) : goto(pageIndex - 1) }

    /// HTML 翻"页"=滚一个视口高度(连续滚动页没有真页号)。
    private func scrollViewport(down: Bool) -> String {
        let js = "window.scrollBy({top: \(down ? "" : "-")window.innerHeight*0.88, left:0, behavior:'smooth'})"
        webView?.evaluateJavaScript(js, completionHandler: nil)
        return down ? "已向下滚一屏。" : "已向上滚一屏。"
    }

    func goto(_ index: Int) -> String {
        if isHTML { return scrollViewport(down: index >= pageIndex) }   // HTML 无真页号,按方向滚一屏
        guard document != nil, pageCount > 0 else { return "还没打开任何预览,先 open_preview。" }
        let clamped = max(0, min(index, pageCount - 1))
        pageIndex = clamped
        navigateToCurrentPage()
        // **防"页码推进了但 PDF 没真翻"(2026-06-19 用户实测脱节根因)**:pdfView 是 weak,全屏切换/视图重建时此刻可能为 nil;
        // 紧凑批量(run_steps)里 SwiftUI 声明式回正会被合并、PDFView 也来不及 repaint。故**下一 runloop 再回正一次**——
        // 让真实显示一定追上 pageIndex(=回复/语音里报的页码),根治"说第10页实际还在第6页"。
        DispatchQueue.main.async { [weak self] in self?.navigateToCurrentPage() }
        return "已到第 \(clamped + 1)/\(pageCount) 页。\n\(pageContentBlock(clamped))"
    }

    /// 把 PDFView 的实际显示页对齐到 pageIndex(幂等:已对齐则不动)。命令式翻页 + 下一 runloop 兜底都走它。
    func navigateToCurrentPage() {
        guard let document, let page = document.page(at: pageIndex) else { return }
        guard let pv = pdfView else {
            lingShuControlLog("preview: 翻到第\(pageIndex + 1)页时 pdfView 未绑定(将由下一 runloop/updateNSView 回正)")
            return
        }
        if pv.currentPage != page { pv.go(to: page) }
        // 诊断:翻完后核对真实显示页 vs pageIndex,脱节即记一笔(便于定位"页码对不上画面")。
        if let cur = pv.currentPage {
            let curIdx = document.index(for: cur)
            if curIdx != pageIndex {
                let expected = safeDisplayPageNumber(for: pageIndex)
                let actual = (curIdx >= 0 && curIdx < pageCount) ? curIdx + 1 : -1
                lingShuControlLog("preview: ⚠️页码脱节 期望第\(expected)页 实际第\(actual)页(已重发 go(to:))")
            }
        }
    }

    private func safeDisplayPageNumber(for rawIndex: Int) -> Int {
        guard pageCount > 0 else { return 1 }
        let clamped = min(max(rawIndex, 0), pageCount - 1)
        return clamped + 1
    }

    /// 当前页**真实文字内容**(从 PDF 抽,演示时讲解必须照这个讲,别凭记忆——保证文字稿对得上画面)。
    func pageText(_ index: Int) -> String {
        guard let document, let page = document.page(at: index) else { return "" }
        let raw = page.string ?? ""
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n").prefix(800))
    }

    /// 把某页**渲染成图片**(给多模态大脑看的:**看着画面理解**图表/表格/流程/版式后讲解,而不是只读抽出来的字)。
    /// 矢量 PDF 按 2× 栅格化(够清晰看清表格/连线),长边封顶 ~1920px 控 token;返回 PNG data URL,失败 nil。
    func pageImageDataURL(_ index: Int) -> String? {
        guard let document, let page = document.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = max(1, min(2, 1920 / max(bounds.width, bounds.height)))
        let img = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    /// 把当前页内容包成给大脑看的块:讲解时**照这页实际内容讲**(对不上画面=失职)。
    private func pageContentBlock(_ index: Int) -> String {
        let text = pageText(index)
        guard !text.isEmpty else {
            return "【本页内容】(这页可能是图为主、没抽到文字;讲解前可 screen_capture 看一眼这页画面再讲,别凭空编)"
        }
        return "【第\(index + 1)页 实际内容,照这个讲、别凭记忆】\n\(text)"
    }

    /// 滚动当前预览(长文档/Excel 拖动浏览;HTML 走 JS 平滑滚)。lines>0 向下、<0 向上。
    func scroll(lines: Int) -> String {
        if isHTML {
            guard webView != nil else { return "网页还在加载,稍等再滚。" }
            let px = lines * 110   // 每"行"约 110px,平滑滚动
            webView?.evaluateJavaScript("window.scrollBy({top: \(px), left:0, behavior:'smooth'})", completionHandler: nil)
            return "已\(lines >= 0 ? "向下" : "向上")滚动网页 \(abs(lines)) 段(平滑)。"
        }
        guard pdfView != nil else { return "预览未就绪。" }
        let n = abs(lines)
        for _ in 0..<max(1, n) {
            if lines >= 0 { pdfView?.scrollLineDown(nil) } else { pdfView?.scrollLineUp(nil) }
        }
        return "已\(lines >= 0 ? "向下" : "向上")滚动 \(max(1, n)) 行。"
    }

    /// 只 resume 一次的守卫(带锁、可 Sendable):正常回调 / 超时兜底谁先到谁 resume,另一个空转,杜绝双 resume 崩溃。
    private final class LingShuResumeOnce: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// HTML 整页可见正文(`document.body.innerText`),供大脑一次取全照着讲(免逐屏 screen_capture)。仅 isHTML 有效。
    /// **超时护栏(2026-06-25)**:生成的网页若带死循环/卡死 JS,WebKit 内容进程可能卡住→`evaluateJavaScript` 回调
    /// 永不触发→`await` 永挂→把演示/生成流程一并拖死(实测「生成并演示」卡死的一类根因)。8s 取不到就放行返回空,
    /// 那页以图为主看着讲即可,**绝不让不可信网页内容挂死主流程**。
    func htmlInnerText() async -> String {
        guard isHTML, let wv = webView else { return "" }
        let resume = LingShuResumeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            wv.evaluateJavaScript("document.body.innerText") { result, _ in
                if resume.claim() { cont.resume(returning: (result as? String) ?? "") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {   // 8s 取不到(网页 JS 卡死)就放行,绝不挂死流程
                if resume.claim() { cont.resume(returning: "") }
            }
        }
    }

    /// 进入/退出全屏演示(WPS 演示式)。进入前确保已打开预览。
    func setSlideshow(_ on: Bool) -> String {
        if on, Date() < suppressAutoReopenUntil {
            return "(用户刚手动中断了演示——本次进全屏已忽略。除非用户重新要求,别再进全屏演示。)"
        }
        guard document != nil || isHTML else { return "还没打开预览,先 open_preview 再全屏演示。" }
        slideshow = on
        if isHTML { return on ? "已进入全屏放映网页;preview_scroll 往下滚着讲,close_preview 退出。" : "已退出全屏。" }
        return on ? "已进入全屏演示(单页满屏);preview_next/preview_prev 翻页,close_preview 退出。" : "已退出全屏演示。"
    }

    func close() -> String {
        isPresented = false
        slideshow = false
        document = nil
        title = ""
        pageCount = 0
        pageIndex = 0
        openedAt = nil
        isHTML = false
        htmlURL = nil
        return "已关闭预览。"
    }

    /// office 文件 → PDF(soffice headless,独立 profile 避锁)。失败 nil。
    private nonisolated static func convertToPDF(_ path: String) async -> String? {
        let soffice = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        guard FileManager.default.isExecutableFile(atPath: soffice) else { return nil }
        let outDir = LingShuRuntimeEnvironment.temporaryDirectoryPath + "lingshu-preview-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let profile = "file://\(outDir)/profile"
        _ = await LingShuState.runCapturing(soffice, ["-env:UserInstallation=\(profile)", "--headless", "--convert-to", "pdf", "--outdir", outDir, path], timeout: 90)
        let pdf = outDir + "/" + ((path as NSString).lastPathComponent as NSString).deletingPathExtension + ".pdf"
        return FileManager.default.fileExists(atPath: pdf) ? pdf : nil
    }
}
