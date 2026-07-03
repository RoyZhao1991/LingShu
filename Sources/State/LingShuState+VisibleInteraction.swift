import Foundation

@MainActor
extension LingShuState {
    /// 交互交付兜底:用户要求"展示/预览/演示/讲解/汇报"时,文件落盘只是中间态。
    /// 如果模型已经产出可预览文件却直接收尾,宿主补齐"打开预览 + 首段讲解"这个可感知动作。
    func fulfillVisibleInteractionIfNeeded(
        result: LingShuAgentRunResult,
        recordID: String?,
        prompt: String
    ) async -> LingShuAgentRunResult {
        guard case .completed(let text) = result,
              LingShuInteractionFulfillment.requiresVisibleInteraction(prompt),
              !turnDidProvideInteractiveOutput(recordID) else { return result }
        let record = taskExecutionRecords.first { $0.id == recordID }
        let isLiveInteraction = LingShuInteractionFulfillment.requiresLiveInteraction(prompt)
        guard let artifact = LingShuInteractionFulfillment
            .previewableArtifacts(in: record, preferPaginated: isLiveInteraction)
            .first else { return result }

        appendTaskRecordMessage(recordID, actor: "交互交付", role: "补齐展示动作", kind: .agent,
                                text: "本轮要求展示/讲解,已发现可预览产物,准备打开:\(artifact.location)")
        let openResult = await previewController.open(path: artifact.location)
        let opened = previewController.isPresented
        appendTaskRecordMessage(
            recordID,
            actor: "交互交付",
            role: opened ? "打开预览" : "预览失败",
            kind: opened ? .result : .warning,
            text: openResult,
            detail: .toolResult(tool: "open_preview", success: opened, output: openResult)
        )
        guard opened else {
            let warning = "⚠️ 我已生成可预览产物,但自动打开预览失败:\(openResult)"
            return .completed(text: text + "\n\n" + warning)
        }

        if isLiveInteraction, !previewController.slideshow {
            let slideshow = previewController.setSlideshow(true)
            appendTaskRecordMessage(recordID, actor: "交互交付", role: "进入演示态", kind: .agent,
                                    text: slideshow, detail: .toolResult(tool: "present_fullscreen", success: previewController.slideshow, output: slideshow))
        }

        let pageText = previewController.isHTML
            ? LingShuInteractionFulfillment.readablePreviewText(for: artifact)
            : previewController.pageText(0)
        let narration = LingShuInteractionFulfillment.firstPageNarration(
            title: previewController.title.isEmpty ? artifact.title : previewController.title,
            pageText: pageText
        )
        voiceManager?.speak(narration)
        recordSpokenLine(narration)
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "首段讲解", kind: .result, text: narration)

