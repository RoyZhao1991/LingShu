import XCTest
@testable import LingShuMac

/// 嵌套分阶段循环(`.nested`)的机制层确定性测试:纯逻辑(规划解析/类型判定/互动完成信号/上下文交接)
/// + 状态机端到端(脚本模型驱动,无网络):规划→逐任务阶段验收→终验聚合;简单请求直通不分阶段。
final class NestedLoopTests: XCTestCase {

    // MARK: - shouldPlanStages(快路启发式,保守)

    func testShouldPlanStagesCatchesMultiStageBenchmarks() {
        XCTAssertTrue(LingShuNestedStagePlanner.shouldPlanStages("先写A,再写B,最后写C"))
        XCTAssertTrue(LingShuNestedStagePlanner.shouldPlanStages("先做一个PPT,做完后全屏演示讲解,然后答疑"))
        XCTAssertTrue(LingShuNestedStagePlanner.shouldPlanStages("做一个5页介绍长城的PPT全屏演示"))   // 互动词+制作词
        XCTAssertTrue(LingShuNestedStagePlanner.shouldPlanStages("依次生成三个文档"))
    }

    func testShouldNotPlanStagesForSimpleRequests() {
        XCTAssertFalse(LingShuNestedStagePlanner.shouldPlanStages("你好"))
        XCTAssertFalse(LingShuNestedStagePlanner.shouldPlanStages("现在几点"))
        XCTAssertFalse(LingShuNestedStagePlanner.shouldPlanStages("写一句话介绍泰山"))   // 单交付物,无顺序/互动信号
        XCTAssertFalse(LingShuNestedStagePlanner.shouldPlanStages("天气怎么样"))
        XCTAssertFalse(LingShuNestedStagePlanner.shouldPlanStages("并行做三件互不相关的小事"))   // 并行非有序→不分阶段,留给 spawn_task
    }

    // MARK: - 规划解析(容错)

    func testParsePlanParsesTaggedStages() {
        let text = """
        1. [任务] 制作一份介绍长城的PPT
        2. [互动] 全屏演示讲解这份PPT
        3. [互动] 回答提问
        """
        let stages = LingShuNestedStagePlanner.parsePlan(text, fallbackRequest: "x")
        XCTAssertEqual(stages.count, 3)
        XCTAssertEqual(stages[0].kind, .task)
        XCTAssertEqual(stages[1].kind, .interaction)
        XCTAssertEqual(stages[2].kind, .interaction)
        XCTAssertTrue(stages[0].title.contains("长城"))
    }

    func testParsePlanFallsBackToSingleTask() {
        let stages = LingShuNestedStagePlanner.parsePlan("（模型没给出结构化阶段）", fallbackRequest: "写个脚本")
        XCTAssertEqual(stages.count, 1)
        XCTAssertEqual(stages[0].kind, .task)
        XCTAssertEqual(stages[0].title, "写个脚本")
    }

    func testParseStageLineVariants() {
        XCTAssertEqual(LingShuNestedStagePlanner.parseStageLine("1、【任务】写文件")?.0, .task)
        XCTAssertEqual(LingShuNestedStagePlanner.parseStageLine("② [互动] 演示")?.0, .interaction)
        XCTAssertEqual(LingShuNestedStagePlanner.parseStageLine("- 演示讲解这份PPT")?.0, .interaction)   // 无标记按关键词
        XCTAssertEqual(LingShuNestedStagePlanner.parseStageLine("3) 生成报告")?.0, .task)
    }

    func testInferKindByKeyword() {
        XCTAssertEqual(LingShuNestedStagePlanner.inferKindByKeyword("全屏演示讲解"), .interaction)
        XCTAssertEqual(LingShuNestedStagePlanner.inferKindByKeyword("回答主人的提问"), .interaction)
        XCTAssertEqual(LingShuNestedStagePlanner.inferKindByKeyword("生成一份PPT"), .task)
    }

    func testStripLeadingOrdinal() {
        XCTAssertEqual(LingShuNestedStagePlanner.stripLeadingOrdinal("1. 写A"), "写A")
        XCTAssertEqual(LingShuNestedStagePlanner.stripLeadingOrdinal("12、做B"), "做B")
        XCTAssertEqual(LingShuNestedStagePlanner.stripLeadingOrdinal("① 演示"), "演示")
        XCTAssertEqual(LingShuNestedStagePlanner.stripLeadingOrdinal("- 列表项"), "列表项")
    }

    // MARK: - 互动完成信号

