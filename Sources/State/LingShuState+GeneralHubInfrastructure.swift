import Foundation

@MainActor
extension LingShuState {
    nonisolated static func loadWorldModelSnapshot() -> LingShuWorldModel {
        guard let data = UserDefaults.standard.data(forKey: "lingshu.worldModel.snapshot"),
              let model = try? JSONDecoder().decode(LingShuWorldModel.self, from: data) else {
            return LingShuWorldModel()
        }
        return model
    }

    func persistWorldModelSnapshot() {
        if let data = try? JSONEncoder().encode(worldModel) {
            UserDefaults.standard.set(data, forKey: "lingshu.worldModel.snapshot")
        }
    }

    func installGeneralHubInfrastructure() {
        let registry = capabilityProbeRegistry
        Task {
            await registry.register(LingShuGeneralCapabilityProbe())
        }
        recordWorldEntity(.init(id: "agent:lingshu", kind: .agent, name: "灵枢", attributes: [
            "role": "general_agent_hub",
            "scope": "goal_understanding,planning,orchestration,verification"
        ]))
        recordCapabilityNodesInWorldModel()
        recordWorldEvent(kind: .system, source: "灵枢", summary: "通用中枢基础设施已装载")
    }

    func recordWorldEntity(_ entity: LingShuWorldEntity) {
        worldModel.upsertEntity(entity)
        persistWorldModelSnapshot()
    }

    func recordWorldEvent(
        kind: LingShuWorldEventKind,
        source: String,
        summary: String,
        relatedEntityIDs: [String] = [],
        payload: [String: String] = [:],
        confidence: Double = 1
    ) {
        worldModel.recordEvent(.init(
            kind: kind,
            source: source,
            summary: summary,
            relatedEntityIDs: relatedEntityIDs,
            payload: payload,
            confidence: confidence
        ))
        persistWorldModelSnapshot()
    }

    func recordWorldTask(_ task: LingShuWorldTaskState) {
        worldModel.upsertTask(task)
        persistWorldModelSnapshot()
    }

    func worldTaskPhase(from status: LingShuTaskExecutionStatus) -> LingShuWorldTaskPhase {
        switch status {
        case .queued: return .waiting
        case .running, .dispatched, .acquiringCapability: return .executing
        case .analyzing: return .thinking
        case .ready: return .planning
        case .blocked, .waitingForUser, .suspended, .needsRevision, .partial: return .waiting
        case .completed, .answered, .verified: return .completed
        case .failed: return .failed
        }
    }

    // MARK: - Capability Probe

    func probedCapabilityEntries() -> [LingShuCapabilityEntry] {
        taskExecutionRecords
            .flatMap { $0.capabilityProbeObservations ?? [] }
            .filter { LingShuCapabilityVerb.parse($0.verb) != .humanConfirm }
            .filter { !Self.referencesKnownNoCredentialBuiltInCapability("\($0.capabilityID) \($0.description)") }
            .map { observation in
                let status = observation.status
                let permission: LingShuCapabilityPermissionState = status == .requiresAuth ? .needsAuth : .unknown
                return LingShuCapabilityEntry(
                    id: "probe:\(observation.capabilityID)",
                    verb: LingShuCapabilityVerb.parse(observation.verb),
                    description: observation.description,
                    source: "probe:\(observation.targetID)",
                    online: status != .unavailable && status != .unsafe,
                    permission: status == .available || status == .probable ? .granted : permission,
                    verified: false,
                    lastVerifiedAt: observation.observedAt
                )
            }
    }

