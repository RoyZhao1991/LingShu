import Foundation
import PDFKit
import AppKit

/// 验收门的"看 + 核"能力:把产出物的**正文文本**(事实核查用)和**渲染图像**(版式自检用)
/// 喂给独立 verifier,让"无错漏 + 不崩版"成为 agent 循环的硬目标,而不只是"文件存在"。
/// 渲染器(LibreOffice)/云端 VL 缺失时优雅降级——文本事实核查仍然生效。
@MainActor
extension LingShuState {

    /// 独立 verifier(maker≠checker):真实落盘 + **看图审版式** + **据知识核事实**,复用 LingShuChecklistVerdict。
    /// 任一维度不过即「需修正」,反馈给 maker 续修(goal-driven,直到通过或停滞交还)。
    func verifyAgentDeliverable(userRequest: String, reply: String, taskRecordID: String?) async -> (passed: Bool, critique: String) {
        let reviewer = expertProfileRegistry.reviewerProfile()
        // 真实落盘 = 已登记产出物(write_file 自动登记)∪ **回复里提到且盘上确实存在的文件**。
        // 关键:run_command 产出的文件(如 python 生成的 .pptx)不会被 write_file 登记,
        // 只认登记表会让 verifier 误判"主交付物不存在",对真实存在的文件反复打回——这正是 PPT 评审死循环的根因。
        var realPaths = Set((taskExecutionRecords.first { $0.id == taskRecordID }?.artifacts ?? []).map(\.location))
        for path in Self.extractFilePaths(from: reply) { realPaths.insert(path) }
        let realFiles = realPaths.filter { FileManager.default.fileExists(atPath: $0) }.sorted()
        let filesBlock = realFiles.isEmpty
            ? "真实落盘文件:(无——盘上没有任何本回合产出文件)"
            : "真实落盘文件(盘上确实存在,已逐一核实):\n" + realFiles.map { "- \($0)" }.joined(separator: "\n")

        // 代码任务测试门(计划 §4):产出真实源码文件 → 必须"有测试且跑通(全绿)"才达标,否则**确定性**判未达标。
        let codeFiles = realFiles.filter { Self.isTestableCodePath($0) }
        let testGate = codeTaskTestEvidence(taskRecordID: taskRecordID, codeFiles: codeFiles)
        let testGateBlock: String
        if codeFiles.isEmpty {
            testGateBlock = "测试门:本次非代码交付,跳过。"
        } else if testGate.passed {
            testGateBlock = "测试门:✅ 已检测到测试并跑通(全绿)。\(testGate.detail)"
        } else {
            testGateBlock = "测试门:❌ 未通过——\(testGate.detail) 代码交付必须写测试用例(随复杂度增多)并运行至全部通过,且把测试文件登记为产出物。"
        }

        // 看 + 核:抽产出物正文(事实核查)+ 渲染图像交云端 VL 审版式(重叠/截断/空白)。只看一个主产出物以控成本。
        var contentBlock = ""
        var visualBlock = "版式视觉评审:未启用(无渲染器或视觉通道)"
        if let primary = realFiles.first(where: { ["pptx", "docx", "html", "md", "pdf", "csv", "txt"].contains(($0 as NSString).pathExtension.lowercased()) }) {
            let text = await extractArtifactContent(path: primary)
            if !text.isEmpty { contentBlock = "\n【产出物正文(节选,供事实核查)】\n\(text)\n" }
            if let visual = await visuallyReviewArtifact(path: primary) {
                visualBlock = "版式视觉评审(VL 看图,逐页):\n\(visual)"
            }
        }

        let prompt = """
        你是独立评审官,严格把关这次交付——既要真实落盘,也要**事实无错、版式不崩**。
        用户要求:\(userRequest)
        交付答复:\(reply)
        \(filesBlock)
        \(contentBlock)
        \(visualBlock)
        \(testGateBlock)
        **重要:上面【真实落盘文件】是宿主已用文件系统逐一核实存在的清单,作为权威事实——不要因"你无法独立验证"而怀疑其存在性。** 你只负责判内容与版式。
        逐条核对这五个维度(每条写达标/未达标+理由):
        1. 真实性:用户要的产出物在上面【真实落盘文件】清单里就算达标;只有"声称生成了某文件、但它不在清单里"才 ❌(假完成)。清单里有对应文件 = 真实性达标,**不要再以"无法独立验证/存疑"为由打回**。
        2. 事实准确性:用你的知识逐条审查正文里的关键数据/年份/事件/数字/人名,**发现明确错误或与公认事实不符才 ❌ 并写出正确值**;不要把"我没法 100% 确认"当作不达标。**但忽略"自指/易变"事实**——产出物描述它自己的文件体积/字节数/页数/生成时间戳这类(每次重生成都会变、且与用户关心的内容无关),以及 KB 四舍五入这种琐碎数值差(如 41KB vs 40KB),**一律不算事实错误、不得据此打回**,以免陷入自指返工死循环。
        3. 完整性:是否覆盖用户要求的主题、结构与数量。
        4. 版式:若有视觉评审,凡文字重叠/被截断/溢出/错位空白 → ❌ 并指出第几页;无视觉评审则此项默认达标。
        5. 测试门:以上【测试门】结论为准——标 ❌ 则本维度未达标(代码任务必须有测试且全绿);标 ✅ 或"非代码交付跳过"则达标。
        输出格式(严格遵守):
        1. 先逐条核对并写明达标/未达标及理由(未达标写清缺什么、怎么改)。
        2. 另起一行:核对统计 PASS=<达标条数> FAIL=<未达标条数>
        3. 最后单独一行:全部达标写「结论:通过」,有未达标写「结论:需修正」。
        """
        let verifier = LingShuAgentSession(
            id: "verifier-\(UUID().uuidString.prefix(6))",
            system: reviewer.promptBlock,
            tools: [],
            model: makeAgentModelAdapter(),
            maxTurns: 1
        )
        let result = await verifier.send(prompt)
        let critique: String
        if case .completed(let value) = result { critique = value } else { critique = "" }
        let verdict = LingShuChecklistVerdict.parse(critique)
        // 测试门是**确定性硬门**:代码任务未"有测试且全绿"→ 即使 LLM 评审放行也判未达标,并把原因回灌给 maker。
        if !codeFiles.isEmpty, !testGate.passed {
            let appended = critique.isEmpty
                ? "测试门未通过:\(testGate.detail) 请补测试用例并跑通(全绿)。"
                : critique + "\n\n[测试门] ❌ \(testGate.detail) 请补测试用例并跑到全绿后再交付。"
            return (false, appended)
        }
        return (verdict.allPassed, critique)
    }

