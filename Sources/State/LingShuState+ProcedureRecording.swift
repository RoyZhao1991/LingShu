import Foundation

/// **Record & Replay — 录制观测(②)**:用户「记录技能」后边做边说,每说一句=一步,灵枢截屏+列AX元素+记下这句当 note;
/// 「记录完成」→ 大脑把 note 序列**抽成带参数的 SKILL.md**(自动分清会变的参数 vs 固定配置),存进技能库。
///
/// 取向:观测=**截当下屏幕状态 + 用户口头描述这步**(note 是主信号,截图/元素做grounding);抽象交大脑,不写死规则。

/// 录制中的过程技能会话:逐步累积「这步说了啥 + 当时屏幕元素」。
struct LingShuProcedureRecordingSession: Equatable, Sendable {
    var name: String?
    var startedAt: Date = Date()
    var frames: [Frame] = []
    struct Frame: Equatable, Sendable {
        var note: String            // 用户这步说的话(如「金额填3600」)
        var elementsSummary: String // 截帧时前台可交互元素摘要(grounding)
        var screenshotPath: String?
    }
}

@MainActor
extension LingShuState {

    // MARK: 路由

    /// 录制进行时:用户开口=一步(或完成/取消)。返回 true=已接管(录制中不走常规分诊)。
    func handleProcedureRecordingInputIfNeeded(_ prompt: String) -> Bool {
        guard procedureRecording != nil else { return false }
        let t = prompt.replacingOccurrences(of: " ", with: "")
        chatMessages.append(.init(speaker: "你", text: prompt, isUser: true))
        requestChatScrollToLatestForUserSend()
        if ["记录完成", "录完了", "完成录制", "录好了", "就这些", "结束录制"].contains(where: { t.contains($0) }) {
            Task { @MainActor [weak self] in await self?.finishProcedureRecording() }
            return true
        }
        if ["取消录制", "不录了", "别录了", "放弃录制"].contains(where: { t.contains($0) }) {
            procedureRecording = nil
            speakAndChat("好,这次录制取消了,没存。")
            return true
        }
        captureProcedureStep(note: prompt)
        return true
    }

    // MARK: 录制流程

    func startProcedureRecording(name: String?) {
        if let gate = computerControlGate(requiresAccessibility: false) {   // 录制要截屏
            speakAndChat("要录技能我得能看屏幕。\(gate)")
            return
        }
        procedureRecording = LingShuProcedureRecordingSession(name: name)
        let named = name.map { "「\($0)」" } ?? ""
        speakAndChat("好,开始录技能\(named)。你正常做、边做边跟我说每一步(比如『点费用报销』『金额填3600』),我都看着记着。做完说『记录完成』。")
    }

    /// 记一步:截当下屏幕 + 列元素 + 记下这句话。
    func captureProcedureStep(note: String) {
        guard var session = procedureRecording else { return }
        let path = LingShuComputerControl.captureScreen()
        let elements = LingShuComputerControl.actionableElements().prefix(18)
            .map { "\(Self.uiRoleLabel($0.role))「\($0.title)」" }.joined(separator: "、")
        session.frames.append(.init(note: note, elementsSummary: String(elements.prefix(400)), screenshotPath: path))
        procedureRecording = session
        chatMessages.append(.init(speaker: "灵枢", text: "第 \(session.frames.count) 步记下了:\(note)", isUser: false))
        appendTrace(kind: .system, actor: "Record&Replay", title: "录制截帧", detail: "第\(session.frames.count)步:\(note)")
    }

    /// 完成录制 → 大脑抽成 SKILL.md → 存盘 + 热载。
    func finishProcedureRecording() async {
        guard let session = procedureRecording else { return }
        procedureRecording = nil
        guard !session.frames.isEmpty else { speakAndChat("这次没记到步骤,不存了。"); return }
        speakAndChat("好,我把刚才这 \(session.frames.count) 步整理成可复用的技能,稍等。")
        guard let skill = await abstractProcedureSkill(session) else {
            speakAndChat("整理技能没成功(大脑没给出可用结构),这次先不存。")
            return
        }
        let saved = saveProcedureSkill(skill)
        (expertProfileRegistry as? LingShuCompositeExpertRegistry)?.reloadUserSkills()
        let paramList = skill.parameters.map(\.name).joined(separator: "、")
        speakAndChat("技能「\(skill.title)」存好了\(saved ? "" : "(写盘提示见日志)")。\(paramList.isEmpty ? "" : "它认这些参数:\(paramList)。")以后跟我说『用\(skill.triggers.first ?? skill.title),\(skill.parameters.first.map { "\($0.name)\($0.example)" } ?? "...")』我就替你跑。")
    }

