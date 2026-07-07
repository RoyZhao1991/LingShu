import XCTest
@testable import LingShuMac

/// 角色管线把规划阶段镜像进 `record.plan` 的回归(2026-06-27 用户实测:右侧面板对 @Claude→@Codex 这类任务没有「执行步骤」)。
/// 根因:角色管线走确定性阶段、不经大脑 `update_plan` → `record.plan` 一直为空 → 右侧 `progressSection`(只在 `!plan.isEmpty` 渲染)被隐藏,
/// 阶段只在左侧出参与方气泡。修复:`mirrorRolePipelinePlan` 把各环镜像成分步计划,`setRolePipelinePlanStatus` 逐环打钩。
@MainActor
final class RolePipelinePlanMirrorTests: XCTestCase {

    private func steps() -> [LingShuRoleStep] {
        [
            LingShuRoleStep(roleID: "engineer", roleTitle: "工程执行专家", agentID: "claude", agentName: "Claude", subtask: "写 H5 3D 超级玛丽"),
            LingShuRoleStep(roleID: "reviewer", roleTitle: "评审官", agentID: "codex", agentName: "Codex", subtask: "验收")
        ]
    }

    /// 镜像后:右侧据以渲染的 `record.plan` 不再为空,步骤名 = 角色（agent）、初始全 pending。
    func testMirrorPopulatesPlanSoRightPanelShowsSteps() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "@Claude 写个 H5 的 3D 超级玛丽，@Codex 验收")
        defer { state.taskExecutionRecords.removeAll { $0.id == rid }; state.persistTaskExecutionRecords() }

        // 镜像前:plan 空 → 右侧分步计划隐藏(复现用户看到的现象)。
        XCTAssertTrue(state.taskExecutionRecords.first { $0.id == rid }?.plan.isEmpty ?? true,
                      "未镜像前角色管线任务的 plan 应为空(右侧无执行步骤)")

        state.mirrorRolePipelinePlan(steps(), recordID: rid)

        let plan = state.taskExecutionRecords.first { $0.id == rid }?.plan ?? []
        XCTAssertEqual(plan.count, 2, "两个角色应镜像成两步")
        XCTAssertFalse(plan.isEmpty, "镜像后 plan 非空 → 右侧分步计划会渲染")
        XCTAssertEqual(plan.map(\.title), ["工程执行专家（Claude）", "评审官（Codex）"], "步骤名=角色（担任 agent）")
        XCTAssertTrue(plan.allSatisfy { $0.status == .pending }, "初始全 pending")
    }

    /// 逐环推进打钩:工程执行环 in_progress→completed,只动那一环、不误动评审环。
    func testStatusAdvancesPerStage() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "角色管线打钩测试")
        defer { state.taskExecutionRecords.removeAll { $0.id == rid }; state.persistTaskExecutionRecords() }
        let s = steps()
        state.mirrorRolePipelinePlan(s, recordID: rid)

        state.setRolePipelinePlanStatus(s[0], status: .inProgress, recordID: rid)
        XCTAssertEqual(state.taskExecutionRecords.first { $0.id == rid }?.plan[0].status, .inProgress)
        XCTAssertEqual(state.taskExecutionRecords.first { $0.id == rid }?.plan[1].status, .pending, "只动工程执行环,评审环不受影响")

        state.setRolePipelinePlanStatus(s[0], status: .completed, recordID: rid)
        XCTAssertEqual(state.taskExecutionRecords.first { $0.id == rid }?.plan[0].status, .completed)

        // 评审环推进。
        state.setRolePipelinePlanStatus(s[1], status: .completed, recordID: rid)
        let plan = state.taskExecutionRecords.first { $0.id == rid }?.plan ?? []
        XCTAssertTrue(plan.allSatisfy { $0.status == .completed }, "两环都完成后全部打钩")
    }

    /// 模型编排出的 Loop 角色槽必须持久化到 record,供 UI/MCP/断点续跑读取。
    /// 这避免再从日志 actor 里猜参与者:显式要求 @Codex 复核时,即使 Codex 还没产生日志,也应先显示 checker 槽。
    func testRoleSlotsPersistPlannedMakerAndChecker() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "@Claude 生成报告，@Codex 复核报告")
        defer { state.taskExecutionRecords.removeAll { $0.id == rid }; state.persistTaskExecutionRecords() }

        state.bindRolePipelineSlots(steps(), recordID: rid)

        guard let record = state.taskExecutionRecords.first(where: { $0.id == rid }) else {
            return XCTFail("任务记录应存在")
        }
        XCTAssertEqual(record.roleSlots.count, 2)
        XCTAssertEqual(record.roleSlots.map(\.agentName), ["Claude", "Codex"])
        XCTAssertEqual(record.roleSlots.map(\.semanticRole), ["maker", "checker"])
        XCTAssertTrue(record.participants.contains("Claude"))
        XCTAssertTrue(record.participants.contains("Codex"))
        XCTAssertFalse(record.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "任务详情顶层 objective 不能再为空")
    }

    /// 槽位状态按 roleID + agent 双键推进,同一任务多个 agent 时不会串槽。
    func testRoleSlotStatusAdvancesIndependently() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "角色槽位状态推进测试")
        defer { state.taskExecutionRecords.removeAll { $0.id == rid }; state.persistTaskExecutionRecords() }
        let s = steps()
        state.bindRolePipelineSlots(s, recordID: rid)

        state.setRolePipelineSlotStatus(s[1], status: .running, recordID: rid)
        let slots = state.taskExecutionRecords.first { $0.id == rid }?.roleSlots ?? []

        XCTAssertEqual(slots.first { $0.agentName == "Claude" }?.status, .pending)
        XCTAssertEqual(slots.first { $0.agentName == "Codex" }?.status, .running)
    }
}
