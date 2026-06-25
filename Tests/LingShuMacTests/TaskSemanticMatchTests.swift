import XCTest
@testable import LingShuMac

final class TaskSemanticMatchTests: XCTestCase {
    private func makeService() -> LingShuMemoryService {
        let suite = "lingshu-task-match-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-task-match-\(UUID().uuidString)", isDirectory: true)
        return LingShuMemoryService(
            repository: LingShuMemoryRepository(defaults: defaults),
            semanticStore: LingShuSemanticMemoryStore(directory: dir)
        )
    }

    // MARK: - 明确回溯判定

    func testExplicitResumeDetection() {
        XCTAssertTrue(LingShuMemoryTextToolkit.isExplicitResumeRequest("继续做上次那个PPT"))
        XCTAssertTrue(LingShuMemoryTextToolkit.isExplicitResumeRequest("回到之前没做完的爬虫任务"))
        XCTAssertTrue(LingShuMemoryTextToolkit.isExplicitResumeRequest("把昨天那个架构文档接着弄完"))
        // 只有延续语气、没有历史指代 → 不算明确回溯
        XCTAssertFalse(LingShuMemoryTextToolkit.isExplicitResumeRequest("继续说"))
        XCTAssertFalse(LingShuMemoryTextToolkit.isExplicitResumeRequest("帮我写个新脚本"))
    }

    // MARK: - 语义召回 + taskID 回链

    func testSemanticLookupSurfacesRewordedTaskWithID() {
        let service = makeService()
        service.rememberTask(
            prompt: "帮我做一个给领导看的季度汇报PPT",
            status: "completed",
            summary: "已产出三页季度业绩汇报演示稿，含营收图表。",
            taskID: "task-quarterly-001"
        )

        // 换一种说法回溯，关键字不完全重叠，靠语义召回
        let lookup = service.taskMemoryLookup(for: "继续弄那个给领导的业绩演示文稿")
        XCTAssertNotEqual(lookup.confidence, .none, "换措辞的回溯应能语义命中")
        let resumable = lookup.candidates.first { $0.taskID == "task-quarterly-001" }
        XCTAssertNotNil(resumable, "候选里应能找回原任务的 taskID")
    }

    // MARK: - 置信分档

    func testStrongTagOverlapIsHighConfidence() {
        let service = makeService()
        service.rememberTask(
            prompt: "修复登录页的爬虫脚本bug",
            status: "in_progress",
            summary: "登录爬虫脚本修复中。",
            taskID: "task-crawler-bug"
        )
        // 多个实义标签重叠（爬虫/登录/bug） → 高置信直接续接
        let lookup = service.taskMemoryLookup(for: "继续修复那个登录爬虫的bug")
        XCTAssertEqual(lookup.confidence, .high)
        XCTAssertTrue(lookup.restored)
        XCTAssertEqual(lookup.hotMatch?.id, "task-crawler-bug")
    }

    func testNoMatchOnUnrelatedPromptIsNoneConfidence() {
        let service = makeService()
        service.rememberTask(
            prompt: "做一个介绍杭州的PPT",
            status: "completed",
            summary: "杭州介绍演示稿。",
            taskID: "task-hangzhou"
        )
        let lookup = service.taskMemoryLookup(for: "今天天气怎么样")
        XCTAssertEqual(lookup.confidence, .none)
        XCTAssertFalse(lookup.restored)
        XCTAssertNil(lookup.hotMatch)
    }

    func testExplicitResumeFlagCarried() {
        let service = makeService()
        let lookup = service.taskMemoryLookup(for: "继续之前那个没做完的任务")
        XCTAssertTrue(lookup.explicitResume, "明确回溯标记应透传给上层")
    }

    func testAmbiguousResumePrefersSingleContinuableTask() {
        let service = makeService()
        service.rememberTask(
            prompt: "写一个 web 爬虫",
            status: "delivered",
            summary: "已产出可运行爬虫代码，并建议下一步运行验证。",
            taskID: "task-crawler"
        )
        service.rememberTask(
            prompt: "修复登录 bug",
            status: "completed",
            summary: "已完成并交付。",
            taskID: "task-login-done"
        )

        let lookup = service.ambiguousTaskResumeLookup(for: "继续")

        XCTAssertEqual(lookup?.confidence, .high)
        XCTAssertTrue(lookup?.restored == true)
        XCTAssertEqual(lookup?.taskID, "task-crawler")
    }

    func testAmbiguousResumeOffersChoicesForParallelContinuableTasks() {
        let service = makeService()
        service.rememberTask(
            prompt: "修复登录 bug",
            status: "in_progress",
            summary: "登录 bug 仍在修复中。",
            taskID: "task-login"
        )
        service.rememberTask(
            prompt: "优化语音模型",
            status: "planned",
            summary: "已形成方案，下一步接入验证。",
            taskID: "task-voice"
        )

        let lookup = service.ambiguousTaskResumeLookup(for: "下一步")

        XCTAssertEqual(lookup?.confidence, .medium)
        XCTAssertFalse(lookup?.restored ?? true)
        XCTAssertEqual(Set(lookup?.candidates.compactMap(\.taskID) ?? []), ["task-login", "task-voice"])
    }

    func testAmbiguousResumeIgnoresCompletedTaskWithoutNextStep() {
        let service = makeService()
        service.rememberTask(
            prompt: "修复登录 bug",
            status: "completed",
            summary: "已完成并交付。",
            taskID: "task-login-done"
        )

        XCTAssertNil(service.ambiguousTaskResumeLookup(for: "继续"))
        XCTAssertFalse(LingShuMemoryTextToolkit.isAmbiguousTaskResumeRequest("继续说"))
    }

    // MARK: - 选择卡 action 协议

    func testChoiceOptionDecodesActionField() throws {
        let json = """
        { "label": "继续：杭州PPT", "detail": "三页初稿", "action": "resume:task-hangzhou" }
        """
        let option = try JSONDecoder().decode(LingShuRouteChoiceOption.self, from: Data(json.utf8))
        XCTAssertEqual(option.action, "resume:task-hangzhou")
    }

    func testChoiceOptionWithoutActionStaysNil() throws {
        let json = """
        { "label": "商务简洁", "detail": "深色底" }
        """
        let option = try JSONDecoder().decode(LingShuRouteChoiceOption.self, from: Data(json.utf8))
        XCTAssertNil(option.action, "模型生成的普通选项不应带 action")
    }
}
