import XCTest
@testable import LingShuMac

/// 先计划后执行(LOOP 标准):update_plan 解析、计划落进记录、总用时格式化。
final class TaskPlanTests: XCTestCase {

    func testParsePlanStepsReadsTitlesAndStatuses() {
        let json = """
        {"steps":[
          {"title":"调取 PPT 设计技能","status":"completed"},
          {"title":"写 slides.json","status":"in_progress"},
          {"title":"跑生成器出 pptx","status":"pending"},
          {"title":"自检落盘","status":"待办"}
        ]}
        """
        let steps = LingShuState.parsePlanSteps(json)
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps[0].status, .completed)
        XCTAssertEqual(steps[1].status, .inProgress)
        XCTAssertEqual(steps[2].status, .pending)
        XCTAssertEqual(steps[3].status, .pending)
        XCTAssertEqual(steps[1].title, "写 slides.json")
    }

    func testParsePlanStepsIgnoresEmpty() {
        XCTAssertTrue(LingShuState.parsePlanSteps("{}").isEmpty)
        XCTAssertTrue(LingShuState.parsePlanSteps("{\"steps\":[{\"title\":\"  \"}]}").isEmpty)
    }

    /// 回归:不同模型对数组参数序列化形状不一,曾全部解析失败→"计划为空"→模型放弃计划(LOOP 失效)。
    func testParsePlanStepsRobustToModelShapes() {
        // ① steps 为纯字符串数组(只给标题)
        let strArr = LingShuState.parsePlanSteps("{\"steps\":[\"找模板\",\"写 slides.json\",\"跑生成器\"]}")
        XCTAssertEqual(strArr.count, 3)
        XCTAssertEqual(strArr[0].title, "找模板")
        XCTAssertEqual(strArr[0].status, .pending)

        // ② steps 是被当成字符串又编码了一遍的数组
        let nested = LingShuState.parsePlanSteps("{\"steps\":\"[{\\\"title\\\":\\\"步骤一\\\",\\\"status\\\":\\\"in_progress\\\"}]\"}")
        XCTAssertEqual(nested.count, 1)
        XCTAssertEqual(nested[0].status, .inProgress)

        // ③ 顶层直接是对象数组(没有 steps 外壳)
        let topArr = LingShuState.parsePlanSteps("[{\"title\":\"A\"},{\"title\":\"B\",\"status\":\"done\"}]")
        XCTAssertEqual(topArr.count, 2)
        XCTAssertEqual(topArr[1].status, .completed)

        // ④ 换了键名(plan + step)
        let altKeys = LingShuState.parsePlanSteps("{\"plan\":[{\"step\":\"准备\",\"status\":\"pending\"}]}")
        XCTAssertEqual(altKeys.count, 1)
        XCTAssertEqual(altKeys[0].title, "准备")

        // ⑤ 顶层纯字符串数组
        let topStr = LingShuState.parsePlanSteps("[\"一\",\"二\"]")
        XCTAssertEqual(topStr.count, 2)
    }

    func testFormatElapsed() {
        XCTAssertEqual(LingShuState.formatElapsed(8), "8秒")
        XCTAssertEqual(LingShuState.formatElapsed(59.4), "59秒")
        XCTAssertEqual(LingShuState.formatElapsed(78), "1分18秒")
        XCTAssertEqual(LingShuState.formatElapsed(120), "2分")
    }

    @MainActor
    func testUpdatePlanToolWritesPlanToRecord() async {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "做个专业 PPT")
        state.currentAgentTurnRecordID = recordID

        let tool = state.updateTaskPlanTool(recordIDProvider: { state.currentAgentTurnRecordID })
        let out = await tool.handler("{\"steps\":[{\"title\":\"列大纲\",\"status\":\"in_progress\"},{\"title\":\"出稿\",\"status\":\"pending\"}]}")

        XCTAssertTrue(out.contains("执行计划"), "应回报已更新计划")
        let plan = state.taskExecutionRecords.first { $0.id == recordID }?.plan ?? []
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.first?.title, "列大纲")
        XCTAssertEqual(plan.first?.status, .inProgress)
    }
}
