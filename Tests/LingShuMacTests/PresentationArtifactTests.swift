import XCTest
@testable import LingShuMac

/// 验证宿主能确定性地把幻灯内容落成**真实可打开的 .pptx**（不依赖 python/run_command）。
/// 这是"目标驱动 Loop 每轮先落地真文件再验收"那条修复的地基：文件必须真的产出且合法。
final class PresentationArtifactTests: XCTestCase {
    private var workDir: URL!

    override func setUp() {
        super.setUp()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-pptx-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        super.tearDown()
    }

    func testMaterializesRealOpenablePPTX() throws {
        let service = LingShuEngineeringArtifactService()
        let reply = """
        # 自我介绍演示
        ## 第1页 封面：你好，我是灵枢
        要点：本机贾维斯式智能体；语音 + 视觉 + 工具执行。
        ## 第2页 我能做什么
        要点：理解目标、调度专家、真实落地交付物。
        ## 第3页 架构
        要点：主线程中枢 + 任务子线程 + 记忆复利。
        ## 第4页 下一步
        要点：目标驱动 Loop，做到达标为止。
        """

        let artifacts = service.materializeArtifacts(
            prompt: "帮我做一个自我介绍 PPT",
            reply: reply,
            workingDirectory: workDir.path
        )

        let pptx = artifacts.first { $0.location.hasSuffix(".pptx") }
        XCTAssertNotNil(pptx, "演示任务必须产出 .pptx 真实文件")
        let path = try XCTUnwrap(pptx).location
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "声明的 .pptx 必须真的落盘")