    func probeCapabilityRequirements(_ requirements: [LingShuCapabilityRequirement], recordID: String?) async {
        let activeRequirements = normalizeCapabilityRequirementsForBuiltIns(requirements)
            .filter { $0.verb != .humanConfirm }
        guard let recordID, !activeRequirements.isEmpty else { return }
        // installGeneralHubInfrastructure also registers this probe, but that happens through
        // an unstructured Task during app boot. Re-register here so an immediate first user
        // command cannot race the registry and silently skip capability discovery.
        await capabilityProbeRegistry.register(LingShuGeneralCapabilityProbe())
        let graph = capabilityGraph()
        let targets = activeRequirements.compactMap { req -> LingShuProbeTarget? in
            switch graph.match(req) {
            case .satisfied:
                return nil
            case .needsAuth, .missing:
                return LingShuProbeTarget(
                    id: "target:\(req.verb.rawValue):\(req.target.hashValue)",
                    kind: Self.probeTargetKind(for: req.verb),
                    name: req.target.isEmpty ? req.verb.rawValue : req.target,
                    locator: nil,
                    metadata: ["verb": req.verb.rawValue, "detail": req.detail]
                )
            }
        }
        guard !targets.isEmpty else { return }
        var observations: [LingShuCapabilityProbeObservation] = []
        for target in targets {
            observations.append(contentsOf: await capabilityProbeRegistry.probe(target))
        }
        bindCapabilityProbeObservations(observations, to: recordID)
        if !observations.isEmpty {
            appendTaskRecordMessage(recordID, actor: "能力探测", role: "探测", kind: .core,
                                    text: capabilityProbeSummary(observations))
            recordWorldEvent(kind: .capability, source: "能力探测", summary: "完成 \(observations.count) 条能力探测观察", payload: [
                "recordID": recordID
            ])
            mergeCapabilityRequirementGaps(activeRequirements, graph: capabilityGraph(), into: recordID)
        }
    }

    func bindCapabilityProbeObservations(_ observations: [LingShuCapabilityProbeObservation], to recordID: String?) {
        guard !observations.isEmpty,
              let recordID,
              let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        var existing = taskExecutionRecords[index].capabilityProbeObservations ?? []
        for observation in observations where !existing.contains(where: { $0.capabilityID == observation.capabilityID && $0.targetID == observation.targetID }) {
            existing.append(observation)
        }
        taskExecutionRecords[index].capabilityProbeObservations = existing
        persistTaskExecutionRecords()
        recordCapabilityNodesInWorldModel()
    }

    nonisolated static func probeTargetKind(for verb: LingShuCapabilityVerb) -> LingShuProbeTargetKind {
        switch verb {
        case .externalSystemRead, .externalSystemWrite, .apiCall:
            return .service
        case .browserOperate, .localFileScan, .documentGenerate, .compute:
            return .software
        case .deviceDiscover, .deviceControl:
            return .device
        case .humanConfirm:
            return .unknown
        case .unknown:
            return .unknown
        }
    }

    nonisolated func capabilityProbeSummary(_ observations: [LingShuCapabilityProbeObservation]) -> String {
        observations.prefix(8).map { item in
            "- \(item.description) [\(item.status.rawValue), 置信度 \(String(format: "%.2f", item.confidence))]"
        }.joined(separator: "\n")
    }

    // MARK: - Effect Verification

    func effectVerificationReport(from acceptance: LingShuAcceptanceReport) -> LingShuEffectVerificationReport {
        let requirements = acceptance.verdicts.map { verdict -> LingShuEffectRequirement in
            LingShuEffectRequirement(
                id: Self.effectRequirementID(verdict),
                kind: Self.effectKind(for: verdict.kind),
                description: verdict.criterion,
                probe: verdict.evidence
            )
        }
        let evidence = acceptance.verdicts.map { verdict -> LingShuEffectEvidence in
            var payload: [String: String] = [
                "criterionKind": verdict.kind.rawValue,
                "acceptanceStatus": verdict.status.rawValue
            ]
            if verdict.status == .unmet { payload["status"] = "failed" }
            return LingShuEffectEvidence(
                requirementID: Self.effectRequirementID(verdict),
                source: "acceptance",
                summary: verdict.evidence,
                payload: payload,
                confidence: verdict.status == .met ? 0.95 : (verdict.status == .unmet ? 0.9 : 0.3)
            )
        }
        return LingShuEffectVerificationReport.make(requirements: requirements, evidence: evidence)
    }

