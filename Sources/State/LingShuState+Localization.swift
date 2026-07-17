import Foundation

enum LingShuLanguagePreferenceStore {
    static let languageKey = "lingshu.voiceLanguage"
    static let initialSelectionKey = "lingshu.interfaceLanguage.didChoose.v1"

    static func hasCompletedInitialSelection(in defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: initialSelectionKey) != nil {
            return defaults.bool(forKey: initialSelectionKey)
        }

        // Existing installations with an explicit language preference migrate without
        // being interrupted by the new first-launch gate. A clean install has neither key.
        return defaults.object(forKey: languageKey) != nil
    }

    static func completeInitialSelection(
        _ language: LingShuVoiceLanguage,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(language.rawValue, forKey: languageKey)
        defaults.set(true, forKey: initialSelectionKey)
    }

    static func localized(
        _ chinese: String,
        _ english: String,
        in defaults: UserDefaults = .standard
    ) -> String {
        currentLanguage(in: defaults) == .english ? english : chinese
    }

    static func currentLanguage(in defaults: UserDefaults = .standard) -> LingShuVoiceLanguage {
        LingShuVoiceLanguage(
            rawValue: defaults.string(forKey: languageKey) ?? LingShuVoiceLanguage.chinese.rawValue
        ) ?? .chinese
    }

    /// Every brain request receives this sentence before any product prompt. Keeping the
    /// rule here makes language selection a protocol concern instead of a model-specific
    /// prompt convention, so newly added compatible providers inherit it automatically.
    static func highestPriorityModelInstruction(
        in defaults: UserDefaults = .standard
    ) -> String {
        highestPriorityModelInstruction(for: currentLanguage(in: defaults))
    }

    static func highestPriorityModelInstruction(for language: LingShuVoiceLanguage) -> String {
        switch language {
        case .english:
            return "ANSWER IN ENGLISH. This is the highest-priority language instruction: use English for every user-visible answer, spoken response, status summary, and clarification unless the user explicitly asks you to translate or quote another language."
        case .chinese:
            return "请用中文沟通和回答。此语言要求具有最高优先级：所有面向用户的回答、语音、状态总结和澄清都使用中文，除非用户明确要求翻译或引用其他语言。"
        }
    }

    /// Adds one, and only one, language directive at the start of a model prompt.
    /// Removing both known directives also prevents a language switch from leaving an
    /// older contradictory instruction in a reused system prompt.
    static func modelPrompt(
        applyingHighestPriorityLanguageTo prompt: String,
        in defaults: UserDefaults = .standard
    ) -> String {
        let instruction = highestPriorityModelInstruction(in: defaults)
        var cleaned = prompt
        for language in LingShuVoiceLanguage.allCases {
            cleaned = cleaned.replacingOccurrences(
                of: highestPriorityModelInstruction(for: language),
                with: ""
            )
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? instruction : "\(instruction)\n\n\(cleaned)"
    }
}

/// 国际化(中/英两档)。`LingShuState.language` 是全局唯一语言开关:切它则**整个界面 + 状态 + 本体**动态切语言,
/// 并同步语音子系统(ASR locale / TTS 嗓音 / 灵枢回复语言)。视图都观察 state,故切语言时全 UI 自动重渲染。
/// 视图里用 `state.loc("中文", "English")` 取当前语言文案;灵枢英文名 = Nous(用户定名 2026-06-17)。
@MainActor
extension LingShuState {

    func completeInitialLanguageSelection(_ selectedLanguage: LingShuVoiceLanguage) {
        LingShuLanguagePreferenceStore.completeInitialSelection(selectedLanguage)
        language = selectedLanguage
        hasCompletedInitialLanguageSelection = true
    }

    /// 取当前语言的文案:`state.loc(中文, English)`。
    func loc(_ zh: String, _ en: String) -> String { language == .english ? en : zh }

    /// 灵枢的对外名字(英文界面叫 Nous;Nous=古希腊「心智/灵慧」,即「灵慧之中枢」)。
    var appName: String { language == .english ? "Nous" : "灵枢" }

    /// 注入系统提示词的回复语言规则:选英文则全程英文(含 speak),否则中文。
    func languageResponseRule() -> String {
        LingShuLanguagePreferenceStore.highestPriorityModelInstruction()
    }

    var missionTitleDisplay: String { localizedRuntimeText(missionTitle) }
    var missionStatusDisplay: String { localizedRuntimeText(missionStatus, fallback: "Ready") }
    var mainMemoryStatusDisplay: String { localizedRuntimeText(mainMemoryStatus, fallback: "Memory ready") }
    var coldMemoryStatusDisplay: String { localizedRuntimeText(coldMemoryStatus, fallback: "Archive ready") }

