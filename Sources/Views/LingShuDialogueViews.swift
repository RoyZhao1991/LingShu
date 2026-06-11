import SwiftUI

struct LingShuDialogueSurface: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway
    @State private var lastChatBottomSignature = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 14) {
                VStack(spacing: 5) {
                    Text(state.coreState.rawValue)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(state.coreState.color)
                    Text(state.coreStateSubtitle)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(state.coreState.color.opacity(0.78))
                    Text("你只需要下达指令；规划、审议、调度、执行、监控、验证等 agent 的实时状态在右侧调用链显示。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .padding(.top, 12)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            if state.hasMoreColdChatHistory {
                                Color.clear
                                    .frame(height: 1)
                                    .id("lingshu-chat-top")
                                    .onAppear {
                                        state.loadOlderChatHistoryIfNeeded()
                                    }
                            }

                            ForEach(state.chatMessages) { message in
                                ChatBubbleView(message: message, state: state)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("lingshu-chat-bottom")
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 2)
                    }
                    .onAppear {
                        lastChatBottomSignature = chatBottomSignature(state.chatMessages)
                        DispatchQueue.main.async {
                            proxy.scrollTo("lingshu-chat-bottom", anchor: .bottom)
                        }
                    }
                    .onReceive(state.$chatMessages) { messages in
                        let signature = chatBottomSignature(messages)
                        guard signature != lastChatBottomSignature else { return }
                        lastChatBottomSignature = signature

                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo("lingshu-chat-bottom", anchor: .bottom)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                LingShuExecutionConsoleView(state: state)
                    .frame(height: state.isExecutionConsoleExpanded ? 164 : 44)

                LingShuInputDock(state: state, voice: voice, vision: vision, perceptionGateway: perceptionGateway)
            }
            .padding(18)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.lingHolo.opacity(0.16))
            }

            LingShuCallChainPanel(state: state)
                .frame(width: 390)
        }
        .padding(20)
        .sheet(isPresented: $state.isTaskRecordPresented) {
            if let record = state.selectedTaskRecord {
                TaskExecutionRecordSheet(record: record, lineageRecords: state.selectedTaskRecordLineage)
            } else {
                Text("任务记录不存在")
                    .frame(width: 520, height: 320)
            }
        }
        .onReceive(state.$chatMessages) { messages in
            speakLatestReplyIfNeeded(messages)
        }
    }

    private func speakLatestReplyIfNeeded(_ messages: [ChatMessage]) {
        guard state.voiceOutputEnabled,
              let message = messages.last(where: { !$0.isUser && !$0.isLoading }),
              message.id != state.lastSpokenMessageID else {
            return
        }

        state.lastSpokenMessageID = message.id
        voice.speak(message.text)
        perceptionGateway.ingestSpeechOutput(message.text)
    }

    private func chatBottomSignature(_ messages: [ChatMessage]) -> String {
        guard let message = messages.last else { return "empty" }
        return "\(message.id.uuidString):\(message.text.count):\(message.isLoading)"
    }

}

struct LingShuInputDock: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway

    var body: some View {
        VStack(spacing: 10) {
            TextField("向灵枢下达需求、任务或约束...", text: $state.prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(5...8)
                .padding(14)
                .frame(minHeight: 126, alignment: .topLeading)
                .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.lingHolo.opacity(0.22))
                }
                .submitLabel(.send)
                .onSubmit {
                    submit()
                }

            HStack(spacing: 10) {
                Button {
                    toggleVoiceInput()
                } label: {
                    Image(systemName: voice.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(voice.isRecording ? .white : Color.lingVoid)
                        .frame(width: 46, height: 42)
                        .background(voice.isRecording ? Color.red.opacity(0.92) : Color.lingHolo, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(voice.isRecording ? "停止语音输入" : "语音输入")

                Button {
                    state.voiceOutputEnabled.toggle()
                } label: {
                    Image(systemName: state.voiceOutputEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(width: 46, height: 42)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(state.voiceOutputEnabled ? "关闭语音输出" : "开启语音输出")

                Button {
                    toggleVision()
                } label: {
                    Image(systemName: vision.isCameraRunning ? "eye.fill" : "eye")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(vision.isCameraRunning ? Color.lingVoid : .white.opacity(0.86))
                        .frame(width: 46, height: 42)
                        .background(vision.isCameraRunning ? Color.cyan.opacity(0.92) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(vision.isCameraRunning ? "关闭视觉解析" : "打开视觉解析")

                if state.hasActiveModelCall {
                    Button {
                        state.cancelCurrentCall()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 46, height: 42)
                            .background(Color.orange.opacity(0.88), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("停止本轮调用")
                }

                Button {
                    submit()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "paperplane.fill")
                        Text("交给灵枢")
                    }
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.lingVoid)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            HStack {
                Text("Return 发送")
                Spacer()
                Text(state.modelConnectionState)
                    .foregroundStyle(state.isModelConnected ? Color.lingHolo : Color.orange.opacity(0.86))
            }
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.48))
        }
    }

    private func submit() {
        if voice.isRecording {
            voice.stopRecognition()
            state.isListening = false
        }

        _ = state.sendPrompt()
    }

    private func toggleVoiceInput() {
        LingShuPerceptionActions.toggleVoiceInput(
            state: state,
            voice: voice,
            perceptionGateway: perceptionGateway
        )
    }

    private func toggleVision() {
        LingShuPerceptionActions.toggleVision(state: state, vision: vision)
    }
}
