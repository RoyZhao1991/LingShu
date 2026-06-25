import SwiftUI

struct LingShuDialogueSurface: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway

    var body: some View {
        VStack(spacing: 12) {
            // 聊天列表抽成只订阅 state 的子视图：voice 的电平 @Published 在收音/播放时 ~20Hz 刷新,
            // 若聊天列表随父视图(订阅 voice)一起重渲,markdown 气泡每秒重算 20 次→主线程过载→
            // 滚动条上下抽搐 + TTS 卡顿。隔离后 voice 跳动不再触发聊天列表重渲(SwiftUI 见 state 未变即跳过)。
            LingShuChatScroll(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 运行脉搏条已删(它只是「状态」surface 的冗余入口,顶栏「状态」tab 即可进,留着白占空间)。
            LingShuInputDock(state: state, voice: voice, vision: vision, perceptionGateway: perceptionGateway)
        }
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .sheet(isPresented: $state.isTaskRecordPresented) {
            if state.selectedTaskRecord != nil {
                TaskExecutionRecordSheet(state: state)
            } else {
                Text("任务记录不存在")
                    .frame(width: 520, height: 320)
            }
        }
    }

}

/// 聊天滚动列表——**只订阅 `state`**(不碰 voice/vision),把高频电平刷新与聊天重渲解耦。
/// 自动滚到底:仅在最后一条消息真的变化(id/字数/loading)时才动画滚动,避免与内容增高竞争抽搐。
private struct LingShuChatScroll: View {
    @ObservedObject var state: LingShuState
    @State private var lastChatBottomSignature = ""
    /// 只渲染最近 N 条的**滑动窗口**:VStack 一次性 realize 全部 → 窗口必须有界,否则消息一多就卡。
    /// 既避开 LazyVStack"行没滚进视野不渲染→空白"的坑,又把渲染量压住→滚动顺滑。"加载更早"按需扩窗。
    @State private var windowSize = 40
    private static let windowStep = 40

    /// 当前窗口内的消息(最近 windowSize 条)。
    private var windowed: ArraySlice<ChatMessage> { state.chatMessages.suffix(windowSize) }
    private var hasOlder: Bool { state.chatMessages.count > windowSize || state.hasMoreColdChatHistory }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    if hasOlder {
                        Button {
                            windowSize += Self.windowStep
                            if windowSize >= state.chatMessages.count { state.loadOlderChatHistoryIfNeeded() }
                        } label: {
                            Text("加载更早的对话")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .id("lingshu-chat-top")
                    }

                    ForEach(windowed) { message in
                        ChatBubbleView(message: message, state: state)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("lingshu-chat-bottom")
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
            .defaultScrollAnchor(.bottom)
            .onAppear {
                lastChatBottomSignature = chatBottomSignature(state.chatMessages)
                DispatchQueue.main.async {
                    if let lastID = state.chatMessages.last?.id {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    } else {
                        proxy.scrollTo("lingshu-chat-bottom", anchor: .bottom)
                    }
                }
            }
            .onReceive(state.$chatMessages) { messages in
                let signature = chatBottomSignature(messages)
                guard signature != lastChatBottomSignature else { return }
                lastChatBottomSignature = signature
                // **不加动画**:对正在增长的(思考中/流式)最后一条做动画 scrollTo 会过冲再回弹=用户看到的"抽一下";
                // 直接定位到最后一条真实消息底部,跟随增长平滑、不回弹。
                DispatchQueue.main.async {
                    if let lastID = messages.last?.id {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    } else {
                        proxy.scrollTo("lingshu-chat-bottom", anchor: .bottom)
                    }
                }
            }
            // 思考中:每次执行阶段(missionTitle)变化会让"思考中"气泡变高,但 chatMessages 没变→不会触发上面的
            // 跟随。这里补一刀:最后一条是 loading 时,阶段一变就把它重新顶到底,保证"灵枢思考中"始终可见。
            .onChange(of: state.missionTitle) { _ in
                guard state.chatMessages.last?.isLoading == true, let lastID = state.chatMessages.last?.id else { return }
                DispatchQueue.main.async { proxy.scrollTo(lastID, anchor: .bottom) }
            }
        }
    }

