import XCTest
import AppKit
import PDFKit
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
        XCTAssertFalse(
            LingShuInteractionFulfillment.isVisiblePresentationControl("老师提问:灵枢和 Codex、Claude Code 相比价值是什么?答完继续等待后续问题。"),
            "答疑问题里出现“继续”等词时,不能被演示控制谓词截走"
        )
    }

    @MainActor
    func testExplicitPreviewCloseCommandClosesOpenPreviewFromMainInput() async throws {
        let state = LingShuState()
        let html = workDir.appendingPathComponent("demo.html")
        try "<html><body><h1>演示材料</h1><p>第一页内容</p></body></html>"
            .write(to: html, atomically: true, encoding: .utf8)

        _ = await state.previewController.open(path: html.path)
        XCTAssertTrue(state.previewController.isPresented)

        let reply = state.submitTextInput("本轮汇报结束,关闭预览材料并收尾,一句话确认。")

        XCTAssertFalse(state.previewController.isPresented)
        XCTAssertTrue(reply.contains("已关闭预览材料"))
        XCTAssertEqual(state.chatMessages.last?.text, reply)
    }

    @MainActor
    func testExplicitPreviewCloseCommandPreemptsActiveBuiltinSkill() async throws {
        let state = LingShuState()
        let interceptor = InterceptingBuiltinSkillForTest()
        state.builtinSkills = [interceptor]
        let html = workDir.appendingPathComponent("demo-active.html")
        try "<html><body><h1>演示材料</h1><p>第一页内容</p></body></html>"
            .write(to: html, atomically: true, encoding: .utf8)

        _ = await state.previewController.open(path: html.path)
        XCTAssertTrue(state.previewController.isPresented)

        let reply = state.submitTextInput("本轮汇报结束,关闭预览材料并收尾,一句话确认。")

        XCTAssertFalse(interceptor.didIntercept)
        XCTAssertTrue(interceptor.didCancel)
        XCTAssertFalse(state.previewController.isPresented)
        XCTAssertTrue(reply.contains("已关闭预览材料"))
    }

    @MainActor
    func testVisibleQuestionGuidanceRequiresDirectAnswer() async throws {
        let state = LingShuState()
        let html = workDir.appendingPathComponent("qa.html")
        try "<html><body><h1>汇报材料</h1><p>规划、执行、监控、验收闭环。</p></body></html>"
            .write(to: html, atomically: true, encoding: .utf8)
        _ = await state.previewController.open(path: html.path)

        let guidance = try XCTUnwrap(state.currentVisibleInteractionGuidance(for: "老师提问:价值是什么?"))

        XCTAssertTrue(guidance.contains("本轮输入更像提问/答疑"))
        XCTAssertTrue(guidance.contains("最终回复必须直接回答用户的问题"))
        XCTAssertTrue(guidance.contains("不要只复述当前页摘要"))
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

    @MainActor
    func testDisplayedPageNumberFallsBackWhenPDFViewPageBelongsToAnotherDocument() async throws {
        let controller = LingShuPreviewController()
        let mainPDF = try makeOnePagePDF(named: "main.pdf")
        let foreignPDF = try makeOnePagePDF(named: "foreign.pdf")

        _ = await controller.open(path: mainPDF.path)
        let foreignDocument = try XCTUnwrap(PDFDocument(url: foreignPDF))
        let pdfView = PDFView()
        pdfView.document = foreignDocument
        pdfView.go(to: try XCTUnwrap(foreignDocument.page(at: 0)))
        controller.pdfView = pdfView

        XCTAssertEqual(controller.displayedPageNumber, 1, "PDFView 临时指向外部文档页时,页码显示应安全回退,不能因 NSNotFound + 1 崩溃")
    }

    func testInteractionStatusWithoutSubstanceIsHollow() {
        XCTAssertTrue(LingShuInteractionFulfillment.isHollowInteractionStatus("已基于汇报内容完成答疑,当前继续停在第1页,等待老师的下一个问题。"))
        XCTAssertTrue(LingShuInteractionFulfillment.isHollowInteractionStatus("已完成答疑。"))
        XCTAssertFalse(LingShuInteractionFulfillment.isHollowInteractionStatus("灵枢的工程管理价值在于把规划、执行、监控、验收和记忆串成一个可复盘的闭环,而不是只完成单点编码。"))
    }

    func testQuestionLikeVisibleInputIsRecognizedWithoutRouting() {
        XCTAssertTrue(LingShuInteractionFulfillment.isQuestionLike("老师提问:你的工程管理价值到底是什么?"))
        XCTAssertTrue(LingShuInteractionFulfillment.isQuestionLike("和其他强客户端相比区别在哪里"))
        XCTAssertFalse(LingShuInteractionFulfillment.isQuestionLike("继续"))
        XCTAssertFalse(LingShuInteractionFulfillment.isQuestionLike("下一页"))
    }

    func testPageNarrationStatusIsNotQuestionAnswer() {
        XCTAssertTrue(LingShuInteractionFulfillment.isPageNarrationStatus("「A2A_工程管理汇报.pptx」第 1 页主要说明:课题背景;四周计划"))
        XCTAssertTrue(LingShuInteractionFulfillment.isPageNarrationStatus("当前材料已打开预览,当前停在第 2 页。页面要点:背景;计划。"))
        XCTAssertFalse(LingShuInteractionFulfillment.isPageNarrationStatus("灵枢的价值在于把目标、流程、执行、验收和记忆统一成工程管理闭环。"))
    }

    func testPresentationQuestionAnswerRejectsStatusOnlyText() {
        XCTAssertFalse(LingShuPresentationSkill.presentationAnswerIsSubstantive("好的,回答完毕。我继续留在全屏演示状态,等待各位老师下一个问题。"))
        XCTAssertFalse(LingShuPresentationSkill.presentationAnswerIsSubstantive("这个问题我先记下,演示后细聊。"))
        XCTAssertTrue(LingShuPresentationSkill.presentationAnswerIsSubstantive("灵枢的价值在于把目标、任务、能力调度、过程监控、结果验收和记忆复用放进一个统一中枢,让工程管理从零散协作变成可追踪的闭环。"))
    }

    func testPresentationQuestionOnlyDropsFlowTail() {
        let q = LingShuPresentationSkill.presentationQuestionOnly("老师提问:灵枢和 Codex、Claude Code 这种强客户端相比,你的工程管理价值到底是什么?请基于刚才汇报内容直接答疑,答完继续等待后续问题。")
        XCTAssertEqual(q, "灵枢和 Codex、Claude Code 这种强客户端相比,你的工程管理价值到底是什么?")
    }

    func testInteractionArtifactInventoryStatusIsDetected() {
        let text = """
        ## 产出物
        | 文件 | 路径 |
        |------|------|
        | deck.pptx | `/Users/example/Library/Application Support/LingShu/Workspace/deck.pptx` |
        已进入演示状态。
        """
        XCTAssertTrue(LingShuInteractionFulfillment.isArtifactInventoryStatus(text))
    }

    func testInteractionArtifactInventoryStatusDetectsPathsWithSpaces() {
        let text = """
        ## 已完成
        ### 产出物
        | 文件 | 路径 |
        |------|------|
        | **PPTX 文件** | `/Users/example/Library/Application Support/LingShu/Workspace/A2A_工程管理汇报.pptx` |
        """
        XCTAssertTrue(LingShuInteractionFulfillment.isArtifactInventoryStatus(text))
    }

    func testLikelyDeliveryInventoryStatusCatchesVisibleCompletionSummary() {
        let text = """
        ✅ 全部完成！以下是本次模拟的完整交付：

        ### 产出物
        | 文件 | 路径 |
        |------|------|
        | **PPTX 文件** | `/Users/example/Library/Application Support/LingShu/Workspace/A2A_工程管理汇报.pptx` |

        当前状态：我已进入全屏演示模式，等待提问。
        """
        XCTAssertTrue(LingShuInteractionFulfillment.isLikelyDeliveryInventoryStatus(text))
    }

    func testTrimInteractionInventoryTailKeepsVisibleState() {
        let text = """
        第一页已讲解完毕。现在进入等待提问状态——

        ---

        ✅ **汇报模拟已完成，当前状态：等待老师提问**

        ### 产出物
        | 文件 | 路径 |
        |------|------|
        | **PPTX 文件** | `/Users/example/Library/Application Support/LingShu/Workspace/A2A_工程管理汇报.pptx` |

        ### 演示进度
        - ✅ 已打开预览
        """

        XCTAssertEqual(
            LingShuInteractionFulfillment.trimInteractionInventoryTail(text),
            "第一页已讲解完毕。现在进入等待提问状态"
        )
    }

    func testTrimInteractionInventoryTailCatchesSeparatorCompletionList() {
        let text = """
        第一页已讲解完毕。现在停下来等待老师提问。

        ---

        **已完成：**
        1. ✅ **PPTX已生成** — `/Users/example/Library/Application Support/LingShu/Workspace/A2A_工程管理汇报.pptx`（5页）
        2. ✅ **预览已打开**
        3. ✅ **全屏演示已进入**
        """

        XCTAssertEqual(
            LingShuInteractionFulfillment.trimInteractionInventoryTail(text),
            "第一页已讲解完毕。现在停下来等待老师提问。"
        )
    }

    func testStreamSpeechSkipsArtifactInventoryLines() {
        XCTAssertNil(LingShuInteractionFulfillment.speechSafeStreamText("### 产出物"))
        XCTAssertNil(LingShuInteractionFulfillment.speechSafeStreamText("| 文件 | 路径 |"))
        XCTAssertNil(LingShuInteractionFulfillment.speechSafeStreamText("|------|------|"))
        XCTAssertNil(LingShuInteractionFulfillment.speechSafeStreamText("| **PPTX 文件** | `/Users/example/Library/Application Support/LingShu/Workspace/A2A.pptx` |"))
        XCTAssertNil(LingShuInteractionFulfillment.speechSafeStreamText("**已完成：**"))
        XCTAssertNil(LingShuInteractionFulfillment.speechSafeStreamText("好的，以下是本次课题规划汇报的完整交付："))
        XCTAssertNil(LingShuInteractionFulfillment.speechSafeStreamText("## ✅ 全部完成！已进入演示状态，等待老师提问"))
        XCTAssertNil(LingShuInteractionFulfillment.speechSafeStreamText("### 页面结构"))
        XCTAssertEqual(
            LingShuInteractionFulfillment.speechSafeStreamText("第一页已讲解完毕。现在进入等待提问状态。"),
            "第一页已讲解完毕。现在进入等待提问状态。"
        )
    }

    func testInteractionSummaryUsefulnessRejectsInventoryLeadIn() {
        XCTAssertFalse(LingShuInteractionFulfillment.isUsefulInteractionSummary("好的，以下是本次课题规划汇报的完整交付："))
        XCTAssertTrue(LingShuInteractionFulfillment.isUsefulInteractionSummary("第一页已讲解完毕。现在进入等待提问状态。"))
    }

    @MainActor
    func testVisibleInventoryReplyIsRepairedToSpokenState() async throws {
        let state = LingShuState()
        let html = workDir.appendingPathComponent("visible.html")
        try "<html><body><h1>演示材料</h1><p>规划、执行、监控、验收闭环。</p></body></html>"
            .write(to: html, atomically: true, encoding: .utf8)
        _ = await state.previewController.open(path: html.path)
        let spoken = "我已经打开材料并开始讲解，当前重点是把目标、执行过程、监控和验收串成可感知的交付闭环。"
        state.recordSpokenLine(spoken)

        let inventory = """
        ✅ 全部完成！以下是本次模拟的完整交付：
        ### 产出物
        | 文件 | 路径 |
        |------|------|
        | **HTML 文件** | `/Users/example/Library/Application Support/LingShu/Workspace/demo.html` |
        """
        let repaired = state.reconcileVisibleInteractionReply(
            .completed(text: inventory),
            prompt: "打开这个材料预览并给我讲解",
            spokenBaseline: 0,
            recordID: nil
        )

        guard case .completed(let text) = repaired else {
            return XCTFail("应该得到完成态回复")
        }
        XCTAssertEqual(text, spoken)
    }

    @MainActor
    func testOpenPreviewToolResultMarksTurnAsInteractiveAndRepairsInventory() async throws {
        let state = LingShuState()
        let html = workDir.appendingPathComponent("visible-open.html")
        try "<html><body><h1>演示材料</h1><p>第一页内容</p></body></html>"
            .write(to: html, atomically: true, encoding: .utf8)
        _ = await state.previewController.open(path: html.path)

        var record = LingShuTaskExecutionRecord.create(prompt: "打开这个材料预览并给我讲解")
        record.append(
            actor: "交互交付",
            role: "打开预览",
            kind: .result,
            text: "已打开预览",
            detail: .toolResult(tool: "open_preview", success: true, output: "已打开预览")
        )
        state.taskExecutionRecords.append(record)

        let reply = """
        第一页已讲解完毕。现在进入等待提问状态——

        ### 产出物
        | 文件 | 路径 |
        |------|------|
        | **HTML 文件** | `/Users/example/Library/Application Support/LingShu/Workspace/demo.html` |
        """

        let repaired = state.reconcileVisibleInteractionReply(
            .completed(text: reply),
            prompt: "打开这个材料预览并给我讲解",
            spokenBaseline: 0,
            recordID: record.id
        )

        guard case .completed(let text) = repaired else {
            return XCTFail("应该得到完成态回复")
        }
        XCTAssertEqual(text, "第一页已讲解完毕。现在进入等待提问状态")
    }

    @MainActor
    func testFinalVisibleInteractionTextIsNormalizedEvenWhenReconcilePathIsBypassed() async throws {
        let state = LingShuState()
        let html = workDir.appendingPathComponent("visible-final.html")
        try "<html><body><h1>演示材料</h1><p>第一页内容</p></body></html>"
            .write(to: html, atomically: true, encoding: .utf8)
        _ = await state.previewController.open(path: html.path)

        var record = LingShuTaskExecutionRecord.create(prompt: "完整模拟一次学校课题规划汇报并进入演示")
        record.appendArtifact(title: "HTML 文件", location: html.path, producer: "测试")
        state.taskExecutionRecords.append(record)

        let reply = """
        好的，以下是本次课题规划汇报的完整交付：

        ---

        ## ✅ 全部完成！已进入演示状态，等待老师提问

        ### 产出物
        | 文件 | 路径 |
        |------|------|
        | **HTML 文件** | `/Users/example/Library/Application Support/LingShu/Workspace/demo.html` |
        """

        let normalized = state.normalizeFinalVisibleInteractionText(
            reply,
            prompt: "完整模拟一次学校课题规划汇报,制作材料并进入演示状态",
            recordID: record.id
        )

        XCTAssertTrue(normalized.contains("已打开预览"))
        XCTAssertTrue(normalized.contains("第 1 页"))
        XCTAssertFalse(normalized.contains("完整交付"))
        XCTAssertFalse(normalized.contains("产出物"))
        XCTAssertFalse(normalized.contains("| 文件 |"))
    }

    func testInteractionArtifactInventoryStatusDoesNotFlagSubstantiveAnswer() {
        let text = "灵枢的工程管理价值在于把规划、执行、监控、验收和记忆串成一个闭环,让强客户端成为被调度的执行层。"
        XCTAssertFalse(LingShuInteractionFulfillment.isArtifactInventoryStatus(text))
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

    private func makeOnePagePDF(named name: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        let image = NSImage(size: NSSize(width: 200, height: 120))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 120).fill()
        NSColor.black.setFill()
        NSString(string: name).draw(at: NSPoint(x: 20, y: 50), withAttributes: [.foregroundColor: NSColor.black])
        image.unlockFocus()

        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: image))
        document.insert(page, at: 0)
        XCTAssertTrue(document.write(to: url))
        return url
    }
}

@MainActor
private final class InterceptingBuiltinSkillForTest: LingShuBuiltinSkill {
    var didIntercept = false
    var didCancel = false
    func mount(host: LingShuState) {}
    var id: String { "test-interceptor" }
    var displayName: String { "测试拦截器" }
    var isActive: Bool { true }
    func interceptActiveInput(_ prompt: String) -> Bool {
        didIntercept = true
        return true
    }
    func onCancel() {
        didCancel = true
    }
}