    /// 是否**需要测试门**的编程源码文件(真程序文件,排除 .md/.txt/.csv/.json/媒体——`isCodeLikePath` 太宽,这里收窄)。
    nonisolated static func isTestableCodePath(_ path: String) -> Bool {
        let exts: Set<String> = ["swift", "py", "js", "jsx", "ts", "tsx", "go", "rs", "java", "kt",
                                 "c", "cc", "cpp", "cxx", "m", "mm", "rb", "php", "scala", "cs"]
        return exts.contains((path as NSString).pathExtension.lowercased())
    }

    /// 文件名是否像测试文件(test_x / x_test / x.spec / FooTests / 在 tests 目录下)。
    nonisolated static func looksLikeTestFile(_ path: String) -> Bool {
        let lower = (path as NSString).lastPathComponent.lowercased()
        if lower.hasPrefix("test_") || lower.hasPrefix("test-") { return true }
        if lower.contains("_test.") || lower.contains("-test.") || lower.contains(".test.") || lower.contains(".spec.") { return true }
        if lower.hasSuffix("tests.swift") || lower.hasSuffix("test.swift") { return true }
        let full = path.lowercased()
        return full.contains("/tests/") || full.contains("/test/") || full.contains("/__tests__/")
    }

    /// 命令是否在运行测试(各语言常见测试运行器)。
    nonisolated static func looksLikeTestCommand(_ command: String) -> Bool {
        let needles = ["swift test", "pytest", "py.test", "-m pytest", "-m unittest", "unittest",
                       "npm test", "npm run test", "yarn test", "pnpm test", "jest", "vitest", "mocha",
                       "go test", "cargo test", "rspec", "phpunit", "gradle test", "mvn test",
                       "ctest", "make test", "tox", "dotnet test"]
        return needles.contains { command.contains($0) }
    }

