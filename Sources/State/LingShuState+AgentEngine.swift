import Foundation

/// maker 引擎解析结果:用哪个引擎 + (localBrain 时)它的模型适配器。
/// externalCLI 引擎的执行接线见步骤2,届时 localAdapter 为 nil、走 CLI 委托。
struct LingShuMakerEnginePlan {
    let engine: LingShuAgentEngineDescriptor
    let localAdapter: LingShuGatewayAgentModel?
}

/// 一条派发任务的「评审绑定」:谁开发(maker)、谁验收(checker)、是否跨源(真独立)。
/// 创建子线程时解析并标注;验收时据 checker 真去复核(异源时换它)。
struct LingShuReviewBinding: Sendable, Equatable {
    let maker: LingShuAgentEngineDescriptor
    let checker: LingShuAgentEngineDescriptor
    let crossSource: Bool

    /// 人读标注:`maker: DeepSeek · checker: MiniMax(异源)`。
    var label: String {
        "maker: \(maker.providerLabel) · checker: \(checker.providerLabel)（\(crossSource ? "异源" : "同源")）"
    }
}

/// 步骤1·把「可用引擎池」接到 live 状态(只读枚举,不改任何派发行为)。
/// 这是后续 resolver(步骤4 选 maker/checker 组合)与派生接线(步骤1b)要消费的输入。
@MainActor
extension LingShuState {

    /// 当前可用的「派生 agent 引擎池」。
    /// - localBrain:当前主脑 + 已配各档脑(按 provider 去重,池内 availablePool 再去一次 id 重)。
    /// - externalCLI:Codex(登录即报可用,执行接线见步骤2);Claude Code 尚未接入(步骤3)恒不可用。
    /// 注:此处只**枚举可用性**,不创建会话、不发起调用——纯读。
    func availableAgentEngines() -> [LingShuAgentEngineDescriptor] {
        var descriptors: [LingShuAgentEngineDescriptor] = []

        // 当前主脑(灵枢自己干的默认引擎)。Codex 已从脑池删除,modelProvider 必为真 LLM。
        descriptors.append(.init(
            id: "localBrain:\(modelProvider.lowercased().trimmingCharacters(in: .whitespaces))",
            kind: .localBrain, providerLabel: modelProvider, available: true))

        // 已配的各档脑(多脑分层 → 多个可选 localBrain 源,使异源审查成为可能)。
        for (_, cfg) in brainTierConfigs() {
            let label = cfg.provider.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            descriptors.append(.init(
                id: "localBrain:\(label.lowercased())",
                kind: .localBrain, providerLabel: label,
                available: !cfg.endpoint.trimmingCharacters(in: .whitespaces).isEmpty))
        }

        // 外部 agent CLI:Codex —— 执行接线在步骤2,这里仅据登录态报可用性。
        descriptors.append(.init(
            id: "external:codex", kind: .externalCLI, providerLabel: "Codex",
            available: codexAuthStatus == "已登录"))

        // Claude Code —— 尚未接入(步骤3),恒不可用,占位以便 UI/日志看到「该源待接入」。
        descriptors.append(.init(
            id: "external:claude-code", kind: .externalCLI, providerLabel: "Claude Code",
            available: false))

        return LingShuAgentEngineRegistry.availablePool(descriptors)
    }

    /// 异源审查是否可用(池里存在 ≥2 个不同源的引擎)。供调用方决定是否能给 maker 配跨源 checker。
    var crossSourceReviewAvailable: Bool {
        let pool = availableAgentEngines()
        guard let first = pool.first else { return false }
        return pool.contains { LingShuAgentEngineRegistry.areCrossSource($0, first) }
    }

    /// 步骤1b·解析本任务 maker 该用的引擎(**行为不变**:maker 仍是当前复杂度路由出的本地脑;
    /// maker 的能力路由 / 外部委托是步骤2/4 的事)。localBrain 时同时给出其模型适配器。
    /// 注:内部只调一次 `routeBrainTier`(=原 `routedModelAdapter` 的等价路径),不产生额外「脑路由」trace。
    func resolveMakerEngine(taskRecordID: String?) -> LingShuMakerEnginePlan {
        let tier = routeBrainTier(taskRecordID: taskRecordID)
        let providerLabel = brainTierConfigs()[tier]?.provider ?? modelProvider
        let engine = LingShuAgentEngineDescriptor(
            id: "localBrain:\(providerLabel.lowercased().trimmingCharacters(in: .whitespaces))",
            kind: .localBrain, providerLabel: providerLabel, available: true)
        return .init(engine: engine, localAdapter: tierModelAdapter(tier))
    }

    /// 据已解析的 maker 挑 checker,组成评审绑定(异源优先)。checker 只在「验收现在能驱动的 localBrain 子集」里挑;
    /// 外部 agent(Codex/Claude)当 checker 待验收接外部驱动后再纳入。供创建子线程时**标注** + 验收复用。
    func reviewBinding(forMaker maker: LingShuAgentEngineDescriptor) -> LingShuReviewBinding {
        let localPool = availableAgentEngines().filter { $0.kind == .localBrain }
        let pool = localPool.contains(where: { $0.id == maker.id }) ? localPool : (localPool + [maker])
        let (checker, cross) = LingShuAgentEngineRegistry.pickChecker(forMaker: maker, from: pool.isEmpty ? [maker] : pool)
        return .init(maker: maker, checker: checker, crossSource: cross)
    }

    /// 取某 localBrain 引擎对应的模型适配器(供验收用指定 checker 复核)。外部引擎返回 nil(验收暂不驱动外部 agent)。
    func adapterForEngine(_ d: LingShuAgentEngineDescriptor) -> LingShuGatewayAgentModel? {
        guard d.kind == .localBrain else { return nil }
        if d.providerLabel.caseInsensitiveCompare(modelProvider) == .orderedSame {
            return makeAgentModelAdapter()
        }
        for (tier, cfg) in brainTierConfigs() where cfg.provider.caseInsensitiveCompare(d.providerLabel) == .orderedSame {
            return tierModelAdapter(tier)
        }
        return makeAgentModelAdapter()
    }

    /// 验收该用哪个 checker 适配器:有**跨源**绑定就用它(真异源复核);否则用原控制面验收脑(行为不变)。
    func checkerAdapter(taskRecordID: String?) -> LingShuGatewayAgentModel {
        if let rid = taskRecordID, let binding = taskReviewBindings[rid], binding.crossSource,
           let adapter = adapterForEngine(binding.checker) {
            return adapter
        }
        return controlPlaneModelAdapter(.deliveryReview, taskRecordID: taskRecordID)
    }
}
