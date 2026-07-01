import XCTest
@testable import LingShuMac

/// 派发任务「附件直接入脑」接线(2026-06-28):`send(_:imageDataURLs:)` 设为协议**要求**,保证对
/// `any LingShuAgentSessioning` **动态派发到真实实现**(而非协议扩展默认静态派发把图悄悄忽略)。
/// 这是修复"派发任务只拿到 VL→文字摘要、多模态脑看不见真图"的关键一环——守住它别回退。
final class DispatchImagePassthroughTests: XCTestCase {

    /// 真带图实现:记录是否收到带图 send 及图内容。
    actor RecordingSession: LingShuAgentSessioning {
        var lastImages: [String]? = nil
        var sawImageSend = false
        nonisolated var isBlocked: Bool { false }
        var turnsUsed = 0
        var toolInvocations: [String] = []
        var messages: [LingShuAgentMessage] = []
        func setTextDeltaSink(_ sink: (@Sendable (String) async -> Void)?) {}
        func send(_ userText: String) async -> LingShuAgentRunResult { .completed(text: "ok") }
        func send(_ userText: String, imageDataURLs: [String]?) async -> LingShuAgentRunResult {
            sawImageSend = true; lastImages = imageDataURLs; return .completed(text: "ok")
        }
        func resume(_ answer: String) async -> LingShuAgentRunResult { .completed(text: "ok") }
        func continueLoop() async -> LingShuAgentRunResult { .completed(text: "ok") }
        func injectCorrection(_ text: String) -> Bool { false }
        func injectBriefing(_ text: String) {}
    }

    /// 没实现带图 send 的会话(非多模态)→ 用协议默认:忽略图、退回纯文本 send。
    actor TextOnlySession: LingShuAgentSessioning {
        var textSendCount = 0
        nonisolated var isBlocked: Bool { false }
        var turnsUsed = 0
        var toolInvocations: [String] = []
        var messages: [LingShuAgentMessage] = []
        func setTextDeltaSink(_ sink: (@Sendable (String) async -> Void)?) {}
        func send(_ userText: String) async -> LingShuAgentRunResult { textSendCount += 1; return .completed(text: "ok") }
        func resume(_ answer: String) async -> LingShuAgentRunResult { .completed(text: "ok") }
        func continueLoop() async -> LingShuAgentRunResult { .completed(text: "ok") }
        func injectCorrection(_ text: String) -> Bool { false }
        func injectBriefing(_ text: String) {}
    }

    /// 核心:对 `any LingShuAgentSessioning` 调带图 send,**必须动态派发到真实实现**、图原样送达。
    func testProtocolDynamicallyDispatchesImageSend() async {
        let mock = RecordingSession()
        let s: any LingShuAgentSessioning = mock
        _ = await s.send("看这张图", imageDataURLs: ["data:image/png;base64,AAA"])
        let saw = await mock.sawImageSend
        let imgs = await mock.lastImages
        XCTAssertTrue(saw, "带图 send 必须打到真实实现,不能被协议默认静态派发吞掉(否则多模态脑又看不见图)")
        XCTAssertEqual(imgs, ["data:image/png;base64,AAA"])
    }

    /// 非多模态会话(未覆盖带图 send)→ 走协议默认,退回纯文本 send,不崩、不丢调用。
    func testTextOnlySessionFallsBackToTextSend() async {
        let mock = TextOnlySession()
        let s: any LingShuAgentSessioning = mock
        _ = await s.send("hi", imageDataURLs: ["data:image/png;base64,AAA"])
        let n = await mock.textSendCount
        XCTAssertEqual(n, 1, "没带图实现的会话应退回纯文本 send")
    }

    /// 编排器把图随首轮目标喂给会话(spawn 路径,等价于派发隔离任务的首轮)。
    func testOrchestratorSpawnPassesImageToSession() async {
        let mock = RecordingSession()
        let orch = LingShuAgentOrchestrator()
        _ = await orch.spawn(id: "t1", objective: "改第5页箭头", session: mock,
                             imageDataURLs: ["data:image/png;base64,REDBOX"])
        let imgs = await mock.lastImages
        XCTAssertEqual(imgs, ["data:image/png;base64,REDBOX"], "派发任务首轮必须把原图送进会话(多模态脑看真图)")
    }
}
