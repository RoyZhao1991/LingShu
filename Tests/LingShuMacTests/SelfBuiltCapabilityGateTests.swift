import XCTest
@testable import LingShuMac

/// P2 完成闸·**防伪但不死板**回归(2026-06-23):
/// 模型用「自写脚本 + run_command 跑通」这种工程师式办法补齐外部能力(如自写 Notion 客户端跑出 200),
/// 应被识别为**真补齐**(完成闸不再把真做成误判成「没能完成」);而只嘴说/脚本没跑/跑了报错仍判 block(防伪不放松)。
@MainActor
final class SelfBuiltCapabilityGateTests: XCTestCase {

    private func msgFileEdit(_ path: String) -> LingShuTaskExecutionMessage {
        .init(actor: "灵枢", role: "动作", kind: .agent, text: "",
              detail: .fileEdit(path: path, operation: .modified, added: 10, removed: 0, diff: ""))
    }
    private func msgRun(_ ok: Bool, _ output: String) -> LingShuTaskExecutionMessage {
        .init(actor: "灵枢", role: "结果", kind: .agent, text: "",
              detail: .toolResult(tool: "run_command", success: ok, output: output))
    }
    private func msgRunCall(_ cmd: String) -> LingShuTaskExecutionMessage {
        .init(actor: "灵枢", role: "动作", kind: .agent, text: "",
              detail: .toolCall(tool: "run_command", summary: cmd, arguments: "{\"command\":\"\(cmd)\"}"))
    }

    private func record(messages: [LingShuTaskExecutionMessage]) -> LingShuTaskExecutionRecord {
        let gap = LingShuGapAnalysis(feasibleNow: false, gaps: [
            LingShuCapabilityGap(kind: .tool, missing: "Notion API 客户端工具", fillPath: "author_component 自写", blocking: true)
        ], note: "")
        var r = LingShuTaskExecutionRecord(id: "r-\(UUID().uuidString.prefix(6))", title: "同步Notion", prompt: "把三件待办同步到Notion",
                                           status: .running, summary: "", participants: [],
                                           createdAt: Date(), updatedAt: Date(), messages: messages)
        r.gapAnalysis = gap
        return r
    }

    private func outcome(_ messages: [LingShuTaskExecutionMessage]) -> LingShuAcquisitionOutcome {
        let state = LingShuState()
        let rec = record(messages: messages)
        let signals = state.acquisitionSignals(record: rec, requiresUser: false)
        return LingShuCapabilityAcquisition.classify(signals)
    }

    // —— 不死板:自写脚本 + 跑通 200 = 真补齐(acquiredVerified)——
    func testSelfBuiltScriptThatRanGreenIsAcquiredVerified() {
        let msgs = [
            msgFileEdit("/Users/example/app/sync_todos_to_notion.py"),
            msgRunCall("python3 sync_todos_to_notion.py"),
            msgRun(true, "✅ 创建页面状态码: 200\n✅ 页面URL: https://app.notion.com/p/2026-06-23-xyz\n📋 吃饭/睡觉/拉屎")
        ]
        XCTAssertEqual(outcome(msgs), .acquiredVerified, "自写脚本+跑通200 → 真补齐,完成闸不该判失败")
    }

    // —— 防伪 ①:写了脚本但跑出报错(Traceback)= 没补成 → 不算 verified ——
    func testSelfBuiltScriptThatErroredIsNotVerified() {
        let msgs = [
            msgFileEdit("/Users/example/app/sync_todos_to_notion.py"),
            msgRun(true, "Traceback (most recent call last):\n  File \"sync.py\", line 12\nKeyError: 'NOTION_TOKEN'")
        ]
        XCTAssertNotEqual(outcome(msgs), .acquiredVerified, "脚本跑出 Traceback → 不算真补齐(防伪)")
    }

    // —— 防伪 ②:exit 非0(success=false)= 没跑成 → 不算 verified ——
    func testSelfBuiltScriptNonZeroExitNotVerified() {
        let msgs = [msgFileEdit("/Users/example/app/sync.py"), msgRun(false, "some partial output")]
        XCTAssertNotEqual(outcome(msgs), .acquiredVerified, "命令失败(exit非0)→ 不算补齐")
    }