    /// 扫任务记录,判断代码任务是否"有测试且跑通(全绿)"。配对 toolCall→toolResult:命中测试运行器或
    /// 执行了测试文件、且该次 run_command 成功(exit 0)= 全绿。返回 passed + 给 maker 的说明。
    func codeTaskTestEvidence(taskRecordID: String?, codeFiles: [String]) -> (passed: Bool, detail: String) {
        guard let record = taskExecutionRecords.first(where: { $0.id == taskRecordID }) else {
            return (false, "未找到本任务执行记录,无法确认测试。")
        }
        let testFileArtifacts = record.artifacts.map(\.location).filter { Self.looksLikeTestFile($0) }
        var sawTest = !testFileArtifacts.isEmpty
        var green = false
        var lastCmd: String?
        for message in record.messages {
            switch message.detail {
            case let .toolCall(tool, summary, args):
                if tool == "run_command" { lastCmd = (summary + " " + args).lowercased() }
            case let .toolResult(tool, success, _):
                if tool == "run_command", let cmd = lastCmd {
                    let isRunner = Self.looksLikeTestCommand(cmd)
                    let runsTestFile = testFileArtifacts.contains { cmd.contains(($0 as NSString).lastPathComponent.lowercased()) }
                    if isRunner || runsTestFile {
                        sawTest = true
                        if success { green = true }
                    }
                }
                lastCmd = nil
            default:
                break
            }
        }
        if !sawTest { return (false, "未检测到任何测试用例(没有测试文件,也没有运行测试的命令)。") }
        if !green { return (false, "检测到测试,但没有一次测试运行成功(全绿)——请运行测试并修到全部通过。") }
        return (true, "检测到测试文件 \(testFileArtifacts.count) 个,且有成功的测试运行。")
    }

    /// 交付话术与返工文本解耦:验收经返工后才通过时,maker 最后一轮文本是"逐条修正"的内部 QA 记录
    /// (用户看到会觉得驴唇不对马嘴)。这里用一个**无工具**的小会话,据原始请求 + 真实产出物清单,
    /// 生成一句面向用户的干净交付说明;为空/失败则回退原文,绝不卡住交付。
    func composeDeliveryMessage(userRequest: String, makerText: String, taskRecordID: String?) async -> String {
        let artifacts = (taskExecutionRecords.first { $0.id == taskRecordID }?.artifacts ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.location) }
        let artifactLines = artifacts.map { "- \($0.title):\($0.location)" }.joined(separator: "\n")
        let prompt = """
        任务已完成。请面向用户写一段简洁的交付说明(2–4 句):说清完成了什么、产出物在哪(给绝对路径)、一两个关键亮点。
        **不要复述内部返工/校对/逐条修正的过程,也不要提"验收/评审/修正"这些词**——用户只关心结果。
        用户原始请求:\(userRequest)
        本次真实产出物:
        \(artifactLines.isEmpty ? "(无登记文件)" : artifactLines)
        """
        let composer = LingShuAgentSession(
            id: "deliver-\(UUID().uuidString.prefix(6))",
            system: "你是交付播报助手,只输出面向用户的最终交付说明,不复述任何内部过程。",
            tools: [],
            model: makeAgentModelAdapter(),
            maxTurns: 1
        )
        let result = await composer.send(prompt)
        if case .completed(let text) = result {
            let cleaned = LingShuReasoningText.stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return makerText
    }