    func testIsInteractionDone() {
        XCTAssertTrue(LingShuNestedStagePlanner.isInteractionDone("没了"))
        XCTAssertTrue(LingShuNestedStagePlanner.isInteractionDone("可以了，结束吧"))
        XCTAssertTrue(LingShuNestedStagePlanner.isInteractionDone("好了"))
        XCTAssertTrue(LingShuNestedStagePlanner.isInteractionDone("没有其他问题了"))
        XCTAssertFalse(LingShuNestedStagePlanner.isInteractionDone("这一页再讲细一点"))   // 是追问,不是收口
        XCTAssertFalse(LingShuNestedStagePlanner.isInteractionDone("长城到底有多长"))
        XCTAssertFalse(LingShuNestedStagePlanner.isInteractionDone(""))
    }

    // MARK: - 退出演示命令 + 对话回复不误判交付(自主模式两个 bug 修复)

    func testIsExitPresentationCommand() {
        XCTAssertTrue(LingShuNestedStagePlanner.isExitPresentationCommand("退出演示"))
        XCTAssertTrue(LingShuNestedStagePlanner.isExitPresentationCommand("灵枢,关闭演示"))
        XCTAssertTrue(LingShuNestedStagePlanner.isExitPresentationCommand("结束放映吧"))
        XCTAssertTrue(LingShuNestedStagePlanner.isExitPresentationCommand("本轮汇报结束,关闭预览材料并收尾"))
        XCTAssertTrue(LingShuNestedStagePlanner.isExitPresentationCommand("不看了"))
        XCTAssertFalse(LingShuNestedStagePlanner.isExitPresentationCommand("下一页"))
        XCTAssertFalse(LingShuNestedStagePlanner.isExitPresentationCommand("这页讲细点"))
        XCTAssertFalse(LingShuNestedStagePlanner.isExitPresentationCommand(""))
    }

    /// 自主模式 bug:对比/解释类对话回复**不能**被判成"任务交付"(否则只念摘要,主人看不到聊天又听不到全文)。
    func testConversationalReplyNotTaskDelivery() {
        let compare = "Claude 和豆包是问答工具,寇 deux/Cursor 是代码工具,而灵枢是你的数字分身——能听、能说、能思考、能动手。我能直接操作你的电脑,做个 PPT 我直接做好文件放到你桌面上。"
        XCTAssertFalse(LingShuState.replyLooksLikeTaskDelivery(compare), "对比类对话(无显式产文件声称/路径/代码块)不该判任务交付→应念全文")
        // 真交付(声称产文件 + 路径)仍判交付 → 念摘要
        XCTAssertTrue(LingShuState.replyLooksLikeTaskDelivery("✅ PPT 已生成,产出物 /Users/example/app/x.pptx"))
    }

    // MARK: - 阶段上下文交接 + 终验聚合

    func testStageInputCarriesPriorContextAndConstraints() {
        let stage = LingShuNestedStage(title: "演示讲解", kind: .interaction)
        let input = LingShuNestedStagePlanner.stageInput(stage: stage, index: 1, total: 3, priorSummaries: ["已做好PPT:/tmp/a.pptx"], originalRequest: "做PPT并演示")
        XCTAssertTrue(input.contains("第 2/3 阶段"))
        XCTAssertTrue(input.contains("/tmp/a.pptx"))           // 前序产物交接
        XCTAssertTrue(input.contains("还需要我做什么吗"))        // 互动阶段不自行收尾
        let taskStage = LingShuNestedStage(title: "写脚本", kind: .task)
        let tInput = LingShuNestedStagePlanner.stageInput(stage: taskStage, index: 0, total: 2, priorSummaries: [], originalRequest: "x")
        XCTAssertTrue(tInput.contains("只做本阶段"))
        XCTAssertTrue(tInput.contains("绝对路径"))
    }

    func testAggregateSummaryNumbersStages() {
        let stages = [LingShuNestedStage(title: "A", kind: .task), LingShuNestedStage(title: "B", kind: .task)]
        let s = LingShuNestedStagePlanner.aggregateSummary(stages: stages, summaries: ["写好A:/tmp/a", "写好B:/tmp/b"])
        XCTAssertTrue(s.contains("1、"))
        XCTAssertTrue(s.contains("2、"))
        XCTAssertTrue(s.contains("/tmp/a"))
    }

    // MARK: - 状态机端到端(脚本模型,无网络,确定性)

