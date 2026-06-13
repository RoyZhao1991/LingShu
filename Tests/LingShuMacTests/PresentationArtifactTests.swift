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