    var remoteSessionStatusDisplay: String {
        language == .english
            ? remoteSessionPool.stats().statusText(language: .english)
            : remoteSessionStatus
    }

    var modelProviderDisplay: String {
        localizedModelProviderName(modelProvider)
    }

    func localizedModelProviderName(_ provider: String) -> String {
        guard language == .english,
              let preset = ModelProviderPreset.catalog.first(where: { $0.name == provider })
        else { return provider }
        return preset.localizedName(language: .english)
    }

    func localizedEventLogItem(_ text: String) -> String {
        guard language == .english else { return text }

        let exact: [String: String] = [
            "09:42  灵枢主线程在线，等待指令。": "09:42  Nous main thread is online and waiting for instructions.",
            "09:42  通用 agent 能力池已注册：在线 13 / 运行 0 / 待启动 13。": "09:42  General agent pool registered: 13 online / 0 running / 13 standby.",
            "09:43  高风险操作将进入人工确认。": "09:43  High-risk actions require human approval."
        ]
        if let translated = exact[text] { return translated }

        let replacements: [(String, String)] = [
            ("现在  主脑已连接：", "Now  Brain connected: "),
            ("现在  模型供应商切换为 ", "Now  Model provider changed to "),
            ("当前供应商「", "Current provider \""),
            ("」内切换模型为 ", "\" model changed to "),
            ("现在  用户停止了本轮模型调用。", "Now  The user stopped the current model call."),
            ("现在  用户清空了主对话上下文(新会话);任务线程与执行记录保留。", "Now  Main chat context cleared; task threads and execution records were retained."),
            ("现在  语音入口进入监听状态。", "Now  Voice input is listening."),
            ("现在  语音入口已暂停。", "Now  Voice input is paused."),
            ("用户提交确认表单(", "User submitted a confirmation form ("),
            (" 项)", " items)"),
            ("凭据已保存(加密落盘,未回显):", "Credential saved encrypted and hidden: "),
            ("已开启开发阶段全权(系统授权门直接放行)", "Development full access enabled; system approval gates are bypassed."),
            ("已关闭开发阶段全权(恢复人工授权)", "Development full access disabled; human approval restored."),
            ("用户授权执行系统命令（本次允许）", "User allowed the system command once."),
            ("用户授权执行系统命令（本次会话完全授权）", "User allowed system commands for this session."),
            ("用户拒绝执行系统命令", "User denied the system command."),
            ("现在  执行权限切换为完整权限", "Now  Execution permission changed to Full Access"),
            ("现在  执行权限切换为沙箱权限", "Now  Execution permission changed to Sandbox"),
            ("执行权限切换为完整权限", "Execution permission changed to Full Access."),
            ("执行权限切换为沙箱权限", "Execution permission changed to Sandbox.")
        ]
        var result = text
        for (source, target) in replacements where result.contains(source) {
            result = result.replacingOccurrences(of: source, with: target)
        }
        result = result.replacingOccurrences(of: "，协议：", with: ", protocol: ")
        result = result.replacingOccurrences(of: "。", with: ".")
        if !Self.containsHan(result) { return result }

        let remainder = result.unicodeScalars.map { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ? " " : String(scalar)
        }.joined()
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? "System event" : "System event · \(remainder)"
    }

    /// Localizes system-owned runtime text without translating user content. Callers that
    /// know the value is a system status should provide an English fallback so a newly added
    /// Chinese status never leaks into the English UI.
    func localizedRuntimeText(_ value: String, fallback: String? = nil) -> String {
        guard language == .english else { return value }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback ?? value }

