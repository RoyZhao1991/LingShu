import Foundation

/// 通用中枢 P2·能力缺口分析**接线**(见 `Docs/通用AI中枢推进方案.md`)。
/// 执行前据「能力快照 + 自我扩展元能力」评估目标可行性、指出缺口 + 补齐路径,**绑定任务记录** →
/// `driveAgentDelivery` 注入执行引导(先补齐再推进)。与 P1 GoalSpec 同属前置认知,共用开关 `goalSpecEnabled`。
@MainActor
extension LingShuState {

    /// 据一条请求 + 当前能力快照派生能力缺口分析(模型 1-shot、无工具),落 trace。返回结果(失败 nil)。
    /// **不硬阻断**:有缺口也只是注入引导让大脑先按补齐路径取得能力,真补不了则如实告知用户。
    @discardableResult
    func deriveGapAnalysis(for request: String) async -> LingShuGapAnalysis? {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let snapshot = capabilitySnapshot()
        let session = LingShuAgentSession(
            id: "gap-\(UUID().uuidString.prefix(6))",
            system: LingShuGapAnalyzer.systemPrompt(capabilities: snapshot),
            tools: [], model: controlPlaneModelAdapter(.gapAnalysis), maxTurns: 1
        )
        guard case .completed(let text) = await session.send(trimmed) else { return nil }
        guard let parsed = LingShuGapAnalyzer.parse(LingShuReasoningText.stripThinkTags(text)) else {
            appendTrace(kind: .system, actor: "能力评估", title: "缺口分析解析失败",
                        detail: "模型未产出可解析的评估(本回合按无缺口评估执行,不影响)。")
            return nil
        }
        let analysis = reconcileGapAnalysisWithCapabilityGraph(parsed, contextText: trimmed)
        let title = analysis.feasibleNow && analysis.gaps.isEmpty ? "能力足够" : (analysis.hasBlockingGap ? "有阻断缺口" : "缺口可自补")
        appendTrace(kind: .system, actor: "能力评估", title: title, detail: analysis.summary)
        return analysis
    }

    /// 模型给出的缺口需要被能力图谱复核:模型可以发现未知缺口,但不能把**已验证的内核/本地能力**
    /// 臆测成"需要用户授权/凭据"。真正的权限阻断必须来自能力节点状态或工具真实失败。
    func reconcileGapAnalysisWithCapabilityGraph(_ analysis: LingShuGapAnalysis, contextText: String = "") -> LingShuGapAnalysis {
        var next = analysis
        let removed = next.gaps.filter { gap in
            referencesVerifiedBuiltInCapability(gap) ||
            referencesExplicitlySelectedRuntimeTool(gap, contextText: contextText) ||
            (gap.blocking && gap.requiresUser && referencesDeliveryOnlyUserConfirmation(gap)) ||
            referencesBareHumanActorAsBlockingGap(gap)
        }
        guard !removed.isEmpty else { return analysis }
        next.gaps.removeAll { gap in
            referencesVerifiedBuiltInCapability(gap) ||
            referencesExplicitlySelectedRuntimeTool(gap, contextText: contextText) ||
            (gap.blocking && gap.requiresUser && referencesDeliveryOnlyUserConfirmation(gap)) ||
            referencesBareHumanActorAsBlockingGap(gap)
        }
        if next.gaps.isEmpty { next.feasibleNow = true }
        let removedNames = removed.map(\.missing).joined(separator: "、")
        let suffix = "前置复核已剔除模型臆测的用户阻断缺口:\(removedNames)。"
        next.note = next.note.isEmpty ? suffix : "\(next.note) \(suffix)"
        return next
    }

    /// 交付播报/结果告知是回复层职责,不是能力缺口。模型偶尔会把
    /// "用户得到结果/文件路径告知"误判为 blocking human_confirmation,这里统一剔除。
    func referencesDeliveryOnlyUserConfirmation(_ gap: LingShuCapabilityGap) -> Bool {
        guard gap.kind == .humanConfirmation else { return false }
        let haystack = "\(gap.missing) \(gap.fillPath)"
        return LingShuAcceptancePlanner.isDeliveryCommunicationCriterion(haystack)
    }