    /// 内部受信 shell 抓取(**不走 run_command 审批门**;仅供验收门提取/渲染自己的产出物)。
    nonisolated static func runCapturing(_ launchPath: String, _ args: [String], timeout: TimeInterval = 120) async -> String {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return "" }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: launchPath)
                proc.arguments = args
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError = Pipe()
                do { try proc.run() } catch { cont.resume(returning: ""); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if proc.isRunning { proc.terminate() } }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    /// 提取产出物可读正文供事实/完整性核查。pptx/docx/xlsx 走 unzip 取 OOXML 正文;文本类直接读。
    func extractArtifactContent(path: String, maxChars: Int = 5000) async -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "pptx", "docx", "xlsx":
            let raw = await Self.runCapturing("/usr/bin/unzip", ["-p", path, "ppt/slides/slide*.xml", "word/document.xml", "xl/sharedStrings.xml"], timeout: 30)
            let texts = Self.matchAll(raw, pattern: "<a:t>(.*?)</a:t>") + Self.matchAll(raw, pattern: "<t[^>]*>(.*?)</t>")
            return String(texts.joined(separator: " ").prefix(maxChars))
        case "md", "txt", "html", "htm", "csv", "json", "py", "sh", "swift":
            return String(((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").prefix(maxChars))
        default:
            return ""
        }
    }

    /// 渲染产出物并用云端 VL「看图」评审版式(重叠/截断/溢出/空白)+ 内容。VL 或渲染器缺失 → nil(降级)。
    func visuallyReviewArtifact(path: String, maxPages: Int = 4) async -> String? {
        guard let vl = cloudPerceptionClient else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        var pdfPath = path
        if ext != "pdf" {
            let soffice = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
            guard FileManager.default.isExecutableFile(atPath: soffice) else { return nil }
            let outDir = (path as NSString).deletingLastPathComponent
            _ = await Self.runCapturing(soffice, ["--headless", "--convert-to", "pdf", "--outdir", outDir, path], timeout: 120)
            pdfPath = (path as NSString).deletingPathExtension + ".pdf"
        }
        guard FileManager.default.fileExists(atPath: pdfPath),
              let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else { return nil }
        var critiques: [String] = []
        for idx in 0..<min(doc.pageCount, maxPages) {
            guard let page = doc.page(at: idx), let b64 = Self.pdfPageBase64PNG(page) else { continue }
            let prompt = "这是一页演示文稿。严格检查版式:① 文字是否重叠 ② 是否被页面边缘截断/溢出 ③ 是否有错位空白 ④ 标题与正文是否清晰可读。逐条指出(没问题就答「版式正常」);并指出页面文字里明显的事实错误。"
            if let r = try? await vl.analyzeImage(imageBase64: b64, prompt: prompt, includeGrounding: false), r.success {
                let s = r.semanticSuggestions.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { critiques.append("第\(idx + 1)页:\(s.prefix(280))") }
            }
        }
        return critiques.isEmpty ? nil : critiques.joined(separator: "\n")
    }

    /// 把 PDF 页渲染成 PNG 的 base64(PDFKit 原生,无外部依赖)。
    nonisolated static func pdfPageBase64PNG(_ page: PDFPage, scale: CGFloat = 1.5) -> String? {
        let rect = page.bounds(for: .mediaBox)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let size = NSSize(width: rect.width * scale, height: rect.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png.base64EncodedString()
    }

    /// 从命令/输出抽取交付型文件(绝对或相对路径,相对则相对工作目录解析)。只认交付型扩展名,
    /// 不收脚本/中间数据(.py/.json/.sh),避免「任务产出文件」被噪声塞满。供 run_command 补登产出物。
    nonisolated static func extractRunCommandArtifacts(_ text: String, workingDirectory: String) -> [String] {
        let pattern = "[\\w\\u4e00-\\u9fff./~_-]+\\.(?:pptx|docx|xlsx|pdf|html?|md|csv|png|jpe?g)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out: [String] = []
        for m in re.matches(in: text, range: range) {
            guard let r = Range(m.range, in: text) else { continue }
            var path = String(text[r])
            if !path.hasPrefix("/") { path = (workingDirectory as NSString).appendingPathComponent(path) }
            if !out.contains(path) { out.append(path) }
        }
        return out
    }

    /// 从回复文本抽取提到的绝对文件路径(常见产出物扩展名;允许中文文件名)。供验收门核实"真有这个文件"。
    nonisolated static func extractFilePaths(from text: String) -> [String] {
        let pattern = "/[^\\s`\"'）)，。、；;】]+?\\.(?:pptx|docx|xlsx|pdf|html?|md|csv|txt|py|json|sh|png|jpe?g)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out: [String] = []
        for m in re.matches(in: text, range: range) {
            guard let r = Range(m.range, in: text) else { continue }
            let p = String(text[r])
            if !out.contains(p) { out.append(p) }
        }
        return out
    }

    nonisolated static func matchAll(_ text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            let s = String(text[r])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
    }
}
