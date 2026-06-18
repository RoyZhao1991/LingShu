import Foundation

/// dreaming 离线固化的接线层(自进化 Phase 2)。
/// 空闲时回放已完成任务,经 `LingShuDreamingConsolidator` 蒸馏成纯提示 skill 落盘到用户 Skills 目录,
/// 下次启动 `LingShuSkillLoader` 自动加载并入组合注册表生效("醒来即更强")。
/// 安全红线由 consolidator 的 `sanitizePromptOnly` 结构性保证:只落纯提示,绝不写可执行脚本。
@MainActor
extension LingShuState {

    // MARK: - 从用户反馈学(子线程纠正 → dreaming 设计经验,真正有意义的进化)
    //
    // 用户在任务窗口给的纠正/追问是**最高信号的改进点**(他亲眼看了产出物)。把它收进该设计任务记录,
    // 并**立即**(不等空闲)走 dreaming 蒸馏进 DesignKB 设计经验 overlay,下次做 PPT 即遵守——
    // 让"用户说过一次的问题不再犯"。只对设计/PPT 任务捕获;红线仍由 consolidator 的 sanitizePromptOnly 守。

    /// 捕获用户对某条**设计任务**的纠正,记进记录的 designIssues(标注「用户反馈:」),并立即固化进设计经验。
    func captureDesignFeedbackForDreaming(_ feedback: String, recordID: String?) {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let recordID,
              let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let record = taskExecutionRecords[idx]
        let isDesign = record.designScore != nil
            || LingShuDreamingConsolidator.domain(for: record.prompt)?.domain == "presentation"
        guard isDesign else { return }   // 非设计任务的纠正不进设计经验
        taskExecutionRecords[idx].designIssues.append("用户反馈: " + String(text.prefix(140)))
        persistTaskExecutionRecords()
        appendTrace(kind: .model, actor: "固化", title: "收录用户设计反馈", detail: "据此 dreaming 提炼设计铁律,下次 PPT 生效:\(text.prefix(40))")
        Task { @MainActor [weak self] in await self?.learnDesignFeedbackNow() }   // 立即固化,用户要它真生效
    }

    /// 立即把已收集的设计反馈/评分蒸馏进 DesignKB 设计经验(绕过空闲节流;用户反馈是高信号,1 条即可固化)。
    func learnDesignFeedbackNow() async {
        let designSamples: [LingShuDreamingConsolidator.DesignSample] = taskExecutionRecordLookup.compactMap { record in
            let isDesign = record.designScore != nil
                || LingShuDreamingConsolidator.domain(for: record.prompt)?.domain == "presentation"
            guard isDesign, !(record.designIssues.isEmpty && record.designScore == nil) else { return nil }
            return .init(prompt: record.prompt, score: record.designScore ?? 0.7,
                         liked: taskRecordFeedback[record.id], issues: record.designIssues)
        }
        guard !designSamples.isEmpty else { return }
        let adapter = makeAgentModelAdapter()
        let distill: @Sendable (String) async -> String = { prompt in
            let session = LingShuAgentSession(
                id: "dream-fb-\(UUID().uuidString.prefix(6))",
                system: "你是经验固化器,只输出提炼后的要点,不写任何可执行代码/脚本。",
                tools: [], model: adapter, maxTurns: 1
            )
            if case .completed(let text) = await session.send(prompt) { return LingShuReasoningText.stripThinkTags(text) }
            return ""
        }
        // 用户反馈是高信号 → minSamples=1 即可固化(不必凑够 3 条)。
        if let insights = await LingShuDreamingConsolidator.consolidateDesignInsights(samples: designSamples, minSamples: 1, distill: distill) {
            LingShuDesignKB.writeDesignInsights(insights)
            appendTrace(kind: .result, actor: "固化", title: "用户反馈已固化进 DesignKB",
                        detail: "据用户设计反馈更新设计经验 overlay,下次做 PPT 即遵守(apply_skill 注入)。")
        }
    }

