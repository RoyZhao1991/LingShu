import SwiftUI

struct LingShuRootView: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway
    @State private var lastVisionTraceAt = Date.distantPast
    private let coreTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// 在岗/自主运行时的麦克风语音通话控制器(复用极简模式那套:听→ASR→思考→回应)。
    @StateObject private var standingVoiceCall = LingShuVoiceCallController()
    /// 自主模式「只剩本体」终态:进入仪式(融化→离子化)播完后置真,界面整个让位给右上角的悬浮本体。
    @State private var autonomousOrbMode = false
    /// 演示窗是否处于"全屏(撑满)"态——供手动接管安全闸判定(演示在独立窗口里,本体浮窗始终在位,不再让位)。
    @State private var previewSlideshow = false
    /// 全屏演示中检测到手动操作 → 弹"是否退出自主"确认框(并已先退全屏恢复屏幕)。
    @State private var manualTakeover = false
    private var orbActive: Bool { state.isStandingPersonOnDuty && autonomousOrbMode }

    var body: some View {
        Group {
            if orbActive {
                // 终态:界面消失,只剩半透明悬浮本体(右键暂停/继续、解除自主模式)。窗口由 controller 收缩成小浮窗。
                LingShuAutonomousOrbOnlyView(state: state, voice: voice, vision: vision, perceptionGateway: perceptionGateway)
            } else if state.isMinimalVoiceMode {
                LingShuMinimalVoiceView(
                    state: state,
                    voice: voice,
                    vision: vision,
                    perceptionGateway: perceptionGateway
                )
                .frame(minWidth: 320, minHeight: 480)
            } else {
                standardLayout
                    .frame(minWidth: 1240, minHeight: 820)
            }
        }
        // 进入仪式只在「上岗→终态之前」的过渡期覆盖(界面融化→离子化凝成本体);终态(只剩本体)不再覆盖。
        .overlay { if state.isStandingPersonOnDuty && !autonomousOrbMode { LingShuAutonomousIntroOverlay(state: state) } }
        .background(LingShuAutonomousWindowController(active: orbActive))
        .onReceive(state.previewController.$slideshow) { previewSlideshow = $0 }
        // **手动接管安全闸**:只要演示窗在全屏(撑满)——无论自主运行还是普通派发任务——一旦检测到你的键鼠/移动/滚动
        // → 立刻退全屏恢复屏幕 + 弹框问是否停止。演示期间灵枢不产生键鼠事件(翻页走内部),故此时任何输入=你在夺回控制,判定可靠。
        .background(LingShuManualTakeoverMonitor(
            active: previewSlideshow && !manualTakeover
        ) { manualTakeover = true })
        .onChange(of: manualTakeover) { _, on in
            if on {
                _ = state.previewController.setSlideshow(false)        // 先立刻退全屏,把屏幕还给用户
                state.pauseActiveFlow(reason: "全屏演示中检测到手动操作(动鼠标/键盘)")  // 真停:批量+TTS 立即暂停(不只退全屏,不再后台偷偷推进)
            }
        }
        .confirmationDialog("检测到你在手动操作", isPresented: $manualTakeover, titleVisibility: .visible) {
            Button("停止,回到正常界面", role: .destructive) {
                state.abortActiveFlow(reason: "演示中手动接管→选择停止")
                if state.isStandingPersonOnDuty { state.stopAutonomousRun() }
            }
            Button("继续演示", role: .cancel) {
                _ = state.previewController.setSlideshow(true)         // 重进全屏
                _ = state.submitVoiceTranscript("从当前这一页继续演示,接着往下讲")   // 让大脑从当前页续讲
            }
        } message: {
            Text("已暂停并退出全屏。停止本任务,还是从当前页继续演示?")
        }
        .onAppear {
            // 关任一演示窗 = 硬中断流程(防大脑下一步又把窗弹回来)。幂等设置,多次 onAppear 无碍。
            state.previewController.onUserClosedWindow = { [weak state] in
                state?.abortActiveFlow(reason: "用户手动关闭了演示窗")
            }
        }
        // 注:进入「托管模式」确认改用 AppKit NSAlert(见 LingShuState.requestManagedMode)——
        // 它会把灵枢拉到前台、app-modal 一定可见,根治 SwiftUI confirmationDialog 在灵枢非前台时不弹的问题。
        .onChange(of: state.isStandingPersonOnDuty) { _, onDuty in
            if onDuty {
                if state.enteringViaManagedHandoff {
                    // 托管模式转入(演示/互动中途):本体**立即**出现,不放入场仪式——否则开场那 2.5s 没本体,看着像"本体消失了"。
                    state.enteringViaManagedHandoff = false
                    withAnimation(.easeInOut(duration: 0.3)) { autonomousOrbMode = true }
                } else {
                    autonomousOrbMode = false
                    // 手动上岗:仪式播完(~2.5s)再切终态(此刻屏幕还被暗幕盖着,窗口收缩不露馅)。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        if state.isStandingPersonOnDuty { withAnimation(.easeInOut(duration: 0.35)) { autonomousOrbMode = true } }
                    }
                }
            } else {
                withAnimation(.easeInOut(duration: 0.3)) { autonomousOrbMode = false }
            }
        }
        .preferredColorScheme(.dark)
        .background(LingShuPreviewHost(controller: state.previewController))   // 大脑 open_preview → 弹出预览
        .background(LingShuBrowserHost(controller: state.browserController))   // 大脑 browser_open → 弹出内置浏览器
        .sheet(item: $state.pendingShellApproval) { pending in
            LingShuPermissionApprovalView(pending: pending) { decision in
                state.resolveShellApproval(decision)
            }
        }
        .sheet(item: $state.brainBenchmarkResult) { result in   // 脑力测试跑完 → 弹窗显示综合分(在哪个界面都弹)
            LingShuBrainBenchmarkResultView(result: result, history: state.brainBenchmarkHistory) { state.brainBenchmarkResult = nil }
                .frame(minWidth: 560, minHeight: 480)
        }
        .onChange(of: state.isMinimalVoiceMode) { _, minimal in
            LingShuWindowPlacement.applyMinimalVoiceWindow(minimal)
            // 极简模式有自己的通话控制器:进极简就停在岗收听(避免双麦),退出极简且仍在岗则恢复。
            if minimal {
                standingVoiceCall.stop()
            } else if state.isStandingPersonOnDuty {
                state.startStandingVoiceListening?()
            }
        }
        .onAppear {
            state.refreshCodexAuthStatusIfNeeded()
            state.livePerceptionContextProvider = { [weak perceptionGateway] in
                guard let perceptionGateway, perceptionGateway.hasLiveSignals else { return "" }
                return perceptionGateway.promptContext
            }
            // 对话发生时按需刷新云端场景理解（"台下有很多人"这类情境必须是当下的）。
            state.perceptionSceneRefreshTrigger = { [weak perceptionGateway] in
                perceptionGateway?.refreshSceneUnderstandingIfStale()
            }
            // 分句早读：语音输出开启时，流式回复每攒满一句立即排队播报，
            // 不必等整段回复生成完才开口。
            state.streamingSentenceSpeaker = { [weak state, weak voice, weak perceptionGateway] sentence in
                guard let state, let voice,
                      state.voiceOutputEnabled || state.isMinimalVoiceMode else { return }
                voice.speakStreamingSentence(sentence)   // 增量无缝流式发声(并行预取+背靠背播)
                perceptionGateway?.ingestSpeechOutput(sentence)
            }
            // 新一轮开始时掐掉上一条朗读(防音频/文字 desync)。
            state.interruptSpeechOutput = { [weak voice] in voice?.stopSpeaking() }
            state.voiceManager = voice   // 供会议对话控制器经 MCP/UI 驱动
            // 在岗/自主运行时同步开/关麦克风收听(听→ASR→思考→回应,和极简模式一致)。
            // 由 begin/endAutonomousActivity 调,故与运行/暂停/停止生命周期严格对齐(不靠视图重渲时机)。
            let standingCall = standingVoiceCall   // 捕获控制器实例(类引用)
            state.startStandingVoiceListening = { [weak state, weak voice, weak perceptionGateway] in
                guard let state, let voice, let perceptionGateway, !state.isMinimalVoiceMode else { return }
                state.voiceOutputEnabled = true   // 语音对话:必须能出声回应
                standingCall.start(state: state, voice: voice, perceptionGateway: perceptionGateway)
            }
            state.stopStandingVoiceListening = { standingCall.stop() }
            // 把持久化的「本地模式」偏好应用到 voiceManager(didSet 不会为初始值触发,启动时手动应用一次)。
            state.applyASRLocalMode()
            state.applyTTSLocalMode()
            // P4:把扩展面板的启停同步进专家注册表(停用的 skill 启动即不参与匹配)。
            state.syncExtensionEnablement()
            // 外接设备感知:注入模型驱动蒸馏器 + 恢复上次开关偏好(默认关)。
            state.wireExternalSensory()
            // 系统通知中枢:设代理(前台也弹横幅)+ 查授权状态(配置页可主动授予)。
            LingShuNotificationCenter.shared.bootstrap()
            // 感知链:注入"活感官"采样器(只在传感器真在跑时投,避免陈旧态被当成实时),并起高频采样。
            state.liveSenseSampler = { [weak voice, weak vision, weak perceptionGateway] in
                var samples: [LingShuPerceptionSample] = []
                guard let perceptionGateway else { return samples }
                let snap = perceptionGateway.latestSnapshot
                if vision?.isCameraRunning == true, !snap.visualSummary.isEmpty {
                    samples.append(.init(channel: .vision, text: snap.visualSummary))
                }
                if voice?.isRecording == true, !snap.audioSummary.isEmpty {
                    samples.append(.init(channel: .hearing, text: snap.audioSummary))
                }
                return samples
            }
            state.startPerceptionChain()

            perceptionGateway.registerCloudPerceptionRoute(client: state.cloudPerceptionClient)
            [0.1, 0.8, 1.6].forEach { delay in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    LingShuWindowPlacement.bringWindowsToMainScreen()
                }
            }
        }
        .onChange(of: state.apiKey) { _, _ in
            perceptionGateway.registerCloudPerceptionRoute(client: state.cloudPerceptionClient)
        }
        .onChange(of: state.modelProvider) { _, _ in
            perceptionGateway.registerCloudPerceptionRoute(client: state.cloudPerceptionClient)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            state.flushChatHistory()
            state.taskExecutionJournal.flush()
        }
        .onReceive(coreTimer) { _ in
            state.tickCoreTimers()
            // 执行音统一调度(前台 coreTimer 这条路;在岗/自主时 coreTimer 被系统暂停,那边由自主感知 1s 自驱 Task 驱动)。
            // 卡授权界面→急促高音催授权;否则处理中且不朗读→忙音。二者互斥不并发,见 executionAudioTick。
            state.executionAudioTick(isSpeaking: voice.isSpeakingOrQueued)
        }
        .onChange(of: voice.isSpeaking) { _, speaking in
            if speaking { LingShuCueSound.busyStop() }   // 一开口朗读立刻停忙音(不等下一拍驱动)
        }
        .onReceive(vision.$latestObservation) { observation in
            if let observation {
                perceptionGateway.ingestVisionObservation(observation)
            }
            traceVisionObservationIfNeeded(observation)
        }
        .onReceive(vision.$latestFramePacket) { packet in
            if let packet {
                perceptionGateway.ingestVideoFrame(packet)
            }
        }
        .onReceive(state.$chatMessages) { messages in
            speakLatestReplyIfNeeded(messages)
        }
    }

    /// 灵枢新回复就播报。集中在根视图，确保普通界面和极简语音模式都会发声。
    private func speakLatestReplyIfNeeded(_ messages: [ChatMessage]) {
        let shouldSpeak = state.voiceOutputEnabled || state.isMinimalVoiceMode
        // 只看**最后一条**消息:它还在加载(本轮流式中)或是用户消息就不念,等它定稿。
        // 旧逻辑 last(where:!isLoading) 会在本轮气泡 loading 时落到**上一轮**回复、把它再念一遍,
        // 还覆盖 lastSpokenMessageID 去重标记 → 本轮 finalize 设的去重失效 → 又被整段 speak()(→ 某段超时降级)。
        guard shouldSpeak,
              let message = messages.last, !message.isUser, !message.isLoading,
              message.id != state.lastSpokenMessageID else {
            return
        }

        state.lastSpokenMessageID = message.id
        lingShuControlLog("TTS来源②: 自动朗读回复气泡 id=\(message.id.uuidString.prefix(8)) 文本「\(String(message.text.prefix(40)))」")
        // 任务型交付只念简短摘要(避免整段念路径/英文/代码);对话/汇报型念全文。决策需模型,异步。
        Task { @MainActor in
            let toSpeak = await state.spokenReplyText(for: message)
            voice.speak(toSpeak)
        }
        perceptionGateway.ingestSpeechOutput(message.text)   // 感知/记忆仍用全文
    }

    private var standardLayout: some View {
        VStack(spacing: 0) {
            LingShuStableTopBar(
                state: state,
                voice: voice,
                vision: vision,
                perceptionGateway: perceptionGateway
            )

            Group {
                switch state.selectedSurface {
                case .chat:
                    LingShuDialogueSurface(
                        state: state,
                        voice: voice,
                        vision: vision,
                        perceptionGateway: perceptionGateway
                    )
                case .taskPool:
                    LingShuTaskPoolView(state: state)
                case .runtime:
                    LingShuRuntimeSurface(state: state, voice: voice)
                case .operations:
                    LingShuOperationsSurface(state: state)
                case .settings:
                    LingShuSettingsHub(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LingShuStableBackground(accent: state.coreState.color))
    }

    private func traceVisionObservationIfNeeded(_ observation: LingShuVisionObservation?) {
        guard let observation, vision.isCameraRunning else { return }
        guard Date().timeIntervalSince(lastVisionTraceAt) >= 6 else { return }

        lastVisionTraceAt = Date()
        state.appendTrace(
            kind: .system,
            actor: "视觉",
            title: "实时观测",
            detail: observation.summary
        )
    }
}

/// 手动接管监听:active 时挂键鼠监听(本 app 内 local + 其他 app global),任一键鼠按下即回调。
/// 仅在「自主运行 + 全屏演示」时启用,此时灵枢自身不产生键鼠事件,故任何输入=用户夺回控制。
private struct LingShuManualTakeoverMonitor: NSViewRepresentable {
    let active: Bool
    let onManualInput: () -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let c = context.coordinator
        c.onInput = onManualInput
        if active, c.local == nil {
            // 键盘、点击、**移动鼠标**、拖拽、滚动都算"你在夺回控制"——演示期间灵枢不产生这些事件(翻页走内部)。
            let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                               .mouseMoved, .leftMouseDragged, .scrollWheel]
            // 为了 .mouseMoved 在自家窗口上也能被本地监听捕获,打开所有窗口的"接收鼠标移动"。
            NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
            c.armedAt = Date()
            c.local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
                c.fireIfArmed(); return event
            }
            c.global = NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in
                c.fireIfArmed()
            }
        } else if !active {
            c.teardown()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var local: Any?
        var global: Any?
        var onInput: (() -> Void)?
        var armedAt: Date?
        /// 武装后 0.8s 内的事件忽略(避免演示刚开屏瞬间光标残留移动误触发);之后任何输入即判定夺回控制。
        func fireIfArmed() {
            guard let armedAt, Date().timeIntervalSince(armedAt) > 0.8 else { return }
            onInput?()
        }
        func teardown() {
            if let local { NSEvent.removeMonitor(local) }
            if let global { NSEvent.removeMonitor(global) }
            local = nil; global = nil; armedAt = nil
        }
        deinit { teardown() }
    }
}

