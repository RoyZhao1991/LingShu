import Foundation

/// 通用中枢 P2 真闭环·**能力图谱**(有状态、可查询的纯值类型,可单测)。
///
/// P2 旧版只有「扁平无状态能力快照」(`enumerateCapabilities`),够不上 spec 第3条要的图谱:
/// 这里给每条能力带**在线/权限/已验证**状态,可按通用动词([[LingShuCapabilityRequirement]])查询命中/需授权/缺失。
/// 动态注册(连 MCP / 自写组件)后 `upsert` 进图谱;**只有通过最小验证(真调通一次)才标 verified、才进 `usable` 可复用**。
enum LingShuCapabilityPermissionState: String, Codable, Sendable, Equatable {
    case granted    // 已授权可用
    case needsAuth  // 需账号授权/凭据
    case denied     // 被拒
    case unknown
}

struct LingShuCapabilityEntry: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var verb: LingShuCapabilityVerb?   // 通用动词(可空:内核原语/未归类)
    var description: String
    var source: String                 // builtin / mcp / skill / authored / external
    var online: Bool
    var permission: LingShuCapabilityPermissionState
    var verified: Bool                 // 是否通过最小验证(真调通一次)→ 才可复用
    var lastVerifiedAt: Date?

    init(id: String, verb: LingShuCapabilityVerb? = nil, description: String, source: String,
         online: Bool = true, permission: LingShuCapabilityPermissionState = .granted,
         verified: Bool = false, lastVerifiedAt: Date? = nil) {
        self.id = id; self.verb = verb; self.description = description; self.source = source
        self.online = online; self.permission = permission; self.verified = verified; self.lastVerifiedAt = lastVerifiedAt
    }

    /// 可复用 = 在线 + 已授权 + 已最小验证。
    var usable: Bool { online && permission == .granted && verified }
}

struct LingShuCapabilityGraph: Sendable, Equatable {
    var entries: [LingShuCapabilityEntry]

    init(entries: [LingShuCapabilityEntry] = []) { self.entries = entries }

    enum Match: Sendable, Equatable {
        case satisfied(LingShuCapabilityEntry)  // 有可用能力命中
        case needsAuth(LingShuCapabilityEntry)  // 有命中但需授权
        case missing                            // 没有命中
    }

    /// 查询某需求是否被满足。内核原语动词默认满足;否则按 verb 命中(可用→satisfied / 需授权→needsAuth)。
    /// hint(目标关键词)用于在同 verb 多条时优先描述命中的那条。
    func match(_ requirement: LingShuCapabilityRequirement) -> Match {
        if requirement.verb.satisfiedByKernel {
            return .satisfied(.init(id: "kernel:\(requirement.verb.rawValue)", verb: requirement.verb,
                                    description: "内核原语满足", source: "builtin", verified: true))
        }
        let hint = requirement.target.lowercased()
        let candidates = entries.filter { $0.verb == requirement.verb }
        let ranked = candidates.sorted { a, b in
            let ah = !hint.isEmpty && a.description.lowercased().contains(hint)
            let bh = !hint.isEmpty && b.description.lowercased().contains(hint)
            if ah != bh { return ah }
            return a.usable && !b.usable
        }
        if let usableHit = ranked.first(where: { $0.usable }) { return .satisfied(usableHit) }
        if let authHit = ranked.first(where: { $0.online && $0.permission == .needsAuth }) { return .needsAuth(authHit) }
        return .missing
    }

    /// 插入/更新一条能力(按 id)。
    mutating func upsert(_ entry: LingShuCapabilityEntry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = entry }
        else { entries.append(entry) }
    }

    /// 标记某能力**最小验证通过**(真调通一次)→ verified + 时间戳;此后才进 `usable`。
    @discardableResult
    mutating func markVerified(id: String, at: Date = Date()) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries[i].verified = true
        entries[i].lastVerifiedAt = at
        return true
    }

    /// 可复用的已验证能力(供执行/快照/复用)。
    var usable: [LingShuCapabilityEntry] { entries.filter { $0.usable } }
}
