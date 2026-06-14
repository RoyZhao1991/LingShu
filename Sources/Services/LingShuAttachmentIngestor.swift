import Foundation

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

/// 把本地文件抽取成模型可读上下文。图片走云感知专项接口（零留存），
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
        case "pdf", "doc", "docx":
            return .document
        case "txt", "md", "markdown", "csv", "json", "swift", "py", "js", "ts", "html", "xml", "yaml", "yml":
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
            // PDF/Word 暂不在本机解析二进制，登记为待模型按需处理。
            return .init(
                filename: filename,
                kind: kind,
                extractedContext: "",
                byteCount: byteCount,
                status: "已登记，正文抽取暂不支持该格式"
            )
        }
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
