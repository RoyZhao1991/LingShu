import Foundation

/// P5 统一「扩展」模型:把 skill / MCP / 插件归一成一种东西,供一个列表统一管理(启停/版本/权限/效能)。
struct LingShuExtension: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case skill, mcp, plugin }
    var id: String
    var name: String
    var kind: Kind
    var version: String
    var permissionSummary: String
    var riskLevel: String            // low/medium/high(来自 PermissionChecker)
    var enabled: Bool
    var successCount: Int
    var failCount: Int

    var successRate: Double? {
        let total = successCount + failCount
        return total > 0 ? Double(successCount) / Double(total) : nil
    }
}

/// P4 扩展运行态(启停 + 效能计数)的**纯**持久状态:可单测,UserDefaults 仅做存取壳。
struct LingShuExtensionStateStore: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        var enabled: Bool = true
        var successCount: Int = 0
        var failCount: Int = 0
    }
    private(set) var records: [String: Record] = [:]

    /// 默认启用(没记录=启用),用户显式停用才记 false。
    func isEnabled(_ id: String) -> Bool { records[id]?.enabled ?? true }
    func record(_ id: String) -> Record { records[id] ?? Record() }

    mutating func setEnabled(_ id: String, _ on: Bool) {
        var r = records[id] ?? Record(); r.enabled = on; records[id] = r
    }
    /// P4 效能:一次使用结果回灌(任务成/败)。
    mutating func recordOutcome(_ id: String, success: Bool) {
        var r = records[id] ?? Record()
        if success { r.successCount += 1 } else { r.failCount += 1 }
        records[id] = r
    }
    /// 该不该自动降级:样本够(≥5)且成功率 < 1/3 → 建议降级/停用(差插件别一直推)。
    func shouldDemote(_ id: String) -> Bool {
        let r = record(id); let total = r.successCount + r.failCount
        guard total >= 5 else { return false }
        return Double(r.successCount) / Double(total) < (1.0 / 3.0)
    }
}
