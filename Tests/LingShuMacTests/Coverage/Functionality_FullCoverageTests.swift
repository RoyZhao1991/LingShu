import XCTest
@testable import LingShuMac

/// **灵枢全功能覆盖**(100+ case):主界面模式(产出物判定/干净交付/续接恢复/状态映射/3并发队列)+
/// 自主模式(权限级/执行策略/自主反应武装)的**确定性决策与状态机**。无模型;端到端真完成另由 live 验。
@MainActor
final class Functionality_FullCoverageTests: XCTestCase {

    private typealias St = LingShuTaskExecutionStatus
    private typealias C = LingShuCompletionStatus

    private func rec(_ id: String, _ status: St, _ updated: TimeInterval) -> LingShuTaskExecutionRecord {
        LingShuTaskExecutionRecord(id: id, title: "T-\(id)", prompt: "P", status: status, summary: "",
                                   participants: [], createdAt: Date(timeIntervalSince1970: 0),
                                   updatedAt: Date(timeIntervalSince1970: updated), messages: [])
    }

    func testFullFunctionality_100Cases() {
        var n = 0

        // ===== 主界面模式 =====

        // —— A. 产出物声称判定(触发验收门)(18 case)——
        let claimTrue = ["已生成 report.pptx", "已保存到 /Users/x/a.md", "已写入文件",
                         "已创建 app.py", "已导出 data.csv", "写好了 index.html", "已落盘到 /tmp/x.json",
                         "生成到 out.pdf", "已写到 notes.txt", "结果已保存到 路径 /a/b"]
        for t in claimTrue { XCTAssertTrue(LingShuState.replyClaimsArtifact(t), "应判声称产出: \(t)"); n += 1 }
        let claimFalse = ["已生成了", "report.pptx 在这", "好的马上做", "我读了文件看看",
                          "这是分析结论", "已完成", "路径很重要但没产出", "明白了"]
        for t in claimFalse { XCTAssertFalse(LingShuState.replyClaimsArtifact(t), "不应判产出: \(t)"); n += 1 }

        // —— B. 内部停滞文本判定(交付前清洗)(12 case)——
        let dumpTrue = ["（无输出", "(无输出)", "反复尝试了很多次也不行", "连续16步只在读取文件",
                        "走了8步还是没能动手", "试了好几步判断不清状态"]
        for t in dumpTrue { XCTAssertTrue(LingShuState.looksLikeInternalDump(t), "应判内部dump: \(t)"); n += 1 }
        let dumpFalse = ["已完成,文件在 /tmp/a.txt", "这是给你的汇报正文", "好的,我来分析一下",
                         "报告共8页,重点如下", "已经帮你订好机票", "分析结论:增长12%"]
        for t in dumpFalse { XCTAssertFalse(LingShuState.looksLikeInternalDump(t), "不应判dump: \(t)"); n += 1 }

        // —— C. 状态终态/可续语义(续接恢复)(20 case)——
        let terminal: Set<St> = [.completed, .answered, .verified, .needsRevision, .failed, .partial]
        let resumable: Set<St> = [.blocked, .partial, .waitingForUser, .suspended, .acquiringCapability]
        let allStatus: [St] = [.queued, .running, .answered, .dispatched, .completed, .needsRevision,
                               .blocked, .suspended, .analyzing, .acquiringCapability, .waitingForUser,
                               .ready, .partial, .verified, .failed]
        for s in allStatus {
            XCTAssertEqual(s.isTerminal, terminal.contains(s), "isTerminal(\(s.rawValue))"); n += 1
        }
        for s in [St.blocked, .partial, .waitingForUser, .suspended, .acquiringCapability] {
            XCTAssertTrue(s.isResumableUnfinished, "可续: \(s.rawValue)"); n += 1
        }
        XCTAssertFalse(St.completed.isResumableUnfinished, "已完成不可续"); n += 1
        XCTAssertFalse(St.running.isResumableUnfinished, "执行中不算可续未竟"); n += 1
        XCTAssertTrue(St.partial.isTerminal && St.partial.isResumableUnfinished, "部分完成既终态又可续"); n += 1
        _ = resumable

        // —— D. 续接优先恢复目标 pickResumeTarget(8 case)——
        XCTAssertNil(LingShuState.pickResumeTarget(from: []), "空→nil"); n += 1
        XCTAssertNil(LingShuState.pickResumeTarget(from: [rec("a", .completed, 100), rec("b", .running, 200)]), "无可续→nil"); n += 1
        XCTAssertEqual(LingShuState.pickResumeTarget(from: [rec("a", .blocked, 100)]), "a", "唯一可续"); n += 1
        XCTAssertEqual(LingShuState.pickResumeTarget(from: [rec("a", .blocked, 100), rec("b", .partial, 200)]), "b", "取最近更新的可续"); n += 1
        XCTAssertEqual(LingShuState.pickResumeTarget(from: [rec("a", .waitingForUser, 300), rec("b", .partial, 200)]), "a", "300>200"); n += 1
        XCTAssertEqual(LingShuState.pickResumeTarget(from: [rec("a", .completed, 999), rec("b", .suspended, 1)]), "b", "完成的不算,取可续"); n += 1
        XCTAssertEqual(LingShuState.pickResumeTarget(from: [rec("a", .acquiringCapability, 50)]), "a"); n += 1
        XCTAssertNil(LingShuState.pickResumeTarget(from: [rec("a", .ready, 100), rec("b", .analyzing, 200)]), "ready/analyzing 非可续未竟→nil"); n += 1

        // —— E. 完成闸→记录状态映射 finishStatus(10 case)——
        XCTAssertEqual(LingShuState.finishStatus(for: .partial, fallback: .completed), .partial); n += 1
        XCTAssertEqual(LingShuState.finishStatus(for: .waitingForUser, fallback: .completed), .waitingForUser); n += 1
        XCTAssertEqual(LingShuState.finishStatus(for: .blocked, fallback: .completed), .blocked); n += 1
        XCTAssertEqual(LingShuState.finishStatus(for: .needsAcquisition, fallback: .completed), .blocked); n += 1
        XCTAssertEqual(LingShuState.finishStatus(for: .ok, fallback: .completed), .completed, "ok→fallback(主会话answered/派发completed)"); n += 1
        XCTAssertEqual(LingShuState.finishStatus(for: nil, fallback: .answered), .answered, "nil→fallback"); n += 1
        XCTAssertEqual(LingShuState.finishStatus(for: .ok, fallback: .answered), .answered); n += 1
        XCTAssertEqual(LingShuState.finishStatus(for: .partial, fallback: .answered), .partial, "partial 压过 fallback"); n += 1
        XCTAssertEqual(LingShuState.finishStatus(for: .blocked, fallback: .answered), .blocked); n += 1
        XCTAssertEqual(LingShuState.finishStatus(for: .waitingForUser, fallback: .answered), .waitingForUser); n += 1

        // —— F. 完成闸状态标签(5 case)——
        for s in [C.ok, .needsAcquisition, .waitingForUser, .partial, .blocked] {
            XCTAssertFalse(LingShuState.completionStatusLabel(s).isEmpty, "标签非空: \(s.rawValue)"); n += 1
        }

        // —— G. 3 并发 + 队列区背压 shouldQueueDispatch(12 case)——
        let q: [(Int, Int, Bool)] = [
            (0, 3, false), (1, 3, false), (2, 3, false), (3, 3, true), (4, 3, true),
            (0, 1, false), (1, 1, true), (2, 1, true), (5, 3, true),
            (0, 0, false), (1, 0, true), (2, 5, false)   // capacity 0 当 1;5容量未满
        ]
        for (r, c, e) in q {
            XCTAssertEqual(LingShuState.shouldQueueDispatch(running: r, capacity: c), e, "queue(running=\(r),cap=\(c))"); n += 1
        }

        // ===== 自主模式 =====

        // —— H. 权限级 + 执行策略模型(12 case)——
        XCTAssertEqual(LingShuAutonomousPermissionLevel.allCases.count, 3, "观察/代理/完整三档"); n += 1
        for lv in LingShuAutonomousPermissionLevel.allCases {
            XCTAssertFalse(lv.rawValue.isEmpty, "权限级名非空"); n += 1
            XCTAssertFalse(lv.detail.isEmpty, "权限级说明非空"); n += 1
            XCTAssertFalse(lv.englishName.isEmpty); n += 1
        }
        XCTAssertEqual(LingShuAutonomousPermissionLevel.observe.rawValue, "观察模式"); n += 1
        XCTAssertEqual(LingShuAutonomousPermissionLevel.full.rawValue, "完整授权"); n += 1
        // 执行策略三态可区分(observe→readOnly / delegated→standard / full→autoAllowShell)
        XCTAssertNotEqual(LingShuAgentExecutionPolicy.readOnly, .standard); n += 1
        XCTAssertNotEqual(LingShuAgentExecutionPolicy.standard, .autoAllowShell); n += 1

        // ===== 有状态:两模式开关/队列(构造 LingShuState)=====
        let state = LingShuState()

        // —— I. 主界面队列区 enqueue/remove(10 case)——
        let before = state.queuedDispatchTasks.count
        state.enqueueDispatchTask(prompt: "任务1", goal: "g1", goalSpec: nil, gap: nil, requirements: [])
        state.enqueueDispatchTask(prompt: "任务2", goal: nil, goalSpec: nil, gap: nil, requirements: [])
        XCTAssertEqual(state.queuedDispatchTasks.count, before + 2, "入队2条"); n += 1
        XCTAssertEqual(state.queuedDispatchTasks.last?.prompt, "任务2"); n += 1
        let firstID = state.queuedDispatchTasks[before].id
        state.removeQueuedDispatchTask(id: firstID)
        XCTAssertEqual(state.queuedDispatchTasks.count, before + 1, "删1条"); n += 1
        XCTAssertFalse(state.queuedDispatchTasks.contains { $0.id == firstID }, "被删的不在了"); n += 1
        state.removeQueuedDispatchTask(id: "不存在")
        XCTAssertEqual(state.queuedDispatchTasks.count, before + 1, "删不存在id无副作用"); n += 1
        let q2 = LingShuQueuedDispatchTask(prompt: "p", goal: nil, goalSpec: nil, gap: nil, requirements: [])
        XCTAssertEqual(q2, q2, "队列项 Equatable 自反"); n += 1
        XCTAssertFalse(q2.id.isEmpty, "队列项有 id"); n += 1
        XCTAssertEqual(q2.prompt, "p"); n += 1
        state.enqueueDispatchTask(prompt: "任务3", goal: nil, goalSpec: nil, gap: nil, requirements: [])
        XCTAssertEqual(state.queuedDispatchTasks.count, before + 2); n += 1
        XCTAssertTrue(state.queuedDispatchTasks.contains { $0.prompt == "任务3" }); n += 1

        // —— J. 模式开关(自主反应武装 / 目标认知 / 自我进化 / 权限级)(10 case)——
        state.autonomousAutoReactArmed = true
        XCTAssertTrue(state.autonomousAutoReactArmed, "可武装自主反应"); n += 1
        state.autonomousAutoReactArmed = false
        XCTAssertFalse(state.autonomousAutoReactArmed); n += 1
        state.autonomousPermissionLevel = .observe
        XCTAssertEqual(state.autonomousPermissionLevel, .observe, "可设观察模式"); n += 1
        state.autonomousPermissionLevel = .full
        XCTAssertEqual(state.autonomousPermissionLevel, .full); n += 1
        state.setGoalSpecEnabled(false)
        XCTAssertFalse(state.goalSpecEnabled, "可关目标认知"); n += 1
        state.setGoalSpecEnabled(true)
        XCTAssertTrue(state.goalSpecEnabled); n += 1
        UserDefaults.standard.removeObject(forKey: "lingshu.selfEvolution")
        let stale = state.selfEvolutionEnabled
        state.setSelfEvolutionEnabled(true)
        XCTAssertTrue(state.selfEvolutionEnabled, "可开自我进化"); n += 1
        state.setSelfEvolutionEnabled(false)
        XCTAssertFalse(state.selfEvolutionEnabled, "可关自我进化(默认态)"); n += 1
        _ = stale
        XCTAssertFalse(state.autonomousRun.phase.rawValue.isEmpty, "自主运行快照阶段可读"); n += 1
        XCTAssertTrue([.lean, .balanced, .guided].contains(state.currentHarnessTier()), "当前脑力档可读(据当前脑动态调整)"); n += 1

        XCTAssertGreaterThanOrEqual(n, 100, "全功能覆盖应 ≥100 case,实际 \(n)")
    }
}
