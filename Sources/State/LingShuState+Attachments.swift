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

    /// 把**发出去的附件**落到稳定目录(供事后点击**重新预览**):粘贴图等临时文件会被系统清掉,复制一份到
    /// `~/Library/Application Support/LingShu/SentAttachments`;已是持久路径的(用户上传/拖入的原文件)**原样返回**(不复制)。
    /// 纯文件系统操作,不挑场景。返回稳定可预览的绝对路径(复制失败则回退原路径)。
    nonisolated static func persistedSentAttachmentPath(_ url: URL) -> String {
        let tmp = FileManager.default.temporaryDirectory.path
        guard url.path.hasPrefix(tmp) else { return url.path }   // 已持久(原文件)→ 直接用,不复制
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return url.path }
        let dir = base.appendingPathComponent("LingShu/SentAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.copyItem(at: url, to: dest) }
        return FileManager.default.fileExists(atPath: dest.path) ? dest.path : url.path
    }

    /// 剪贴板粘贴进来的图片：落临时 PNG 后走与上传**完全相同**的解析管线
    /// （图片 → 云视觉 → 文字描述 → 注入模型输入；远程处理边界以对应服务商条款为准）。
    func ingestPastedImage(_ data: Data) {
        // 去重:一次 Cmd+V 可能多次触发(实测 performKeyEquivalent 命中 3 次→3 个附件)。同一张图在 1.5s 内重复进来只收一次。
        let fingerprint = data.count ^ (data.prefix(512).hashValue)
        if let last = lastPastedImageFingerprint, last.hash == fingerprint, Date().timeIntervalSince(last.at) < 1.5 {
            return
        }
        lastPastedImageFingerprint = (fingerprint, Date())
        let stamp = Int(Date().timeIntervalSince1970)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("粘贴图片-\(stamp)-\(UUID().uuidString.prefix(6)).png")
        guard (try? data.write(to: tempURL)) != nil else { return }
        ingestAttachment(at: tempURL)
    }

    /// 拖拽/粘贴进主输入框的内容**整体就是**真实存在的绝对文件路径时,转成附件并清空输入框。
    func convertDroppedFilePathsIfNeeded() {
        if convertDroppedFilePaths(in: prompt) { prompt = "" }
    }

    /// 通用:给定一段文本,若它**整体 = 一个或多个真实存在的绝对文件路径**(每行一个),全部转成附件并返回 true
    /// (调用方据此清空对应输入框);否则不动、返回 false。任务窗口底栏用独立 draft,故走这个通用版而非 prompt 版。
    /// 只在"整框 = 纯路径"时触发——正文里顺带写的路径不动。
    @discardableResult
    func convertDroppedFilePaths(in text: String) -> Bool {
        let paths = Self.droppedFilePaths(in: text)
        guard !paths.isEmpty else { return false }
        for path in paths { ingestAttachment(at: URL(fileURLWithPath: path)) }
        return true
    }

    /// 纯函数(可单测):文本若**整体 = 一个或多个存在的绝对文件路径**(每行一个),返回这些路径;否则返回 []。
    /// 正文里顺带写的路径 → 返回 []( 不误转)。
    nonisolated static func droppedFilePaths(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return [] }
        let tokens = trimmed
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let fileManager = FileManager.default
        func isExistingFile(_ path: String) -> Bool {
            guard path.hasPrefix("/") else { return false }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        guard !tokens.isEmpty, tokens.allSatisfy(isExistingFile) else { return [] }
        return tokens
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func clearAttachments() {
        pendingAttachments.removeAll()
    }

    /// 把当前待发送附件拼成一段上下文，注入到用户消息前；交付落地时模型据此理解/改写。
    /// (「附件直接入脑」的图片直发逻辑见 LingShuState+DirectMultimodal.swift。)
    ///
    /// 关键约束:附件的**本机路径**也是上下文的一部分。正文抽取是异步的,用户可能在解析完成前就发送;
    /// 只要文件句柄还在,大脑就应该直接用这个路径读取/预览/演示/修改,而不是再去工作目录里猜文件。
    func attachmentContextBlock() -> String {
        let ready = pendingAttachments.filter { !$0.extractedContext.isEmpty || $0.localURL != nil }
        guard !ready.isEmpty else { return "" }
        let blocks = ready.map { attachment -> String in
            let path = attachment.localURL?.path.trimmingCharacters(in: .whitespacesAndNewlines)
            let pathLine: String
            if let path = path, !path.isEmpty {
                pathLine = "本机路径：\(path)"
            } else {
                pathLine = "本机路径：未提供"
            }
            let sizeLine: String
            if attachment.byteCount > 0 {
                sizeLine = "大小：\(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))"
            } else {
                sizeLine = "大小：未知"
            }
            let statusLine = attachment.status?.trimmingCharacters(in: .whitespacesAndNewlines)
            let extracted = attachment.extractedContext.trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            【\(attachment.kind.label)：\(attachment.filename)】
            \(pathLine)
            \(sizeLine)
            解析状态：\((statusLine?.isEmpty == false) ? statusLine! : "就绪")
            内容摘要：
            \(extracted.isEmpty ? "(正文尚未抽取完成；如需读取、预览、演示或修改，请直接使用本机路径调用对应工具。)" : extracted)
            """
        }
        return """
        用户上传了以下文件，请基于它们的真实内容来理解、读取、修改、预览、演示或按需交付：

        附件使用规则：
        - 如果用户要求读取、预览、演示、修改或基于附件继续工作，优先直接使用附件的「本机路径」调用工具。
        - 不要为了定位已上传附件再搜索工作目录或全盘；只有本机路径为空、失效，或工具明确返回无法打开时，才查找替代文件。
        - 如果正文摘要尚未抽取完成，仍然可以先用本机路径打开/读取/预览文件，不能把“没抽取完”当成文件不存在。

        \(blocks.joined(separator: "\n\n"))
        """
    }
}
