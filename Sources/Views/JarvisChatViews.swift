import SwiftUI

struct JarvisChatView: View {
    @ObservedObject var state: LingShuState
    @StateObject private var voice = VoiceIOManager()
    @State private var lastChatBottomSignature = ""

    var body: some View {
        ZStack {
            Color.lingVoid
                .ignoresSafeArea()

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Color.lingHolo)
                            .frame(width: 42, height: 42)
                            .background(Color.lingHolo.opacity(0.10), in: Circle())

                        VStack(alignment: .leading, spacing: 3) {
                            Text("灵枢")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("主对话只由灵枢回应；agent 状态在右侧调用链显示。")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(state.activeLayer)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.lingHolo)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.lingHolo.opacity(0.10), in: Capsule())
                    }
                    .padding(.bottom, 4)

                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
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
                            .padding(.trailing, 4)
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
                    .layoutPriority(1)

                    VStack(spacing: 10) {
                        ReturnSubmittingTextEditor(
                            text: $state.prompt,
                            foregroundColor: .white,
                            fontSize: 15.5,
                            onSubmit: sendToLingShu
                        )
                            .padding(14)
                            .frame(height: 142)
                            .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                if state.prompt.isEmpty {
                                    Text("向灵枢下达需求、任务或约束...")
                                        .font(.system(size: 14.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.30))
                                        .padding(.top, 15)
                                        .padding(.leading, 15)
                                        .allowsHitTesting(false)
                                }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.lingHolo.opacity(0.22))
                            }

                        HStack(spacing: 10) {
                            Button {
                                toggleVoiceInput()
                            } label: {
                                Image(systemName: voice.isRecording ? "mic.fill" : "mic")
                                    .font(.system(size: 17, weight: .bold))
                                    .frame(width: 44, height: 40)
                                    .foregroundStyle(voice.isRecording ? .white : Color.lingVoid)
                                    .background(voice.isRecording ? Color.red.opacity(0.92) : Color.lingHolo, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("语音输入")

                            Button {
                                state.voiceOutputEnabled.toggle()
                            } label: {
                                Image(systemName: state.voiceOutputEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .frame(width: 44, height: 40)
                                    .foregroundStyle(.white.opacity(0.86))
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.white.opacity(0.10))
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(state.voiceOutputEnabled ? "关闭语音输出" : "开启语音输出")

                            if state.hasActiveModelCall {
                                Button {
                                    state.cancelCurrentCall()
                                } label: {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 15, weight: .bold))
                                        .frame(width: 44, height: 40)
                                        .foregroundStyle(.white.opacity(0.92))
                                        .background(Color.orange.opacity(0.88), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .help("停止本轮调用")
                            }

                            Button {
                                sendToLingShu()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "paperplane.fill")
                                    Text("交给灵枢")
                                }
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .foregroundStyle(Color.lingVoid)
                                .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        HStack(spacing: 8) {
                            HoloStatusDot(active: voice.isRecording)
                            Text(voice.statusMessage)
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.58))
                            Spacer()
                            Text(state.modelConnectionState)
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(state.isModelConnected ? Color.lingHolo : Color.orange.opacity(0.82))
                        }
                    }
                }
                .padding(18)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.lingHolo.opacity(0.16))
                }

                MissionStatusPanelView(state: state)
                    .frame(width: 360)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
    }

    private func toggleVoiceInput() {
        if voice.isRecording {
            voice.stopRecognition()
            state.isListening = false
            return
        }

        voice.requestAuthorization { allowed in
            guard allowed else {
                state.chatMessages.append(.init(
                    speaker: "灵枢",
                    text: "语音入口需要麦克风和语音识别权限。你可以在系统设置里授权，也可以继续用文字输入。",
                    isUser: false
                ))
                return
            }

            do {
                try voice.startRecognition { text in
                    state.prompt = text
                } onFinal: { text in
                    _ = state.submitVoiceTranscript(text)
                }
                state.isListening = true
                state.missionTitle = "正在监听"
                state.missionStatus = "语音会先被系统转写成文字，再交给灵枢和模型网关理解。"
                state.logEvent("现在  语音入口开始监听。")
            } catch {
                state.isListening = false
                voice.markInputError("语音启动失败")
                state.chatMessages.append(.init(
                    speaker: "灵枢",
                    text: "语音启动失败：\(error.localizedDescription)",
                    isUser: false
                ))
            }
        }
    }

    private func sendToLingShu() {
        if voice.isRecording {
            voice.stopRecognition()
            state.isListening = false
        }

        let reply = state.submitTextInput(state.prompt, source: .typed)
        if state.voiceOutputEnabled && !state.isModelReplying {
            voice.speak(reply)
        }
    }

    private func chatBottomSignature(_ messages: [ChatMessage]) -> String {
        guard let message = messages.last else { return "empty" }
        return "\(message.id.uuidString):\(message.text.count):\(message.isLoading)"
    }
}

struct ChatBubbleView: View {
    let message: ChatMessage
    @ObservedObject var state: LingShuState

    var body: some View {
        HStack {
            if message.isUser {
                Spacer(minLength: 80)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(message.isUser ? "你" : "灵枢")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(message.isUser ? .white.opacity(0.72) : Color.lingHolo.opacity(0.84))

                if message.isLoading && !message.isUser {
                    HStack(alignment: .top, spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(Color.lingHolo)
                            .frame(width: 18, height: 18, alignment: .leading)

                        Text(message.text.isEmpty ? "我在判断。" : message.text)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(message.text)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(.white.opacity(message.isUser ? 0.94 : 0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !message.isUser,
                   !message.isLoading,
                   let taskRecordID = message.taskRecordID,
                   state.taskExecutionRecordLookup.contains(where: { $0.id == taskRecordID }) {
                    Button {
                        state.openTaskRecord(taskRecordID)
                    } label: {
                        Label("查看任务执行记录", systemImage: "bubble.left.and.bubble.right")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.lingHolo.opacity(0.92))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.lingHolo.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.lingHolo.opacity(0.18))
                            }
                    }
                    .buttonStyle(.plain)
                    .help("打开本轮任务的 agent 群聊式执行记录")
                }
            }
            .padding(14)
            .frame(maxWidth: message.isUser ? 420 : 760, alignment: .leading)
            .background(message.isUser ? Color.lingHolo.opacity(0.22) : Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(message.isUser ? Color.lingHolo.opacity(0.34) : Color.white.opacity(0.10))
            }

            if !message.isUser {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
}
