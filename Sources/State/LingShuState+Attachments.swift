import AppKit
import UniformTypeIdentifiers

@MainActor
extension LingShuState {
    /// 弹出文件选择器，选择图片/PPT/文档上传给灵枢处理。
    func presentAttachmentPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "上传给灵枢"
        panel.message = "选择要让灵枢理解或修改的图片、PPT 或文档"
        var types: [UTType] = [.image, .pdf, .text, .plainText]
        if let pptx = UTType(filenameExtension: "pptx") { types.append(pptx) }
        if let ppt = UTType(filenameExtension: "ppt") { types.append(ppt) }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            ingestAttachment(at: url)
        }
    }

    func ingestAttachment(at url: URL) {
        let placeholderID = UUID()
        let placeholder = LingShuAttachment(
            id: placeholderID,
            filename: url.lastPathComponent,
            kind: LingShuAttachmentIngestor.kind(forExtension: url.pathExtension),
            extractedContext: "",
            byteCount: 0,
            status: "解析中…",
            localURL: url
        )
        pendingAttachments.append(placeholder)

        let ingestor = LingShuAttachmentIngestor(perceptionClient: cloudPerceptionClient)
        Task { [weak self] in
            let attachment = await ingestor.ingest(fileURL: url)
            await MainActor.run {
                guard let self else { return }
                if let index = self.pendingAttachments.firstIndex(where: { $0.id == placeholderID }) {
                    let resolved = LingShuAttachment(
                        id: placeholderID,
                        filename: attachment.filename,
                        kind: attachment.kind,
                        extractedContext: attachment.extractedContext,
                        byteCount: attachment.byteCount,
                        status: attachment.status,
                        localURL: url
                    )
                    self.pendingAttachments[index] = resolved
                }
            }
        }
    }

    /// 剪贴板粘贴进来的图片：落临时 PNG 后走与上传**完全相同**的解析管线
    /// （图片 → 云视觉 → 文字描述 → 注入模型输入；零留存边界不变）。
    func ingestPastedImage(_ data: Data) {
        let stamp = Int(Date().timeIntervalSince1970)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("粘贴图片-\(stamp)-\(UUID().uuidString.prefix(6)).png")
        guard (try? data.write(to: tempURL)) != nil else { return }
        ingestAttachment(at: tempURL)
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func clearAttachments() {
        pendingAttachments.removeAll()
    }

    /// 把当前待发送附件拼成一段上下文，注入到用户消息前；交付落地时模型据此理解/改写。
    func attachmentContextBlock() -> String {
        let ready = pendingAttachments.filter { !$0.extractedContext.isEmpty }
        guard !ready.isEmpty else { return "" }
        let blocks = ready.map { attachment -> String in
            """
            【\(attachment.kind.label)：\(attachment.filename)】
            \(attachment.extractedContext)
            """
        }
        return """
        用户上传了以下文件，请基于它们的真实内容来理解或修改，并按交付物落地：
        \(blocks.joined(separator: "\n\n"))
        """
    }
}
