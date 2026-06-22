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
        for cap in enumerateCapabilities() {
            graph.upsert(.init(id: cap.id, verb: nil, description: cap.description, source: cap.source,
                               online: true, permission: .granted, verified: true, lastVerifiedAt: nil))
        }
        for acquired in acquiredCapabilities() { graph.upsert(acquired) }
        return graph
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
            tools: [], model: makeAgentModelAdapter(), maxTurns: 1
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
        if !missing.isEmpty {
            appendTrace(kind: .system, actor: "能力需求", title: "需求查图谱",
                        detail: "需要 \(reqs.count) 项能力,\(missing.count) 项图谱未命中:" + missing.map { $0.verb.rawValue }.joined(separator: "、"))
        }
    }

    /// 已获取且可复用的能力(注入能力快照,让大脑下次同类目标直接复用,不必重新获取)。
    func acquiredCapabilitiesContext() -> String {
        let usable = acquiredCapabilities().filter { $0.usable }
        guard !usable.isEmpty else { return "" }
        return "- 已获取并验证可复用的能力:" + usable.prefix(16).map(\.description).joined(separator: "、")
    }
}