        var suffix = "我已把材料打开在预览窗口，并先讲解了第一页。你可以继续提问，或让我接着往下讲。"
        if isLiveInteraction {
            let handoff = managedInteractionHandoffPrompt(originalPrompt: prompt, artifact: artifact)
            appendTaskRecordMessage(recordID, actor: "交互交付", role: "转入自主模式", kind: .router,
                                    text: "本轮目标包含实时讲解/演示/答疑,已把当前材料交给在岗上下文继续推进。")
            goLiveForInteractiveTask(prompt: handoff)
            suffix = "我已把材料打开并讲解了开头；这类任务需要持续演示/答疑，我已把它交给自主模式接着推进。你可以随时插话提问、翻页或要求收尾。"
        }
        return text.contains(suffix) ? result : .completed(text: text + "\n\n" + suffix)
    }

    func turnDidProvideInteractiveOutput(_ taskRecordID: String?) -> Bool {
        guard let record = taskExecutionRecords.first(where: { $0.id == taskRecordID }) else { return false }
        let interactiveTools: Set<String> = [
            "speak",
            "open_preview",
            "close_preview",
            "present_fullscreen",
            "present_documents",
            "run_steps",
            "preview_next",
            "preview_prev",
            "preview_goto",
            "preview_scroll",
            "enter_managed_mode"
        ]
        return record.messages.contains { msg in
            if case let .toolCall(tool, _, _) = msg.detail {
                return interactiveTools.contains(tool)
            }
            if case let .toolResult(tool, success, _) = msg.detail, success {
                return interactiveTools.contains(tool)
            }
            return false
        }
    }

    func managedInteractionHandoffPrompt(originalPrompt: String, artifact: LingShuTaskExecutionArtifact) -> String {
        let title = previewController.title.isEmpty ? artifact.title : previewController.title
        return """
        继续完成这次实时交互交付。
        原始目标:\(originalPrompt)
        当前材料已在预览中打开:\(title)
        材料路径:\(artifact.location)

        现在请作为在岗灵枢接手:读取当前预览材料的实际内容,按主人目标进行可视演示/口头讲解/答疑。需要连续演示时进入全屏演示并用 run_steps 批量顺滑执行;如果主人插话,先回答,再问是否继续。不要重新生成材料,除非主人明确要求改稿。
        """
    }

    func reconcileVisibleInteractionReply(
        _ result: LingShuAgentRunResult,
        prompt: String,
        spokenBaseline: Int,
        recordID: String?
    ) -> LingShuAgentRunResult {
        guard case .completed(let text) = result else { return result }
        let requestedVisible = LingShuInteractionFulfillment.requiresVisibleInteraction(prompt)
        let didInteractiveOutput = turnDidProvideInteractiveOutput(recordID)
        let hasPreviewableArtifact = !LingShuInteractionFulfillment
            .previewableArtifacts(in: taskExecutionRecords.first { $0.id == recordID })
            .isEmpty
        let inInteraction = previewController.isPresented
            || presentationController.isActive
            || didInteractiveOutput
            || requestedVisible
            || hasPreviewableArtifact
            || LingShuInteractionFulfillment.requiresLiveInteraction(prompt)
            || LingShuInteractionFulfillment.isLikelyInteractionFollowup(prompt)
        let questionLike = LingShuInteractionFulfillment.isQuestionLike(prompt)
        let inventoryStatus = LingShuInteractionFulfillment.isArtifactInventoryStatus(text)
            || ((requestedVisible || didInteractiveOutput || hasPreviewableArtifact)
                && LingShuInteractionFulfillment.isLikelyDeliveryInventoryStatus(text))
        let shouldRepair = LingShuInteractionFulfillment.isHollowInteractionStatus(text)
            || (inInteraction && inventoryStatus)
            || (questionLike && LingShuInteractionFulfillment.isPageNarrationStatus(text))
        let trimmed = questionLike ? nil : LingShuInteractionFulfillment.trimInteractionInventoryTail(text)
        let usefulTrimmed = trimmed.flatMap {
            LingShuInteractionFulfillment.isUsefulInteractionSummary($0) ? $0 : nil
        }
        let visibleFallback = questionLike ? nil : currentVisibleInteractionReply()
        guard inInteraction,
              shouldRepair,
              let replacement = LingShuInteractionFulfillment.latestSubstantiveSpokenLine(after: spokenBaseline, in: recentSpokenLines)
                ?? usefulTrimmed
                ?? visibleFallback,
              !(questionLike && LingShuInteractionFulfillment.isPageNarrationStatus(replacement))
        else { return result }
        appendTaskRecordMessage(recordID, actor: "交互交付", role: "答疑正文回填", kind: .result,
                                text: "交互型任务的最终气泡已同步为当前可感知状态,路径清单保留在任务记录中。")
        return .completed(text: replacement)
    }

    func normalizeFinalVisibleInteractionText(
        _ text: String,
        prompt: String,
        recordID: String?
    ) -> String {
        let requestedVisible = LingShuInteractionFulfillment.requiresVisibleInteraction(prompt)
        let didInteractiveOutput = turnDidProvideInteractiveOutput(recordID)
        let hasPreviewableArtifact = !LingShuInteractionFulfillment
            .previewableArtifacts(in: taskExecutionRecords.first { $0.id == recordID })
            .isEmpty
        let inInteraction = previewController.isPresented
            || presentationController.isActive
            || didInteractiveOutput
            || requestedVisible
            || hasPreviewableArtifact
            || LingShuInteractionFulfillment.requiresLiveInteraction(prompt)
            || LingShuInteractionFulfillment.isLikelyInteractionFollowup(prompt)
        guard inInteraction else { return text }

        let inventoryStatus = LingShuInteractionFulfillment.isArtifactInventoryStatus(text)
            || ((requestedVisible || didInteractiveOutput || hasPreviewableArtifact)
                && LingShuInteractionFulfillment.isLikelyDeliveryInventoryStatus(text))
        let hollow = LingShuInteractionFulfillment.isHollowInteractionStatus(text)
        guard inventoryStatus || hollow else { return text }

        let trimmed = LingShuInteractionFulfillment.trimInteractionInventoryTail(text)
        let usefulTrimmed = trimmed.flatMap {
            LingShuInteractionFulfillment.isUsefulInteractionSummary($0) ? $0 : nil
        }
        let replacement = usefulTrimmed ?? currentVisibleInteractionReply()
        guard let replacement, !replacement.isEmpty, replacement != text else { return text }
        appendTaskRecordMessage(recordID, actor: "交互交付", role: "最终气泡归一", kind: .result,
                                text: "交互型任务收口时移除了文件库存式主回复;文件路径保留在任务记录和产出物面板。")
        return replacement
    }

    func currentVisibleInteractionReply() -> String? {
        guard previewController.isPresented else { return nil }
        let title = previewController.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = previewController.displayedPageNumber
        let pageText: String
        if previewController.isHTML {
            pageText = ""
        } else {
            pageText = previewController.pageText(max(0, page - 1))
        }
        let compact = pageText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(4)
            .joined(separator: "；")
        let name = title.isEmpty ? "当前材料" : "「\(title)」"
        let mode = previewController.slideshow ? "已进入全屏演示状态" : "已打开预览"
        if compact.isEmpty {
            return "\(name)\(mode),当前停在第 \(page) 页。我会按屏幕内容继续讲解,你可以随时提问、让我翻页或收尾。"
        }
        return "\(name)\(mode),当前停在第 \(page) 页。页面要点:\(String(compact.prefix(180)))。你可以随时提问、让我翻页或收尾。"
    }
}
