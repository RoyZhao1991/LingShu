import Foundation

/// 会议纪要(在岗自动):检测进入会议 → 分段累积系统声音转写(轮转绕开单次 ASR 时长上限)→
/// 离会后台自动生成结构化纪要、落成本地文档、主动推送。
///
/// 只在**在岗(独立运行)**时工作——那时灵枢已在听系统声音(`startStandingAmbientListening`)、看屏幕(感知循环)。
/// 检测是机械"反射"([LingShuMeetingDetector]);纪要的理解/撰写/落档/推送交给**大脑**(复用在岗会话 +
/// write_file/run_command/speak),不写死模板。隐私:转写仅内存累积,生成纪要后即清空分段。
@MainActor
extension LingShuState {

    /// 周期感知每拍调:据前台 app/窗口标题/声音活动推进会议检测,跃迁则起停纪要。
    func updateMeetingDetection(windowSignature: String, audioActive: Bool, now: Date = Date()) {
        let bundle = LingShuComputerControl.frontmostAppToken()?.label
        let transition = LingShuMeetingDetector.update(
            &meetingDetectionState,
            frontmostBundle: bundle,
            windowSignature: windowSignature,
            audioActive: audioActive,
            now: now
        )
        switch transition {
        case .entered:
            // 暂不自动开会议纪要:它要"系统声音 ASR 与麦克风 ASR 并发",目前没验证跑通(会弄哑麦克风)。
            // 检测仍生效(用于 ambientGated 智能唤醒:会议中要喊「灵枢」),只是不启动会冲突的系统声音转写。
            appendTrace(kind: .system, actor: "会议", title: "检测到会议", detail: "智能唤醒生效(喊「灵枢」叫我);会议纪要暂未开启(待双引擎并发跑通)。")
        case .exited:
            if meetingMinutesActive { endMeetingMinutesAndGenerate() }
        case .none: break
        }
    }

    /// 进入会议:开始分段累积(每 40s 轮转一段:落定当前转写 + 重启 ASR 接下一段,绕开单会话时长上限)。
    func beginMeetingMinutes() {
        guard !meetingMinutesActive else { return }
        meetingMinutesActive = true
        meetingMinutesSegments = []
        meetingMinutesStartedAt = Date()
        appendTrace(kind: .runtime, actor: "会议", title: "检测到会议", detail: "开始分段记录系统声音转写,离会后自动生成纪要。")
        // 确保系统声音 ASR 在跑(在岗一般已开;保险起见)。
        if !standingAmbientASRActive { startStandingAmbientListening() }
        meetingMinutesRotationTask?.cancel()
        meetingMinutesRotationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000_000)   // 40s 一段
                guard !Task.isCancelled, let self, self.meetingMinutesActive else { return }
                self.rotateMeetingMinutesSegment()
            }
        }
    }

    /// 轮转一段:落定当前 ASR 转写为一段,重启 ASR 清空缓冲接下一段。
    func rotateMeetingMinutesSegment() {
        let text = LingShuMeetingASR.shared.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            meetingMinutesSegments.append(.init(at: Date(), text: text))
        }
        // 重启 ASR:清空当前段缓冲 + 规避单次识别会话时长上限(onPCMChunk 仍指向 shared,继续喂)。
        LingShuMeetingASR.shared.stop()
        LingShuMeetingASR.shared.start()
    }

    /// 离开会议:收尾累积 → 拼完整转写 → 交大脑生成纪要(落档 + 推送)。转写过短则跳过。
    func endMeetingMinutesAndGenerate() {
        guard meetingMinutesActive else { return }
        meetingMinutesActive = false
        meetingMinutesRotationTask?.cancel()
        meetingMinutesRotationTask = nil
        rotateMeetingMinutesSegment()   // 收尾最后一段

        let transcript = LingShuMeetingDetector.assembleTranscript(meetingMinutesSegments, start: meetingMinutesStartedAt)
        let segCount = meetingMinutesSegments.count
        meetingMinutesSegments = []
        meetingMinutesStartedAt = nil

        guard transcript.count >= 30 else {
            appendTrace(kind: .system, actor: "会议", title: "会议结束", detail: "转写过短(\(transcript.count)字),不生成纪要。")
            return
        }
        appendTrace(kind: .runtime, actor: "会议", title: "会议结束", detail: "共 \(segCount) 段转写,后台生成纪要中…")
        generateMeetingMinutes(transcript: transcript)
    }

    /// 把转写交给在岗会话:生成结构化纪要 → write_file 落档(优先 docx,不行则 md)→ speak 简短播报 + 回复摘要+路径。
    /// 复用 wake 的串行模式(等上一回合结束再插入,避免抢占正在跑的脑回路)。
    func generateMeetingMinutes(transcript: String) {
        guard let session = autonomousSessionHolder else {
            appendTrace(kind: .warning, actor: "会议", title: "无在岗会话", detail: "未在岗,跳过纪要生成(会议纪要仅在独立运行时工作)。")
            return
        }
        let prompt = """
        刚结束一场会议。下面是「系统声音」的完整转写(分段带相对时间,可能有识别误差,请据上下文纠正明显错字)。请:
        1) 生成一份结构化中文**会议纪要**:主题 / 时间与时长 / 讨论要点(分条)/ 形成的决议 / 待办事项(尽量标责任人与时限)/ 风险或待跟进问题;
        2) 用 `write_file` 把纪要**落成本地文档**存到工作目录 \(codexWorkingDirectory),文件名带日期(如 `会议纪要-YYYYMMDD-HHmm`)。**优先 .docx**(可用 run_command 走 python-docx/pandoc 生成;装不了或不可用就存 .md,别卡住);
        3) 用 `speak` 简短播报一句「会议纪要已生成」,**并调用 `push_notification`** 推一条系统通知(标题「会议纪要已生成」、正文带文件名),这样主人不在电脑前也能看到;最后在回复里给出**纪要要点摘要 + 文件绝对路径**。

        完整转写:
        \(transcript)
        """
        let previous = autonomousRunTask
        autonomousRunTask?.cancel()
        autonomousRunTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { self?.autonomousRunTask = nil; return }
            let recordID = self.autonomousRunRecordID ?? self.createTaskExecutionRecord(for: "会议纪要")
            self.autonomousRunRecordID = recordID
            self.enterAutonomousRunningState(statusLine: "会议结束,正在生成纪要并落档…")
            self.missionTitle = "会议纪要"
            self.appendTrace(kind: .runtime, actor: "会议", title: "生成纪要", detail: "已把完整转写交给大脑撰写并落档。")
            let baseline = self.currentArtifactCount(recordID)
            let initial = await session.resume(prompt)
            let result = await self.verifyAndContinue(session: session, result: initial, userRequest: "生成会议纪要并落档", taskRecordID: recordID, artifactBaseline: baseline)
            guard !Task.isCancelled else { return }
            self.finishAutonomousRun(result: result, recordID: recordID)
        }
    }
}