struct LingShuStableBackground: View {
    var accent: Color = .lingHolo

    var body: some View {
        LingShuHUDBackground(accent: accent)
    }
}

struct LingShuStableTopBar: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway
    @State private var headerWidth: CGFloat = 1400

    var body: some View {
        // 顶栏随窗口宽度自适应：空间不足时先隐藏状态类文字，再紧到只剩导航图标——
        // 不再被压缩换行。
        let dense = headerWidth < 1300      // 隐藏感知值 / STATE·AUTO·TRUST / 副标题
        let compact = headerWidth < 1080    // 进一步：导航也只剩图标
        let digitalHuman = state.digitalHumanSnapshot(voice: voice, vision: vision, perceptionGateway: perceptionGateway)
        HStack(spacing: 16) {
            HStack(spacing: 11) {
                LingShuDigitalHumanMiniOrb(snapshot: digitalHuman, audioLevel: Double(voice.outputLevel))
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.appName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    if !dense {
                        Text("NOUS · GENERAL AGENT HUB")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .tracking(1.8)
                            .foregroundStyle(Color.lingHolo.opacity(0.6))
                            .lineLimit(1)
                    }
                }
            }

            LingShuTopPerceptionStrip(
                state: state,
                voice: voice,
                vision: vision,
                perceptionGateway: perceptionGateway,
                compact: dense
            )

            Spacer()

            HStack(spacing: 2) {
                ForEach(AppSurface.allCases) { surface in
                    let isSelected = state.selectedSurface == surface
                    Button {
                        state.selectedSurface = surface
                    } label: {
                        VStack(spacing: 5) {
                            Group {
                                if compact {
                                    Image(systemName: surface.icon)
                                } else {
                                    Label(state.loc(surface.rawValue, surface.englishName), systemImage: surface.icon)
                                }
                            }
                            .font(.system(size: compact ? 15 : 12.5, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)   // 标签(如"线程")不换行:按自然宽度排,别被宽图标挤成两行
                            .foregroundStyle(isSelected ? Color.lingHolo : .white.opacity(0.6))
                            Rectangle()
                                .fill(isSelected ? Color.lingHolo : .clear)
                                .frame(height: 2)
                                .shadow(color: isSelected ? Color.lingHolo.opacity(0.8) : .clear, radius: 4)
                        }
                        .padding(.horizontal, 13)
                        .padding(.top, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(surface.rawValue)
                }
            }

            // STATE/AUTO/脑力 是运行状态，始终显示（不随窗口变窄隐藏）。
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                LingShuHUDReadout(label: "STATE", value: state.coreStateDisplay, color: state.coreState.color)
            }
            LingShuHUDReadout(label: "AUTO", value: state.autonomousRunDisplayStatus, color: state.autonomousRun.isActive ? .orange : .lingFaint)
            LingShuBrainScoreChip(state: state)   // 可点:看具体评分 + 一键检测脑力分

            Button {
                // 右上角闪电=一键进/出自主模式(化身右上角悬浮本体)。在岗→退出夺回;否则→直接上岗(常驻灵枢,无需目标)。
                // 旧逻辑调 prepareAutonomousRun(需目标)→点了只会"缺少目标·空目标已拒绝启动",根本进不去自主模式。
                if state.isStandingPersonOnDuty {
                    state.stopAutonomousRun()
                } else {
                    state.goLiveAsStandingPerson()
                }
            } label: {
                Image(systemName: state.autonomousRun.isActive ? "bolt.circle.fill" : "bolt.circle")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(state.autonomousRun.isActive ? Color.lingVoid : Color.lingHolo)
                    .frame(width: 34, height: 30)
                    .background(state.autonomousRun.isActive ? Color.orange : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay { LingShuHUDCorners(accent: state.autonomousRun.isActive ? .orange : .lingHolo, cornerLength: 7) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.isStandingPersonOnDuty ? "退出自主模式" : "进入自主模式（灵枢上岗，化身右上角悬浮本体）")

        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.6))
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, newWidth in
                    headerWidth = newWidth
                }
            }
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, Color.lingHolo.opacity(0.55), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
    }
}

struct LingShuCompactStatus: View {
    let title: String
    let value: String
    var color: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color.opacity(0.92))
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
