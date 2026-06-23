import Foundation

/// 通用中枢 P2 真闭环·**能力图谱接线**(见 [[LingShuCapabilityGraph]])。
/// 把现有扁平能力(`enumerateCapabilities`:已连 MCP / 固化技能,在线+已授权+视为已验证)
/// 与**已获取并最小验证通过**的能力(持久化)合成一张有状态图谱;动态注册(连 MCP / 自写组件)后写入,
/// **只有最小验证通过(真调通一次)才标 verified、才进 `usable` 可复用**。已验证的会进能力快照供下次复用(reuse 闭环)。
@MainActor
extension LingShuState {

    private static let acquiredCapabilitiesKey = "lingshu.capability.acquired"

    /// 当前能力图谱:现有扁平能力(视为已验证可用)+ 持久化的已获取能力。
    func capabilityGraph() -> LingShuCapabilityGraph {
        var graph = LingShuCapabilityGraph()
        for entry in Self.kernelCapabilityEntries() {
            graph.upsert(entry)
        }
        for cap in enumerateCapabilities() {
            graph.upsert(.init(id: cap.id,
                               verb: LingShuCapabilityVerb.infer(id: cap.id, description: cap.description, source: cap.source),
                               description: cap.description, source: cap.source,
                               online: true, permission: .granted, verified: true, lastVerifiedAt: nil))
        }
        for entry in probedCapabilityEntries() { graph.upsert(entry) }
        for acquired in acquiredCapabilities() { graph.upsert(acquired) }
        return graph
    }

    /// 内核和本体原生四肢也进入图谱,否则 P2 会把"浏览器自动化/本地生成"误判为缺能力。
    nonisolated static func kernelCapabilityEntries() -> [LingShuCapabilityEntry] {
        [
            .init(id: "kernel:local_file.scan", verb: .localFileScan, description: "内核原语:本机文件读取/搜索/扫描", source: "builtin", verified: true),
            .init(id: "kernel:document.generate", verb: .documentGenerate, description: "内核原语:本地生成文档、代码、报告、演示材料", source: "builtin", verified: true),
            .init(id: "kernel:compute", verb: .compute, description: "内核原语:本地计算与数据处理", source: "builtin", verified: true),
            .init(id: "kernel:browser.operate", verb: .browserOperate, description: "内核四肢:浏览器自动化、网页读取与交互", source: "builtin", verified: true),
            .init(id: "kernel:device.discover", verb: .deviceDiscover, description: "内核四肢:发现本机硬件、外设与传感器", source: "builtin", verified: true)
        ]
    }

