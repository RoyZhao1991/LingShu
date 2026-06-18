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
                    // 灵枢自己正在发声时,不拿这段(含自家 TTS 回声的)音频做声线画像——否则自激回声被当成第二个人,
                    // 假"多人对话"会让寻址闸门把主人的提问丢弃(实测"问了不回"根因)。
                    perceptionGateway.ingestAudioChunk(packet, profileSpeaker: !voice.isSpeakingOrQueued)
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
        // **例外:带目标的自主运行进行中**——那时麦克风是为"随时插话打断"常开的(系统提示里的人机讨论 LOOP),
        // 绝不能在这里把含唤醒词的插话一并吞掉,否则带目标自主运行下"喊灵枢打断"永远到不了下面 ① 的判定
        // (实测打断失灵的根因之一)。运行态放行,继续往下走唤醒词/打断判定。
        if (voice.isSpeaking || state.hasActiveModelCall), !continuousMode, state.autonomousRun.phase != .running {
            state.missionStatus = voice.isSpeaking
                ? "我正在说话，先不接收你的语音。"
                : "我还在处理上一件事（模型调用进行中），这句语音暂未接收。"
            if result.isFinal { lingShuControlLog("voice/barge: 早返回吞输入(非连续·非运行) speaking=\(voice.isSpeaking) model=\(state.hasActiveModelCall)「\(cleanedText.prefix(20))」") }
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

        // 诊断打断:正在发声/忙或听到唤醒词时,把这条转写的全部判据记一笔——
        // 定位"喊灵枢为何没打断"到底卡在哪:ASR 没识别出灵枢 / 被回声门吞 / busy 早返回 / 在等收口。
        let echoWindowDiag = voice.isSpeaking || Date().timeIntervalSince(voice.lastSpeechEndedAt) < 5
        if speaking || busy || containsWake {
            lingShuControlLog("voice/barge: wake=\(containsWake) pure=\(pureWake) final=\(result.isFinal) speaking=\(speaking) busy=\(busy) aec=\(voice.isVoiceProcessingActive) echoWin=\(echoWindowDiag) cont=\(continuousMode) lvl=\(String(format: "%.2f", voice.inputLevel)) cmd「\(command.prefix(14))」all「\(cleanedText.prefix(28))」")
        }

        // **半双工硬闸(AEC 没生效时)**:灵枢正发声/刚发完的回声窗口内,麦克风听到的**全是它自己**——
        // 没有 AEC 就分不清"自己"和"主人插话"(实测:念到"我是灵枢"被自己当唤醒词打断、把误识别的"林叔"当主人名)。
        // 此时一律丢弃:不打断、不提交、不进我在听。等灵枢说完 + 回声冷却过去,再正常听。
        // AEC 一旦真生效(isVoiceProcessingActive=true,自己的声音已被消掉),这道闸自动放开,恢复说话时也能被主人插话打断。
        let selfEchoWindow = voice.isSpeakingOrQueued || Date().timeIntervalSince(voice.lastSpeechEndedAt) < voice.echoCooldownSeconds
        if !voice.isVoiceProcessingActive, selfEchoWindow {
            state.prompt = ""
            if result.isFinal || containsWake {
                lingShuControlLog("voice/barge: 半双工(AEC关·发声中)丢弃 wake=\(containsWake)「\(cleanedText.prefix(20))」")
            }
            return
        }

        // 唤醒词打断(barge-in):点名「灵枢」且此刻在说/在跑 → **立刻**掐掉正在播的语音 + 中止在飞回合,
        // 不等收口(partial 即触发,小爱/小度式实时打断)、不要求纯唤醒。两道防自激护栏:
        //  ① 唤醒词须**领头**且其后指令很短(command ≤ 8 字)——真插话「灵枢/灵枢停一下」如此,长回声里夹个同音字不会(它的 command 是整段长串);
        //  ② 回声门兜底:这句若是灵枢自己刚说过的话的回声(AEC 没消干净)→ 不当插话,避免自激打断。
        if containsWake, busy, !pureWake, command.count <= 8,
           !(echoWindowDiag && LingShuEchoDetector.isEcho(cleanedText, recentOutputs: state.recentSpokenForEcho())) {
            state.interruptSpeechOutput?()
            voice.stopSpeaking()
            lingShuControlLog("voice/barge: 唤醒词打断(非纯·partial即触发) final=\(result.isFinal)「\(cleanedText.prefix(24))」")
        }

        // ① **纯唤醒词=进入聆听/打断的触发(最高优先,永不当回声、不被 busy 拦)**:不提交、不调模型。
        if pureWake {
            let interrupted = busy
            if interrupted { state.interruptSpeechOutput?(); voice.stopSpeaking(); lingShuControlLog("voice/barge: 纯唤醒打断 final=\(result.isFinal)") }   // 喊「灵枢」打断当前
            state.prompt = ""
            voice.transcript = ""   // 清掉唤醒前累积的回声,开一个干净的「我在听」窗口(只等主人接下来真正的指令)
            // 喊「灵枢」=进入/重置聆听窗口:**打断时一定给提示音 + 「我在听」反馈**(哪怕之前已 armed,
            // 用户要的就是每次喊都听到"叮"并进入等待);只在已 armed 且非打断时不重复响,避免连环 chime。
            if !state.voiceListeningArmed || interrupted {
                state.voiceListeningArmed = true
                state.lastVoiceActivityAt = Date()
                state.missionStatus = "我在听,请说。"
                LingShuCueSound.playWakeChime()
                lingShuControlLog("voice: 唤醒词→进入我在听(触发,不当指令提交) 打断=\(interrupted)")
            }
            return
        }

        // ② **自激回声兜底**:发声中或刚说完 5s 内,听到的若是灵枢自己说过的话(或其片段)→ 判回声丢弃。
        // **不再因为含唤醒词就跳过**——灵枢自己的话常含"灵枢"同音误识别(如"林纾"),那也是回声、不能当指令。
        // (纯唤醒词已在 ① 放行,不会被这里误杀;真打断指令"灵枢,做X"不匹配最近输出 → 不算回声。)
        let echoWindow = voice.isSpeaking || Date().timeIntervalSince(voice.lastSpeechEndedAt) < 5
        if echoWindow, LingShuEchoDetector.isEcho(cleanedText, recentOutputs: state.recentSpokenForEcho()) {
            state.prompt = ""
            // 含唤醒词却被回声门吞 = 打断失灵的关键现场(用户的插话和灵枢自己的话混在一句里),partial 也记。
            if result.isFinal || containsWake { lingShuControlLog("voice/barge: 回声门吞掉(wake=\(containsWake) final=\(result.isFinal))「\(cleanedText.prefix(24))」") }
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

        // 「进入聆听模式」提示音:非会议靠声音、会议靠唤醒词;同段会话不重复响,聆听窗口静默超时后重置(下次开口重新响)。
        let nowTS = Date()
        if nowTS.timeIntervalSince(state.lastVoiceActivityAt) > state.voiceListeningWindowSeconds { state.voiceListeningArmed = false }
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
            state.voiceListeningArmed = false   // 有效内容已收口提交,关闭聆听窗口(状态机:我在听 → 处理中);下次开口重新响铃
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
