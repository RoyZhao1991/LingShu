import XCTest
@testable import LingShuMac

final class SelfReferenceIntentTests: XCTestCase {
    func testReportContextSelfIntroductionIsDirectChat() {
        XCTAssertTrue(
            LingShuSelfReferenceIntent.isDirectAssistantSelfIntroduction("我在给老师汇报课题，介绍一下你自己")
        )
        XCTAssertTrue(
            LingShuSelfReferenceIntent.isDirectAssistantSelfIntroduction("我在给老师做报告，介绍一下你自己")
        )
        XCTAssertTrue(
            LingShuSelfReferenceIntent.isDirectAssistantSelfIntroduction("我的课题就是灵枢，你来介绍一下自己")
        )
    }

    func testArtifactRequestStillCountsAsDeliverableTask() {
        XCTAssertFalse(
            LingShuSelfReferenceIntent.isDirectAssistantSelfIntroduction("给我做一个介绍灵枢的 PPT")
        )
        XCTAssertTrue(
            LingShuSelfReferenceIntent.requestsConcreteDeliverable("给我做一个介绍灵枢的 PPT")
        )
        XCTAssertTrue(
            LingShuSelfReferenceIntent.requestsConcreteDeliverable("给我做个介绍灵枢的报告")
        )
    }

    @MainActor
    func testAskFormIsSuppressedForKnownSelfIntroductionTurn() async {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "我在给老师汇报课题，介绍一下你自己")
        state.currentAgentTurnRecordID = recordID
        let formCountBefore = state.chatMessages.filter { $0.form != nil }.count
        let result = await state.presentForm("""
        {"title":"课题汇报——AI助手介绍定制","fields":[
          {"key":"topic","question":"你的课题方向/研究领域是什么?","options":["软件工程","人工智能"]},
          {"key":"duration","question":"汇报时长/介绍篇幅","options":["30秒","1分钟"]}
        ]}
        """)

        XCTAssertTrue(result.contains("主体是灵枢本人"))
        let formCountAfter = state.chatMessages.filter { $0.form != nil }.count
        XCTAssertEqual(formCountAfter, formCountBefore, "本轮不应新增表单卡导致主线程挂起")
    }
}
