import XCTest
@testable import LingShuMac

/// 通用中枢 P2 真闭环·防伪完成闸 + 能力获取分类(纯逻辑,无模型,通用零领域)。
final class TaskCompletionGateTests: XCTestCase {

    // MARK: 能力获取分类(最小验证)

    func testAcquisitionClassifyTriState() {
        XCTAssertEqual(LingShuCapabilityAcquisition.classify(.init(requiresUser: true)), .needsUser, "需用户类→needsUser")
        XCTAssertEqual(LingShuCapabilityAcquisition.classify(.init(requiresUser: false)), .notAttempted, "没试过→notAttempted")
        XCTAssertEqual(LingShuCapabilityAcquisition.classify(
            .init(requiresUser: false, attemptedSelfAcquire: true, acquireSucceeded: false)), .failed, "试了没成→failed")
        XCTAssertEqual(LingShuCapabilityAcquisition.classify(
            .init(requiresUser: false, attemptedSelfAcquire: true, acquireSucceeded: true, newCapabilityVerified: false)),
            .acquiredUnverified, "补到了但最小验证没过→acquiredUnverified")
        XCTAssertEqual(LingShuCapabilityAcquisition.classify(
            .init(requiresUser: false, attemptedSelfAcquire: true, acquireSucceeded: true, newCapabilityVerified: true)),
            .acquiredVerified, "补到+最小验证过→acquiredVerified")
    }

    func testOnlyAcquiredVerifiedResolvesGap() {
        XCTAssertTrue(LingShuAcquisitionOutcome.acquiredVerified.resolvesGap)
        XCTAssertFalse(LingShuAcquisitionOutcome.acquiredUnverified.resolvesGap, "未验证不算解除")
        XCTAssertFalse(LingShuAcquisitionOutcome.failed.resolvesGap)
        XCTAssertFalse(LingShuAcquisitionOutcome.needsUser.resolvesGap)
    }

    // MARK: 完成闸(spec 第14条通用用例)

    /// 缺 external_system.write(可自补)且还没试 → 进获取流程,不直接完成。
    func testSelfAcquirableGapNotAttemptedDrivesAcquisition() {
        let d = LingShuTaskCompletionGate.decide(.init(
            hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: false, unresolvedGapSelfAcquirable: true,
            acquisition: .notAttempted))
        XCTAssertEqual(d.status, .needsAcquisition, "可自补但没试→驱动获取,绝不直接完成")
    }

    /// 需用户授权 → waitingForUser。
    func testUserRequiredGapWaitsForUser() {
        let d = LingShuTaskCompletionGate.decide(.init(
            hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: true, unresolvedGapSelfAcquirable: false,
            acquisition: .needsUser))
        XCTAssertEqual(d.status, .waitingForUser, "需用户授权/凭据→明确阻断等用户,不伪完成")
    }

    /// 复合任务:A 成功(有成功标准达成)、B 因授权阻断 → partial。
    func testCompoundPartialWhenSomeMetSomeBlocked() {
        let d = LingShuTaskCompletionGate.decide(.init(
            hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: true,
            acquisition: .needsUser, someSuccessCriteriaMet: true))
        XCTAssertEqual(d.status, .partial, "部分完成+部分阻断→partial,不是 completed,也不是纯 waitingForUser")
    }

    /// 回复承认「无法接入/未授权」→ 禁止 verified(无任何达成→blocked)。
    func testAdmitsIncapacityForbidsVerified() {
        let d = LingShuTaskCompletionGate.decide(.init(replyAdmitsIncapacity: true))
        XCTAssertEqual(d.status, .blocked, "承认无能力且无达成→blocked,绝不当完成")
        let d2 = LingShuTaskCompletionGate.decide(.init(replyAdmitsIncapacity: true, someSuccessCriteriaMet: true))
        XCTAssertEqual(d2.status, .partial, "承认无能力但有部分达成→partial")
    }

    /// 成功标准部分达成、部分未达成 → partial。
    func testPartialFromCriteriaSplit() {
        let d = LingShuTaskCompletionGate.decide(.init(someSuccessCriteriaMet: true, someSuccessCriteriaUnmet: true))
        XCTAssertEqual(d.status, .partial)
    }

