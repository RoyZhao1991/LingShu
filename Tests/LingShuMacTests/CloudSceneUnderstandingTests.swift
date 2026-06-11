import XCTest
@testable import LingShuMac

final class CloudSceneUnderstandingTests: XCTestCase {
    func testFlattenSemanticsExtractsReadableText() {
        let flattened = LingShuCloudPerceptionClient.flattenSemantics([
            "scene": "会议室里正在进行演示，台下约有八个人",
            "person_state": ["多数人注视屏幕", "前排一人在记笔记"],
            "nested": ["risk": "无明显风险"]
        ])
        XCTAssertTrue(flattened.contains("台下约有八个人"))
        XCTAssertTrue(flattened.contains("多数人注视屏幕、前排一人在记笔记"))
        XCTAssertTrue(flattened.contains("无明显风险"))
        XCTAssertFalse(flattened.contains("{"), "应是可读文本，不是 JSON 包装")
    }

    func testMakeReplyLeadsWithSceneSemantics() {
        let reply = LingShuDataNetPerceptionProvider.makeReply(from: .init(
            success: true,
            taskType: "image",
            transcript: "",
            ocrTexts: ["季度目标"],
            detectionCount: 9,
            semanticSuggestions: "会议室演示场景，台下八人，注意力集中",
            warnings: [],
            totalTokens: 120,
            model: "swds-vision-fast"
        ))
        XCTAssertTrue(reply.summary.contains("场景理解：会议室演示场景"))
        XCTAssertLessThan(
            reply.summary.range(of: "场景理解")!.lowerBound,
            reply.summary.range(of: "画面文字")!.lowerBound,
            "场景语义必须排在 OCR 之前——它是情境化回应的主输入"
        )
    }

    func testSceneRefreshDecision() {
        // 本地路由：绝不出网
        XCTAssertFalse(LingShuRealtimePerceptionGateway.shouldRefreshScene(routeIsRemote: false, frameAge: 1, understandingAge: 100, maxAge: 20))
        // 没有新鲜帧：不刷新
        XCTAssertFalse(LingShuRealtimePerceptionGateway.shouldRefreshScene(routeIsRemote: true, frameAge: nil, understandingAge: 100, maxAge: 20))
        XCTAssertFalse(LingShuRealtimePerceptionGateway.shouldRefreshScene(routeIsRemote: true, frameAge: 30, understandingAge: 100, maxAge: 20))
        // 理解还新鲜：不重复花钱
        XCTAssertFalse(LingShuRealtimePerceptionGateway.shouldRefreshScene(routeIsRemote: true, frameAge: 1, understandingAge: 5, maxAge: 20))
        // 远端路由 + 新鲜帧 + 理解陈旧：刷新
        XCTAssertTrue(LingShuRealtimePerceptionGateway.shouldRefreshScene(routeIsRemote: true, frameAge: 1, understandingAge: 25, maxAge: 20))
    }
}
