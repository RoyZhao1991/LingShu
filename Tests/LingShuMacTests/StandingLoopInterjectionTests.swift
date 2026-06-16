import XCTest
@testable import LingShuMac

/// 通用 LOOP「演示中被主人插话→答→断点续」的会话级回归(bug #2)。
/// 验证:一条**正在跑的长回合**(模拟逐页演示)能在回合边界**接住中途插话**、
/// 当场作答、再**接着往下**跑到收尾——不重启、不丢插话。复用 injectCorrection(已被 AgentLoopTests 证实)。
final class StandingLoopInterjectionTests: XCTestCase {

    func testPresentationAcceptsInterjectionThenResumes() async {
        // 模拟"演示型"模型:逐页翻(preview_next),中途收到主人插话→先口头答→继续翻到末页收尾。
        final class PresentingModel: LingShuAgentModel, @unchecked Sendable {
            weak var session: LingShuAgentSession?
            var page = 0
            private(set) var sawInterjection = false
            private(set) var pagesAfterInterjection = 0
            private var answered = false

            func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
                let hasInterjection = messages.contains { $0.role == .user && $0.content.contains("主人中途插话") }
                if hasInterjection, !answered {
                    // 先把插话当场口头答掉,再继续(不重头)。
                    sawInterjection = true
                    answered = true
                    return .toolCalls([.init(id: "ans", name: "speak", argumentsJSON: "{\"text\":\"这页讲的是架构\"}")])
                }
                if answered, page >= 2, sawInterjection {
                    pagesAfterInterjection += 1
                }
                page += 1
                if page <= 3 {
                    // 第 2 页时由测试注入插话(同时模型还在按节奏翻页)。
                    if page == 2 { await session?.injectCorrection("[主人中途插话/提问] 这页什么意思?") }
                    return .toolCalls([.init(id: "p\(page)", name: "preview_next", argumentsJSON: "{}")])
                }
                return .text("演示完成,全程边讲边答。")
            }
        }
        let model = PresentingModel()
        let speak = LingShuAgentTool(name: "speak", description: "出声") { _ in "spoken" }
        let next = LingShuAgentTool(name: "preview_next", description: "翻页") { _ in "翻到下一页" }
        let session = LingShuAgentSession(id: "present", tools: [speak, next], model: model)
        model.session = session

        let result = await session.send("打开这个PPT给我讲")
        XCTAssertEqual(result, .completed(text: "演示完成,全程边讲边答。"), "演示应跑到收尾(没被插话打断成失败/重启)")
        XCTAssertTrue(model.sawInterjection, "正在跑的演示回合应在边界接住中途插话")
        XCTAssertGreaterThan(model.pagesAfterInterjection, 0, "答完插话后应从当前进度接着往下翻(断点续,不重头)")

        let messages = await session.messages
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content.contains("主人中途插话") },
                      "插话应作为高优先 user 指令进入同一会话上下文(同一个大脑边讲边答)")
        XCTAssertTrue(messages.contains { $0.content == "打开这个PPT给我讲" },
                      "原始演示指令仍在上下文(没被重启清掉)")
    }
}
