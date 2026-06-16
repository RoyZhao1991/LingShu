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

        let command = LingShuWakeWordMatcher.stripWakeWord(from: cleanedText, wakeWord: effectiveWakeWord(for: state))
        // 连续模式即便对话态标志没置上也照收(显式上岗/通话);非连续模式仍需进对话态。
        guard continuousMode || state.isVoiceConversationActive, !command.isEmpty else { return }

        state.prompt = command   // 实时显示当前听到的指令
        guard result.isFinal else { return }   // 只在整句收口时才提交/插话,partial 只用于显示

        // 声线寻址闸门：以主人声线为最高优先，多人环境未点名不插话，屏蔽嘈杂环境污染。
        // 连续态(通话/在岗)= 显式拨给灵枢的"电话",单人环境默认都在对它说话。
        let verdict = LingShuVoiceAddressingGate.decide(.init(
            transcript: command,
            containsWakeWord: LingShuWakeWordMatcher.contains(cleanedText, wakeWord: effectiveWakeWord(for: state)),
            lockEnabled: perceptionGateway.ownerIdentityLockEnabled,
            ownerVoiceConfidence: perceptionGateway.ownerIdentitySnapshot.voiceConfidence,
            multipleSpeakersDetected: perceptionGateway.multipleSpeakersSuspected,
            secondsSinceLastExchange: state.chatMessages.last.map { Date().timeIntervalSince($0.createdAt) },
            isExplicitCallMode: continuousMode
        ))

        switch verdict {
        case .respond:
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