    /// 多任务阶段:规划→阶段1验收→阶段2验收→终验聚合;验收被调 2 次(每任务阶段一次)。
    @MainActor
    func testNestedPipelineDrivesTaskStagesWithPerStageVerification() async {
        let box = HookBox()
        // 脚本:① 规划(2 个任务阶段)② 阶段1交付 ③ 阶段2交付。
        let model = LingShuScriptedAgentModel([
            .text("1. [任务] 写A\n2. [任务] 写B"),
            .text("已写好A,产出物 /tmp/a.txt"),
            .text("已写好B,产出物 /tmp/b.txt")
        ])
        let session = makeTestSession(id: "t1", model: model, box: box, verifyPasses: true)
        let result = await session.send("先写A,再写B")
        guard case .completed(let text) = result else { return XCTFail("应 completed,得 \(result)") }
        XCTAssertTrue(text.contains("1、"))   // 聚合带序号
        XCTAssertEqual(box.verifyCount, 2, "两个任务阶段各验收一次")
        XCTAssertTrue(box.noteTitles.contains("规划完成"))
        XCTAssertTrue(box.noteTitles.contains("终验"))
    }

    /// 简单请求:不分阶段,走 spine 直通(验收不被调用=与经典一致,对简单流程零影响)。
    @MainActor
    func testNestedPassthroughForSimpleRequestSkipsStaging() async {
        let box = HookBox()
        let model = LingShuScriptedAgentModel([.text("你好呀,我在。")])
        let session = makeTestSession(id: "t2", model: model, box: box, verifyPasses: true)
        let result = await session.send("你好")
        guard case .completed(let text) = result else { return XCTFail("应 completed") }
        XCTAssertEqual(text, "你好呀,我在。")
        XCTAssertEqual(box.verifyCount, 0, "简单请求不分阶段、不进阶段验收")
    }

    /// 互动阶段不验收 + 完成信号推进:任务阶段(验)→互动阶段(开场后等)→"没了"→终验。
    @MainActor
    func testInteractionStageNoVerifyAndAdvancesOnDoneSignal() async {
        let box = HookBox()
        let model = LingShuScriptedAgentModel([
            .text("1. [任务] 做PPT\n2. [互动] 演示讲解"),
            .text("已做好PPT,产出物 /tmp/x.pptx"),   // 任务阶段交付
            .text("演示讲完了,还需要我做什么吗?")       // 互动阶段开场
        ])
        let session = makeTestSession(id: "t3", model: model, box: box, verifyPasses: true)
        let first = await session.send("先做PPT,然后演示讲解")
        guard case .completed = first else { return XCTFail("互动阶段开场应交还 completed") }
        XCTAssertEqual(box.verifyCount, 1, "只有任务阶段被验收一次,互动阶段不验")
        // 主人示意结束 → 推进到终验完成。
        let second = await session.send("没了")
        guard case .completed = second else { return XCTFail("收口后应终验完成") }
        XCTAssertEqual(box.verifyCount, 1, "互动阶段始终不验收")
        XCTAssertTrue(box.noteTitles.contains("互动完成"))
        XCTAssertTrue(box.noteTitles.contains("终验"))
    }

    /// 打断 → 存断点(awaitingResume)→ "继续" 从**断点阶段**续(不重头、不重新规划),且入口复位打断标志(修旁路bug)。确定性证明。
    @MainActor
    func testInterruptSavesBreakpointThenResumesFromStage() async {
        let box = HookBox()
        // 运行中打断:第一次阶段验收后触发一次打断(模拟主人在第1阶段后插话)。
        box.armInterruptAfterFirstAccept = true
        let model = LingShuScriptedAgentModel([
            .text("1. [任务] 写A\n2. [任务] 写B"),
            .text("已写好A /tmp/a"),   // 阶段0 首跑
            .text("已写好A /tmp/a"),   // 阶段0 断点续接后重跑(从断点阶段续)
            .text("已写好B /tmp/b")    // 阶段1
        ])
        let session = makeTestSession(id: "ti", model: model, box: box, verifyPasses: true)
        // 第一次:规划→阶段0 执行+验收→验收后命中打断 → 存断点(awaitingResume 第0阶段)、停下交还。
        let first = await session.send("先写A,再写B")
        guard case .completed = first else { return XCTFail("打断应交还 completed") }
        XCTAssertTrue(box.noteTitles.contains("打断"), "运行中打断应存断点")
        XCTAssertEqual(box.noteTitles.filter { $0 == "规划完成" }.count, 1, "只规划一次")
        // "继续":awaitingResume 分支 → consumeInterrupt(复位标志=修旁路bug)→ 断点续接 → 从断点阶段跑完。
        let second = await session.send("继续")
        guard case .completed = second else { return XCTFail("继续应跑完") }
        XCTAssertTrue(box.noteTitles.contains("断点续接"), "应从断点续")
        XCTAssertEqual(box.noteTitles.filter { $0 == "规划完成" }.count, 1, "续接不重新规划(仍只 1 次)")
        XCTAssertTrue(box.noteTitles.contains("终验"), "续接后跑到终验完成")
        XCTAssertFalse(box.interrupted, "续接入口已消费/复位打断标志(内在修掉经典引擎的旁路bug)")
    }

