import SwiftUI

@MainActor
enum LingShuPerceptionActions {
    static func toggleVoiceInput(
        state: LingShuState,
        voice: VoiceIOManager,
        perceptionGateway: LingShuRealtimePerceptionGateway
    ) {
        if state.voiceWakeListeningEnabled || voice.isRecording {
            state.voiceWakeListeningEnabled = false
            state.isVoiceConversationActive = false
            voice.stopRecognition()
            state.isListening = false
            state.appendTrace(kind: .system, actor: "语音", title: "停止听写", detail: "麦克风实时转写已暂停。")
            return
        }

        // 用户显式点击麦克风=立即进入实时对话，不再要求先喊触发词（触发词只用于后台免手唤醒）。
        state.voiceWakeListeningEnabled = true
        state.isVoiceConversationActive = identityAllowsConversation(perceptionGateway)
        state.isListening = true
        state.missionTitle = identityAllowsConversation(perceptionGateway) ? "实时对话" : "身份待确认"
        state.missionStatus = identityAllowsConversation(perceptionGateway)
            ? "实时对话已开启。你说完一句，我会自动进入中枢判断。"
            : "身份锁已开启。我会先确认面容和声线，再进入实时对话。"

        voice.requestAuthorization { allowed in
            guard allowed else {
                state.voiceWakeListeningEnabled = false
                state.isVoiceConversationActive = false
                state.isListening = false
                voice.markInputError("语音权限未授权")
                state.chatMessages.append(.init(
                    speaker: "灵枢",
                    text: "麦克风或语音识别权限还没有打开。授权之后，我就能听你说话。",
                    isUser: false
                ))
                return
            }

            startRecognitionLoop(state: state, voice: voice, perceptionGateway: perceptionGateway)
        }
    }

    /// 连续对话模式：进入即开启实时对话并开始监听（无需喊触发词）。
    static func startContinuousConversation(
        state: LingShuState,
        voice: VoiceIOManager,
        perceptionGateway: LingShuRealtimePerceptionGateway
    ) {
        state.voiceWakeListeningEnabled = true
        state.isVoiceConversationActive = identityAllowsConversation(perceptionGateway)
        state.isListening = true
        voice.requestAuthorization { allowed in
            guard allowed else {
                state.voiceWakeListeningEnabled = false
                state.isVoiceConversationActive = false
                state.isListening = false
                voice.markInputError("语音权限未授权")
                return
            }
            startRecognitionLoop(state: state, voice: voice, perceptionGateway: perceptionGateway)
        }
    }

    /// 一句话收口或灵枢说完后，重新武装监听（连续对话循环用）。
    static func resumeListening(
        state: LingShuState,
        voice: VoiceIOManager,
        perceptionGateway: LingShuRealtimePerceptionGateway
    ) {
        guard state.voiceWakeListeningEnabled, !voice.isRecording else { return }
        startRecognitionLoop(state: state, voice: voice, perceptionGateway: perceptionGateway)
    }

    static func stopConversation(state: LingShuState, voice: VoiceIOManager) {
        state.voiceWakeListeningEnabled = false
        state.isVoiceConversationActive = false
        state.isListening = false
        voice.stopRecognition()
        voice.stopSpeaking()
    }

    private static func startRecognitionLoop(
        state: LingShuState,
        voice: VoiceIOManager,
        perceptionGateway: LingShuRealtimePerceptionGateway
    ) {
        guard state.voiceWakeListeningEnabled, !voice.isRecording else { return }

        do {
            try voice.startRecognition(
                onText: { _ in },
                onAudioChunk: { packet in
                    perceptionGateway.ingestAudioChunk(packet)
                },
                onInterruption: {
                    scheduleRecognitionRestart(
                        state: state,
                        voice: voice,
                        perceptionGateway: perceptionGateway
                    )
                },
                onResult: { result in
                    handleVoiceTranscript(
                        result,
                        state: state,
                        voice: voice,
                        perceptionGateway: perceptionGateway
                    )
                    // 每句结束的续听已由 VoiceIOManager 内部无缝轮换处理，不再整体重启识别。
                }
            )

            state.isListening = true
            // 连续态(在岗/极简通话)不要求唤醒词,别再误报"正在等待触发词灵枢"(实测误导)。
            let continuousMode = state.isMinimalVoiceMode || state.isStandingPersonOnDuty
            let waitingForWake = state.requiresVoiceWakeWord && !continuousMode && !state.isVoiceConversationActive
            state.appendTrace(
                kind: .system,
                actor: "语音",
                title: waitingForWake ? "等待唤醒" : "实时对话",
                detail: waitingForWake
                    ? "麦克风已接入，正在等待触发词“\(effectiveWakeWord(for: state))”。"
                    : "麦克风已接入，实时对话已开启（在岗/通话态可直接说话，无需唤醒词）。"
            )
        } catch {
            state.voiceWakeListeningEnabled = false
            state.isVoiceConversationActive = false
            state.isListening = false
            voice.markInputError("语音启动失败")
            state.chatMessages.append(.init(
                speaker: "灵枢",
                text: "语音启动失败：\(error.localizedDescription)",
                isUser: false
            ))
        }
    }

