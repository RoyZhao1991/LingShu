import Foundation

/// 灵枢表现层：只负责“身体怎么表现”，不负责判断业务该怎么做。
/// 大脑可以通过工具临时下发表现指令；没有指令时，这里从真实运行状态推导默认表现。
@MainActor
extension LingShuState {

    func expireDigitalHumanDirectiveIfNeeded(now: Date = Date()) {
        guard let directive = digitalHumanDirective, directive.isExpired(at: now) else { return }
        digitalHumanDirective = nil
    }

    func setDigitalHumanExpression(
        _ expression: LingShuDigitalHumanExpression,
        message: String = "",
        source: String = "大脑",
        durationSeconds: Double = 8,
        intensity: Double? = nil
    ) {
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = min(max(durationSeconds, 1), 60)
        digitalHumanDirective = LingShuDigitalHumanDirective(
            expression: expression,
            message: cleanMessage,
            source: source.isEmpty ? "大脑" : source,
            intensity: min(max(intensity ?? expression.baseIntensity, 0), 1),
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(duration)
        )
    }

    func digitalHumanSnapshot(
        voice: VoiceIOManager,
        vision: VisionIOManager,
        perceptionGateway: LingShuRealtimePerceptionGateway
    ) -> LingShuDigitalHumanSnapshot {
        var signals: Set<LingShuDigitalHumanSignal> = []
        let audibleOutput = voice.hasAudibleOutput
        if voice.isRecording || voiceWakeListeningEnabled || isVoiceConversationActive { signals.insert(.ear) }
        if audibleOutput { signals.insert(.mouth) }
        if vision.isCameraRunning { signals.insert(.eye) }
        if hasActiveModelCall || isStandingPersonOnDuty { signals.insert(.brain) }
        if isModelExecuting || runtimePhase != .idle { signals.insert(.hand) }
        if perceptionGateway.isOwnerIdentityLocked { signals.insert(.owner) }

        // 处理中(与忙音同口径:在岗回合/模型/LOOP 在跑且不在朗读)→ 本体随忙音"嘟"声在几种颜色间切换,等待不无聊。
        let pulsing = (autonomousRunTask != nil || hasActiveModelCall || loopPhase.isActive) && !voice.isSpeakingOrQueued
        let pulseIndex: Int? = pulsing ? LingShuCueSound.busyPulseIndex : nil

        if let directive = digitalHumanDirective, !directive.isExpired(at: Date()) {
            let effectiveIntensity = directive.expression == .speaking
                ? max(directive.intensity, Double(voice.outputLevel))
                : directive.intensity
            return LingShuDigitalHumanSnapshot(
                expression: directive.expression,
                displayText: directive.message.isEmpty ? directive.expression.displayName : directive.message,
                source: directive.source,
                intensity: effectiveIntensity,
                activeSignals: signals,
                isDirectiveDriven: true
            )
        }

        let expression: LingShuDigitalHumanExpression
        let text: String
        var phaseIntensity: Double? = nil   // LOOP 各环节给本体不同的"身体表现"(色+脉动快慢),不只是文字
        if coreState == .abnormal {
            expression = .alert
            text = missionStatus
        } else if loopPhase.isActive {
            // 跑任务时本体**按 LOOP 环节给独立观感(颜色)**:理解/规划=思考态(青,沉稳慢脉动)、执行=执行态(橙,快脉动)、验收=确认态(绿)。
            // 出声(讲解/演示)时**叠加真实音量脉动**——边讲边按环节色一起脉动,既保留语音反馈、又能看清当前在哪个环节(执行不再被发声态吞成绿色)。
            switch loopPhase {
            case .understanding: expression = .thinking;   text = "理解中"; phaseIntensity = 0.42
            case .planning:      expression = .thinking;   text = "规划中"; phaseIntensity = 0.58
            case .executing:     expression = .executing;  text = audibleOutput ? "演示中" : "执行中"; phaseIntensity = 0.82
            case .verifying:     expression = .confirming; text = "结果验证"; phaseIntensity = 0.64
            case .idle:          expression = .executing;  text = missionTitle
            }
            if audibleOutput { phaseIntensity = min(1, (phaseIntensity ?? 0.6) + Double(voice.outputLevel) * 0.35) }
        } else if audibleOutput {
            expression = .speaking
            text = "正在发声"
        } else if voice.isRecording || isVoiceConversationActive {
            // 自主/在岗时:接收主人输入用专门的绿色「我在听」态;普通对话仍用聆听(青)。
            if isStandingPersonOnDuty {
                expression = .receiving
                text = "我在听"
            } else {
                expression = .listening
                text = "正在聆听"
            }
        } else if coreState == .thinking {
            expression = .thinking
            text = missionTitle
        } else if coreState == .executing || isModelExecuting {
            expression = .executing
            text = missionTitle
        } else if vision.isCameraRunning {
            expression = .greeting
            text = "视觉在线"
        } else if isStandingPersonOnDuty {
            expression = .standby
            text = "在岗待命"
        } else {
            expression = .standby
            text = "待机"
        }

        return LingShuDigitalHumanSnapshot(
            expression: expression,
            displayText: text,
            source: "状态推导",
            // 发声时强度 = 基线 + 真实音量加成(随 outputLevel 提升,封顶 1)。LOOP 环节用各自的脉动强度(phaseIntensity)区分快慢。
            intensity: expression == .speaking ? min(1, expression.baseIntensity + Double(voice.outputLevel) * 0.3) : (phaseIntensity ?? expression.baseIntensity),
            activeSignals: signals,
            isDirectiveDriven: false,
            pulseIndex: pulseIndex   // 处理中随忙音切色
        )
    }

    func digitalHumanTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "set_digital_human",
            description: "调度灵枢身体表现层(光球动画),只改变可视表现,不改变业务状态。用于回应、聆听、思考、演示、确认、警戒等身体表达。",
            parametersJSON: """
            {"type":"object","properties":{"expression":{"type":"string","description":"表现态: standby/listening/speaking/thinking/executing/alert/greeting/confirming/presenting, 也支持中文:待机/聆听/发声/思考/执行/警戒/回应/确认/演示"},"message":{"type":"string","description":"显示在灵枢旁边的短句,可留空"},"duration_seconds":{"type":"number","description":"持续秒数,1-60,默认8"},"intensity":{"type":"number","description":"动画强度0-1,可留空"}},"required":["expression"]}
            """
        ) { [weak self] argumentsJSON in
            let args = Self.parseArgs(argumentsJSON)
            let rawExpression = args["expression"] ?? ""
            guard let expression = LingShuDigitalHumanExpression.parse(rawExpression) else {
                return "未识别的灵枢表现态:\(rawExpression)。可用: \(LingShuDigitalHumanExpression.allCases.map(\.rawValue).joined(separator: ", "))"
            }
            let message = args["message"] ?? ""
            let duration = Double(args["duration_seconds"] ?? "") ?? 8
            let intensity = Double(args["intensity"] ?? "")
            return await MainActor.run { [weak self] in
                self?.setDigitalHumanExpression(
                    expression,
                    message: message,
                    source: "大脑",
                    durationSeconds: duration,
                    intensity: intensity
                )
                return "灵枢表现层已切换为「\(expression.displayName)」。"
            }
        }
    }
}