    private func chatBottomSignature(_ messages: [ChatMessage]) -> String {
        guard let message = messages.last else { return "empty" }
        return "\(message.id.uuidString):\(message.text.count):\(message.isLoading)"
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
                    // 待机时不显示副标题：它会压在核心中央的白点上重叠。仅思考/执行/异常时显示已用时。
                    if state.coreState != .standby {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(state.coreStateSubtitle)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(state.coreState.color.opacity(0.75))
                        }
                    }
                    LingShuVoiceWaveView(
                        color: state.coreState.color,
                        isActive: voice.isRecording || voice.isSpeaking
                    )
                }
                // 整体上移，让文字避开核心中央的白色圆心（圆心在 ZStack 几何中心）。
                .offset(y: -14)
            }

            VStack(alignment: .trailing, spacing: 10) {
                LingShuHUDReadout(label: "CHANNEL", value: state.modelProvider, color: state.isModelConnected ? .lingHolo : .orange)
                LingShuHUDReadout(label: "SESSIONS", value: state.remoteSessionStatus)
                LingShuBrainScoreChip(state: state)   // 可点:看具体评分 + 一键检测脑力分
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
    /// 滑动窗口起点:附件多于 pageSize 时,一次只显示 pageSize 个,左右箭头滑动。
    @State private var startIndex = 0
    private let pageSize = 3

    var body: some View {
        let items = state.pendingAttachments
        let total = items.count
        let maxStart = max(0, total - pageSize)
        let start = min(max(0, startIndex), maxStart)   // 删附件后不越界
        let window = total > pageSize ? Array(items[start..<min(start + pageSize, total)]) : items

        HStack(spacing: 8) {
            if total > pageSize {
                pageArrow("chevron.left", enabled: start > 0) { startIndex = max(0, start - 1) }
            }
            ForEach(window) { attachment in chip(attachment) }
            if total > pageSize {
                pageArrow("chevron.right", enabled: start + pageSize < total) { startIndex = min(maxStart, start + 1) }
                Text("\(start + 1)-\(min(start + pageSize, total))/\(total)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
    }

    /// 左右翻页箭头(到头/到尾禁用置灰)。
    private func pageArrow(_ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? Color.lingHolo : .white.opacity(0.2))
                .frame(width: 22, height: 38)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// 单个附件芯片:缩略图 + 文件名 + 解析状态 + 移除。
    private func chip(_ attachment: LingShuAttachment) -> some View {
        HStack(spacing: 8) {
            attachmentThumbnail(attachment)

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

    /// 缩略图预览(对齐 codex/claude):图片显真实缩略图,其它文件显类型图标小图块。
    @ViewBuilder
    private func attachmentThumbnail(_ attachment: LingShuAttachment) -> some View {
        if attachment.kind == .image, let url = attachment.localURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12), lineWidth: 1))
        } else {
            Image(systemName: attachment.kind.icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.lingHolo)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
        }
    }
}

/// **派发队列区**(用户定调):并发满 3 时,多出来的 task 进这里**可见等待**(未进主窗口/未派发),
/// 有空位自动晋级开始;晋级前可在此**删除**。横排芯片 + 删除 X,样式对齐附件托盘。
struct LingShuDispatchQueueTray: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        let items = state.queuedDispatchTasks
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.lingHolo)
                Text("队列区 · \(items.count) 条等待中(任务串行,前一条完成后开始;晋级前可删)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { chip($0) }
                }
            }
        }
    }

    private func chip(_ item: LingShuQueuedDispatchTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.lingHolo.opacity(0.85))
            VStack(alignment: .leading, spacing: 1) {
                Text((item.goal?.isEmpty == false ? item.goal! : item.prompt))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text("排队中")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.lingHolo.opacity(0.7))
            }
            Button { state.removeQueuedDispatchTask(id: item.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 240)
        .lingShuHUDPanel(cornerLength: 6, fillOpacity: 0.05)
    }
}

