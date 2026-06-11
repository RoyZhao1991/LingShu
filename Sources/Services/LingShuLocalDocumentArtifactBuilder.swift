import CoreGraphics
import CoreText
import Foundation

extension LingShuEngineeringArtifactService {
    func makeDocumentArtifacts(
        root: URL,
        stamp: String,
        prompt: String,
        reply: String
    ) -> [LingShuMaterializedArtifact] {
        let directory = root.appendingPathComponent("document-local-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let title = documentTitle(from: prompt)
        let markdown = documentMarkdown(title: title, prompt: prompt, reply: reply)
        let text = documentPlainText(title: title, prompt: prompt, reply: reply)
        let html = documentHTML(title: title, markdown: markdown)
        let json = documentJSON(title: title, prompt: prompt, reply: reply)
        let csv = documentCSV(title: title, prompt: prompt, reply: reply)

        var artifacts: [LingShuMaterializedArtifact] = []
        let producer = "文档"

        let markdownURL = directory.appendingPathComponent("lingshu-document.md")
        if write(markdown, to: markdownURL) {
            artifacts.append(.init(title: "Markdown 文档", location: markdownURL.path, producer: producer))
        }

        let textURL = directory.appendingPathComponent("lingshu-document.txt")
        if write(text, to: textURL) {
            artifacts.append(.init(title: "文本文件", location: textURL.path, producer: producer))
        }

        let htmlURL = directory.appendingPathComponent("lingshu-document.html")
        if write(html, to: htmlURL) {
            artifacts.append(.init(title: "HTML 预览页", location: htmlURL.path, producer: producer))
        }

        let pdfURL = directory.appendingPathComponent("lingshu-document.pdf")
        if writePDF(text: text, to: pdfURL) {
            artifacts.append(.init(title: "PDF 文档", location: pdfURL.path, producer: producer))
        }

        let jsonURL = directory.appendingPathComponent("lingshu-document.json")
        if write(json, to: jsonURL) {
            artifacts.append(.init(title: "JSON 结构化摘要", location: jsonURL.path, producer: producer))
        }

        let csvURL = directory.appendingPathComponent("lingshu-document.csv")
        if write(csv, to: csvURL) {
            artifacts.append(.init(title: "CSV 清单", location: csvURL.path, producer: producer))
        }

        return artifacts
    }

    private func documentTitle(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "灵枢本地文档" }
        let limited = String(trimmed.prefix(32))
        return limited == trimmed ? trimmed : "\(limited)..."
    }

    private func documentMarkdown(title: String, prompt: String, reply: String) -> String {
        """
        # \(title)

        ## 原始需求

        \(emptyFallback(prompt, fallback: "未提供原始需求。"))

        ## 灵枢整理

        \(emptyFallback(reply, fallback: "本轮尚未形成模型回复，已先生成本地文档骨架。"))

        ## 本地交付说明

        - 本批文件由灵枢本机产出物构建器生成。
        - Markdown、TXT、HTML、PDF、JSON、CSV 均在本机落盘，不依赖云端文件服务。
        - 后续如果模型或 agent 补充内容，任务记录会继续追加新的产出物清单。
        """
    }

    private func documentPlainText(title: String, prompt: String, reply: String) -> String {
        """
        \(title)

        [原始需求]
        \(emptyFallback(prompt, fallback: "未提供原始需求。"))

        [灵枢整理]
        \(emptyFallback(reply, fallback: "本轮尚未形成模型回复，已先生成本地文档骨架。"))

        [本地交付说明]
        1. 本批文件由灵枢本机产出物构建器生成。
        2. Markdown、TXT、HTML、PDF、JSON、CSV 均在本机落盘，不依赖云端文件服务。
        3. 后续如果模型或 agent 补充内容，任务记录会继续追加新的产出物清单。
        """
    }

    private func documentHTML(title: String, markdown: String) -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(htmlEscape(title))</title>
          <style>
            :root { color-scheme: dark; background: #071312; color: #eef7f4; }
            body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; background: #071312; }
            main { max-width: 880px; margin: 0 auto; padding: 56px 34px 72px; }
            h1 { margin: 0 0 22px; font-size: 34px; color: #33f4dd; }
            pre { white-space: pre-wrap; line-height: 1.75; font-size: 16px; background: rgba(255,255,255,0.06); border: 1px solid rgba(51,244,221,0.28); border-radius: 8px; padding: 24px; }
            .meta { color: rgba(238,247,244,0.58); margin-bottom: 28px; }
          </style>
        </head>
        <body>
          <main>
            <h1>\(htmlEscape(title))</h1>
            <div class="meta">LingShu local artifact</div>
            <pre>\(htmlEscape(markdown))</pre>
          </main>
        </body>
        </html>
        """
    }

    private func documentJSON(title: String, prompt: String, reply: String) -> String {
        let object: [String: Any] = [
            "title": title,
            "type": "local-document",
            "formats": ["markdown", "text", "html", "pdf", "json", "csv"],
            "prompt": prompt,
            "reply": reply,
            "generatedBy": "LingShuLocalDocumentArtifactBuilder"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func documentCSV(title: String, prompt: String, reply: String) -> String {
        [
            "field,value",
            "title,\(csvEscape(title))",
            "type,local-document",
            "prompt,\(csvEscape(prompt))",
            "reply,\(csvEscape(reply))"
        ].joined(separator: "\n")
    }

    private func writePDF(text: String, to url: URL) -> Bool {
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return false
        }

        let font = CTFontCreateWithName("PingFang SC" as CFString, 13, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0.08, alpha: 1)
        ]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            return false
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let length = CFAttributedStringGetLength(attributed)
        let margin: CGFloat = 54
        var range = CFRange(location: 0, length: 0)

        while range.location < length {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: mediaBox.height)
            context.scaleBy(x: 1, y: -1)

            let path = CGMutablePath()
            path.addRect(CGRect(
                x: margin,
                y: margin,
                width: mediaBox.width - margin * 2,
                height: mediaBox.height - margin * 2
            ))

            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            range.location += max(visible.length, 1)

            context.restoreGState()
            context.endPDFPage()
        }

        context.closePDF()
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func emptyFallback(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
