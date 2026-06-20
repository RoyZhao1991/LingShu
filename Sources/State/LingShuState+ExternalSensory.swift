import Foundation

/// 外接设备感知 · 下游接线（模型驱动蒸馏 + 与大脑对接）。
///
/// 中枢 `LingShuExternalSensoryHub` 负责各独立模块的汇聚/开关/缓冲；这里补上**用大脑把读数蒸馏成
/// 关键待办**的那条路（§4 第 3 步）。失败/断网回退到 `LingShuPhoneTodoDistiller.heuristicDistill`。
/// 隐私 [[perception-data-zero-retention]]：只把**去标识后的最小必要文本**喂模型，绝不留存原始消息。
@MainActor
extension LingShuState {
    /// 启动时调一次：把模型驱动蒸馏器注入中枢，并恢复用户上次的开关偏好。
    func wireExternalSensory() {
        externalSensory.todoDistiller = { [weak self] readings in
            await self?.distillPhoneTodos(readings) ?? LingShuPhoneTodoDistiller.heuristicDistill(readings)
        }
        // 对外广播的蓝牙名按当前语言(中文「灵枢」/ 英文「Nous」),语言切换时在 language didSet 同步。
        externalSensory.setBluetoothLocalName(appName)
        externalSensory.restorePersistedPreferences()
        // M2:把已安装的**自编传感器型外围**重新注册进感知中枢(跨重启持续可用;隔离的不自动启用)。
        loadAndRegisterSensorComponents()
        rebaseBrainScoreToCurrentBrain()   // 顶栏脑力分对齐当前脑(持久分若属别的脑→归零)
        // P0②:首启把第一个决策知识包种进知识图谱(陈述性事实/教训)。后台跑、不阻塞启动(知识图谱懒加载,
        // 含本地向量重建,别压在启动关键路径上);幂等,有标记即跳过。
        Task { @MainActor [weak self] in
            guard let self else { return }
            let n = self.knowledgeGraph.seedDecisionKnowledgeIfNeeded()
            if n > 0 { self.appendTrace(kind: .system, actor: "记忆", title: "决策知识种子", detail: "首启种入 \(n) 条陈述性事实/教训") }
        }
    }

    /// 感知链高频采样驱动:每 ~1s 把各通道**此刻**的内容投进感知链(视觉/听觉来自感知网关采样器、
    /// 外接设备来自中枢、情境本地算)。屏幕语义由在岗周期 VL 单独 note(它昂贵、节流)。
    /// 采样只读已缓存的态、不触发昂贵感知——所以可以高频且廉价。启动幂等。
    func startPerceptionChain(interval: TimeInterval = 1.0) {
        guard perceptionChainDriverTask == nil else { return }
        perceptionChainDriverTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.samplePerceptionChainOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPerceptionChain() {
        perceptionChainDriverTask?.cancel()
        perceptionChainDriverTask = nil
    }

    /// 一拍采样:汇集当前各通道并投进链。
    func samplePerceptionChainOnce(now: Date = Date()) {
        var samples = liveSenseSampler?() ?? []   // 视觉/听觉麦克风(摄像头/麦克风,经感知网关)
        // 听觉·系统声音:会议 ASR 在跑时,把滚动转写的尾段(最近内容)投进环境音通道。
        let meeting = LingShuMeetingASR.shared
        if meeting.isRunning {
            let tail = meeting.transcript.trimmingCharacters(in: .whitespacesAndNewlines).suffix(160)
            if !tail.isEmpty { samples.append(.init(channel: .ambientAudio, text: String(tail))) }
        }
        if externalSensory.masterEnabled, let ext = externalSensory.situationContribution() {
            samples.append(.init(channel: .externalDevice, text: ext.replacingOccurrences(of: "\n", with: " ")))
        }
        samples.append(.init(channel: .situation, text: currentSituationLine(now: now)))
        perceptionChain.ingest(samples, now: now)
    }

    /// 情境一句话(时间/时段 + 在执行的任务),始终可贡献(免费)。
    private func currentSituationLine(now: Date) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        let minute = Calendar.current.component(.minute, from: now)
        var line = String(format: "%02d:%02d %@", hour, minute, LingShuSituationContext.daySegment(hour: hour))
        if isModelExecuting, let task = activeTaskThread.map({ String($0.prompt.prefix(24)) }) {
            line += "·正执行:\(task)"
        }
        return line
    }