    /// 需用户介入的缺口必须指向一个**受保护对象或高风险动作**。如果模型只产出
    /// "用户/主人/我" 这种参与者名,再配上泛化的"授权/凭据",它不是可执行前提,
    /// 只能说明模型在把交互对象误当能力对象。真实边界(外部账号、token、付款、
    /// 删除、物理设备等)仍保留,由权限闸/执行失败证据接管。
    func referencesBareHumanActorAsBlockingGap(_ gap: LingShuCapabilityGap) -> Bool {
        guard gap.blocking, gap.requiresUser, !gap.resolved else { return false }
        guard [.permission, .humanConfirmation].contains(gap.kind) else { return false }
        let target = Self.humanGapTarget(gap.missing)
        guard LingShuHumanBoundarySemantics.isBareHumanActorTarget(target) else { return false }
        let text = "\(gap.missing) \(gap.fillPath)"
        return !LingShuHumanBoundarySemantics.containsConcreteProtectedBoundary(text)
    }

    /// 判断缺口文本是否指向一个已验证的内置/本地能力。
    /// 这里用**能力节点与工具契约**做通用复核,不按业务目标写分支。
    func referencesVerifiedBuiltInCapability(_ gap: LingShuCapabilityGap) -> Bool {
        let haystack = "\(gap.missing) \(gap.fillPath)".lowercased()
        guard !haystack.isEmpty else { return false }

        if Self.referencesKnownNoCredentialBuiltInCapability(haystack) {
            return true
        }

        let safeBuiltInPermissions: Set<LingShuCapabilityPermission> = [
            .none, .readLocalFiles, .writeLocalFiles, .runCommand, .network, .speaker, .microphone, .camera
        ]
        return capabilityNodes().contains { node in
            guard node.isSchedulable, node.source == "builtin" || node.source == "local" else { return false }
            guard Set(node.requiredPermissions).isSubset(of: safeBuiltInPermissions) else { return false }
            let labels = [node.id, node.name, node.description, node.adapterID ?? ""].map { $0.lowercased() }
            return labels.contains { !$0.isEmpty && haystack.contains($0) }
        }
    }

    /// 用户已经显式点名一个**运行时已注册工具**时,能力评估模型不能再把同一目标臆测成
    /// "缺外部授权/缺工具"并阻断。真正的权限/凭据问题只应来自工具真实返回或执行层安全闸。
    /// 这里不写任何领域名:只做「请求中点名的工具」与「缺口文本」之间的通用词汇重合复核。
    func referencesExplicitlySelectedRuntimeTool(_ gap: LingShuCapabilityGap, contextText: String) -> Bool {
        guard gap.blocking, !gap.resolved else { return false }
        guard [.permission, .tool, .humanConfirmation].contains(gap.kind) else { return false }
        // Only match the missing target itself. `fillPath` often contains generic phrases such
        // as "需要用户授权/凭据"; using it for token overlap can make an unrelated named tool
        // appear to cover a real third-party permission gap.
        let text = gap.missing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? gap.fillPath
            : gap.missing
        return explicitlySelectedRuntimeTool(covers: text, in: contextText) != nil
    }

    /// 已注册在本机能力池、无需第三方登录/凭据的能力别名。它是能力层通用事实,
    /// 供 GapAnalysis、CapabilityRequirement、CapabilityProbe 共用,避免各链路重复误判。
    nonisolated static func noCredentialBuiltInCapabilityAliases() -> [String] {
        [
            "recall_local", "index_local_knowledge", "index_browser_history",
            "index_calendar", "index_mail", "index_photos", "recall_memory",
            "read_file", "list_directory", "search_text", "write_file",
            "edit_file", "apply_patch", "run_command", "fetch_url",
            "web_search", "list_capabilities",
            "local knowledge", "local recall", "local index", "memory recall",
            "本地知识库索引工具", "本机知识库索引工具", "本地知识索引工具", "本机知识索引工具",
            "本地知识库索引", "本机知识库索引", "本地知识索引", "本机知识索引",
            "本地召回工具", "本机召回工具", "本地知识检索工具", "本机知识检索工具",
            "本地知识检索服务", "本机知识检索服务", "本地索引服务", "本机索引服务",
            "本地知识库", "本机知识库", "本地知识", "本机知识"
        ]
    }

