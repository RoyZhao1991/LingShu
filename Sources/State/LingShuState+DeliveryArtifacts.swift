import Foundation
import PDFKit
import AppKit

@MainActor
extension LingShuState {
    /// 内部受信 shell 抓取(**不走 run_command 审批门**;仅供验收门提取/渲染自己的产出物)。
    nonisolated static func runCapturing(_ launchPath: String, _ args: [String], timeout: TimeInterval = 120) async -> String {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return "" }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: launchPath)
                proc.arguments = args
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError = Pipe()
                do { try proc.run() } catch { cont.resume(returning: ""); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if proc.isRunning { proc.terminate() }
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    /// 提取产出物可读正文供事实/完整性核查。pptx/docx/xlsx 走 unzip 取 OOXML 正文;文本类直接读。
    func extractArtifactContent(path: String, maxChars: Int = 5000) async -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "pptx", "docx", "xlsx":
            let raw = await Self.runCapturing(
                "/usr/bin/unzip",
                ["-p", path, "ppt/slides/slide*.xml", "word/document.xml", "xl/sharedStrings.xml"],
                timeout: 30
            )
            let texts = Self.matchAll(raw, pattern: "<a:t>(.*?)</a:t>") + Self.matchAll(raw, pattern: "<t[^>]*>(.*?)</t>")
            return String(texts.joined(separator: " ").prefix(maxChars))
        case "md", "txt", "html", "htm", "csv", "json", "py", "sh", "swift":
            return String(((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").prefix(maxChars))
        default:
            return ""
        }
    }

    /// 渲染产出物并用云端 VL「看图」评审版式(重叠/截断/溢出/空白)+ 内容。VL 或渲染器缺失 → nil(降级)。
    func visuallyReviewArtifact(path: String, maxPages: Int = 4) async -> String? {
        guard let vl = cloudPerceptionClient else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        var pdfPath = path
        if ext != "pdf" {
            let soffice = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
            guard FileManager.default.isExecutableFile(atPath: soffice) else { return nil }
            let outDir = (path as NSString).deletingLastPathComponent
            _ = await Self.runCapturing(soffice, ["--headless", "--convert-to", "pdf", "--outdir", outDir, path], timeout: 120)
            pdfPath = (path as NSString).deletingPathExtension + ".pdf"
        }
        guard FileManager.default.fileExists(atPath: pdfPath),
              let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else { return nil }
        var critiques: [String] = []
        for idx in 0..<min(doc.pageCount, maxPages) {
            guard let page = doc.page(at: idx), let b64 = Self.pdfPageBase64PNG(page) else { continue }
            let prompt = "这是一页演示文稿。严格检查版式:① 文字是否重叠 ② 是否被页面边缘截断/溢出 ③ 是否有错位空白 ④ 标题与正文是否清晰可读。逐条指出(没问题就答「版式正常」);并指出页面文字里明显的事实错误。"
            if let r = try? await vl.analyzeImage(imageBase64: b64, prompt: prompt, includeGrounding: false), r.success {
                let s = r.semanticSuggestions.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { critiques.append("第\(idx + 1)页:\(s.prefix(280))") }
            }
        }
        return critiques.isEmpty ? nil : critiques.joined(separator: "\n")
    }

    /// 把 PDF 页渲染成 PNG 的 base64(PDFKit 原生,无外部依赖)。
    nonisolated static func pdfPageBase64PNG(_ page: PDFPage, scale: CGFloat = 1.5) -> String? {
        let rect = page.bounds(for: .mediaBox)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let size = NSSize(width: rect.width * scale, height: rect.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png.base64EncodedString()
    }

    /// 从命令/输出抽取交付型文件(绝对或相对路径,相对则相对工作目录解析)。
    nonisolated static func extractRunCommandArtifacts(_ text: String, workingDirectory: String) -> [String] {
        let pattern = "[\\w\\u4e00-\\u9fff./~_-]+\\.(?:pptx|docx|xlsx|pdf|html?|md|csv|png|jpe?g|java|kt|swift|py|jsx|js|tsx|ts|go|rs|rb|cpp|cc|c|hpp|h|cs|php|scala|vue|sql|xml|yaml|yml|json|toml|ini|properties|gradle|sh|bash|env|conf|cfg|txt|jar)\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out: [String] = []
        for m in re.matches(in: text, range: range) {
            guard let r = Range(m.range, in: text) else { continue }
            var path = String(text[r])
            if !path.hasPrefix("/") { path = (workingDirectory as NSString).appendingPathComponent(path) }
            if !out.contains(path) { out.append(path) }
        }
        return out
    }

    /// 从回复文本抽取提到的绝对文件路径(常见产出物扩展名;允许中文文件名)。供验收门核实"真有这个文件"。
    nonisolated static func extractFilePaths(from text: String) -> [String] {
        let pattern = "/[^\\s`\"'）)，。、；;】]+?\\.(?:pptx|docx|xlsx|pdf|html?|md|csv|txt|py|json|sh|png|jpe?g)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out: [String] = []
        for m in re.matches(in: text, range: range) {
            guard let r = Range(m.range, in: text) else { continue }
            let p = String(text[r])
            if !out.contains(p) { out.append(p) }
        }
        return out
    }

    nonisolated static func matchAll(_ text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            let s = String(text[r])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
    }
}
