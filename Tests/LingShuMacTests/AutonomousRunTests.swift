import XCTest
@testable import LingShuMac

final class AutonomousRunTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-autonomous-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testEnvironmentProbeWarnsWhenFullAutonomyLacksFullExecutionPermission() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = LingShuAutonomousEnvironmentProbe().run(input: .init(
            workingDirectory: directory.path,
            modelProvider: "DeepSeek",
            modelName: "deepseek-chat",
            isModelConnected: true,
            modelConnectionState: "已连接",
            executionPermissionMode: .sandbox,
            requireHumanApproval: false,
            permissionLevel: .full,
            voiceOutputEnabled: true,
            voiceWakeListeningEnabled: true,
            memoryDigestAvailable: true,
            onlineAgentCount: 11,
            runningAgentCount: 0,
            pendingAgentCount: 11
        ))

        XCTAssertTrue(report.canRun)
        XCTAssertEqual(report.items.first { $0.id == "workspace" }?.level, .pass)
        XCTAssertEqual(report.items.first { $0.id == "artifact-root" }?.level, .pass)
        XCTAssertEqual(report.items.first { $0.id == "permission" }?.level, .warning)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("LingShuAutonomousRuns", isDirectory: true).path
        ))
    }

    func testRunbookPlannerBuildsPresentationFlowFromObjective() {
        let environment = LingShuAutonomousEnvironmentReport(generatedAt: Date(), items: [
            .init(id: "workspace", title: "工作区", level: .pass, detail: "ok"),
            .init(id: "model", title: "模型通道", level: .pass, detail: "ok")
        ])

        let runbook = LingShuAutonomousRunbookPlanner().plan(
            objective: "明天晚上学校课题规划汇报，3分钟，灵枢自主完成材料、汇报和答疑",
            permissionLevel: .delegated,
            environment: environment,
            memoryStatus: "已读取主线程记忆。"
        )

        XCTAssertTrue(runbook.missingInformation.isEmpty)
        XCTAssertTrue(runbook.capabilityHints.contains("汇报设计"))
        XCTAssertTrue(runbook.expectedArtifacts.contains("答疑库"))
        XCTAssertTrue(runbook.reviewGates.contains("时间控制"))
        XCTAssertTrue(runbook.steps.contains { $0.id == "live-qa" })
    }

    func testSelfCheckFailsWhenEnvironmentCannotRunAndWarnsOnMissingInformation() {
        let environment = LingShuAutonomousEnvironmentReport(generatedAt: Date(), items: [
            .init(id: "workspace", title: "工作区", level: .failed, detail: "缺少工作区")
        ])
        let runbook = LingShuAutonomousRunbook(
            objective: "做一次汇报",
            assumptions: [],
            missingInformation: ["截止时间", "汇报时长"],
            capabilityHints: ["规划"],
            expectedArtifacts: ["讲稿"],
            reviewGates: ["人工接管可用"],
            steps: [
                .init(id: "objective", title: "目标建模", owner: "灵枢", detail: "确认目标。", status: .waiting)
            ]
        )

        let selfCheck = LingShuAutonomousSelfCheckRunner().run(environment: environment, runbook: runbook)

        XCTAssertEqual(selfCheck.items.first { $0.id == "environment" }?.level, .failed)
        XCTAssertEqual(selfCheck.items.first { $0.id == "clarification" }?.level, .warning)
        XCTAssertEqual(selfCheck.failedCount, 1)
    }
}