    func bindEffectVerificationReport(_ report: LingShuEffectVerificationReport, to recordID: String?) {
        guard !report.verdicts.isEmpty,
              let recordID,
              let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        taskExecutionRecords[index].effectVerificationReport = report
        persistTaskExecutionRecords()
        recordWorldEvent(kind: .verification, source: "真实效果验收", summary: report.summary, payload: ["recordID": recordID])
    }

    func bindAndGateEffectVerification(_ acceptance: LingShuAcceptanceReport, taskRecordID: String?) -> (passed: Bool, critique: String)? {
        guard !acceptance.isEmpty else { return nil }
        let report = effectVerificationReport(from: acceptance)
        bindEffectVerificationReport(report, to: taskRecordID)
        if report.hasFailure {
            appendTrace(kind: .warning, actor: "真实效果验收", title: "效果证据未通过", detail: report.summary)
            return (false, report.summary)
        }
        if report.needsHuman {
            appendTrace(kind: .system, actor: "真实效果验收", title: "需要用户确认", detail: report.summary)
        }
        return nil
    }

    nonisolated static func effectRequirementID(_ verdict: LingShuCheckVerdict) -> String {
        "effect:\(verdict.kind.rawValue):\(verdict.criterion.hashValue)"
    }

    nonisolated static func effectKind(for kind: LingShuCriterionKind) -> LingShuEffectKind {
        switch kind {
        case .fileExists: return .file
        case .commandSucceeds: return .command
        case .deviceEffect: return .device
        case .environmentChange: return .environment
        case .userConfirmation: return .userConfirmation
        case .contentQuality: return .content
        case .unknown: return .unknown
        }
    }

    // MARK: - Adaptive Brain

    func adaptiveBrainProfiles() -> [LingShuBrainProfile] {
        let configs = brainTierConfigs()
        guard !configs.isEmpty else {
            return [.init(
                id: "current",
                displayName: "当前脑",
                capabilities: [.fastChat, .deepReasoning, .toolCalling, .codeExecution, .longContext, .highReliability],
                maxContextTokens: Int(contextBudget),
                latencyScore: 0.6,
                reliabilityScore: 0.7,
                costScore: 0.5,
                available: true
            )]
        }
        return configs.keys.sorted { $0.rank < $1.rank }.map { tier in
            LingShuBrainProfile(
                id: "tier:\(tier.rawValue)",
                displayName: "\(tier.rawValue)档",
                capabilities: Self.defaultCapabilities(for: tier),
                maxContextTokens: tier == .strong ? max(Int(contextBudget), 128_000) : (tier == .medium ? 64_000 : 24_000),
                latencyScore: tier == .weak ? 0.9 : (tier == .medium ? 0.65 : 0.35),
                reliabilityScore: tier == .strong ? 0.95 : (tier == .medium ? 0.75 : 0.55),
                costScore: tier == .weak ? 0.9 : (tier == .medium ? 0.55 : 0.25),
                available: true
            )
        }
    }

    func adaptiveBrainDemand(taskRecordID: String?, escalationCount: Int = 0) -> LingShuBrainTaskDemand {
        let spec = goalSpec(for: taskRecordID)
        let gap = gapAnalysis(for: taskRecordID)
        var required: Set<LingShuBrainCapability> = []
        var preferred: Set<LingShuBrainCapability> = [.highReliability]
        let kind = spec?.kind ?? .task
        if kind == .question {
            required.insert(.fastChat)
        } else {
            required.insert(.toolCalling)
        }
        if (spec?.constraints.count ?? 0) + (spec?.successCriteria.count ?? 0) >= 4 || (gap?.hasBlockingGap ?? false) || escalationCount > 0 {
            preferred.insert(.deepReasoning)
        }
        if (taskExecutionRecords.first(where: { $0.id == taskRecordID })?.capabilityRequirements ?? []).contains(where: { $0.verb == .apiCall || $0.verb == .externalSystemRead || $0.verb == .externalSystemWrite }) {
            required.insert(.toolCalling)
        }
        if Int(contextBudget) > 64_000 { preferred.insert(.longContext) }
        let risk: LingShuBrainRiskLevel = (gap?.blockingNeedsUser ?? false) ? .high : ((gap?.hasBlockingGap ?? false) ? .medium : .low)
        return .init(
            requiredCapabilities: required,
            preferredCapabilities: preferred,
            risk: risk,
            contextTokens: min(Int(contextBudget), 64_000),
            latencySensitive: kind == .question,
            privacySensitive: false
        )
    }

