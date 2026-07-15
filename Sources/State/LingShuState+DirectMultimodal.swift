import Foundation

/// 「附件入脑」(多模态)接线集中处:**当前脑能看图时**,把待发图片/PDF **直发大脑原生视觉**(而非 VL→文字);
/// 纯文本脑则回退 VL→文字管线。**自动按脑能力判、无手动开关**(2026-06-28 用户定调:能自动判多模态就不需要开关了)。
/// 边界:这条只管**显式附件**;**态势感知(环境感知)另走 `perceptionVLTask`、一律强制 VL**,不经此路。远程数据边界以对应服务商条款为准。见 [[LingShuMultimodal]]。
@MainActor
extension LingShuState {
    func configureNativeMultimodalGate(on adapter: LingShuGatewayAgentModel) {
        let provider = modelProvider
        let model = modelName
        let currentEndpoint = endpoint
        let protocolName = selectedModelPreset?.protocolName ?? "OpenAI 兼容"
        adapter.shouldSendNativeMultimodal = {
            LingShuMultimodal.shouldAttemptNativeMultimodal(
                provider: provider,
                model: model,
                endpoint: currentEndpoint,
                protocolName: protocolName
            )
        }
    }

    func shouldAttemptNativeMultimodalForCurrentModel() -> Bool {
        LingShuMultimodal.shouldAttemptNativeMultimodal(
            provider: modelProvider,
            model: modelName,
            endpoint: endpoint,
            protocolName: selectedModelPreset?.protocolName ?? "OpenAI 兼容"
        )
    }

    func isCurrentModelMarkedNativeMultimodalUnsupported() -> Bool {
        LingShuMultimodal.isMarkedNativeMultimodalUnsupported(
            provider: modelProvider,
            model: modelName,
            endpoint: endpoint,
            protocolName: selectedModelPreset?.protocolName ?? "OpenAI 兼容"
        )
    }

    func markCurrentModelNativeMultimodalUnsupported(reason: String) {
        LingShuMultimodal.markNativeMultimodalUnsupported(
            provider: modelProvider,
            model: modelName,
            endpoint: endpoint,
            protocolName: selectedModelPreset?.protocolName ?? "OpenAI 兼容"
        )
        appendTrace(
            kind: .warning,
            actor: "模型通道",
            title: "原生多模态降级",
            detail: "已标记 \(modelProvider)/\(modelName) 不支持原生多模态:\(reason.prefix(120))"
        )
    }

    /// 把待发图片/PDF 读成 base64 data URL(供直发大脑);脑不支持看图则返回 [](调用方回退 VL→文字)。只直发图片/PDF;粗挡 >20MB。
    func directBrainImageDataURLs() -> [String] {
        guard shouldAttemptNativeMultimodalForCurrentModel() else { return [] }
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

    /// 首次原生多模态被模型拒绝时,记住该模型能力并在同一会话中续跑纯文本降级。
    func retryMainTurnAfterNativeMultimodalRejection(
        result: LingShuAgentRunResult,
        session: any LingShuAgentSessioning,
        imageDataURLs: [String]?,
        taskRecordID: String?,
        userRequest: String
    ) async -> LingShuAgentRunResult {
        guard case .interrupted(let reason) = result,
              imageDataURLs?.isEmpty == false,
              LingShuModelServiceFailure.isNativeMultimodalUnsupportedReason(reason) else {
            return result
        }
        let message = LingShuModelServiceFailure.userFacingReason(reason)
        markCurrentModelNativeMultimodalUnsupported(reason: message)
        appendTaskRecordMessage(
            taskRecordID,
            actor: "模型通道",
            role: "多模态降级",
            kind: .warning,
            text: "原生多模态请求被当前模型拒绝,已标记 \(modelProvider)/\(modelName) 下次直接走图片解析降级;本轮改用附件摘要/本机路径继续。"
        )
        let retry = await session.continueLoop()
        return await verifyAndContinue(
            session: session,
            result: retry,
            userRequest: userRequest,
            taskRecordID: taskRecordID,
            trustReplyClaim: false
        )
    }
}