/// **进行中长条**(用户定调 2026-06-23):任务线串行,同时只一条在跑;长条**自动定位**当前正在执行的派发任务,
/// 让你随时看到"是谁占着槽、堵着队列"。点「定位」打开它的执行窗口看进度;点「停止」终止它(释放槽位让队列晋级,
/// 不影响问答线)。无在跑任务时不显示。
struct LingShuRunningTaskBar: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        if let rec = state.runningDispatchedTask {
            HStack(spacing: 9) {
                LingShuPulseDot()
                Text("进行中")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.lingHolo)
                Text(rec.title.isEmpty ? rec.prompt : rec.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button { state.openTaskRecord(rec.id) } label: {
                    Label("定位", systemImage: "scope").font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.bordered).controlSize(.small)
                Button { state.stopDispatchedTask(recordID: rec.id) } label: {
                    Label("停止", systemImage: "stop.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.85))
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .lingShuHUDPanel(cornerLength: 6, fillOpacity: 0.08)
        }
    }
}

/// 在跑指示的小脉动点。
private struct LingShuPulseDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.lingHolo)
            .frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

struct LingShuInputDock: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 10) {
            LingShuRunningTaskBar(state: state)
            if !state.queuedDispatchTasks.isEmpty {
                LingShuDispatchQueueTray(state: state)
            }
            if !state.pendingAttachments.isEmpty {
                LingShuAttachmentTray(state: state)
            }

