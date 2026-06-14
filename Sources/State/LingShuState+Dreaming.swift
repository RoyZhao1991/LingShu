import Foundation

/// dreaming 离线固化的接线层(自进化 Phase 2)。
/// 空闲时回放已完成任务,经 `LingShuDreamingConsolidator` 蒸馏成纯提示 skill 落盘到用户 Skills 目录,
/// 下次启动 `LingShuSkillLoader` 自动加载并入组合注册表生效("醒来即更强")。
/// 安全红线由 consolidator 的 `sanitizePromptOnly` 结构性保证:只落纯提示,绝不写可执行脚本。
@MainActor
extension LingShuState {

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
            appendTrace(kind: .result, actor: "固化", title: "dreaming 完成",
                        detail: "自固化 skill(纯提示,已热加载即时生效):\(written.joined(separator: "、"))。")
        }
    }
}
