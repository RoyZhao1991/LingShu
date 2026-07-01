import Foundation

/// 「附件入脑」(多模态)接线集中处:**当前脑能看图时**,把待发图片/PDF **直发大脑原生视觉**(而非 VL→文字);
/// 纯文本脑则回退 VL→文字管线。**自动按脑能力判、无手动开关**(2026-06-28 用户定调:能自动判多模态就不需要开关了)。
/// 边界:这条只管**显式附件**;**态势感知(环境感知)另走 `perceptionVLTask`、一律强制 VL/零留存**,不经此路。见 [[LingShuMultimodal]]。
@MainActor
extension LingShuState {
    /// 把待发图片/PDF 读成 base64 data URL(供直发大脑);脑不支持看图则返回 [](调用方回退 VL→文字)。只直发图片/PDF;粗挡 >20MB。
    func directBrainImageDataURLs() -> [String] {
        guard LingShuMultimodal.isVisionCapable(provider: modelProvider, model: modelName) else { return [] }
        var urls: [String] = []
        for att in pendingAttachments {
            guard let url = att.localURL, let data = try? Data(contentsOf: url), data.count <= 20_000_000 else { continue }
            let mime: String?
            switch url.pathExtension.lowercased() {
            case "png": mime = "image/png"
            case "jpg", "jpeg": mime = "image/jpeg"
            case "gif": mime = "image/gif"
            case "webp": mime = "image/webp"
            case "pdf": mime = "application/pdf"
            default: mime = nil
            }
            guard let mime else { continue }
            urls.append("data:\(mime);base64,\(data.base64EncodedString())")
        }
        return urls
    }

    /// 一次性消费 submitTextWithAttachments 暂存的"直发"图片(取出即清空)。
    func consumePendingDirectBrainImages() -> [String]? {
        defer { pendingDirectBrainImages = nil }
        return pendingDirectBrainImages
    }

    /// 投首条用户输入:经典引擎(LingShuAgentSession)带图就走多模态 send;其它引擎/无图走纯文本原路。
    func sendInitialTurn(session: any LingShuAgentSessioning, text: String, imageDataURLs: [String]?) async -> LingShuAgentRunResult {
        if let imageDataURLs, !imageDataURLs.isEmpty, let loop = session as? LingShuAgentSession {
            return await loop.send(text, imageDataURLs: imageDataURLs)
        }
        return await session.send(text)
    }
}