    /// 无缺口、未承认无能力、未见部分缺失 → ok(交既有验收/收尾流程,不越权)。
    func testCleanGoesOk() {
        XCTAssertEqual(LingShuTaskCompletionGate.decide(.init()).status, .ok)
        XCTAssertEqual(LingShuTaskCompletionGate.decide(.init(someSuccessCriteriaMet: true)).status, .ok, "全达成无未达成→ok")
    }

    /// 自补缺口已 acquiredVerified → 落回成功标准判,不再阻断。
    func testAcquiredVerifiedFallsThrough() {
        let d = LingShuTaskCompletionGate.decide(.init(
            hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: true,
            acquisition: .acquiredVerified, someSuccessCriteriaMet: true))
        XCTAssertEqual(d.status, .ok, "缺口已补齐+验证过→按成功标准走,不卡")
    }

    /// 尝试补齐但失败/未验证 → 无达成则 blocked、有达成则 partial(诚实,非伪完成)。
    func testAcquireFailedHonestlyBlocksOrPartial() {
        XCTAssertEqual(LingShuTaskCompletionGate.decide(.init(
            hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: true, acquisition: .failed)).status, .blocked)
        XCTAssertEqual(LingShuTaskCompletionGate.decide(.init(
            hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: true,
            acquisition: .acquiredUnverified, someSuccessCriteriaMet: true)).status, .partial)
    }

    // MARK: 通用承认语检测(非领域)

    func testReplyAdmitsIncapacityGeneric() {
        XCTAssertTrue(LingShuTaskCompletionGate.replyAdmitsIncapacity("结果:无法接入 Notion,我当前没有该 API 接入能力"))
        XCTAssertTrue(LingShuTaskCompletionGate.replyAdmitsIncapacity("未授权,需要你授权后我才能操作"))
        XCTAssertTrue(LingShuTaskCompletionGate.replyAdmitsIncapacity("暂时无法完成这一步"))
        XCTAssertFalse(LingShuTaskCompletionGate.replyAdmitsIncapacity("已完成,文件保存在 /tmp/out.txt"), "正常完成不应误判")
    }

    // MARK: 状态映射

    func testFinishStatusMapping() {
        XCTAssertEqual(LingShuState.finishStatus(for: .partial, fallback: .completed), .partial)
        XCTAssertEqual(LingShuState.finishStatus(for: .waitingForUser, fallback: .completed), .waitingForUser)
        XCTAssertEqual(LingShuState.finishStatus(for: .blocked, fallback: .completed), .blocked)
        XCTAssertEqual(LingShuState.finishStatus(for: .needsAcquisition, fallback: .completed), .blocked, "驱动到顶仍没补→blocked")
        XCTAssertEqual(LingShuState.finishStatus(for: .ok, fallback: .answered), .answered, "ok→用 fallback")
        XCTAssertEqual(LingShuState.finishStatus(for: nil, fallback: .completed), .completed)
    }

    // MARK: 不泄漏内部停滞文本(修"返回值很怪")

    func testInternalDumpDetection() {
        XCTAssertTrue(LingShuState.looksLikeInternalDump("（我连续 16 步只在读取查看、没能动手产出——这步我判断不清,先停下。最近看到：✓ run_command：（无输出，退出码 0）"))
        XCTAssertTrue(LingShuState.looksLikeInternalDump("（无输出，退出码 0）"))
        XCTAssertTrue(LingShuState.looksLikeInternalDump("反复尝试同一动作未果"))
        XCTAssertFalse(LingShuState.looksLikeInternalDump("已完成,文件在 /tmp/out.txt,含三张图表。"))
    }

