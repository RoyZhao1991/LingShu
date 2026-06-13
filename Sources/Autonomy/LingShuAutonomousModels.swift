import Foundation

enum LingShuAutonomousRunPhase: String, Codable, CaseIterable, Identifiable {
    case idle = "未启用"
    case probing = "环境检测"
    case planning = "动态规划"
    case ready = "待授权"
    case running = "独立运行中"
    case paused = "已暂停"
    case completed = "已完成"
    case blocked = "已阻断"

    var id: String { rawValue }

    var isActive: Bool {
        switch self {
        case .idle, .completed, .blocked:
            return false
        case .probing, .planning, .ready, .running, .paused:
            return true
        }
    }
}

enum LingShuAutonomousPermissionLevel: String, Codable, CaseIterable, Identifiable {
    case observe = "观察模式"
    case delegated = "代理模式"
    case full = "完整授权"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .observe:
            return "只感知、分析、提醒，不主动操作文件和应用。"
        case .delegated:
            return "可在授权目录内生成产出物和调用工具，高风险动作仍需确认。"
        case .full:
            return "在干净设备或明确授权边界内自主推进，保留一键接管。"
        }
    }
}

enum LingShuAutonomousCheckLevel: String, Codable, Equatable {
    case pass = "通过"
    case warning = "降级"
    case failed = "不可用"
}

struct LingShuAutonomousCheckItem: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var level: LingShuAutonomousCheckLevel
    var detail: String
}

struct LingShuAutonomousEnvironmentReport: Codable, Equatable {
    var generatedAt: Date
    var items: [LingShuAutonomousCheckItem]

    var failedCount: Int {
        items.filter { $0.level == .failed }.count
    }

    var warningCount: Int {
        items.filter { $0.level == .warning }.count
    }

    var passCount: Int {
        items.filter { $0.level == .pass }.count
    }

    var canRun: Bool {
        failedCount == 0
    }

    var summaryLine: String {
        "环境检测：\(passCount) 项通过，\(warningCount) 项降级，\(failedCount) 项不可用"
    }
}

enum LingShuAutonomousRunbookStepStatus: String, Codable, Equatable {
    case waiting = "待执行"
    case running = "执行中"
    case completed = "已完成"
    case blocked = "已阻断"
}

struct LingShuAutonomousRunbookStep: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var owner: String
    var detail: String
    var status: LingShuAutonomousRunbookStepStatus
}

struct LingShuAutonomousRunbook: Codable, Equatable {
    var objective: String
    var assumptions: [String]
    var missingInformation: [String]
    var capabilityHints: [String]
    var expectedArtifacts: [String]
    var reviewGates: [String]
    var steps: [LingShuAutonomousRunbookStep]

    var summaryLine: String {
        "动态规划：\(steps.count) 个步骤，\(capabilityHints.count) 类能力，\(reviewGates.count) 个验收门"
    }
}

struct LingShuAutonomousSelfCheckReport: Codable, Equatable {
    var generatedAt: Date
    var items: [LingShuAutonomousCheckItem]

    var failedCount: Int {
        items.filter { $0.level == .failed }.count
    }

    var summaryLine: String {
        "自检：\(items.filter { $0.level == .pass }.count)/\(items.count) 项通过" + (failedCount > 0 ? "，存在阻断项" : "")
    }
}

struct LingShuAutonomousRunSnapshot: Codable, Equatable {
    var id: String
    var objective: String
    var phase: LingShuAutonomousRunPhase
    var permissionLevel: LingShuAutonomousPermissionLevel
    var environment: LingShuAutonomousEnvironmentReport?
    var selfCheck: LingShuAutonomousSelfCheckReport?
    var runbook: LingShuAutonomousRunbook?
    var statusLine: String
    var startedAt: Date?
    var updatedAt: Date

    static var idle: LingShuAutonomousRunSnapshot {
        .init(
            id: "autonomous-idle",
            objective: "",
            phase: .idle,
            permissionLevel: .delegated,
            environment: nil,
            selfCheck: nil,
            runbook: nil,
            statusLine: "独立运行未启用",
            startedAt: nil,
            updatedAt: Date()
        )
    }

    var isActive: Bool {
        phase.isActive
    }
}