    nonisolated static func referencesKnownNoCredentialBuiltInCapability(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return noCredentialBuiltInCapabilityAliases().contains { lower.contains($0.lowercased()) }
    }

    /// 模型/子任务有时会绕过 P2 typed gap,在运行中把已注册的本地能力误说成"需要授权/凭据"。
    /// 这类交还不能进入 waitingForUser,否则会卡死派发队列;应由能力图谱事实纠偏后继续执行。
    func isBogusBuiltInCapabilityHandback(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        let asksForExternalAccess = [
            "授权", "凭据", "登录", "login", "credential", "api key", "apikey", "token", "access"
        ].contains { lower.contains($0) }
        guard asksForExternalAccess else { return false }
        let probe = LingShuCapabilityGap(kind: .permission, missing: trimmed, fillPath: trimmed, blocking: true)
        return referencesVerifiedBuiltInCapability(probe)
    }

    func builtInCapabilityCorrection(for handback: String) -> String {
        """
        【能力图谱纠偏】你刚才把已注册的本地内置能力误判为需要用户授权/凭据:
        \(handback)

        事实:这些工具/能力已在灵枢本机能力池中注册,不需要用户提供第三方登录或 API 凭据。请立即继续执行:
        1. 直接调用对应本地工具完成任务;
        2. 只有当工具真实返回 macOS 隐私权限/文件权限/访问失败时,才把真实错误和最小授权动作交还给用户;
        3. 不要再次要求用户为这些内置工具提供"登录/凭据/授权"。
        """
    }

    /// 把缺口分析绑定为记录的 typed 字段(持久化)+ 落记录时间线(有缺口才落,免噪声)。
    func bindGapAnalysis(_ analysis: LingShuGapAnalysis?, to recordID: String) {
        guard let analysis, let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let sanitized = reconcileGapAnalysisWithCapabilityGraph(analysis)
        taskExecutionRecords[idx].gapAnalysis = sanitized
        if !sanitized.gaps.isEmpty {
            appendTaskRecordMessage(recordID, actor: "能力评估", role: "缺口", kind: .core, text: sanitized.summary)
        } else {
            persistTaskExecutionRecords()
        }
    }

    /// 取某任务记录的 typed 缺口分析(单一真相 = 记录字段,跨重启可用)。
    func gapAnalysis(for recordID: String?) -> LingShuGapAnalysis? {
        guard let recordID,
              let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }),
              let raw = taskExecutionRecords[idx].gapAnalysis else { return nil }
        let sanitized = reconcileGapAnalysisWithCapabilityGraph(raw)
        if sanitized != raw {
            taskExecutionRecords[idx].gapAnalysis = sanitized
            persistTaskExecutionRecords()
        }
        return sanitized
    }

    /// P2 覆盖对齐:**已知是 task 型目标**的入口(自主真实目标 / spawn 子任务)统一前置认知——
    /// GoalSpec 先独立完成并通过结构校验,再并发派生能力缺口/需求。
    /// 核心目标重试耗尽时返回 false 并将记录收口为失败,调用方必须停止派生执行器。
    @discardableResult
    func bindPreflightCognition(request: String, recordID: String) async -> Bool {
        guard goalSpecEnabled else { return true }
        let spec: LingShuGoalSpec?
        if let existing = goalSpec(for: recordID) {
            spec = existing
        } else {
            spec = await deriveGoalSpec(for: request, taskRecordID: recordID)
        }
        guard !Task.isCancelled else { return false }
        guard let spec else {
            markGoalSpecPreflightFailure(
                request: request,
                recordID: recordID,
                appendChatIfMissing: false
            )
            return false
        }
        if goalSpec(for: recordID) == nil { bindGoalSpec(spec, to: recordID) }
        async let gapF = deriveGapAnalysis(for: request)
        async let reqF = deriveCapabilityRequirements(for: request)   // P2 真闭环:通用能力需求(查图谱)
        let analysis = await gapF
        let reqs = await reqF
        if gapAnalysis(for: recordID) == nil { bindGapAnalysis(analysis, to: recordID) }
        bindCapabilityRequirements(reqs, to: recordID)
        return true
    }
}
