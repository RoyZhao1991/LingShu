import Foundation

struct LingShuAutonomousSelfCheckRunner {
    func run(
        environment: LingShuAutonomousEnvironmentReport,
        runbook: LingShuAutonomousRunbook,
        now: Date = Date()
    ) -> LingShuAutonomousSelfCheckReport {
        var items: [LingShuAutonomousCheckItem] = []
        items.append(.init(
            id: "environment",
            title: "环境完整性",
            level: environment.canRun ? .pass : .failed,
            detail: environment.summaryLine
        ))
        items.append(.init(
            id: "runbook",
            title: "动态流程",
            level: runbook.steps.isEmpty ? .failed : .pass,
            detail: runbook.summaryLine
        ))
        items.append(.init(
            id: "clarification",
            title: "缺失信息",
            level: runbook.missingInformation.isEmpty ? .pass : .warning,
            detail: runbook.missingInformation.isEmpty
                ? "目标信息足够进入授权执行。"
                : "仍建议确认：\(runbook.missingInformation.joined(separator: "、"))。"
        ))
        items.append(.init(
            id: "takeover",
            title: "人工接管",
            level: .pass,
            detail: "独立运行保留暂停、继续、停止三种接管动作。"
        ))
        items.append(.init(
            id: "review",
            title: "验收门",
            level: runbook.reviewGates.isEmpty ? .failed : .pass,
            detail: runbook.reviewGates.joined(separator: "、")
        ))

        return .init(generatedAt: now, items: items)
    }
}
