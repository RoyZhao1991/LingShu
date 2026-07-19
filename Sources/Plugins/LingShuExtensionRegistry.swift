import Foundation

/// P4/P5 扩展注册表:统一管理 skills + MCP 的**启停 / 版本 / 权限 / 效能**,持久化(UserDefaults)。
/// 纯状态在 `LingShuExtensionStateStore`(可单测);本类只做存取壳 + 聚合 + 发布。
@MainActor
final class LingShuExtensionRegistry: ObservableObject {
    static let shared = LingShuExtensionRegistry()

    @Published private(set) var store: LingShuExtensionStateStore
    private let key = "lingshu.extensions.state"

    init() {
        if let data = LingShuRuntimeEnvironment.preferences.data(forKey: key),
           let decoded = try? JSONDecoder().decode(LingShuExtensionStateStore.self, from: data) {
            store = decoded
        } else {
            store = LingShuExtensionStateStore()
        }
    }

    func isEnabled(_ id: String) -> Bool { store.isEnabled(id) }

    /// 当前被显式停用的 id 集合(供专家注册表过滤,real enforcement)。
    var disabledIDs: Set<String> { Set(store.records.filter { !$0.value.enabled }.map { $0.key }) }

    func setEnabled(_ id: String, _ on: Bool) { store.setEnabled(id, on); persist() }

    /// P4 效能:一次使用结果回灌(由 apply_skill 后任务成败调)。
    func recordOutcome(_ id: String, success: Bool) { store.recordOutcome(id, success: success); persist() }

    func shouldDemote(_ id: String) -> Bool { store.shouldDemote(id) }

    /// P5 聚合:把 skills + MCP 合成统一扩展列表(供面板展示/管理)。
    func extensions(skills: [LingShuSkillLoader.LoadedSkill], mcp: [LingShuMCPServerConfig]) -> [LingShuExtension] {
        var out: [LingShuExtension] = []
        for skill in skills {
            let manifest = skill.manifest
            let rec = store.record(skill.profile.id)
            out.append(LingShuExtension(
                id: skill.profile.id, name: skill.profile.title, kind: .skill, version: manifest.version,
                permissionSummary: manifest.permissionSummary,
                riskLevel: LingShuPluginPermissionChecker.riskLevel(manifest).rawValue,
                enabled: store.isEnabled(skill.profile.id),
                successCount: rec.successCount, failCount: rec.failCount))
        }
        for server in mcp {
            let rec = store.record(server.id)
            out.append(LingShuExtension(
                id: server.id, name: server.name, kind: .mcp, version: "—",
                permissionSummary: "外部 MCP 进程(自带工具)", riskLevel: "—",
                enabled: server.enabled,   // MCP 启停用其自身配置
                successCount: rec.successCount, failCount: rec.failCount))
        }
        return out.sorted { $0.kind.rawValue == $1.kind.rawValue ? $0.name < $1.name : $0.kind.rawValue < $1.kind.rawValue }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(store) { LingShuRuntimeEnvironment.preferences.set(data, forKey: key) }
    }
}
