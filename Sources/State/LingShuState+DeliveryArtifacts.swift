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
        case "md", "txt", "html", "htm", "csv", "json",
             "py", "sh", "swift", "js", "jsx", "ts", "tsx", "go", "rs",
             "java", "kt", "c", "cc", "cpp", "cxx", "m", "mm", "rb", "php",
             "scala", "cs":
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
        var out: [String] = []
        let extPattern = "(?:pptx|docx|xlsx|pdf|html?|md|csv|png|jpe?g|java|kt|swift|py|jsx|js|tsx|ts|go|rs|rb|cpp|cc|c|hpp|h|cs|php|scala|vue|sql|xml|yaml|yml|json|toml|ini|properties|gradle|sh|bash|env|conf|cfg|txt|jar)"
        func append(_ raw: String) {
            var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
            guard !path.isEmpty else { return }
            if path.hasPrefix("~/") { path = (path as NSString).expandingTildeInPath }
            if !path.hasPrefix("/") { path = (workingDirectory as NSString).appendingPathComponent(path) }
            path = (path as NSString).standardizingPath
            if out.contains(where: { $0.hasSuffix(path) && $0.count > path.count }) { return }
            out.removeAll { path.hasSuffix($0) && path.count > $0.count }
            if !out.contains(path) { out.append(path) }
        }

        // Quoted shell arguments may contain spaces, e.g.
        // "/Users/me/Library/Application Support/LingShu/Workspace/deck.pptx".
        for pattern in [
            "[`\"']([^`\"'\\n]+\\.\(extPattern))[`\"']",
            "([\\w\\u4e00-\\u9fff./~_-]+\\.\(extPattern))\\b"
        ] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for m in re.matches(in: text, range: range) {
                let targetRange = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
                guard let r = Range(targetRange, in: text) else { continue }
                append(String(text[r]))
            }
        }
        return out
    }

    /// 从回复文本抽取提到的绝对文件路径(常见产出物扩展名;允许中文文件名)。供验收门核实"真有这个文件"。
    nonisolated static func extractFilePaths(from text: String) -> [String] {
        var out: [String] = []
        let extPattern = "(?:pptx|docx|xlsx|pdf|html?|md|csv|txt|py|json|sh|png|jpe?g)"
        func append(_ raw: String) {
            let path = (raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'")) as NSString).standardizingPath
            guard path.hasPrefix("/"), !out.contains(path) else { return }
            if out.contains(where: { $0.hasSuffix(path) && $0.count > path.count }) { return }
            out.removeAll { path.hasSuffix($0) && path.count > $0.count }
            out.append(path)
        }

        for pattern in [
            "[`\"'](/[^`\"'\\n]+\\.\(extPattern))[`\"']",
            "(/[^\\s`\"'）)，。、；;】]+?\\.\(extPattern))"
        ] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for m in re.matches(in: text, range: range) {
                let targetRange = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
                guard let r = Range(targetRange, in: text) else { continue }
                append(String(text[r]))
            }
        }
        return out
    }

    /// 产物的"源"通常是这些**可改的脚本/矢量/数据/模板**扩展名(用于自动溯源:同名兄弟文件)。
    nonisolated static let artifactSourceExtensions: Set<String> = [
        "py", "svg", "json", "sh", "js", "ts", "rb", "go", "yaml", "yml", "toml",
        "tmpl", "template", "j2", "jinja", "ejs", "dot", "puml", "mmd", "tex", "scss", "less", "gen"
    ]

    /// **能看就别写像素码(铁律)**——只在**多模态脑**任务里注入(非多模态脑没眼睛,不适用)。
    /// 根因实测:多模态脑明明能看图,却写 94 段 PIL 逐像素扫红框/绿字、连验收都在算"y=1092 的绿像素是字还是框边",
    /// 把"删一行字"拖成 20+ 分钟还判错。有眼睛就用眼睛。
    nonisolated static let visionOverPixelsDirective = """
    【能看就别写像素码·铁律(你是多模态脑,有眼睛)】你能直接"看"图片 / 截图 / PDF。所以:
    - **识别**图里的标记(红框 / 圈注 / 箭头 / 某一行字)、判断要改哪儿 → **直接看图说出来**,**别**写 Python 逐像素扫红/扫绿/算坐标;
    - **核验**结果(改对没、版式坏没坏)→ **重新看一眼成品图**,**别**写代码做像素 diff / 逐行比对。
    逐像素扫描又慢又脆、还常判错(把方框描边当成文字)。需要"看清楚"就调看图工具(screen_capture / 把图发给自己看),不是写扫描脚本。
    """

    /// **改产物·统一范式(用户定调 2026-06-28:先溯源→无法溯源再改/重做)**:任务引用了绝对路径产物文件时,
    /// **替 agent 先溯源**——找同目录、同名(去掉成品扩展名后前缀相同)的源文件(脚本/矢量/数据/模板,如
    /// `灵枢介绍.diagram.png` → `灵枢介绍.diagram.gen.py`),**把"产物→源"映射直接交到它手里**(不靠它自己发现),
    /// 再压一条铁律:① 先溯源 → ② 找到改源、重新生成 → ③ 确实溯不到才直接改成品/重做。
    /// 根因实测:agent 只点验被告知的文件、从不整列目录,没认出源 → 在 PNG 上像素/字节手术(把 PPT 文字删坏了)。
    /// **纯函数、读文件系统、不挑场景、不写死任何具体文件**——任何带文件的修改任务通用。返回空串=没引用到存在文件(零开销)。
    nonisolated static func artifactNeighborhoodContext(for text: String, limitDirs: Int = 3, limitEntries: Int = 50,
                                                        fileManager fm: FileManager = .default) -> String {
        let paths = extractFilePaths(from: text).filter { fm.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return "" }
        var dirs: [String] = []   // 文件所在目录,按出现顺序去重,最多 limitDirs 个
        var traced: [(artifact: String, sources: [String])] = []   // 自动溯源结果:产物→候选源
        var seenArtifacts = Set<String>()
        for p in paths {
            let d = (p as NSString).deletingLastPathComponent
            guard !d.isEmpty, d != "/" else { continue }
            if !dirs.contains(d) && dirs.count < limitDirs { dirs.append(d) }
            let name = (p as NSString).lastPathComponent
            guard !seenArtifacts.contains(name) else { continue }
            seenArtifacts.insert(name)
            // 溯源:同目录里**去掉最后扩展名后前缀相同**、且扩展名是"源类"的兄弟文件(precise:diagram.png 只配 diagram.*,不串 arch.*)
            let stem = (name as NSString).deletingPathExtension
            if let items = try? fm.contentsOfDirectory(atPath: d) {
                let sources = items.filter { s in
                    s != name && s.hasPrefix(stem) && artifactSourceExtensions.contains((s as NSString).pathExtension.lowercased())
                }.sorted()
                if !sources.isEmpty { traced.append((artifact: name, sources: sources)) }
            }
        }
        let skip: Set<String> = [".git", ".build", "node_modules", "__pycache__", ".venv", "venv", "dist",
                                 "build", "target", ".pytest_cache", ".idea", ".next", ".cache", "DerivedData"]
        var blocks: [String] = []
        for d in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: d) else { continue }
            let entries = items.filter { !$0.hasPrefix(".") && !skip.contains($0) }.sorted().prefix(limitEntries)
            guard !entries.isEmpty else { continue }
            let listing = entries.map { name -> String in
                var isDir: ObjCBool = false
                fm.fileExists(atPath: (d as NSString).appendingPathComponent(name), isDirectory: &isDir)
                return isDir.boolValue ? "\(name)/" : name
            }.joined(separator: "  ")
            blocks.append("目录 \(d)/:\n\(listing)")
        }
        guard !blocks.isEmpty else { return "" }
        var out = """
        【改产物·统一范式·铁律(先溯源,无法溯源再改/重做)】
        修改/删除任何**产物**(图 / PPT / PDF / 网页 / 文档 / 图表)前,**必须先溯源**:
        ① **先找产生它的源**(脚本 / 矢量 / 数据 / 模板,如 `*.gen.py`、`*.svg`、`*.slides.json`、模板);
        ② **找到就改源,再用「产生这套产物的那条管线/工具」原样重新生成**(如 gen 脚本 → 渲染器 → `slides_to_pptx`)——
           **绝不**在成品(PNG / 二进制)上做像素/字节手术,也**别手搓 pptx、别手动摆图/裁图**
           (又慢又错:上次正因此既把文字删坏、又把整张图摆裁了);
        ③ **确实溯不到源**,才考虑直接改成品或整页重做。
        """
        if !traced.isEmpty {
            let lines = traced.map { "· `\($0.artifact)` 的源很可能是 → \($0.sources.map { "`\($0)`" }.joined(separator: "、"))" }
            out += "\n\n🔎 已替你溯源(同目录同名源文件,优先改这些、再重新生成产物):\n" + lines.joined(separator: "\n")
        }
        out += "\n\n产物所在目录(自己再核一眼有没有别的源):\n" + blocks.joined(separator: "\n\n")
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