            TextField("", text: $state.prompt, axis: .vertical)
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
                // 输入框为空时，中心位置显示提示语；一旦开始输入即隐藏。
                .overlay(alignment: .center) {
                    if state.prompt.isEmpty {
                        Text(state.loc("有什么需要我做的？", "What can I do for you?"))
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.32))
                            .allowsHitTesting(false)
                    }
                }
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
                // 剪贴板粘贴图片（Cmd+V）：抓剪贴板里的图 → 走云视觉解析管线，作为输入的一部分。
                // 仅拦截图片类型，纯文本粘贴仍由输入框默认处理。
                .onPasteCommand(of: [.image, .png, .jpeg, .tiff]) { _ in
                    guard let image = NSImage(pasteboard: .general),
                          let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { return }
                    state.ingestPastedImage(png)
                }
                // 拖拽/粘贴文件到输入框:多行文本框会把拖入的文件落成**路径文本**(原生 NSTextView 抢先处理,
                // SwiftUI 的 dropDestination 盖不住),这里识别"整框就是真实存在的文件路径"并自动转成附件芯片
                // (与 📎 选择、Cmd+V 粘贴同一条解析管线);正文里顺带提到的路径不动。
                .onChange(of: state.prompt) { _, _ in
                    state.convertDroppedFilePathsIfNeeded()
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

                // **声明式调插件(对标 Codex「+」)**:选一个插件,下一条消息**确定性直达它、不经大脑分诊**(根治误调用)。
                Menu {
                    Section("声明式调插件(下一条消息直达,不经大脑判断)") {
                        ForEach(state.invocablePlugins()) { p in
                            Button {
                                state.pinnedPluginInvocation = (state.pinnedPluginInvocation == p.id) ? nil : p.id
                            } label: {
                                Label("\(p.displayName)\(state.pinnedPluginInvocation == p.id ? " ✓" : "") — \(p.subtitle)", systemImage: p.icon)
                            }
                        }
                    }
                    if state.pinnedPluginInvocation != nil {
                        Divider()
                        Button("取消指定(交回大脑判断)", role: .destructive) { state.pinnedPluginInvocation = nil }
                    }
                } label: {
                    Image(systemName: state.pinnedPluginInvocation == nil ? "plus" : "plus.circle.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(state.pinnedPluginInvocation == nil ? .white.opacity(0.86) : Color.lingVoid)
                        .frame(width: 46, height: 42)
                        .background(state.pinnedPluginInvocation == nil ? Color.white.opacity(0.08) : Color.lingHolo, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("声明式调插件:选一个,下一条消息直达它,不经大脑判断(像 Codex 的「+」)")

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

                // 正在播报时出现：一键打断当前 TTS（含分句早读队列）。
                if voice.isSpeaking {
                    Button {
                        voice.stopSpeaking()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 42)
                            .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("中断当前播放")
                    .transition(.opacity)
                }

                Button {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(width: 46, height: 42)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("清空上下文 / 新会话")
                .confirmationDialog("清空当前对话上下文?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                    Button("清空(新会话)", role: .destructive) { state.clearMainContext() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("清掉当前聊天与执行轨迹、重置会话。任务线程与长期记忆保留。")
                }

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
                        Text(state.loc("交给灵枢", "Send to \(state.appName)"))
                    }
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.lingVoid)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .animation(.easeInOut(duration: 0.2), value: voice.isSpeaking)

            HStack(spacing: 12) {
                Text(state.loc("Return 发送", "Return to send"))
                Spacer(minLength: 8)
                if !activeAlerts.isEmpty {
                    LingShuAlertTicker(alerts: activeAlerts)
                    Spacer(minLength: 8)
                }
                Text(state.modelConnectionState)
                    .foregroundStyle(state.isModelConnected ? Color.lingHolo : Color.orange.opacity(0.86))
            }
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.48))
        }
    }

    /// 底部告警栏的数据源：把分散在各处、用户容易忽略的"降级/不可用"状态收集起来集中提示。
    private var activeAlerts: [String] {
        var alerts: [String] = []
        if state.voiceOutputEnabled {
            // 优先用持久降级标记（云端男声失败后常驻，不随单句播完而消失）；
            // 没有标记时再看实时输出状态里的降级关键词。
            if let degraded = voice.cloudVoiceDegradedReason {
                alerts.append("情绪 TTS：\(degraded)")
            } else {
                let tts = voice.outputStatusMessage
                if ["不可用", "失败", "缺凭据", "降级", "未配置", "未就绪", "兜底"].contains(where: tts.contains) {
                    alerts.append("情绪 TTS：\(tts)")
                }
            }
        }
        let perception = perceptionGateway.statusText
        if ["中断", "降级", "异常", "不可用", "失败"].contains(where: perception.contains) {
            alerts.append("云感知：\(perception)")
        }
        return alerts
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

/// 底部告警条：单条直接显示；多条每 3 秒滚动一条，右侧带数量徽标；
/// 点击展开弹窗一次性看全部告警。
struct LingShuAlertTicker: View {
    let alerts: [String]
    @State private var showAll = false

    var body: some View {
        Button { showAll = true } label: {
            TimelineView(.periodic(from: .now, by: 3)) { context in
                let index = alerts.isEmpty
                    ? 0
                    : Int(context.date.timeIntervalSinceReferenceDate / 3) % alerts.count
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(alerts.isEmpty ? "" : alerts[index])
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.orange.opacity(0.92))
                    if alerts.count > 1 {
                        Text("\(alerts.count)")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.lingVoid)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
                    }
                }
                .frame(maxWidth: 320, alignment: .trailing)
            }
        }
        .buttonStyle(.plain)
        .help("点击查看全部告警")
        .popover(isPresented: $showAll, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("当前告警（\(alerts.count)）")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.orange)
                ForEach(Array(alerts.enumerated()), id: \.offset) { _, alert in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text(alert)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(width: 360, alignment: .leading)
            .background(Color.lingVoid)
        }
    }
}