    private static func scheduleRecognitionRestart(
        state: LingShuState,
        voice: VoiceIOManager,
        perceptionGateway: LingShuRealtimePerceptionGateway
    ) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard state.voiceWakeListeningEnabled, !voice.isRecording else { return }
            startRecognitionLoop(state: state, voice: voice, perceptionGateway: perceptionGateway)
        }
    }

    private static func handleVoiceTranscript(
        _ result: LingShuVoiceTranscriptionResult,
        state: LingShuState,
        voice: VoiceIOManager,
        perceptionGateway: LingShuRealtimePerceptionGateway
    ) {
        perceptionGateway.ingestAudioTranscription(result)

        let cleanedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }

        // **连续对话态** = 极简通话模式 或 灵枢在岗(完全接管)。这两种都是用户**显式开启**的"通话"——
        // 像打电话一样**不要求先喊唤醒词**,随时能说话;且灵枢正说话/在跑长回合时,新整句当作**中途插话**接住(LOOP 人机讨论)。
        let continuousMode = state.isMinimalVoiceMode || state.isStandingPersonOnDuty

        // 非连续态且灵枢正忙:维持原行为(等它说完),并让被吞的语音可见(可审计)。
        if (voice.isSpeaking || state.hasActiveModelCall), !continuousMode {
            state.missionStatus = voice.isSpeaking
                ? "我正在说话，先不接收你的语音。"
                : "我还在处理上一件事（模型调用进行中），这句语音暂未接收。"
            return
        }

        // 唤醒词闸门:仅当"要求唤醒词 + 尚未进入对话态 + 非连续模式"时才拦。匹配走宽松同音近音(实测 ASR 把"灵枢"转写不稳)。
        if state.requiresVoiceWakeWord, !state.isVoiceConversationActive, !continuousMode {
            guard LingShuWakeWordMatcher.contains(cleanedText, wakeWord: effectiveWakeWord(for: state)) else {
                state.missionTitle = "等待唤醒"
                state.missionStatus = "我正在等待触发词“\(effectiveWakeWord(for: state))”。"
                return
            }
            guard identityAllowsConversation(perceptionGateway) else {
                state.missionTitle = "身份待确认"
                state.missionStatus = "我听到了触发词，但身份还没有通过面容和声线联合确认。"
                state.appendTrace(kind: .warning, actor: "身份锁", title: "唤醒拦截", detail: perceptionGateway.ownerIdentitySnapshot.detailText)
                return
            }
            state.isVoiceConversationActive = true
            state.missionTitle = "实时对话"
            state.missionStatus = "我在。你说完一句，我会自动进入中枢判断。"
            state.appendTrace(kind: .system, actor: "语音", title: "触发词命中", detail: "实时对话已开启。")
        }

        guard identityAllowsConversation(perceptionGateway) else {
            state.missionTitle = "身份待确认"
            state.missionStatus = "身份锁已开启，正在等待面容和声线同时命中。"
            return
        }

        let containsWake = LingShuWakeWordMatcher.contains(cleanedText, wakeWord: effectiveWakeWord(for: state))
        let command = containsWake
            ? LingShuWakeWordMatcher.commandAfterWake(from: cleanedText, wakeWord: effectiveWakeWord(for: state))
            : cleanedText
        let pureWake = containsWake && command.isEmpty   // 整句就是「灵枢」=纯触发

        // busy 判据(以音频为准):模型在跑 / LOOP 在跑 / TTS 已请求或正在播 / 刚说完的回声冷却。
        let speaking = voice.isSpeaking || voice.hasAudibleOutput
        let speechPending = voice.isSpeakingOrQueued && !speaking
        let echoCooldown = Date().timeIntervalSince(voice.lastSpeechEndedAt) < voice.echoCooldownSeconds
        let busy = speaking || state.hasActiveModelCall || state.loopPhase.isActive || speechPending || echoCooldown
        let ambientGated = state.isStandingPersonOnDuty && state.meetingDetectionState.inMeeting

        // ① **纯唤醒词=进入聆听/打断的触发(最高优先,永不当回声、不被 busy 拦)**:不提交、不调模型。
        if pureWake {
            if busy { state.interruptSpeechOutput?(); voice.stopSpeaking() }   // 喊「灵枢」打断当前
            state.prompt = ""
            if !state.voiceListeningArmed {
                state.voiceListeningArmed = true
                state.lastVoiceActivityAt = Date()
                state.missionStatus = "我在听,请说。"
                LingShuCueSound.playWakeChime()
                lingShuControlLog("voice: 唤醒词→进入我在听(触发,不当指令提交)")
            }
            return
        }

        // ② **自激回声兜底**:发声中或刚说完 5s 内,听到的若是灵枢自己说过的话(或其片段)→ 判回声丢弃。
        // **不再因为含唤醒词就跳过**——灵枢自己的话常含"灵枢"同音误识别(如"林纾"),那也是回声、不能当指令。
        // (纯唤醒词已在 ① 放行,不会被这里误杀;真打断指令"灵枢,做X"不匹配最近输出 → 不算回声。)
        let echoWindow = voice.isSpeaking || Date().timeIntervalSince(voice.lastSpeechEndedAt) < 5
        if echoWindow, LingShuEchoDetector.isEcho(cleanedText, recentOutputs: state.recentSpokenForEcho()) {
            state.prompt = ""
            if result.isFinal { lingShuControlLog("voice: 回声(灵枢自己说的话)忽略「\(cleanedText.prefix(24))」") }
            return
        }

        // ③ busy/会议:非唤醒词一律忽略(串行管线,忙时只接受唤醒词打断)。
        if (busy || ambientGated), !containsWake {
            state.prompt = ""
            if result.isFinal {
                state.missionStatus = busy ? "正在处理中,喊一声「\(effectiveWakeWord(for: state))」可打断。"
                                           : "会议/多人环境:喊一声「\(effectiveWakeWord(for: state))」我才应。"
                lingShuControlLog("voice: 门(\(busy ? "忙·非唤醒" : "会议·非唤醒"))忽略「\(cleanedText.prefix(20))」")
            }
            return
        }

        // 「进入聆听模式」提示音:非会议靠声音、会议靠唤醒词;同段会话不重复响,静默 25s 后重置。
        let nowTS = Date()
        if nowTS.timeIntervalSince(state.lastVoiceActivityAt) > 25 { state.voiceListeningArmed = false }
        state.lastVoiceActivityAt = nowTS
        let entersListening = ambientGated ? containsWake : true
        if entersListening, !state.voiceListeningArmed {
            state.voiceListeningArmed = true
            LingShuCueSound.playWakeChime()
            lingShuControlLog("voice: 进入聆听模式(\(ambientGated ? "唤醒词" : "声音"))→ 提示音")
        }

        // 连续模式即便对话态标志没置上也照收(显式上岗/通话);非连续模式仍需进对话态。
        guard continuousMode || state.isVoiceConversationActive, !command.isEmpty else { return }

        state.prompt = command   // 实时显示当前听到的指令
        guard result.isFinal else { return }   // 只在整句收口时才提交/插话,partial 只用于显示

        // 声线寻址闸门：以主人声线为最高优先，多人环境未点名不插话，屏蔽嘈杂环境污染。
        // 连续态(通话/在岗)= 显式拨给灵枢的"电话",单人环境默认都在对它说话。
        let verdict = LingShuVoiceAddressingGate.decide(.init(
            transcript: command,
            containsWakeWord: containsWake,
            lockEnabled: perceptionGateway.ownerIdentityLockEnabled,
            ownerVoiceConfidence: perceptionGateway.ownerIdentitySnapshot.voiceConfidence,
            multipleSpeakersDetected: perceptionGateway.multipleSpeakersSuspected,
            secondsSinceLastExchange: state.chatMessages.last.map { Date().timeIntervalSince($0.createdAt) },
            isExplicitCallMode: continuousMode
        ))

        switch verdict {
        case .respond:
            // 调大模型前先筛:无意义语句(纯语气词/标点/噪声)**直接放弃、转待机**,不惊动大脑(省钱+免乱回应)。
            guard LingShuUtteranceMeaning.isMeaningful(command) else {
                state.prompt = ""
                state.voiceListeningArmed = false   // 收口本句,下次开口重新进入聆听
                lingShuControlLog("voice: 丢弃无意义语句「\(command.prefix(20))」→ 不调模型,转待机")
                return
            }
            // 进入聆听的提示音已在上面按"两套激活逻辑"响过(声音/唤醒词),这里不再重复响。
            // 连续 LOOP + 灵枢正说话/在跑:这是「中途插话」——先掐掉正在播的 TTS,再把整句交给中枢
            // (submitTextInput→在岗会话会把它注入正在跑的那条脑回路,答完再续)。
            if voice.isSpeaking || state.hasActiveModelCall { voice.stopSpeaking() }
            lingShuControlLog("voice: 闸门=respond callMode=\(state.isMinimalVoiceMode) standing=\(state.isStandingPersonOnDuty) → 提交「\(String(command.prefix(30)))」")
            _ = state.submitVoiceTranscript(command)
        case .ignore(let reason):
            lingShuControlLog("voice: 闸门=ignore(\(reason)) → 丢弃「\(String(command.prefix(30)))」")
            state.prompt = ""
            state.appendTrace(
                kind: .system,
                actor: "声线闸门",
                title: "环境音忽略",
                detail: "\(reason)。被忽略内容：「\(String(command.prefix(42)))」"
            )
        }
    }

    private static func effectiveWakeWord(for state: LingShuState) -> String {
        let wakeWord = state.voiceWakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        return wakeWord.isEmpty ? "灵枢" : wakeWord
    }

    private static func identityAllowsConversation(_ perceptionGateway: LingShuRealtimePerceptionGateway) -> Bool {
        !perceptionGateway.ownerIdentityLockEnabled || perceptionGateway.isOwnerIdentityLocked
    }

    private static func initialVoiceMissionTitle(
        state: LingShuState,
        perceptionGateway: LingShuRealtimePerceptionGateway
    ) -> String {
        if perceptionGateway.ownerIdentityLockEnabled && !perceptionGateway.isOwnerIdentityLocked {
            return "身份待确认"
        }

        return state.requiresVoiceWakeWord ? "等待唤醒" : "实时对话"
    }

    // 唤醒词匹配/剥离已抽到纯函数 LingShuWakeWordMatcher（宽松同音近音 + 可单测）。

    static func toggleVision(state: LingShuState, vision: VisionIOManager) {
        if vision.isCameraRunning {
            vision.stopCamera()
            state.appendTrace(kind: .system, actor: "视觉", title: "视觉下线", detail: "摄像头实时解析已暂停。")
            return
        }

        vision.requestAuthorization { allowed in
            guard allowed else {
                state.chatMessages.append(.init(
                    speaker: "灵枢",
                    text: "摄像头权限还没有打开。授权之后，我可以看见画面并把观察结果交回对话。",
                    isUser: false
                ))
                return
            }

            do {
                try vision.startCamera()
                state.missionTitle = "视觉在线"
                state.missionStatus = "我已经接入摄像头，会持续解析画面并形成可回溯的观察记录。"
                state.appendTrace(kind: .system, actor: "视觉", title: "视觉上线", detail: "摄像头已接入，正在实时解析画面亮度、运动、人脸和文字。")
            } catch {
                state.chatMessages.append(.init(
                    speaker: "灵枢",
                    text: "视觉启动失败：\(error.localizedDescription)",
                    isUser: false
                ))
            }
        }
    }
}
