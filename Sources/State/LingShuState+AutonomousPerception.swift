import Foundation

/// 周期感知循环（模块 2）的接线层：常驻灵枢在岗（完全接管）时，
/// 定时**廉价感知**屏幕 + 系统声音 → 有变化才花 VL 理解态势 → 维护一份滚动 digest，
/// 并在「武装自主反应」时由显著事件唤醒大脑动手。
///
/// 设计取向（坑：VL 单次 1–3s，成本/延迟敏感，不能每拍都跑）：
/// - **廉价闸门优先**：先用前台上下文签名（app + 焦点窗口标题，`LingShuComputerControl.frontmostContextSignature`）
///   判「屏幕变没变」，没变就不花 VL；纯逻辑节流由 `LingShuPerceptionCadencePlanner` 决策（可单测）。
/// - **成本天花板**：两次 VL 有硬下限间隔；无显著变化时靠强制刷新兜底（抓同窗口内容变化）。
/// - **大脑在跑回合时让位**：它自己会按需 `screen_capture`，周期循环不重复花 VL、不打断、不抢着唤醒。
/// - **唤醒是 opt-in**：默认只保持 digest 新鲜（喂进下一条指令的上下文），不擅自行动；
///   只有用户「武装」(`autonomousAutoReactArmed`) 后，环境事件（如系统声音突然出现）才会唤醒大脑自主判断。
@MainActor
extension LingShuState {

    /// 常驻灵枢在岗且**运行中**（完全接管态）。
    var isStandingPersonActive: Bool {
        isStandingPersonOnDuty && autonomousRun.phase == .running
    }

    /// 周期感知 = 两段式，由专用驱动 Task 串起来(见 beginAutonomousActivity)：
    /// ① `perceptionHeartbeatOnMain`(主线程,**廉价**:守门 + 采音频 + 判到点)；
    /// ② 到点才在**后台**算 AX 焦点窗口签名(慢)；③ `perceptionApplySignal`(主线程,轻量决策+启 VL)。
    /// **关键:绝不在主线程每拍跑 AX/截屏**——那会饿死同在主线程的 TTS 喂 PCM 任务 → 在岗时音频卡顿(实测根因)。
    ///
    /// 主线程廉价心跳:守门 + 采音频电平(读 Float)+ 锁存起音 + 判是否到点。
    /// 返回非 nil(前台 app token)= 到点了,交给驱动去后台算签名;返回 nil = 本拍到此为止(未在岗/未授权/未到点)。
    func perceptionHeartbeatOnMain() -> (pid: pid_t, label: String)? {
        perceptionTickSeq &+= 1
        guard isStandingPersonActive else {
            perceptionDebugLine = "seq=\(perceptionTickSeq) idle onDuty=\(isStandingPersonOnDuty) phase=\(autonomousRun.phase.rawValue)"
            idleAutonomousPerception()
            return nil
        }
        guard computerControlAuthorized else {
            perceptionDebugLine = "gate=未授权计算机操作"
            return nil
        }
        startAutonomousPerceptionAudioIfNeeded()
        // 每拍采一次音频电平(廉价 Float 读)+ 锁存起音,不受 tick 节流影响、不丢起音。
        if let s = currentSystemAudioActivity() {
            perceptionLatestAudioState = s
            if s == .onset { perceptionAudioOnsetLatched = true }
        }
        // **灵枢正在说话(TTS):暂停一切感知重活(截屏子进程 + 全屏图缩放 + VL + AX)**——
        // 这些 CPU/IO 突发会抢占实时音频渲染线程 → 播放"一字一字"卡顿(实测在岗卡顿真因)。说完即恢复。
        if voiceManager?.isSpeakingOrQueued == true {
            perceptionDebugLine = "seq=\(perceptionTickSeq) 让位TTS(说话中暂停感知)"
            return nil
        }
        // 廉价 due 判定(纯时间,不碰 AX)。没到点本拍主线程零重活,直接结束。
        guard Date().timeIntervalSince(lastPerceptionTickAt) >= perceptionCadenceConfig.tickInterval - 0.001 else {
            return nil
        }
        return LingShuComputerControl.frontmostAppToken()   // 到点:前台 token 交驱动去**后台**算 AX 签名
    }