        // 真实非空文件。
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 1000, ".pptx 不应是空壳")

        // 合法 OOXML：是 zip（PK 头）且能解出 ppt/presentation.xml。
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], ".pptx 必须是 zip 容器（PK 头）")

        let listing = try runUnzipList(path)
        XCTAssertTrue(listing.contains("[Content_Types].xml"), "缺 [Content_Types].xml，PowerPoint 打不开")
        XCTAssertTrue(listing.contains("ppt/presentation.xml"), "缺 ppt/presentation.xml")
        XCTAssertTrue(listing.contains("ppt/slides/slide1.xml"), "至少要有第 1 页幻灯")
    }

    func testInteractionFulfillmentDetectsPresentationPreviewNeed() {
        XCTAssertTrue(LingShuInteractionFulfillment.requiresVisibleInteraction("制作一份 PPT,打开预览窗口并给我讲第一页"))
        XCTAssertTrue(LingShuInteractionFulfillment.requiresVisibleInteraction("明天课题汇报要用的幻灯片"))
        XCTAssertFalse(LingShuInteractionFulfillment.requiresVisibleInteraction("生成一份项目说明文档保存到本地"))
    }

    func testInteractionFulfillmentSelectsPreviewableArtifacts() throws {
        let html = workDir.appendingPathComponent("deck.html")
        let pptx = workDir.appendingPathComponent("deck.pptx")
        let pdf = workDir.appendingPathComponent("deck.pdf")
        let log = workDir.appendingPathComponent("run.log")
        try "<html></html>".write(to: html, atomically: true, encoding: .utf8)
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: pptx)
        try "%PDF-1.4".write(to: pdf, atomically: true, encoding: .utf8)
        try "log".write(to: log, atomically: true, encoding: .utf8)

        var record = LingShuTaskExecutionRecord.create(prompt: "做一份 PPT 并展示")
        record.appendArtifact(title: "日志", location: log.path, producer: "测试")
        record.appendArtifact(title: "PPTX", location: pptx.path, producer: "测试")
        record.appendArtifact(title: "PDF", location: pdf.path, producer: "测试")
        record.appendArtifact(title: "HTML", location: html.path, producer: "测试")

        let artifacts = LingShuInteractionFulfillment.previewableArtifacts(in: record)
        XCTAssertEqual(artifacts.first?.location, html.path, "HTML 预览应优先于 PPTX,减少转换与窗口等待")
        XCTAssertTrue(artifacts.contains { $0.location == pptx.path })

        let paginated = LingShuInteractionFulfillment.previewableArtifacts(in: record, preferPaginated: true)
        XCTAssertEqual(paginated.first?.location, pdf.path, "实时演示应优先选择有页序的产物,确保自动翻页稳定")
    }

    func testInteractionFulfillmentExtractsReadableHTMLText() throws {
        let html = workDir.appendingPathComponent("deck.html")
        try """
        <!doctype html>
        <html><head><style>.x{}</style><script>console.log('noise')</script></head>
        <body>
          <section><h1>课题背景</h1><p>基于AI原生的A2A工程管理。</p></section>
          <section><h2>四周工作计划</h2><ul><li>第一周完成目标建模。</li></ul></section>
        </body></html>
        """.write(to: html, atomically: true, encoding: .utf8)

        var record = LingShuTaskExecutionRecord.create(prompt: "做一份 PPT 并汇报")
        record.appendArtifact(title: "HTML", location: html.path, producer: "测试")
        let artifact = try XCTUnwrap(LingShuInteractionFulfillment.previewableArtifacts(in: record).first)
        let text = LingShuInteractionFulfillment.readablePreviewText(for: artifact)
        XCTAssertTrue(text.contains("课题背景"))
        XCTAssertTrue(text.contains("基于AI原生的A2A工程管理"))
        XCTAssertTrue(text.contains("四周工作计划"))
        XCTAssertFalse(text.contains("console.log"))
    }

    func testLiveInteractionRequiresExplicitInteractiveIntent() {
        XCTAssertTrue(LingShuInteractionFulfillment.requiresLiveInteraction("材料做好后进入自主模式,替我现场汇报并答疑"))
        XCTAssertTrue(LingShuInteractionFulfillment.requiresLiveInteraction("打开这份文档,全屏演示并带我看"))
        XCTAssertFalse(LingShuInteractionFulfillment.requiresLiveInteraction("生成一份课题汇报材料保存到本地"))
        XCTAssertFalse(LingShuInteractionFulfillment.requiresLiveInteraction("打开普通预览给我看,不要全屏托管"))
    }

    func testVisiblePresentationControlCommandsAreRecognized() {
        XCTAssertTrue(LingShuInteractionFulfillment.isVisiblePresentationControl("从当前这一页继续演示,接着往下讲"))
        XCTAssertTrue(LingShuInteractionFulfillment.isNextPageCommand("下一页"))
        XCTAssertTrue(LingShuInteractionFulfillment.isPreviousPageCommand("回上一页"))
        XCTAssertFalse(LingShuInteractionFulfillment.isVisiblePresentationControl("帮我重新生成一版材料"))
    }

    func testPageNarrationIncludesStablePageContext() {
        let text = LingShuInteractionFulfillment.pageNarration(
            title: "工程管理汇报",
            pageNumber: 2,
            totalPages: 3,
            pageText: "四周计划\n第一周完成目标建模\n第二周完成验收闭环"
        )
        XCTAssertTrue(text.contains("工程管理汇报"))
        XCTAssertTrue(text.contains("第 2/3 页"))
        XCTAssertTrue(text.contains("四周计划"))
    }

    func testInteractionStatusWithoutSubstanceIsHollow() {
        XCTAssertTrue(LingShuInteractionFulfillment.isHollowInteractionStatus("已基于汇报内容完成答疑,当前继续停在第1页,等待老师的下一个问题。"))
        XCTAssertTrue(LingShuInteractionFulfillment.isHollowInteractionStatus("已完成答疑。"))
        XCTAssertFalse(LingShuInteractionFulfillment.isHollowInteractionStatus("灵枢的工程管理价值在于把规划、执行、监控、验收和记忆串成一个可复盘的闭环,而不是只完成单点编码。"))
    }

    func testLatestSubstantiveSpokenLineCanRepairHollowChatReply() {
        let lines = [
            "[屏显第1页] 第一页主要说明课题背景。",
            "[屏显第1页] 谢谢老师的问题。灵枢的价值在于把强客户端纳入执行层,由中枢统一规划、调度、验收和沉淀经验。"
        ]
        let spoken = LingShuInteractionFulfillment.latestSubstantiveSpokenLine(after: 1, in: lines)
        XCTAssertEqual(spoken, "谢谢老师的问题。灵枢的价值在于把强客户端纳入执行层,由中枢统一规划、调度、验收和沉淀经验。")
    }

    private func runUnzipList(_ path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
