import XCTest
@testable import LingShuMac

final class TaskSegmenterTests: XCTestCase {
    private let segmenter = LingShuTaskSegmenter()

    // MARK: 启发式快路

    func testHeuristicSingleTaskSkipsModel() {
        let result = segmenter.heuristicSegmentation("帮我做一个介绍灵枢的 PPT")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.source, "heuristic")
        XCTAssertEqual(result?.intents.count, 1)
        XCTAssertEqual(result?.taskIntents.count, 1)
        XCTAssertFalse(result?.isMultiTask ?? true)
    }

    func testHeuristicChatMarkedNonTask() {
        let result = segmenter.heuristicSegmentation("你好呀，今天感觉怎么样")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.taskIntents.count, 0)
    }

    func testHeuristicDefersMultiTaskToModel() {
        // 出现多任务信号 → 快路返回 nil，交模型拆。
        XCTAssertNil(segmenter.heuristicSegmentation("帮我做个 PPT，另外把昨天那个爬虫也跑一下"))
        XCTAssertNil(segmenter.heuristicSegmentation("写个登录页，顺便把测试补一下"))
    }

    // MARK: 模型输出解析

    func testParseModelSegmentationSplitsUnrelatedTasks() {
        let json = """
        {"tasks":[
          {"text":"做一个介绍灵枢的 PPT","group":"g1","is_task":true},
          {"text":"把昨天的爬虫任务跑一下","group":"g2","is_task":true,"resume_hint":"昨天那个爬虫"}
        ]}
        """
        let seg = LingShuTaskSegmenter.parseModelSegmentation(json, original: "原句")
        XCTAssertEqual(seg.source, "model")
        XCTAssertEqual(seg.taskIntents.count, 2)
        XCTAssertTrue(seg.isMultiTask)
        // 无关任务在不同分组 → 两个任务簇。
        XCTAssertEqual(seg.taskGroups.count, 2)
        XCTAssertEqual(seg.taskIntents.last?.resumeHint, "昨天那个爬虫")
    }

    func testParseModelSegmentationGroupsRelatedTasks() {
        let json = """
        {"tasks":[
          {"text":"做 PPT 大纲","group":"g1","is_task":true},
          {"text":"给 PPT 配演讲稿","group":"g1","is_task":true}
        ]}
        """
        let seg = LingShuTaskSegmenter.parseModelSegmentation(json, original: "原句")
        XCTAssertEqual(seg.taskIntents.count, 2)
        // 相关任务同组 → 一个任务簇。
        XCTAssertEqual(seg.taskGroups.count, 1)
    }

    func testParseModelSegmentationStripsCodeFenceAndJunk() {
        let raw = """
        好的，这是拆分结果：
        ```json
        {"tasks":[{"text":"修复登录 bug","group":"g1","is_task":true}]}
        ```
        """
        let seg = LingShuTaskSegmenter.parseModelSegmentation(raw, original: "原句")
        XCTAssertEqual(seg.taskIntents.count, 1)
        XCTAssertEqual(seg.taskIntents.first?.text, "修复登录 bug")
    }

    func testParseModelSegmentationFallsBackOnGarbage() {
        let seg = LingShuTaskSegmenter.parseModelSegmentation("这不是 JSON", original: "原始指令")
        XCTAssertEqual(seg.source, "model-fallback")
        XCTAssertEqual(seg.taskIntents.count, 1)
        XCTAssertEqual(seg.taskIntents.first?.text, "原始指令")
    }

    // MARK: 组合入口

    func testSegmentUsesFastPathWithoutCallingModel() async {
        var modelCalled = false
        let seg = await segmenter.segment("帮我写个登录页") { _ in
            modelCalled = true
            return nil
        }
        XCTAssertFalse(modelCalled, "单任务应走快路，不应调用模型")
        XCTAssertEqual(seg.source, "heuristic")
    }

    func testSegmentCallsModelForMultiTask() async {
        var modelCalled = false
        let seg = await segmenter.segment("做个 PPT，另外把爬虫跑一下") { _ in
            modelCalled = true
            return """
            {"tasks":[
              {"text":"做个 PPT","group":"g1","is_task":true},
              {"text":"把爬虫跑一下","group":"g2","is_task":true}
            ]}
            """
        }
        XCTAssertTrue(modelCalled, "多任务信号应触发模型拆分")
        XCTAssertEqual(seg.taskIntents.count, 2)
        XCTAssertEqual(seg.taskGroups.count, 2)
    }

    func testSegmentFallsBackWhenModelUnavailable() async {
        let seg = await segmenter.segment("做个 PPT，另外把爬虫跑一下") { _ in nil }
        XCTAssertEqual(seg.source, "model-fallback")
        XCTAssertEqual(seg.taskIntents.count, 1)
    }
}
