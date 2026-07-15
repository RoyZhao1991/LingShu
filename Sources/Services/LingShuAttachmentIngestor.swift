import Foundation
import PDFKit

/// 用户上传给灵枢处理的附件（图片 / PPT / PDF / 文本等）。
struct LingShuAttachment: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case image
        case presentation
        case document
        case text
        case other

        var label: String {
            switch self {
            case .image: "图片"
            case .presentation: "演示文稿"
            case .document: "文档"
            case .text: "文本"
            case .other: "文件"
            }
        }

        var icon: String {
            switch self {
            case .image: "photo"
            case .presentation: "rectangle.on.rectangle.angled"
            case .document: "doc.richtext"
            case .text: "doc.plaintext"
            case .other: "doc"
            }
        }
    }

    let id: UUID
    let filename: String
    let kind: Kind
    /// 供模型理解/改写用的已抽取内容（图片为云感知解析摘要，文档为正文文本）。
    var extractedContext: String
    var byteCount: Int
    /// 解析中/解析失败的状态描述；nil 表示就绪。
    var status: String?
    /// 本地源文件路径：输入框据此渲染缩略图预览（图片显真图、其余显类型图标）。
    var localURL: URL?

    init(
        id: UUID = UUID(),
        filename: String,
        kind: Kind,
        extractedContext: String,
        byteCount: Int,
        status: String? = nil,
        localURL: URL? = nil
    ) {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.extractedContext = extractedContext
        self.byteCount = byteCount
        self.status = status
        self.localURL = localURL
    }
}

enum LingShuAttachmentError: Error {
    case unreadable
    case unsupported
}

/// 把本地文件抽取成模型可读上下文。图片可走云感知专项接口（服务端留存边界以实际部署条款为准），
/// PPT/PDF/文本在本机抽取正文，不上传原始媒体。
struct LingShuAttachmentIngestor {
    /// 图片解析所用的云感知客户端；为 nil 时图片只登记元数据，不做内容理解。
    var perceptionClient: LingShuCloudPerceptionClient?

