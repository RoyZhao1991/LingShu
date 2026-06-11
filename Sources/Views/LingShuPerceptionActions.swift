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

                    if result.isFinal {
                        scheduleRecognitionRestart(
                            state: state,
                            voice: voice,
                            perceptionGateway: perceptionGateway
                        )
                    }
                }
            )

            state.isListening = true
            state.appendTrace(
                kind: .system,
                actor: "语音",
                title: state.requiresVoiceWakeWord ? "等待唤醒" : "实时对话",
                detail: state.requiresVoiceWakeWord
                    ? "麦克风已接入，正在等待触发词“\(effectiveWakeWord(for: state))”。"
                    : "麦克风已接入，实时对话已开启。"
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

        guard !voice.isSpeaking, !state.hasActiveModelCall else { return }

        let cleanedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }

        if state.requiresVoiceWakeWord, !state.isVoiceConversationActive {
            guard containsWakeWord(cleanedText, wakeWord: effectiveWakeWord(for: state)) else {
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

        let command = commandText(from: cleanedText, wakeWord: effectiveWakeWord(for: state))
        guard state.isVoiceConversationActive, !command.isEmpty else { return }

        state.prompt = command

        if result.isFinal {
            _ = state.submitVoiceTranscript(command)
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

    private static func containsWakeWord(_ text: String, wakeWord: String) -> Bool {
        normalized(text).contains(normalized(wakeWord))
    }

    private static func commandText(from text: String, wakeWord: String) -> String {
        guard containsWakeWord(text, wakeWord: wakeWord),
              let range = text.range(of: wakeWord, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(text[range.upperBound...])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
            .map(String.init)
            .joined()
    }

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