    /// 拿到(后台算好的)前台签名后,在主线程跑节流决策 + 启 VL/唤醒。AX 已在后台算完,这里只是轻量状态更新。
    func perceptionApplySignal(signature: String) {
        guard isStandingPersonActive, computerControlAuthorized else { return }
        let now = Date()
        let screenChanged = signature != lastScreenSignature
        let audioForPlanner: LingShuAudioActivityState? =
            perceptionAudioOnsetLatched ? .onset : perceptionLatestAudioState

        // 会议检测(反射):据前台 app/窗口标题/声音活动判断进入/离开会议,起停会议纪要累积。
        updateMeetingDetection(
            windowSignature: signature,
            audioActive: audioForPlanner == .onset || audioForPlanner == .active,
            now: now
        )

        let decision = LingShuPerceptionCadencePlanner.decide(.init(
            now: now,
            lastTickAt: lastPerceptionTickAt,
            lastVLAt: lastPerceptionVLAt,
            lastWakeAt: lastPerceptionWakeAt,
            screenChanged: screenChanged,
            audio: audioForPlanner,
            agentBusy: autonomousRunTask != nil || hasActiveModelCall,
            autoReactArmed: autonomousAutoReactArmed
        ), config: perceptionCadenceConfig)

        perceptionDebugLine = "seq=\(perceptionTickSeq) due=\(decision.due) vl=\(decision.captureVL) task=\(autonomousRunTask != nil) changed=\(screenChanged) vlTask=\(perceptionVLTask != nil)"
        guard decision.due else { return }
        lastPerceptionTickAt = now
        perceptionAudioOnsetLatched = false   // 本拍已消费起音锁存

        if decision.captureVL {
            lastPerceptionVLAt = now
            lastScreenSignature = signature   // 真去理解了才把签名当作"已看过"
            capturePerceptionSituation(audio: audioForPlanner)
        }
        if decision.wakeAgent, let reason = decision.wakeReason {
            lastPerceptionWakeAt = now
            wakeStandingPersonWithPerception(reason: reason)
        }
    }