    @MainActor
    func testHonestWaitingMessageIsCleanNoStallLeak() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "同步到 Notion")
        defer { state.taskExecutionRecords.removeAll { $0.id == rid }; state.persistTaskExecutionRecords(); state.taskExecutionJournal.flush() }
        state.bindGoalSpec(.init(objective: "把待办同步到 Notion", kind: .task), to: rid)
        state.bindGapAnalysis(.init(feasibleNow: false, gaps: [
            .init(kind: .humanConfirmation, missing: "Notion 集成 Token", fillPath: "去 notion.so/my-integrations 创建", blocking: true)
        ], note: ""), to: rid)
        let dump = "（我连续 16 步只在读取查看、没能动手产出——这步我判断不清,先停下。最近看到：✓ run_command：（无输出"
        let out = state.honestDeliveryText(decision: .init(status: .waitingForUser, reason: "需用户"), original: dump, taskRecordID: rid)
        XCTAssertFalse(out.contains("连续"), "不泄漏内部停滞文本")
        XCTAssertFalse(out.contains("无输出"), "不泄漏占位文本")
        XCTAssertTrue(out.contains("Notion 集成 Token"), "干净地说清需要用户给什么")
    }

    // MARK: 缺口解除 → 不再无限再问(修"给了 token 仍循环再问")

    func testResolvedGapStopsReAsking() {
        let blocking = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .permission, missing: "Notion Token", fillPath: "去创建集成", blocking: true)
        ], note: "")
        // 未解除:有阻断 + 需用户 → 完成闸 waitingForUser(会问)。
        XCTAssertTrue(blocking.hasBlockingGap)
        XCTAssertTrue(blocking.blockingNeedsUser)
        // 解除后:不再算阻断 → 完成闸不再据它问。
        var resolved = blocking
        resolved.gaps[0].resolved = true
        XCTAssertFalse(resolved.hasBlockingGap, "解除后无未解除阻断缺口")
        XCTAssertFalse(resolved.blockingNeedsUser)
        XCTAssertTrue(resolved.blockingGaps.isEmpty, "blockingGaps 只算未解除")
    }

    func testGapResolvedCodableBackCompat() throws {
        // 新:带 resolved 往返。
        var g = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .permission, missing: "Token", fillPath: "p", blocking: true)
        ], note: "")
        g.gaps[0].resolved = true
        let back = try JSONDecoder().decode(LingShuGapAnalysis.self, from: JSONEncoder().encode(g))
        XCTAssertTrue(back.gaps[0].resolved, "resolved 随记录持久化")
        // 旧:无 resolved 键 → 解码为 false(向后兼容,不崩)。
        let oldJSON = #"{"feasibleNow":false,"note":"","gaps":[{"kind":"permission","missing":"Token","fillPath":"p","blocking":true}]}"#
        let old = try JSONDecoder().decode(LingShuGapAnalysis.self, from: Data(oldJSON.utf8))
        XCTAssertFalse(old.gaps[0].resolved, "老记录无 resolved 键→false")
        XCTAssertTrue(old.hasBlockingGap, "老阻断缺口仍生效")
    }

    @MainActor
    func testResolveUserProvidedGapsUnblocks() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "同步 Notion")
        defer { state.taskExecutionRecords.removeAll { $0.id == rid }; state.persistTaskExecutionRecords(); state.taskExecutionJournal.flush() }
        state.bindGapAnalysis(.init(feasibleNow: false, gaps: [
            .init(kind: .permission, missing: "Notion Token", fillPath: "创建集成", blocking: true)
        ], note: ""), to: rid)
        if let i = state.taskExecutionRecords.firstIndex(where: { $0.id == rid }) { state.taskExecutionRecords[i].taskOutcome = .waitingForUser }
        XCTAssertTrue(state.gapAnalysis(for: rid)?.hasBlockingGap ?? false)
        state.resolveUserProvidedGaps(recordID: rid)
        XCTAssertFalse(state.gapAnalysis(for: rid)?.hasBlockingGap ?? true, "用户回应后阻断缺口解除→不再无限再问")
        XCTAssertNil(state.taskExecutionRecords.first { $0.id == rid }?.taskOutcome, "清旧裁决,据真实结果重判")
    }

    func testNewStatusSemantics() {
        XCTAssertTrue(LingShuTaskExecutionStatus.verified.isTerminal)
        XCTAssertTrue(LingShuTaskExecutionStatus.partial.isTerminal)
        XCTAssertFalse(LingShuTaskExecutionStatus.waitingForUser.isTerminal, "待用户是可续中间停,非终态")
        XCTAssertTrue(LingShuTaskExecutionStatus.waitingForUser.isResumableUnfinished)
        XCTAssertTrue(LingShuTaskExecutionStatus.partial.isResumableUnfinished)
        XCTAssertTrue(LingShuTaskExecutionStatus.blocked.isResumableUnfinished)
        XCTAssertFalse(LingShuTaskExecutionStatus.completed.isResumableUnfinished)
    }
}