    static func kind(forExtension ext: String) -> LingShuAttachment.Kind {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "tiff":
            return .image
        case "ppt", "pptx", "key":
            return .presentation
        case "xlsx", "xls":
            return .document
        case "pdf", "doc", "docx":
            return .document
        case "txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "xml", "html", "htm", "yaml", "yml",
             "toml", "ini", "conf", "cfg", "properties", "env", "log", "rtf", "tex", "srt", "vtt",
             "swift", "py", "js", "jsx", "ts", "tsx", "java", "kt", "kts", "c", "cc", "cpp", "cxx",
             "h", "hpp", "m", "mm", "go", "rs", "rb", "php", "scala", "cs", "sh", "bash", "zsh",
             "sql", "r", "lua", "pl", "gradle", "dart", "vue", "svelte":
            return .text
        default:
            return .other
        }
    }

    func ingest(fileURL: URL) async -> LingShuAttachment {
        let filename = fileURL.lastPathComponent
        let kind = Self.kind(forExtension: fileURL.pathExtension)
        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        let byteCount = data.count

        guard byteCount > 0 else {
            return .init(filename: filename, kind: kind, extractedContext: "", byteCount: 0, status: "文件为空或无法读取")
        }

        switch kind {
        case .image:
            return await ingestImage(filename: filename, data: data, byteCount: byteCount)
        case .presentation:
            return ingestPresentation(fileURL: fileURL, filename: filename, byteCount: byteCount)
        case .text:
            let text = String(data: data, encoding: .utf8) ?? ""
            return .init(
                filename: filename,
                kind: .text,
                extractedContext: Self.clip(text),
                byteCount: byteCount,
                status: text.isEmpty ? "无法以文本解码" : nil
            )
        case .document, .other:
            // 本机解析常见办公文档正文(不上传原文件):PDF→PDFKit,xlsx/docx→解压读 OOXML。
            let ext = fileURL.pathExtension.lowercased()
            let text: String
            switch ext {
            case "pdf":  text = Self.extractPDFText(fileURL: fileURL)
            case "xlsx": text = Self.extractXLSXText(fileURL: fileURL)
            case "docx": text = Self.extractDOCXText(fileURL: fileURL)
            default:     text = ""
            }
            if !text.isEmpty {
                return .init(filename: filename, kind: kind, extractedContext: Self.clip(text), byteCount: byteCount)
            }
            // 兜底:未知扩展名但其实是纯文本(各种 config/log/代码无后缀等)→ 试 UTF-8 解码,是文本就当文本用。
            if let utf8 = Self.decodeAsTextIfPlausible(data) {
                return .init(filename: filename, kind: .text, extractedContext: Self.clip(utf8), byteCount: byteCount)
            }
            return .init(
                filename: filename, kind: kind, extractedContext: "", byteCount: byteCount,
                status: ["pdf", "xlsx", "docx"].contains(ext) ? "未能从该文件抽取文本" : "已登记，正文抽取暂不支持该二进制格式(\(ext))"
            )
        }
    }

    /// 若 data 是可读纯文本(UTF-8 可解码且无 NUL 字节)就返回文本,否则 nil(判定二进制)。
    static func decodeAsTextIfPlausible(_ data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        if data.prefix(4096).contains(0) { return nil }   // 含 NUL → 二进制
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : s
    }

    /// PDF 正文(PDFKit,本机解析,不出网)。
    static func extractPDFText(fileURL: URL) -> String {
        guard let doc = PDFDocument(url: fileURL) else { return "" }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            if let s = doc.page(at: i)?.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(s)
            }
        }
        return parts.joined(separator: "\n")
    }

    /// xlsx 正文:解压 xl/sharedStrings.xml(单元格共享字符串)抽 <t> 文本。
    static func extractXLSXText(fileURL: URL) -> String {
        let xml = unzipMember(fileURL: fileURL, member: "xl/sharedStrings.xml")
        return extractTags(xml, tag: "t").joined(separator: " ")
    }

    /// docx 正文:解压 word/document.xml 抽 <w:t> 文本。
    static func extractDOCXText(fileURL: URL) -> String {
        let xml = unzipMember(fileURL: fileURL, member: "word/document.xml")
        return extractTags(xml, tag: "w:t").joined(separator: "")
    }

    /// 解压 zip 容器里某成员的 XML 文本(unzip -p,本机)。
    static func unzipMember(fileURL: URL, member: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", fileURL.path, member]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 从 XML 抽 `<tag ...>内容</tag>` 的文本(容忍带属性的开标签;以词边界避免误匹配如 w:tab)。
    static func extractTags(_ xml: String, tag: String) -> [String] {
        guard !xml.isEmpty else { return [] }
        var out: [String] = []
        var rem = Substring(xml)
        let openPrefix = "<\(tag)"
        let closeTag = "</\(tag)>"
        while let op = rem.range(of: openPrefix) {
            // 开标签后必须紧跟 '>' 或空白(否则是别的标签,如 <w:tab>)。
            let after = op.upperBound
            guard after < rem.endIndex else { break }
            let ch = rem[after]
            guard ch == ">" || ch == " " || ch == "\t" || ch == "\n" || ch == "/" else {
                rem = rem[after...]; continue
            }
            guard let gt = rem.range(of: ">", range: after..<rem.endIndex),
                  let cl = rem.range(of: closeTag, range: gt.upperBound..<rem.endIndex) else { break }
            let frag = rem[gt.upperBound..<cl.lowerBound]
            let decoded = frag
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#10;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !decoded.isEmpty { out.append(decoded) }
            rem = rem[cl.upperBound...]
        }
        return out
    }

    private func ingestImage(filename: String, data: Data, byteCount: Int) async -> LingShuAttachment {
        guard let perceptionClient else {
            return .init(filename: filename, kind: .image, extractedContext: "", byteCount: byteCount, status: "未接入云感知，图片仅登记")
        }
        do {
            let result = try await perceptionClient.analyzeImage(
                imageBase64: data.base64EncodedString(),
                prompt: "请尽量完整地描述这张图片的文字、结构、图表、布局与要点，供后续编辑使用。"
            )
            var parts: [String] = []
            if !result.ocrTexts.isEmpty {
                parts.append("画面文字：" + result.ocrTexts.joined(separator: " / "))
            }
            if !result.transcript.isEmpty {
                parts.append(result.transcript)
            }
            if result.detectionCount > 0 {
                parts.append("识别到 \(result.detectionCount) 个对象")
            }
            let context = parts.isEmpty ? "（图片已解析，但未提取到显著文字或对象）" : parts.joined(separator: "；")
            return .init(filename: filename, kind: .image, extractedContext: context, byteCount: byteCount)
        } catch {
            return .init(filename: filename, kind: .image, extractedContext: "", byteCount: byteCount, status: "图片解析失败：\(error.localizedDescription)")
        }
    }

    /// 从 .pptx（zip 容器）抽取每页文本。仅本机解压读取 XML，不上传原文件。
    private func ingestPresentation(fileURL: URL, filename: String, byteCount: Int) -> LingShuAttachment {
        guard fileURL.pathExtension.lowercased() == "pptx" else {
            return .init(filename: filename, kind: .presentation, extractedContext: "", byteCount: byteCount, status: "仅支持 .pptx 正文抽取")
        }
        let text = Self.extractPPTXText(fileURL: fileURL)
        return .init(
            filename: filename,
            kind: .presentation,
            extractedContext: Self.clip(text),
            byteCount: byteCount,
            status: text.isEmpty ? "未能从 PPTX 抽取文本" : nil
        )
    }

    /// 用 `unzip -p` 读取 ppt/slides/slide*.xml 并剥离标签，得到逐页文本。
    static func extractPPTXText(fileURL: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", fileURL.path, "ppt/slides/slide*.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let xml = String(data: data, encoding: .utf8) else { return "" }

        // <a:t>…</a:t> 是幻灯片里的文本节点；提取后按页粗分。
        var texts: [String] = []
        var remainder = Substring(xml)
        while let open = remainder.range(of: "<a:t>"),
              let close = remainder.range(of: "</a:t>", range: open.upperBound..<remainder.endIndex) {
            let fragment = remainder[open.upperBound..<close.lowerBound]
            let decoded = fragment
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#10;", with: " ")
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { texts.append(trimmed) }
            remainder = remainder[close.upperBound...]
        }
        return texts.joined(separator: "\n")
    }

    private static func clip(_ text: String, limit: Int = 8000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n…（正文过长已截断）"
    }
}