    /// 任务阶段中途需要扫码/登录等人机协作时，必须冻结当前 inner 与阶段索引；恢复后续跑
    /// 原会话，再进入本阶段验收和后继阶段，不能把 blocked 误记成阶段交付，也不能重新规划。
    @MainActor
    func testTaskStageHumanInteractionResumesExactInnerWithoutReplanning() async {
        let box = HookBox()
        let interaction = #"""
        {
          "reply": "请扫码后继续。",
          "completion": {"status": "waiting_for_user", "reason": "等待扫码", "needs_user": true},
          "user_input": null,
          "human_interaction": {
            "kind": "qr_code",
            "title": "扫码登录",
            "prompt": "请扫描二维码完成登录",
            "payload": {},
            "options": [],
            "completion_probe": null,
            "resume_token": null,
            "source": "worker"
          },
          "inability": null,
          "OAuth": null
        }
        """#
        let model = LingShuScriptedAgentModel([
            .text("1. [任务] 登录并交付A\n2. [任务] 完成B"),
            .text(interaction),
            .text("登录完成，A 已交付 /tmp/a.txt"),
            .text("B 已交付 /tmp/b.txt")
        ])
        let session = makeTestSession(id: "human-stage", model: model, box: box, verifyPasses: true)

        let first = await session.send("先写A,再写B")
        guard case .blocked(let prompt) = first else { return XCTFail("阶段应暂停等待人机协作，实际为 \(first)") }
        XCTAssertEqual(
            LingShuWorkflowControlEnvelope.decode(from: prompt)?.humanInteraction?.kind,
            .qrCode
        )
        let blockedBeforeResume = await session.isBlocked
        XCTAssertTrue(blockedBeforeResume)
        XCTAssertEqual(box.verifyCount, 0, "暂停不是交付，不能提前进入阶段验收")

        let resumed = await session.resume("已扫码")
        guard case .completed(let text) = resumed else { return XCTFail("人工步骤完成后应跑完剩余阶段") }
        XCTAssertTrue(text.contains("/tmp/a.txt"))
        XCTAssertTrue(text.contains("/tmp/b.txt"))
        XCTAssertEqual(box.verifyCount, 2, "恢复后应依次验收当前阶段和后继阶段")
        XCTAssertEqual(box.noteTitles.filter { $0 == "规划完成" }.count, 1, "恢复不能重新规划")
        XCTAssertTrue(box.noteTitles.contains("人机协作完成"))
        let blockedAfterResume = await session.isBlocked
        XCTAssertFalse(blockedAfterResume)
    }

    // MARK: - 测试脚手架

    /// 测试用 hook 容器(只在 @MainActor 钩子里访问,单线程安全)。
    @MainActor final class HookBox {
        var verifyCount = 0
        var noteTitles: [String] = []
        var interrupted = false
        var armInterruptAfterFirstAccept = false   // 第一次阶段验收后触发一次打断(模拟运行中插话)
        var armedOnce = false
    }

    @MainActor
    private func makeTestSession(id: String, model: LingShuScriptedAgentModel, box: HookBox, verifyPasses: Bool) -> LingShuNestedAgentSession {
        LingShuNestedAgentSession(
            id: id, system: "测试系统提示", initialMessages: [], tools: [], model: model,
            maxTurns: 8, maxHistoryMessages: 0, blockingToolNames: ["ask_user"],
            // acceptStage 模拟:计一次验收,直接交还该阶段结果;可选在首次验收后触发一次"运行中打断"。
            acceptStage: { @MainActor _, stageResult, _ in
                box.verifyCount += 1
                if box.armInterruptAfterFirstAccept, !box.armedOnce { box.armedOnce = true; box.interrupted = true }
                return stageResult
            },
            note: { @MainActor title, _ in box.noteTitles.append(title) },
            setPhase: { @MainActor _ in },
            isInterrupted: { @MainActor in box.interrupted },
            consumeInterrupt: { @MainActor in box.interrupted = false }
        )
    }
}