    /// 任务收尾后调用:满足空闲 + 节流则在后台静默触发一次离线固化(不阻塞当前流程)。
    func scheduleDreamingConsolidationIfIdle() {
        guard !hasActiveModelCall else { return }                  // 正在作答/执行 → 不打扰
        let minInterval: TimeInterval = 3600                       // 至少隔 1h 才再固化一次
        if let last = lastDreamConsolidationAt, Date().timeIntervalSince(last) < minInterval { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)     // 静默 20s 确认确实空闲(用户没接着发指令)
            guard let self, !self.hasActiveModelCall else { return }
            if await self.agentOrchestrator.runningCount() > 0 { return }   // 还有子任务在跑 → 让位
            await self.runDreamingConsolidation()
        }
    }

    /// 执行一次离线固化:回放样本 → 挖候选 → 蒸馏纯提示 skill → 落盘。
    func runDreamingConsolidation() async {
        lastDreamConsolidationAt = Date()

        // 0. 知识图谱轨(记忆 v2):从近期对话蒸馏原子事实并入图谱 + 园丁维护。放最前、独立于下面的技能/设计轨早返回,
        //    保证每次 dreaming 都会维护知识图谱(衰减/补链/剪枝)。全程 guarded,失败只跳过。详见 +KnowledgeGraphDreaming。
        await consolidateKnowledgeGraph()

        // 1. 回放样本:终态的交付型任务(完成=成功;未达标/异常=失败,用于算通过率)。热 + 冷一起看。
        let samples: [LingShuDreamingConsolidator.Sample] = taskExecutionRecordLookup.compactMap { record in
            // 用户点踩(👎)的输出不当成功样本——别从用户不满意的产出里学经验。
            let disliked = taskRecordFeedback[record.id] == false
            switch record.status {
            case .completed:
                return .init(prompt: record.prompt, summary: record.summary, succeeded: !disliked)
            case .needsRevision, .blocked:
                return .init(prompt: record.prompt, summary: record.summary, succeeded: false)
            default:
                return nil   // 排队/执行中/直接回答(无交付物)不进固化样本
            }
        }
        guard samples.count >= 3 else { return }

        // 2. 已被现有 skill(策展 + 用户自有)覆盖的领域不重复固化(尤其不覆盖打磨过的策展 PPT)。
        var existingDomains = Set(LingShuCuratedSkillRegistry.skills.map(\.domain))
        for userSkill in LingShuSkillLoader.loadSkills() {
            for entry in LingShuDreamingConsolidator.knownDomains
            where userSkill.triggers.contains(where: { trigger in entry.triggers.contains { $0.lowercased() == trigger.lowercased() } }) {
                existingDomains.insert(entry.domain)
            }
        }

        let candidates = LingShuDreamingConsolidator.candidates(from: samples, existingDomains: existingDomains)
        let designSamples: [LingShuDreamingConsolidator.DesignSample] = taskExecutionRecordLookup.compactMap { record in
            guard let score = record.designScore,
                  LingShuDreamingConsolidator.domain(for: record.prompt)?.domain == "presentation" else { return nil }
            return .init(prompt: record.prompt, score: score, liked: taskRecordFeedback[record.id], issues: record.designIssues)
        }
        // 两条进化轨都没料就早退;否则任一有料就跑。
        guard !candidates.isEmpty || designSamples.count >= 3 else { return }
        appendTrace(kind: .model, actor: "固化", title: "dreaming 开始", detail: "回放 \(samples.count) 条任务,\(candidates.count) 个领域待固化,\(designSamples.count) 条 PPT 设计样本。")

        // 蒸馏器:注入一个无工具小会话做模型调用(无网络时返回空 → 自然跳过)。
        let adapter = makeAgentModelAdapter()
        let distill: @Sendable (String) async -> String = { prompt in
            let session = LingShuAgentSession(
                id: "dream-\(UUID().uuidString.prefix(6))",
                system: "你是经验固化器,只输出提炼后的要点,不写任何可执行代码/脚本。",
                tools: [],
                model: adapter,
                maxTurns: 1
            )
            if case .completed(let text) = await session.send(prompt) {
                return LingShuReasoningText.stripThinkTags(text)
            }
            return ""
        }

        // 设计进化轨(Phase C):从历史 PPT 的设计分 + 👍👎 提炼可复用设计经验,写入 DesignKB overlay(纯文字、热加载)。
        if let insights = await LingShuDreamingConsolidator.consolidateDesignInsights(samples: designSamples, distill: distill) {
            LingShuDesignKB.writeDesignInsights(insights)   // 纯文字 + sanitize 过,红线安全
            appendTrace(kind: .result, actor: "固化", title: "dreaming 设计进化",
                        detail: "据 \(designSamples.count) 次 PPT 设计分提炼设计经验,已写入 DesignKB(下次做 PPT 即生效)。")
        }

        // 技能固化轨(Phase 2):新领域蒸馏成纯提示 skill 落盘。
        let distilled = await LingShuDreamingConsolidator.consolidate(candidates: candidates, distill: distill)
        guard !distilled.isEmpty else { return }
        let directory = LingShuSkillLoader.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String] = []
        for skill in distilled {
            let url = directory.appendingPathComponent("dreamed-\(skill.domain).md")
            if (try? skill.markdown.write(to: url, atomically: true, encoding: .utf8)) != nil {
                written.append(skill.domain)
            }
        }
        if !written.isEmpty {
            // 热重载:免重启即时生效——固化出来的 skill 当场并入组合注册表。
            (expertProfileRegistry as? LingShuCompositeExpertRegistry)?.reloadUserSkills()
        syncExtensionEnablement()
            appendTrace(kind: .result, actor: "固化", title: "dreaming 完成",
                        detail: "自固化 skill(纯提示,已热加载即时生效):\(written.joined(separator: "、"))。")
        }
    }
}