        let exact: [String: String] = [
            "待机中": "Standby",
            "待机": "Idle",
            "待命": "Ready",
            "热记忆待检索": "Memory awaiting retrieval",
            "冷备待检索": "Archive awaiting retrieval",
            "主线程初始化中": "Main thread initializing",
            "主线程冷启动": "Main thread cold start",
            "未探活": "Not checked",
            "等待主线程远端探活": "Waiting for main-thread connectivity check",
            "灵枢中枢": "Nous Core",
            "随时待命": "Ready",
            "正在监听": "Listening",
            "语音已暂停": "Voice paused",
            "实时对话": "Live conversation",
            "身份待确认": "Identity verification required",
            "等待唤醒": "Waiting for wake word",
            "视觉在线": "Vision online",
            "视觉待机": "Vision idle",
            "正在请求摄像头权限": "Requesting camera access",
            "视觉权限已就绪": "Camera access ready",
            "视觉权限未授权": "Camera access not granted",
            "语音输入异常": "Voice input error",
            "收音待机": "Audio input idle",
            "发声待机": "Audio output idle",
            "语音待机": "Voice idle",
            "正在请求语音权限": "Requesting microphone access",
            "正在听": "Listening",
            "正在听（本机）": "Listening on device",
            "正在听（SenseVoice）": "Listening with SenseVoice",
            "语音已转写": "Speech transcribed",
            "语音识别已中断": "Speech recognition interrupted",
            "本地收音已停止": "Local listening stopped",
            "本地收音已中断": "Local listening interrupted",
            "SenseVoice 运行异常": "SenseVoice runtime error",
            "SenseVoice 未就绪，已回退 Apple Speech": "SenseVoice unavailable; using Apple Speech",
            "语音模型未就绪，已回退 Apple Speech": "Speech model unavailable; using Apple Speech",
            "本地男声待机": "Local voice ready",
            "本地男声未就绪，系统发声兜底": "Local voice unavailable; using system speech",
            "正在发声（流式·预合成）": "Speaking with streaming pre-synthesis",
            "正在发声（流式）": "Speaking · streaming",
            "正在发声（低延迟）": "Speaking · low latency",
            "正在发声（本机系统语音·兜底）": "Speaking with system fallback",
            "云端 TTS 未配置": "Cloud TTS is not configured",
            "本地解析": "Local analysis",
            "模型直连": "Direct model",
            "外部适配": "External adapter",
            "云感知就绪": "Cloud perception ready",
            "模型解析中": "Model analysis in progress",
            "模型解析在线": "Model analysis online",
            "模型解析中断": "Model analysis interrupted",
            "未认主": "Owner not enrolled",
            "认主中": "Owner enrollment in progress",
            "身份已锁定": "Owner identity locked",
            "认主完成": "Owner enrollment complete",
            "理解需求": "Understanding request",
            "等待模型配置": "Waiting for model setup",
            "模型服务异常": "Model service error",
            "局域网未发现设备。若设备没出现,确认已允许灵枢访问「本地网络」(系统设置 → 隐私与安全 → 本地网络)。": "No devices were found on the local network. Make sure Nous has Local Network access in System Settings > Privacy & Security > Local Network.",
            "大脑未蒸馏出待办，按规则兜底": "The brain returned no to-dos; rule-based distillation was used.",
            "我在。能力池已注册，随时待命，等你开口。": "I am ready. Capabilities are registered and waiting for your request."
        ]
        if let translated = exact[trimmed] { return translated }

        let numberedPrefixes: [(String, String)] = [
            ("本地解析 ", "Local analysis "),
            ("执行中：", "Running: "),
            ("正在等待：", "Waiting for: "),
            ("正在处理：", "Processing: "),
            ("已由大脑蒸馏 ", "Brain-distilled "),
            ("规则蒸馏 ", "Rule-distilled ")
        ]
        for (source, target) in numberedPrefixes where trimmed.hasPrefix(source) {
            var suffix = String(trimmed.dropFirst(source.count))
            if source.contains("蒸馏"), suffix.hasSuffix(" 条待办") {
                suffix.removeLast(" 条待办".count)
                return target + suffix + " to-dos"
            }
            if !Self.containsHan(suffix) { return target + suffix }
        }

        if trimmed.hasSuffix(" 已选定") {
            return "Voice selected"
        }
        if trimmed.hasSuffix("待机") && trimmed.contains("TTS") {
            return "TTS ready"
        }
        if !Self.containsHan(trimmed) { return value }
        return fallback ?? value
    }

    nonisolated static func containsHan(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}

extension LingShuExpertProfile {
    func localizedTitle(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return title }
        let values = [
            "expert-pm": "Project Manager",
            "expert-product": "Product Manager",
            "expert-architect": "Solution Architect",
            "expert-design": "Design Director",
            "expert-engineer": "Engineering Executor",
            "expert-reviewer": "Reviewer"
        ]
        return values[id] ?? (LingShuState.containsHan(title) ? "Custom Expert" : title)
    }

    func localizedMission(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return mission }
        let values = [
            "expert-pm": "Turn goals into an executable, testable plan with a timeline, risks, and resource estimates.",
            "expert-product": "Turn requests into a clear product definition covering users, scenarios, boundaries, and priorities.",
            "expert-architect": "Design an evolvable architecture with explicit layers, boundaries, tradeoffs, and rationale.",
            "expert-design": "Turn content into a coherent narrative and a polished presentation or design deliverable.",
            "expert-engineer": "Produce complete, runnable engineering deliverables including code, scripts, configuration, and operating steps.",
            "expert-reviewer": "Verify the draft against expert checklists and acceptance criteria, then provide a clear verdict and concrete fixes."
        ]
        return values[id] ?? (LingShuState.containsHan(mission) ? "User-defined expert capability." : mission)
    }
}