    /// 大脑抽象:note 序列 + 元素 → 带参 SKILL.md 结构(JSON)。
    private func abstractProcedureSkill(_ session: LingShuProcedureRecordingSession) async -> LingShuProcedureSkill? {
        let steps = session.frames.enumerated().map { i, f in
            "第\(i + 1)步 用户说:\(f.note)\(f.elementsSummary.isEmpty ? "" : "（当时屏上元素:\(f.elementsSummary)）")"
        }.joined(separator: "\n")
        let sys = LingShuPersona.identityLine + "\n" + """
        现在你把用户**演示一遍**的操作,整理成一个**可复用的过程技能**(像 Codex 的 SKILL.md)。**只输出一行 JSON**:
        {"title":"技能名","app":"主要在哪个App操作(没有填\\"\\")","steps":["按意图描述的步骤,会变的值用 {{参数名}} 占位"],"params":[{"name":"参数名","desc":"说明","example":"用户这次的示例值"}]}
        要点:
        - **分清参数 vs 配置**:用户每次会变的(金额/日期/收件人/标题…)抽成 {{参数}};固定不变的(选某个固定科目、点提交)直接写进步骤。
        - 步骤按**意图**写(「点费用报销」「科目选差旅费」「金额填 {{金额}}」),别写坐标。
        - 步骤要完整覆盖用户说的每一步,顺序一致。
        - title 简短;triggers 不用给(系统用 title)。
        """
        let session2 = LingShuAgentSession(id: "proc-\(UUID().uuidString.prefix(5))", system: sys, tools: [],
                                           model: controlPlaneModelAdapter(.deliveryComposer), maxTurns: 1)
        let r = await session2.send("用户的演示记录:\n\(steps)\n\n技能名参考(用户起的):\(session.name ?? "（没起,你定）")")
        guard case .completed(let raw) = r else { return nil }
        let clean = LingShuReasoningText.stripThinkTags(raw)
        guard let data = Self.firstJSONObject(clean)?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (session.name ?? "未命名技能")
        let stepsArr = (obj["steps"] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
        guard !stepsArr.isEmpty else { return nil }
        let params: [LingShuProcedureSkill.Param] = (obj["params"] as? [Any])?.compactMap { item in
            guard let d = item as? [String: Any],
                  let name = (d["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            return .init(name: name, description: (d["desc"] as? String) ?? "", example: (d["example"] as? String) ?? "")
        } ?? []
        let app = (obj["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let id = "proc-\(title.replacingOccurrences(of: " ", with: ""))-\(UUID().uuidString.prefix(4))"
        var triggers = [title]
        if let n = session.name, n != title { triggers.append(n) }
        return LingShuProcedureSkill(id: id, title: title, triggers: triggers, appHint: app, parameters: params, steps: stepsArr)
    }

    /// 存成技能目录里的 .md(复用现成技能目录,跨工具可读)。
    @discardableResult
    func saveProcedureSkill(_ skill: LingShuProcedureSkill) -> Bool {
        let dir = LingShuSkillLoader.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(skill.id).md")
        do { try skill.toMarkdown().write(to: url, atomically: true, encoding: .utf8); return true }
        catch { appendTrace(kind: .warning, actor: "Record&Replay", title: "技能写盘失败", detail: error.localizedDescription); return false }
    }

    // MARK: 小工具

    /// 进聊天 + 出声(录制/replay 的旁白)。
    func speakAndChat(_ text: String) {
        chatMessages.append(.init(speaker: "灵枢", text: text, isUser: false))
        voiceManager?.speak(text)
        recordSpokenLine(text)
    }

    /// 抽第一个完整 JSON 对象({…})。
    nonisolated static func firstJSONObject(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var idx = start
        while idx < s.endIndex {
            if s[idx] == "{" { depth += 1 }
            else if s[idx] == "}" { depth -= 1; if depth == 0 { return String(s[start...idx]) } }
            idx = s.index(after: idx)
        }
        return nil
    }
}