    /// 大脑「拉取感知链时间窗」工具:做判断/决策前调用,瞬时拿到最近若干秒的多模态实时态势
    /// (感知链已持续融合好,不必当场触发昂贵感知再等)。这是大脑与感知解耦后的"实时取数"入口。
    func perceiveTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "perceive",
            description: "拉取最近若干秒的多模态实时感知快照(视觉/听觉/屏幕/外接设备/情境的融合)。做判断或决策前调用以获取此刻态势——感知链已持续融合好,瞬时返回,不必当场触发昂贵感知。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"seconds\":{\"type\":\"number\",\"description\":\"回看的时间窗(秒),默认 5\"}}}"
        ) { [weak self] argumentsJSON in
            let seconds = Self.jsonNumber(argumentsJSON, "seconds") ?? 5
            return await MainActor.run { [weak self] in
                self?.perceptionChain.formattedWindow(seconds: max(1, min(60, seconds))) ?? "感知链不可用。"
            }
        }
    }

    nonisolated static func jsonNumber(_ json: String, _ key: String) -> Double? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let d = object[key] as? Double { return d }
        if let i = object[key] as? Int { return Double(i) }
        if let s = object[key] as? String { return Double(s) }
        return nil
    }

    /// 把「外接设备」这一路汇聚成给大脑的合并文本(待办 + 近期读数)。无信号时返回引导语。
    func externalSignalsBrainInput() -> String {
        guard externalSensory.masterEnabled else {
            return "外接设备感知未开启(配置 → 连接器 → 外设连接器 可开)。"
        }
        var blocks: [String] = []
        if let contribution = externalSensory.situationContribution() {
            blocks.append(contribution)
        }
        let recent = externalSensory.recentReadings.prefix(8)
        if !recent.isEmpty {
            let lines = recent.map { reading -> String in
                let due = reading.metadata["due"].map { "(\($0))" } ?? ""
                return "・[\(reading.originApp ?? reading.channel.label)] \(reading.headline)\(due)"
            }
            blocks.append("近期信号:\n" + lines.joined(separator: "\n"))
        }
        return blocks.isEmpty ? "外接设备已开启,但暂无信号。" : blocks.joined(separator: "\n\n")
    }

    /// 模型驱动蒸馏：批量读数 → 关键待办。只挑真需行动的，忽略寒暄/系统噪声。
    func distillPhoneTodos(_ readings: [LingShuExternalSensoryReading]) async -> [LingShuPhoneTodo] {
        let fallback = LingShuPhoneTodoDistiller.heuristicDistill(readings)
        let payload = LingShuPhoneTodoDistiller.promptPayload(for: readings)
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let prompt = """
        下面是来自外接设备（手机通知/日历提醒等）的近期信号清单。请只挑出**真正需要主人采取行动**的关键待办，
        忽略寒暄、营销、系统噪声、纯通知性消息。每条待办用如下 JSON 字段表达，输出一个 JSON 数组（没有就输出 []）：
        [{"title":"一句话待办","sourceApp":"来源app","due":"截止/时间或null","people":["涉及人"],"actionSuggestion":"建议的下一步","sourceQuote":"原文最小引用"}]
        只输出 JSON 数组本身，不要解释、不要代码块标记。

        信号清单：
        \(payload)
        """
        let session = LingShuAgentSession(
            id: "todo-distill-\(UUID().uuidString.prefix(6))",
            system: "你是灵枢的'关键待办蒸馏器'。从嘈杂的设备通知里提炼真正需要行动的事，宁缺毋滥。只输出 JSON 数组。",
            tools: [],
            model: makeAgentModelAdapter(),
            maxTurns: 1
        )
        guard case .completed(let text) = await session.send(prompt) else { return fallback }
        let cleaned = LingShuReasoningText.stripThinkTags(text)
        guard let todos = Self.parsePhoneTodos(from: cleaned), !todos.isEmpty else { return fallback }
        return todos
    }

    /// 从模型回复里抽出 JSON 数组并解码成待办（容错：剥代码块、定位首个 `[...]`）。
    nonisolated static func parsePhoneTodos(from text: String) -> [LingShuPhoneTodo]? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = body.firstIndex(of: "["), let end = body.lastIndex(of: "]"), start < end else { return nil }
        let json = String(body[start...end])
        guard let data = json.data(using: .utf8) else { return nil }

        struct DTO: Decodable {
            var title: String
            var sourceApp: String?
            var due: String?
            var people: [String]?
            var actionSuggestion: String?
            var sourceQuote: String?
        }
        guard let dtos = try? JSONDecoder().decode([DTO].self, from: data) else { return nil }
        return dtos
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { dto in
                LingShuPhoneTodo(
                    title: dto.title,
                    sourceApp: dto.sourceApp ?? "设备",
                    due: dto.due.flatMap { $0.lowercased() == "null" ? nil : $0 },
                    people: dto.people ?? [],
                    actionSuggestion: dto.actionSuggestion ?? "",
                    sourceQuote: dto.sourceQuote ?? ""
                )
            }
    }
}
