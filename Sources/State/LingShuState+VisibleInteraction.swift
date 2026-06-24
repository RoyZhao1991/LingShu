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
        return record.messages.contains { msg in
            if case let .toolCall(tool, _, _) = msg.detail {
                return tool == "speak" || tool == "present_fullscreen" || tool == "enter_managed_mode"
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
        let inInteraction = previewController.isPresented
            || LingShuInteractionFulfillment.requiresLiveInteraction(prompt)
            || LingShuInteractionFulfillment.isLikelyInteractionFollowup(prompt)
        guard inInteraction,
              LingShuInteractionFulfillment.isHollowInteractionStatus(text),
              let spoken = LingShuInteractionFulfillment.latestSubstantiveSpokenLine(after: spokenBaseline, in: recentSpokenLines)
        else { return result }
        appendTaskRecordMessage(recordID, actor: "交互交付", role: "答疑正文回填", kind: .result,
                                text: "模型已通过语音给出实质内容,最终聊天回复已同步为同一正文,避免只显示空状态。")
        return .completed(text: spoken)
    }
}
