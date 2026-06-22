import Foundation

/// 子代理/编排深度(差距6)的**纯逻辑核**:命名角色 + 依赖 DAG 的拓扑分层调度。
///
/// 同一个任务可以拆给**多个命名角色**(研究员/执行/审查… 名字由大脑命名,壳零硬编码),角色间可声明**依赖**
/// (B 依赖 A → A 的产出作为 B 的上下文)。这里把团队按依赖拓扑**分层**:每层内的角色互不依赖、可并行;
/// 层与层按序执行(后一层只依赖更早层)。检测环 / 未知依赖 / 重名。纯函数、可单测、无副作用、通用。
///
/// 跑层的执行(起隔离会话、传依赖产出、聚合)在 `LingShuState+AgentTeam`;可见性(命名角色卡)复用任务时间线。

/// 一个命名角色 agent 的声明。
struct LingShuRoleAgentSpec: Equatable, Sendable {
    let name: String          // 角色名(大脑命名,如"研究员" / "Kierkegaard")——团队内唯一
    let role: String          // 角色职责标签(如"调研" / "实现" / "审查")
    let objective: String     // 该角色要达成的目标(一句话)
    let dependsOn: [String]    // 依赖的其它角色名(它们的产出作为本角色上下文)
}

enum LingShuAgentDAG {

    enum Failure: Error, Equatable, CustomStringConvertible {
        case emptyTeam
        case duplicateName(String)
        case unknownDependency(agent: String, dep: String)
        case cycle([String])     // 处在环上的角色名(无法拓扑排序)
        var description: String {
            switch self {
            case .emptyTeam: return "团队为空(没有任何角色)"
            case .duplicateName(let n): return "角色重名:\(n)"
            case .unknownDependency(let a, let d): return "角色「\(a)」依赖了不存在的角色「\(d)」"
            case .cycle(let names): return "依赖成环,无法调度:\(names.joined(separator: " → "))"
            }
        }
    }

    // MARK: 解析 JSON 团队声明 → specs(容错别名:name、role、objective/goal、depends_on/dependsOn/deps)

    static func parse(_ json: String) -> [LingShuRoleAgentSpec]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = (obj["agents"] as? [[String: Any]]) ?? (obj["team"] as? [[String: Any]]) ?? (obj["roles"] as? [[String: Any]])
        else { return nil }
        var specs: [LingShuRoleAgentSpec] = []
        for a in raw {
            let name = ((a["name"] as? String) ?? (a["role"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let role = (a["role"] as? String) ?? name
            let objective = ((a["objective"] as? String) ?? (a["goal"] as? String) ?? (a["task"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let deps = (a["depends_on"] as? [String]) ?? (a["dependsOn"] as? [String]) ?? (a["deps"] as? [String]) ?? []
            specs.append(LingShuRoleAgentSpec(name: name, role: role, objective: objective,
                                              dependsOn: deps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        }
        return specs
    }

    // MARK: 拓扑分层(Kahn)——每层内可并行,层间按序

    /// 返回有序的层:`layers[0]` 无依赖、可先并行跑;`layers[n]` 只依赖更早层。层内按名字排序(确定性)。
    static func topologicalLayers(_ specs: [LingShuRoleAgentSpec]) -> Result<[[LingShuRoleAgentSpec]], Failure> {
        guard !specs.isEmpty else { return .failure(.emptyTeam) }

        var byName: [String: LingShuRoleAgentSpec] = [:]
        for s in specs {
            if byName[s.name] != nil { return .failure(.duplicateName(s.name)) }
            byName[s.name] = s
        }
        // 依赖必须指向存在的角色(忽略自依赖中的未知;自依赖本身会在环检测里暴露)。
        for s in specs {
            for d in s.dependsOn where byName[d] == nil {
                return .failure(.unknownDependency(agent: s.name, dep: d))
            }
        }

        var inDegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]   // dep → 依赖它的角色们
        for s in specs {
            let uniqueDeps = Set(s.dependsOn.filter { $0 != s.name })   // 去重 + 排除自依赖(自依赖→留给环检测)
            inDegree[s.name] = uniqueDeps.count + (s.dependsOn.contains(s.name) ? 1 : 0)
            for d in uniqueDeps { dependents[d, default: []].append(s.name) }
        }

        var layers: [[LingShuRoleAgentSpec]] = []
        var remaining = Set(specs.map(\.name))
        while !remaining.isEmpty {
            let ready = remaining.filter { (inDegree[$0] ?? 0) == 0 }.sorted()
            guard !ready.isEmpty else {
                // 没有入度 0 的 → 剩下的都在环上。
                return .failure(.cycle(remaining.sorted()))
            }
            layers.append(ready.compactMap { byName[$0] })
            for name in ready {
                remaining.remove(name)
                for dep in dependents[name] ?? [] { inDegree[dep, default: 0] -= 1 }
            }
        }
        return .success(layers)
    }
}
