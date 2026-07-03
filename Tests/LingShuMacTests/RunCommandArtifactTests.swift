import XCTest
@testable import LingShuMac

/// `extractRunCommandArtifacts` 扩展名识别(纯逻辑)。棘轮:守住"run_command 写的工程文件(pom.xml/*.java/*.yml)
/// 不进产出物"这个真 bug(SpringCloud 交付后产出物面板空)不复发。误登记由调用处 mtime 过滤兜住,本测只验"能识别到候选"。
final class RunCommandArtifactTests: XCTestCase {

    private func paths(_ text: String) -> [String] {
        LingShuState.extractRunCommandArtifacts(text, workingDirectory: "/proj")
    }

    func testExtractsCodeAndConfigFiles() {
        // heredoc 写工程文件:这些以前都被漏掉(只认 pptx/docx/… 文档扩展名)。
        let names = paths("cat > pom.xml <<EOF\ncat > src/main/java/com/example/GatewayApplication.java\ncat > application.yml")
            .map { ($0 as NSString).lastPathComponent }
        XCTAssertTrue(names.contains("pom.xml"), "pom.xml 应被识别")
        XCTAssertTrue(names.contains("GatewayApplication.java"), ".java 应被识别")
        XCTAssertTrue(names.contains("application.yml"), ".yml 应被识别")
    }

    func testRelativePathResolvedAgainstWorkingDir() {
        XCTAssertEqual(paths("wrote build.gradle").first, "/proj/build.gradle")
    }

    func testPrefixOverlapNotTruncated() {
        // \b 边界:cpp/jsx 不被前缀 c/js 截短成 .c/.js。
        let names = paths("touch a.cpp b.jsx c.tsx").map { ($0 as NSString).lastPathComponent }
        XCTAssertTrue(names.contains("a.cpp"), "应是 a.cpp 而非 a.c")
        XCTAssertTrue(names.contains("b.jsx"))
        XCTAssertTrue(names.contains("c.tsx"))
    }

    func testStillExtractsDocsAndKeepsAbsolutePaths() {
        // 原有文档识别不回归;绝对路径原样保留。
        XCTAssertEqual(paths("生成 /Users/x/报告.pptx 完成").first, "/Users/x/报告.pptx")
    }

    func testQuotedPathWithSpacesIsExtracted() {
        let command = #"python3 "/Users/me/Library/Application Support/LingShu/Skills/slides_to_pptx.py" "/Users/me/Library/Application Support/LingShu/Workspace/A2A_课题汇报_slides.json" "/Users/me/Library/Application Support/LingShu/Workspace/A2A_课题汇报.pptx""#
        let extracted = LingShuState.extractRunCommandArtifacts(command, workingDirectory: "/proj")

        XCTAssertTrue(
            extracted.contains("/Users/me/Library/Application Support/LingShu/Workspace/A2A_课题汇报.pptx"),
            "带空格目录的引用路径也必须被识别为候选产物"
        )
    }

    func testReplyPathWithSpacesIsExtractedWhenQuoted() {
        let reply = #"PPTX 文件：`/Users/me/Library/Application Support/LingShu/Workspace/A2A_课题汇报.pptx`"#
        let extracted = LingShuState.extractFilePaths(from: reply)

        XCTAssertEqual(extracted, ["/Users/me/Library/Application Support/LingShu/Workspace/A2A_课题汇报.pptx"])
    }
}