extension LingShuOwnerIdentitySnapshot {
    var preferredOwnerName: String {
        ownerName == "主人" && LingShuLanguagePreferenceStore.currentLanguage() == .english ? "Owner" : ownerName
    }
}

extension LingShuAgent {
    func displayShortName(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return shortName }
        return [
            "规划": "Planning", "审议": "Review", "调度": "Dispatch", "设计": "Design",
            "执行": "Execution", "监控": "Monitoring", "验证": "Verification", "记忆": "Memory",
            "安全": "Safety", "知识": "Knowledge", "路由": "Routing"
        ][shortName] ?? shortName
    }

    func displayDomain(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return domain }
        return [
            "通用治理": "General Governance", "设计交付": "Design Delivery", "能力节点": "Capability Node",
            "记忆层": "Memory Layer", "治理边界": "Governance Boundary", "知识层": "Knowledge Layer",
            "协议层": "Protocol Layer"
        ][domain] ?? domain
    }
}

extension LingShuRemoteSessionPoolStats {
    func statusText(language: LingShuVoiceLanguage) -> String {
        language == .english
            ? "Online \(online) / Running \(running) / Standby \(standby)"
            : statusText
    }
}

extension LingShuExtension.Kind {
    func displayName(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return rawValue }
        switch self {
        case .skill: return "Skill"
        case .mcp: return "MCP"
        case .plugin: return "Plugin"
        }
    }
}

extension LingShuExtension {
    func localizedPermissionSummary(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return permissionSummary }
        if permissionSummary == "外部 MCP 进程(自带工具)" {
            return "External MCP process with its own tools"
        }
        if permissionSummary.hasPrefix("无特殊权限声明") {
            return "No special permissions declared (least privilege)"
        }

        var translated = permissionSummary
        let replacements: [(String, String)] = [
            ("读:", "Read: "), ("写:", "Write: "), ("联网:", "Network: "),
            ("跑命令", "Shell"), ("系统敏感", "System-sensitive")
        ]
        for (source, target) in replacements {
            translated = translated.replacingOccurrences(of: source, with: target)
        }
        return translated
    }
}

// MARK: - 界面枚举的英文映射(中文 rawValue 已是显示名,这里补英文)

extension AppSurface {
    var englishName: String {
        switch self {
        case .chat: "Chat"
        case .taskPool: "Threads"
        case .runtime: "Status"
        case .operations: "Ops"
        case .settings: "Settings"
        }
    }
}

extension LingShuCoreState {
    var englishName: String {
        switch self {
        case .standby: "Standby"
        case .thinking: "Thinking"
        case .executing: "Executing"
        case .abnormal: "Abnormal"
        }
    }
}

extension LingShuLoopPhase {
    var englishName: String {
        switch self {
        case .idle: ""
        case .understanding: "Understanding"
        case .planning: "Planning"
        case .executing: "Executing"
        case .verifying: "Verifying"
        }
    }
}

extension LingShuTaskExecutionStatus {
    var englishName: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .answered: "Answered"
        case .dispatched: "Dispatched"
        case .completed: "Completed"
        case .needsRevision: "Needs Revision"
        case .blocked: "Blocked"
        case .suspended: "Paused"
        case .analyzing: "Analyzing"
        case .acquiringCapability: "Acquiring Capability"
        case .waitingForUser: "Waiting for User"
        case .ready: "Ready"
        case .partial: "Partially Completed"
        case .verified: "Verified"
        case .failed: "Failed"
        }
    }
}

extension LingShuArtifactOperation {
    var englishName: String {
        switch self {
        case .created: "Added"
        case .modified: "Modified"
        }
    }
}

extension LingShuHistorySearchScope {
    var englishName: String {
        switch self {
        case .all: "All"
        case .hot: "Recent"
        case .cold: "Archive"
        }
    }
}

extension LingShuHistorySearchSource {
    var englishName: String {
        switch self {
        case .hotChat: "Recent Chat"
        case .coldChat: "Archived Chat"
        case .hotTask: "Recent Task"
        case .coldTask: "Archived Task"
        }
    }
}

extension LingShuAutonomousRunbookStepStatus {
    var englishName: String {
        switch self {
        case .waiting: "Waiting"
        case .running: "Running"
        case .completed: "Completed"
        case .blocked: "Blocked"
        }
    }
}

extension LingShuVoicePhase {
    var englishCaption: String {
        switch self {
        case .standby: "Standby"
        case .listening: "Listening"
        case .processing: "Processing"
        case .responding: "Responding"
        }
    }
}