    /// 持久化的已获取能力(跨重启可复用)。
    func acquiredCapabilities() -> [LingShuCapabilityEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.acquiredCapabilitiesKey),
              let list = try? JSONDecoder().decode([LingShuCapabilityEntry].self, from: data) else { return [] }
        return list
    }

    private func persistAcquiredCapabilities(_ list: [LingShuCapabilityEntry]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.acquiredCapabilitiesKey)
        }
    }

    /// 把一条**已获取**能力写入图谱。**最小验证未过(minVerified=false)→ 标 unverified、不可复用**(spec 第7条:验证失败不写入可用能力)。
    /// 返回是否写成「可复用」(在线+已授权+已验证)。
    @discardableResult
    func upsertAcquiredCapability(id: String, verb: LingShuCapabilityVerb?, description: String,
                                  source: String = "authored",
                                  permission: LingShuCapabilityPermissionState = .granted,
                                  minVerified: Bool) -> Bool {
        var list = acquiredCapabilities()
        let entry = LingShuCapabilityEntry(id: id, verb: verb, description: description, source: source,
                                           online: true, permission: permission,
                                           verified: minVerified, lastVerifiedAt: minVerified ? Date() : nil)
        if let i = list.firstIndex(where: { $0.id == id }) { list[i] = entry } else { list.append(entry) }
        persistAcquiredCapabilities(list)
        let usable = entry.usable
        appendTrace(kind: usable ? .result : .warning, actor: "能力图谱",
                    title: usable ? "已获取能力入图谱(可复用)" : "已获取但未通过最小验证(不可复用)",
                    detail: "\(description)")
        return usable
    }

    /// 从目标文本推导通用能力需求(模型 1-shot、无工具)。解析失败 → []。
    @discardableResult
    func deriveCapabilityRequirements(for goalText: String) async -> [LingShuCapabilityRequirement] {
        let trimmed = goalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let session = LingShuAgentSession(
            id: "capreq-\(UUID().uuidString.prefix(6))",
            system: LingShuCapabilityRequirementPlanner.systemPrompt,
            tools: [], model: controlPlaneModelAdapter(.capabilityRequirement), maxTurns: 1
        )
        guard case .completed(let text) = await session.send(trimmed) else { return [] }
        return LingShuCapabilityRequirementPlanner.parse(LingShuReasoningText.stripThinkTags(text))
    }

    /// 绑定能力需求到记录(typed,持久化)+ 查图谱标注未命中(信息性落 trace)。
    func bindCapabilityRequirements(_ reqs: [LingShuCapabilityRequirement], to recordID: String?) {
        guard !reqs.isEmpty, let recordID, let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        guard taskExecutionRecords[idx].capabilityRequirements == nil else { return }   // 幂等
        taskExecutionRecords[idx].capabilityRequirements = reqs
        persistTaskExecutionRecords()
        let graph = capabilityGraph()
        let missing = reqs.filter { if case .missing = graph.match($0) { return true }; return false }
        mergeCapabilityRequirementGaps(reqs, graph: graph, into: recordID)
        if !missing.isEmpty {
            appendTrace(kind: .system, actor: "能力需求", title: "需求查图谱",
                        detail: "需要 \(reqs.count) 项能力,\(missing.count) 项图谱未命中:" + missing.map { $0.verb.rawValue }.joined(separator: "、"))
        }
        Task { @MainActor [weak self] in
            await self?.probeCapabilityRequirements(reqs, recordID: recordID)
        }
    }

    /// P2 补齐:能力需求查图谱后的权威事实要进入 GapAnalysis,让 CompletionGate 能确定性驱动"找能力/要授权"。
    func mergeCapabilityRequirementGaps(_ reqs: [LingShuCapabilityRequirement], graph: LingShuCapabilityGraph, into recordID: String) {
        let gaps = reqs.compactMap { req -> LingShuCapabilityGap? in
            switch graph.match(req) {
            case .satisfied:
                return nil
            case .needsAuth(let entry):
                return .init(kind: .permission,
                             missing: "\(req.verb.rawValue):\(req.target.isEmpty ? entry.description : req.target)",
                             fillPath: "需要用户授权或提供凭据后启用 \(entry.description)",
                             blocking: true)
            case .missing:
                guard !req.verb.satisfiedByKernel else { return nil }
                return Self.gapFromMissingRequirement(req)
            }
        }
        guard !gaps.isEmpty, let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        var analysis = taskExecutionRecords[idx].gapAnalysis ??
            LingShuGapAnalysis(feasibleNow: false, gaps: [], note: "能力图谱前置核验发现缺口。")
        for gap in gaps where !analysis.gaps.contains(where: { $0.kind == gap.kind && $0.missing == gap.missing }) {
            analysis.gaps.append(gap)
        }
        if analysis.gaps.contains(where: { $0.blocking && !$0.resolved }) { analysis.feasibleNow = false }
        taskExecutionRecords[idx].gapAnalysis = analysis
        appendTaskRecordMessage(recordID, actor: "能力图谱", role: "缺口", kind: .core,
                                text: "能力图谱核验发现 \(gaps.count) 项待补能力,已并入完成闸。")
        persistTaskExecutionRecords()
    }

    nonisolated static func gapFromMissingRequirement(_ req: LingShuCapabilityRequirement) -> LingShuCapabilityGap {
        let target = req.target.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = target.isEmpty ? req.verb.rawValue : "\(req.verb.rawValue):\(target)"
        switch req.verb {
        case .externalSystemRead, .externalSystemWrite:
            return .init(kind: .tool, missing: name,
                         fillPath: "先查已连 MCP/连接器;没有则 discover_skill 或 author_component 补外部系统读写能力,必要时请求授权。",
                         blocking: true)
        case .apiCall:
            return .init(kind: .tool, missing: name,
                         fillPath: "先查已有 API 工具;没有则 author_component 编写受限 API 调用组件并最小验证。",
                         blocking: true)
        case .browserOperate:
            return .init(kind: .tool, missing: name,
                         fillPath: "补浏览器自动化/网页操作能力后再推进。",
                         blocking: true)
        case .deviceDiscover, .deviceControl:
            return .init(kind: .device, missing: name,
                         fillPath: "先 discover_devices 探测设备;控制真实设备前需要用户确认设备与权限。",
                         blocking: true)
        case .humanConfirm:
            // **防伪但不死板**(2026-06-23):能力需求规划器的 human.confirm 是**推测性**的(它常给自包含任务也安一个
            // "确认结果"),不该独立把已做完+已核验的任务卡成「待用户」。降级为**非阻断**(advisory):
            // ① 真需凭据/授权 → 对应外部动作会失败(401/错误),由 external_system 等缺口 + 真实失败证据兜住(防伪不放松);
            // ② 真需用户拍板 → 模型自己会 ask_user(走真 .blocked→waitingForUser 的合法路径),不靠这条推测缺口。
            return .init(kind: .humanConfirmation, missing: name,
                         fillPath: "如确需用户确认/凭据,执行中用 ask_user 主动索取;否则按自包含完成。",
                         blocking: false)
        case .localFileScan, .documentGenerate, .compute, .unknown:
            return .init(kind: .tool, missing: name, fillPath: "补齐对应通用工具能力。", blocking: true)
        }
    }

    /// 已获取且可复用的能力(注入能力快照,让大脑下次同类目标直接复用,不必重新获取)。
    func acquiredCapabilitiesContext() -> String {
        let usable = acquiredCapabilities().filter { $0.usable }
        guard !usable.isEmpty else { return "" }
        return "- 已获取并验证可复用的能力:" + usable.prefix(16).map(\.description).joined(separator: "、")
    }
}