    /// 抑制 App Nap + 启动专用感知驱动:灵枢操作别的 app 时自己必在后台,
    /// 若靠 UI 的 Timer.publish(窗口遮挡/后台会被暂停),周期感知就停了。
    /// 进入运行/在岗态时调用(幂等):① beginActivity 抑制 App Nap;② 起一个用 Task.sleep 自驱的感知 Task。
    func beginAutonomousActivity() {
        if autonomousActivityToken == nil {
            autonomousActivityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "灵枢自主运行/在岗:需持续感知屏幕+系统声音并推进,避免后台 App Nap 暂停心跳。"
            )
        }
        // 上岗只开**麦克风收听(Apple SFSpeech,已验证可用)**。
        // 不切麦克风引擎、不起系统声音 ASR——这两样都曾把麦克风搞哑:① 两个 SFSpeech 并发互相饿死;
        // ② 切到 SenseVoice 后麦克风没跑通(实测 13:11 上岗后说话不回复)。系统声音转写(会议纪要)
        // 需要"两路 ASR 真并发"的能力,尚未验证跑通,**暂不自动开**,绝不再因此弄哑麦克风。
        voiceOutputEnabled = true   // 自主模式语音播报必须自动打开(否则只有文字、没有"回应中"语音)
        startStandingVoiceListening?()
        guard autonomousPerceptionDriverTask == nil else { return }
        // 驱动 Task **不是 @MainActor**:主线程只做廉价心跳,AX 焦点窗口签名(慢)在后台算,绝不卡主线程音频。
        autonomousPerceptionDriverTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // 定时触发器也搭这趟**后台安全**的车:在岗/自主时 UI 的 coreTimer(Timer.publish)会被系统暂停(与周期感知同因),
                // 单靠它定时任务到点不触发。这里每拍(1s)在主线程廉价检查一次到点触发器(配合 fireDueTriggers 的追赶窗口,健壮)。
                await MainActor.run {
                    self.fireScheduledTriggersIfDue(now: Date())
                    // 执行音统一调度也搭这趟**后台安全**车(UI coreTimer 在岗/自主被系统暂停,靠不住):
                    // 卡授权界面→急促高音催授权;否则处理中→忙音。二者互斥不并发,见 executionAudioTick。
                    self.executionAudioTick(isSpeaking: self.voiceManager?.isSpeakingOrQueued == true)
                    // 待机主动汇报:互动结束、空闲下来后,把攒着的后台子任务完成情况主动出声报给主人(也搭这趟后台安全车)。
                    self.deliverPendingReportsIfIdle()
                }
                let token = await self.perceptionHeartbeatOnMain()   // 主线程廉价:守门+采音频+判到点
                if let token {
                    // 到点了:AX 签名在**后台线程**算(慢,可能阻塞数十 ms,绝不放主线程)
                    let signature = LingShuComputerControl.windowTitleSignature(pid: token.pid, label: token.label)
                    await self.perceptionApplySignal(signature: signature)   // 主线程轻量:决策+启 VL
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)   // 1s 自驱(内部再按 tickInterval 节流)
            }
        }
    }

    /// **执行音统一调度(前台 coreTimer + 后台自驱都走它)**:用户定调——
    /// ① **卡在授权界面**(系统授权门弹窗 `pendingShellApproval` 在等你点)→ 急促、声调高的**断音**催授权;
    /// ② 否则**处理中且不在朗读** → 柔和低**忙音**「嘟」。
    /// **二者互斥、绝不并发**:授权态先 `busyStop()` 再走授权告警,离开授权态先 `authNeededStop()` 复位再判忙音。
    func executionAudioTick(isSpeaking: Bool) {
        let processing = autonomousRunTask != nil || hasActiveModelCall || loopPhase.isActive
        switch LingShuCueSound.executionAudioDecision(stuckAtAuth: pendingShellApproval != nil, processing: processing, isSpeaking: isSpeaking) {
        case .authAlert:
            LingShuCueSound.busyStop()          // 隔离:授权态先停执行忙音,绝不并发
            LingShuCueSound.authNeededTick()    // 急促高音断音催授权
        case .busy:
            LingShuCueSound.authNeededStop()    // 离开授权态:复位需授权告警
            LingShuCueSound.busyTick()
        case .silent:
            LingShuCueSound.authNeededStop()
            LingShuCueSound.busyStop()
        }
    }

    /// 释放 App Nap 抑制 + 停专用感知驱动 + 停麦克风收听(暂停/停止/目标驱动收尾时)。
    func endAutonomousActivity() {
        autonomousPerceptionDriverTask?.cancel()
        autonomousPerceptionDriverTask = nil
        stopStandingVoiceListening?()   // 离开运行/在岗态:停麦克风收听
        stopStandingAmbientListening()  // 停「听系统声音」
        // 还原麦克风识别引擎(上岗时若为腾 SFSpeech 切到过 SenseVoice)。
        if let prev = standingPrevMicProvider {
            voiceManager?.transcriptionProvider = prev
            standingPrevMicProvider = nil
        }
        if let token = autonomousActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            autonomousActivityToken = nil
        }
    }

    /// 在岗收尾时彻底收住感知(停 VL/音频 + 清 digest 与节流时戳)。由 stopAutonomousRun 调。
    func teardownAutonomousPerception() {
        idleAutonomousPerception()
        perceptionDigest = ""
        lastScreenSignature = ""
        perceptionLatestAudioState = nil
        perceptionAudioOnsetLatched = false
        lastPerceptionTickAt = .distantPast
        lastPerceptionVLAt = .distantPast
        lastPerceptionWakeAt = .distantPast
    }

    // MARK: - 私有

    /// 暂停/离岗时收住:停在飞 VL + 关自己启的音频采集(保留 digest 供恢复时显示)。
    private func idleAutonomousPerception() {
        perceptionVLTask?.cancel()
        perceptionVLTask = nil
        stopAutonomousPerceptionAudioIfNeeded()
    }

    /// 读系统音频活动态(只在已有采集流时;音频采集是 opt-in,见 startAutonomousPerceptionAudioIfNeeded)。
    private func currentSystemAudioActivity() -> LingShuAudioActivityState? {
        let cap = LingShuSystemAudioCapture.shared
        guard cap.isCapturing else { return nil }
        return perceptionAudioDetector.ingest(level: cap.lastLevel)
    }

    /// 仅当「武装自主反应」时才为感知启动系统音频采集(否则不必要的 SCStream + 权限弹框 + 功耗都省了)。
    /// 会议已在采集 → 复用它的电平,不重复启;不归本对象所有,不会去停它。
    private func startAutonomousPerceptionAudioIfNeeded() {
        guard autonomousAutoReactArmed, !perceptionOwnsAudioCapture else { return }
        let cap = LingShuSystemAudioCapture.shared
        guard !cap.isCapturing, !meetingConversation.isActive else { return }
        perceptionOwnsAudioCapture = true
        Task { try? await LingShuSystemAudioCapture.shared.start() }
    }

    /// 只停**本对象启的**采集;会议此刻在用、或在岗「听系统声音」仍要用,就不动(避免误关别人的听)。
    private func stopAutonomousPerceptionAudioIfNeeded() {
        guard perceptionOwnsAudioCapture else { return }
        perceptionOwnsAudioCapture = false
        guard !meetingConversation.isActive, !standingAmbientASRActive else { return }
        Task { await LingShuSystemAudioCapture.shared.stop() }
    }

    /// 在岗「听系统声音」:系统音频 → 会议 ASR → 滚动转写(供感知链 ambient 通道采样)。
    /// **纯听不应答**(不走会议的虚拟麦应答闭环)。会议模式已在听就不重复。上岗自动调,幂等。
    func startStandingAmbientListening() {
        guard !standingAmbientASRActive else { return }
        guard !meetingConversation.isActive else { return }   // 会议模式自己在听+应答,别重复
        standingAmbientASRActive = true
        LingShuMeetingASR.shared.start()
        let cap = LingShuSystemAudioCapture.shared
        cap.onPCMChunk = { samples, sampleRate in
            LingShuMeetingASR.shared.appendPCM(samples, sampleRate: sampleRate)
        }
        if !cap.isCapturing {
            Task { try? await cap.start() }
        }
        appendTrace(kind: .runtime, actor: "在岗", title: "听系统声音", detail: "系统音频→ASR 已起,转写进感知链(系统声音通道)")
    }

    /// 停在岗「听系统声音」;采集若没别人(会议/感知活动)还要用,才真停。
    func stopStandingAmbientListening() {
        guard standingAmbientASRActive else { return }
        standingAmbientASRActive = false
        LingShuMeetingASR.shared.stop()
        let cap = LingShuSystemAudioCapture.shared
        cap.onPCMChunk = nil
        guard !meetingConversation.isActive, !perceptionOwnsAudioCapture else { return }
        Task { await cap.stop() }
    }

    /// 花一次 VL 理解当前屏幕 → 更新 digest。关键帧用完即删(零留存)。并发保护:上次 VL 没回来不叠加。
    /// 截屏(screencapture 子进程,会阻塞)放后台线程,主线程只 await,不卡 UI。
    private func capturePerceptionSituation(audio: LingShuAudioActivityState?) {
        guard perceptionVLTask == nil else { return }
        let client = cloudPerceptionClient
        perceptionVLTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.perceptionVLTask = nil }
            // 截屏 + 缩放转 JPEG + base64 在后台线程做(关键帧用完即删,零留存)。
            // 必须缩放:全屏 Retina PNG ~4MB 会让 VL 网关上游 500;~1280 长边 JPEG <300KB 又稳又快。
            let b64 = await Task.detached(priority: .utility) { () -> String? in
                guard let path = LingShuComputerControl.captureScreen() else { return nil }
                defer { try? FileManager.default.removeItem(atPath: path) }
                return LingShuComputerControl.downscaledJPEGBase64(pngPath: path)
            }.value
            guard !Task.isCancelled else { return }
            guard let b64 else {
                self.appendTrace(kind: .warning, actor: "感知", title: "截屏失败", detail: "screencapture 没拿到图(可能缺屏幕录制授权)。")
                return
            }
            guard let client else {
                self.appendTrace(kind: .warning, actor: "感知", title: "VL 通道未配置", detail: "已截屏但数据网关 VL token 未配置,无法理解屏幕。先配感知通道。")
                return
            }
            var screenLine = ""
            var diag = "imgKB=\(b64.count * 3 / 4 / 1024)"
            // VL 调用(含 ~400KB base64 的 JSON 序列化 + 网络)放**后台线程**,不在主线程做 → 不给音频/UI 添堵。
            let vl = await Task.detached(priority: .utility) { () -> (result: LingShuCloudPerceptionResult?, err: String?) in
                do {
                    return (try await client.analyzeImage(
                        imageBase64: b64,
                        prompt: "用一句话概括这个电脑屏幕现在在显示什么:当前 app、主要内容、有没有正在等用户操作的弹窗/按钮。",
                        includeGrounding: false
                    ), nil)
                } catch {
                    return (nil, String(String(describing: error).prefix(80)))
                }
            }.value
            guard !Task.isCancelled else { return }
            if let r = vl.result {
                diag += " success=\(r.success) semLen=\(r.semanticSuggestions.count) ocr=\(r.ocrTexts.count)"
                if r.success { screenLine = String(r.semanticSuggestions.prefix(180)) }
            } else if let err = vl.err {
                diag += " threw=\(err)"
            }
            if screenLine.isEmpty {
                self.appendTrace(kind: .warning, actor: "感知", title: "VL 未返回", detail: diag)
            }
            self.updatePerceptionDigest(screen: screenLine, audio: audio)
        }
    }

    /// 多模态合并:屏幕(眼)+ 声音(耳)+ 外接设备(第六感)汇聚成一份周期态势 digest。
    /// 这是「定时」给大脑的多模态信号合并点——各通道各自独立采集,在此刻合并成一套标准输入。
    private func updatePerceptionDigest(screen: String, audio: LingShuAudioActivityState?) {
        var parts: [String] = []
        if !screen.isEmpty { parts.append("屏幕:\(screen)") }
        switch audio {
        case .onset, .active: parts.append("声音:有活动")
        case .offset, .silent: parts.append("声音:安静")
        case nil: break
        }
        // 外接设备(手机通知/日历…)汇聚成的标准输入,并入多模态信号。
        if let ext = externalSensory.situationContribution()?.replacingOccurrences(of: "\n", with: " ") {
            parts.append("外接设备:\(ext)")
        }
        // 屏幕语义昂贵(VL 节流),拿到就单独投进感知链(高频采样器不碰 VL)。
        if !screen.isEmpty { perceptionChain.note(.screen, screen) }
        let digest = parts.joined(separator: " · ")
        guard !digest.isEmpty else { return }
        perceptionDigest = digest
        appendTrace(kind: .system, actor: "感知", title: "周期态势", detail: String(digest.prefix(120)))
    }

    /// 被显著环境事件唤醒:先用**一次性临时会话**评估"要不要主动处理",**绝不在岗对话会话/聊天里留痕**——
    /// 否则日常界面变化每次都生成一句"屏幕变化…保持在岗待命",既刷屏又灌满在岗会话上下文 → 真提问也被带跑偏
    /// (实测 bug:问"介绍一下你自己"只回"在岗待命",而干净主会话答得很好=灵枢污染问题,非模型问题)。
    /// 只有评估为"要处理"(ACT)才真用在岗会话去做并正常呈现;"无需处理"(IDLE)只留一条轨迹,不进聊天、不污染。
    private func wakeStandingPersonWithPerception(reason: String) {
        guard let session = autonomousSessionHolder, autonomousRunTask == nil else { return }
        let digest = perceptionDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        let observation = digest.isEmpty ? reason : "\(reason)。当前态势:\(digest)"

        let previous = autonomousRunTask
        autonomousRunTask?.cancel()
        autonomousRunTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { self?.autonomousRunTask = nil; return }
            // 临时评估器(独立会话,用完即弃,不碰在岗对话上下文)。
            let action = await self.evaluatePerceptionForAction(observation: observation)
            guard !Task.isCancelled else { self.autonomousRunTask = nil; return }
            guard let action else {
                // IDLE:无需主动处理——只留轨迹,绝不进聊天、不污染对话上下文。
                self.autonomousRunTask = nil
                self.appendTrace(kind: .system, actor: "感知", title: "已评估·无需主动处理", detail: String(observation.prefix(60)))
                return
            }
            // ACT:确实发现了值得提醒主人的问题——简短出声提醒(不替主人做主、不啰嗦旁白)。
            let recordID = self.autonomousRunRecordID ?? self.createTaskExecutionRecord(for: "灵枢在岗")
            self.autonomousRunRecordID = recordID
            self.enterAutonomousRunningState(statusLine: "发现需要留意的情况,正在提醒…")
            self.missionTitle = "灵枢在岗"
            self.appendTaskRecordMessage(recordID, actor: "感知", role: "提醒", kind: .core, text: action)
            self.appendTrace(kind: .runtime, actor: "灵枢", title: "感知触发提醒", detail: String(action.prefix(40)))
            let baseline = self.currentArtifactCount(recordID)
            let initial = await session.resume("[屏幕监测·主动提醒] 你刚留意到一个可能需要主人知道的情况:\(action)\n用一句话(`speak` 出声)简短提醒主人即可,不必动手处理(除非主人接着发指令)。")
            let result = await self.verifyAndContinue(session: session, result: initial, userRequest: action, taskRecordID: recordID, artifactBaseline: baseline)
            guard !Task.isCancelled else { return }
            self.finishAutonomousRun(result: result, recordID: recordID)
        }
    }

    /// 一次性评估环境观察是否值得**主动提醒主人**(独立临时会话,不污染在岗对话)。
    /// 用户定调(2026-06-16):屏幕变化**不必念出来**,保持静默监测,**只有遇到问题/异常才提醒**。
    /// 返回非 nil = 值得提醒的一句话;nil = 无需提醒(绝大多数日常变化都 nil)。
    private func evaluatePerceptionForAction(observation: String) async -> String? {
        let prompt = """
        你在静默监测主人的屏幕。刚观察到:\(observation)
        判断这**是否是一个值得主动打断主人、出声提醒的问题**。门槛要**高**——
        - 值得提醒(回 "ACT: <一句话说清是什么问题>"):明显的报错/崩溃弹窗、构建或测试失败、危险/不可逆操作的确认框、长任务卡死或异常、安全风险提示等**真正的异常或需要主人当下决断的事**。
        - 不值得提醒(回 "IDLE"):正常切换 app、浏览网页、写代码、看文档、播放视频、界面正常变化等**一切日常活动**。屏幕只是变了不等于有问题。
        宁可漏报也不要打扰。除 "ACT: ..." 或 "IDLE" 外不要输出任何内容。
        """
        let evaluator = LingShuAgentSession(
            id: "perceive-eval-\(UUID().uuidString.prefix(6))",
            system: LingShuPersona.system("现在你在岗盯屏当'异常哨兵':只在发现真正的问题/异常时回 'ACT: ...',其余一律 'IDLE'。不解释、不啰嗦。"),
            tools: [],
            model: makeAgentModelAdapter(),
            maxTurns: 1
        )
        guard case .completed(let text) = await evaluator.send(prompt) else { return nil }
        let cleaned = LingShuReasoningText.stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.uppercased().hasPrefix("ACT:") else { return nil }
        let action = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        return action.isEmpty ? nil : action
    }
}
