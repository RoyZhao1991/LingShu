import SwiftUI

struct LingShuDialogueSurface: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway
    @State private var lastChatBottomSignature = ""

    var body: some View {
        VStack(spacing: 12) {
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

            LingShuPulseStrip(state: state)

            LingShuInputDock(state: state, voice: voice, vision: vision, perceptionGateway: perceptionGateway)
        }
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
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

/// 对话表面的运行脉搏条：状态速览的唯一入口，点击进入运行态。
/// 条上每个元素都映射真实信号——状态点与文字 = 中枢状态（秒级局部刷新），
/// 中段文案 = 当前任务动作，计数 = 活跃任务线程，波形 = 主通道是否有调用在途。
struct LingShuPulseStrip: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        Button {
            state.selectedSurface = .runtime
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(state.coreState.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: state.coreState.color.opacity(0.85), radius: 4)

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(state.coreStateDisplay)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(state.coreState.color)
                }

                Text(state.missionStatus)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)

                Spacer(minLength: 10)

                if !state.taskThreads.isEmpty {
                    Text("\(state.taskThreads.count) 线程")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }

                LingShuVoiceWaveView(color: .lingHolo, isActive: state.hasActiveModelCall)
                    .help("主通道调用活动：跳动表示模型调用在途")

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .lingShuHUDPanel(cornerLength: 8, fillOpacity: 0.03)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开运行态：完整调用链、执行轨迹与会话状态")
    }
}

/// 对话区头部：全息核心居中，两侧为任务/通道实时读数。
/// 核心动画由 TimelineView 驱动；秒级读数包在 1 秒周期的 TimelineView 里局部刷新，
/// 不依赖全局状态对象的 objectWillChange。
struct LingShuCoreHeader: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                LingShuHUDReadout(label: "MISSION", value: state.missionTitle, color: state.coreState.color)
                LingShuHUDReadout(label: "THREADS", value: "\(state.taskThreads.count) 条任务线程")
                LingShuHUDReadout(label: "MEMORY", value: state.mainMemoryStatus)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                LingShuHoloCoreView(
                    color: state.coreState.color,
                    intensity: coreIntensity,
                    isAbnormal: state.coreState == .abnormal
                )
                .frame(width: 150, height: 150)

                VStack(spacing: 3) {
                    Text(state.coreState.rawValue)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(state.coreState.color)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(state.coreStateSubtitle)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(state.coreState.color.opacity(0.75))
                    }
                    LingShuVoiceWaveView(
                        color: state.coreState.color,
                        isActive: voice.isRecording || voice.isSpeaking
                    )
                }
            }

            VStack(alignment: .trailing, spacing: 10) {
                LingShuHUDReadout(label: "CHANNEL", value: state.modelProvider, color: state.isModelConnected ? .lingHolo : .orange)
                LingShuHUDReadout(label: "SESSIONS", value: state.remoteSessionStatus)
                LingShuHUDReadout(label: "TRUST", value: "\(state.trustScore)%", color: .lingHolo)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 4)
        .frame(height: 158)
    }

    private var coreIntensity: Double {
        if voice.isRecording { return 1.0 }
        switch state.coreState {
        case .standby: return 0.12
        case .thinking: return 1.0
        case .executing: return 0.75
        case .abnormal: return 0.45
        }
    }
}

/// 待发送附件托盘：每个 chip = 文件名（字面）+ 解析状态（底层服务状态：解析中/就绪/失败）。
struct LingShuAttachmentTray: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(state.pendingAttachments) { attachment in
                    HStack(spacing: 7) {
                        Image(systemName: attachment.kind.icon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.lingHolo)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.filename)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                            Text(attachment.status ?? (attachment.extractedContext.isEmpty ? "已登记" : "已解析 · 可改写"))
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(attachment.status == nil ? Color.lingHolo.opacity(0.85) : .orange.opacity(0.85))
                                .lineLimit(1)
                        }

                        Button {
                            state.removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: 220)
                    .lingShuHUDPanel(cornerLength: 6, fillOpacity: 0.05)
                }
            }
            .padding(.horizontal, 1)
        }
    }
}

struct LingShuInputDock: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway

    var body: some View {
        VStack(spacing: 10) {
            if !state.pendingAttachments.isEmpty {
                LingShuAttachmentTray(state: state)
            }

            TextField("向灵枢下达需求、任务或约束...", text: $state.prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(5...8)
                .padding(14)
                .frame(minHeight: 126, alignment: .topLeading)
                .lingShuHUDPanel(
                    accent: voice.isRecording ? .red : .lingHolo,
                    cornerLength: 10,
                    fillOpacity: 0.06
                )
                .overlay(alignment: .bottomTrailing) {
                    if voice.isRecording {
                        HStack(spacing: 6) {
                            LingShuVoiceWaveView(color: .red, isActive: true, barCount: 7)
                            Text("正在聆听")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.red.opacity(0.85))
                        }
                        .padding(10)
                    }
                }
                .submitLabel(.send)
                .onSubmit {
                    submit()
                }

            HStack(spacing: 10) {
                Button {
                    state.presentAttachmentPicker()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(state.pendingAttachments.isEmpty ? .white.opacity(0.86) : Color.lingVoid)
                        .frame(width: 46, height: 42)
                        .background(state.pendingAttachments.isEmpty ? Color.white.opacity(0.08) : Color.lingHolo, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("上传图片 / PPT / 文档给灵枢理解或修改")

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