    nonisolated static func defaultCapabilities(for tier: LingShuBrainTier) -> Set<LingShuBrainCapability> {
        switch tier {
        case .weak:
            return [.fastChat, .lowCost]
        case .medium:
            return [.fastChat, .toolCalling, .codeExecution, .highReliability]
        case .strong:
            return [.deepReasoning, .toolCalling, .codeExecution, .visionReasoning, .longContext, .highReliability]
        }
    }

    // MARK: - Safe Self Evolution

    func safeEvolutionGateDecision(for proposal: LingShuImprovementProposal) -> LingShuEvolutionGateDecision {
        let level: LingShuEvolutionLevel
        let suggestion = proposal.suggestion.lowercased()
        if suggestion.contains("连接器") || suggestion.contains("adapter") {
            level = .adapter
        } else if suggestion.contains("策略") || suggestion.contains("提示") {
            level = .memoryLesson
        } else {
            level = .generatedTool
        }
        let risk = LingShuSafeSelfEvolutionPolicy.normalizedRisk(level: level, requestedRisk: .low)
        let safeProposal = LingShuEvolutionProposal(
            id: proposal.id,
            level: level,
            risk: risk,
            objective: proposal.theme,
            rationale: proposal.suggestion,
            trigger: .init(source: "goal_experience", symptom: proposal.theme, repeatedCount: proposal.occurrences),
            touchedAreas: ["external_capability"],
            validationPlan: proposal.safetyPipeline,
            rollbackPlan: "保留默认关闭的变体/能力登记,可一键禁用并删除已生成外围组件。",
            status: .pendingApproval,
            createdAt: proposal.at
        )
        return LingShuSafeSelfEvolutionPolicy.evaluate(safeProposal)
    }
}

struct LingShuGeneralCapabilityProbe: LingShuCapabilityProbe {
    let id = "general-capability-probe"
    let supportedTargetKinds: Set<LingShuProbeTargetKind> = Set(LingShuProbeTargetKind.allCases)

    func probe(_ target: LingShuProbeTarget) async -> [LingShuCapabilityProbeObservation] {
        let verb = target.metadata["verb"] ?? "unknown"
        let status: LingShuCapabilityProbeStatus
        let confidence: Double
        let description: String
        let targetText = "\(target.name) \(target.metadata["detail"] ?? "") \(verb)"
        if LingShuState.referencesKnownNoCredentialBuiltInCapability(targetText) {
            return [.init(
                targetID: target.id,
                capabilityID: "\(verb):\(target.name)",
                verb: LingShuCapabilityVerb.localFileScan.rawValue,
                description: "本机内置能力可覆盖:\(target.name)",
                status: .available,
                confidence: 0.9,
                evidence: ["builtin-local-capability"]
            )]
        }
        switch LingShuCapabilityVerb.parse(verb) {
        case .localFileScan, .documentGenerate, .compute, .browserOperate, .deviceDiscover:
            status = .available
            confidence = 0.88
            description = "内核或本机能力可覆盖:\(target.name)"
        case .externalSystemRead, .externalSystemWrite, .apiCall:
            status = .requiresAuth
            confidence = 0.75
            description = "外部系统能力需要探测接口/授权/连接器:\(target.name)"
        case .deviceControl:
            status = .requiresDriver
            confidence = 0.7
            description = "设备控制需要先发现设备、确认驱动和安全权限:\(target.name)"
        case .humanConfirm:
            return []
        case .unknown:
            status = .unknown
            confidence = 0.4
            description = "未知能力目标,需要进一步探测:\(target.name)"
        }
        return [.init(
            targetID: target.id,
            capabilityID: "\(verb):\(target.name)",
            verb: verb,
            description: description,
            status: status,
            confidence: confidence,
            evidence: ["probe:\(id)", "targetKind:\(target.kind.rawValue)"]
        )]
    }
}