    // —— 防伪 ③:写了脚本但从没跑 = 只写没验证 → 不算 verified ——
    func testAuthoredButNeverRanIsNotVerified() {
        XCTAssertNotEqual(outcome([msgFileEdit("/Users/example/app/sync.py")]), .acquiredVerified,
                          "写了脚本但没跑 → 没最小验证,不算真补齐")
    }

    // —— 防伪 ④:没写脚本,只跑了个 echo = 没建能力 → notAttempted(仍驱动获取/block)——
    func testBareCommandWithoutAuthoringIsNotAcquisition() {
        let msgs = [msgRunCall("echo done"), msgRun(true, "done")]
        XCTAssertEqual(outcome(msgs), .notAttempted, "没自建工具、只跑命令 → 不算补齐缺失能力(防伪)")
    }

    // —— 防伪 ⑤:纯嘴说完成,零工具 = notAttempted ——
    func testNarrationOnlyIsNotAttempted() {
        let say = LingShuTaskExecutionMessage(actor: "灵枢", role: "核心", kind: .agent, text: "✅ 已全部同步完成")
        XCTAssertEqual(outcome([say]), .notAttempted, "只嘴说完成 → notAttempted(防伪)")
    }

    // —— 完成闸联动:真补齐 → 不再判 blocked(决策落到正常收尾)——
    func testGateDoesNotBlockGenuineSelfBuiltCompletion() async {
        let state = LingShuState()
        state.setGoalSpecEnabled(true)
        var rec = record(messages: [
            msgFileEdit("/Users/example/app/sync_todos_to_notion.py"),
            msgRun(true, "✅ 创建页面状态码: 200\n页面URL: https://app.notion.com/p/xyz")
        ])
        rec.goalSpec = LingShuGoalSpec(objective: "把三件待办同步到Notion", kind: .task)
        state.taskExecutionRecords.insert(rec, at: 0)
        let decision = await state.computeCompletionDecision(taskRecordID: rec.id, reply: "✅ 已把吃饭/睡觉/拉屎同步到 Notion,页面已创建。")
        XCTAssertNotEqual(decision.status, .blocked, "真自建补齐+跑通 → 完成闸不该判 blocked")
        XCTAssertNotEqual(decision.status, .needsAcquisition, "已补齐 → 不该再驱动获取")
    }

    // —— 防伪联动:嘴说完成但啥也没干 → 完成闸仍 needsAcquisition/blocked(不放过伪完成)——
    func testGateStillBlocksFakeCompletion() async {
        let state = LingShuState()
        state.setGoalSpecEnabled(true)
        var rec = record(messages: [
            LingShuTaskExecutionMessage(actor: "灵枢", role: "核心", kind: .agent, text: "✅ 已全部同步到 Notion")
        ])
        rec.goalSpec = LingShuGoalSpec(objective: "把三件待办同步到Notion", kind: .task)
        state.taskExecutionRecords.insert(rec, at: 0)
        let decision = await state.computeCompletionDecision(taskRecordID: rec.id, reply: "✅ 已全部同步到 Notion")
        XCTAssertNotEqual(decision.status, .ok, "嘴说完成、零真实补齐 → 完成闸不放过(防伪)")
    }

    // —— 辅助纯函数 ——
    func testHelpers() {
        XCTAssertTrue(LingShuState.isScriptArtifact("/a/b/sync.py"))
        XCTAssertTrue(LingShuState.isScriptArtifact("tool.js"))
        XCTAssertTrue(LingShuState.isScriptArtifact("run.sh"))
        XCTAssertFalse(LingShuState.isScriptArtifact("/a/report.pdf"))
        XCTAssertFalse(LingShuState.isScriptArtifact("notes.txt"))
        XCTAssertTrue(LingShuState.runOutputLooksFailed("Traceback (most recent call last):"))
        XCTAssertTrue(LingShuState.runOutputLooksFailed("zsh: command not found: foo"))
        XCTAssertTrue(LingShuState.runOutputLooksFailed("❌ 同步失败"))
        XCTAssertTrue(LingShuState.runOutputLooksFailed("401 Unauthorized"))
        XCTAssertFalse(LingShuState.runOutputLooksFailed("✅ 创建页面状态码: 200"))
        XCTAssertFalse(LingShuState.runOutputLooksFailed("all good, 3 rows written"))
    }
}
