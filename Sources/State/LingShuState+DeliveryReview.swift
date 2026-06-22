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

        // P3 通用验收(全类型,详见 LingShuState+Acceptance):把 GoalSpec 成功标准分类后逐条确定性核验。
        // 任一**能确定性核验**的条未达成(文件不存在 / 命令·测试没成功)→ 硬门返工,模型口头"已完成"不能推翻文件系统事实;
        // 其余(内容质量/设备/环境/用户确认)注入评审官逐条核对(unverifiable 如实标,不假定达成)。无成功标准 → 空报告、零成本跳过。
        let acceptance = await acceptanceReport(taskRecordID: taskRecordID, realFiles: realFiles)
        if !acceptance.isEmpty { bindAcceptanceReport(acceptance, to: taskRecordID) }
        if acceptance.hasDeterministicFailure {
            appendTrace(kind: .warning, actor: "验收", title: "成功标准确定性核验未过", detail: acceptance.summary)
            return (false, acceptance.deterministicFailureReason)
        }
        let acceptanceBlock = acceptance.isEmpty ? "" : "\n\(acceptance.verifierBlock)\n"

        // 代码任务**确定性硬门**(计划 §4 + 执行恢复力):产出真实源码文件 → 必须同时满足
        // ① 测试门:有测试且跑通(全绿) ② 运行门:最近一次构建/运行程序本身不崩(若跑过)。任一不过即确定性判未达标。
        let codeFiles = realFiles.filter { Self.isTestableCodePath($0) }
        let testGate = codeTaskTestEvidence(taskRecordID: taskRecordID, codeFiles: codeFiles)
        let runGate = codeTaskRunEvidence(taskRecordID: taskRecordID, codeFiles: codeFiles)
        // 运行门只在「真尝试过构建/运行且最近一次崩了」时拦(runGate.attempted && !runGate.clean);从没跑过程序不单独拦(交测试门)。
        let runGateBlocks = runGate.attempted && !runGate.clean
        // **能力加固·验收门校准(2026-06-21,根治"springboot 脚手架编译成功却'未能自行收尾'撞顶返工")**:
        // 确定性成功证据**多形态择一**即可,不再"非有单测全绿不可"——
        // ① 有测试且全绿 + 运行不崩;或 ② **真把程序构建/运行起来且没崩**(脚手架/构建/可运行程序"建到能跑"就是成功,
        //    很多工程没有也不需要单测)。但**两者都没有**(只写了文件、从没构建/运行/测试)仍判未达标:必须有确定性验证,
        //    不许"声称写好了"就收。零关键词、不挑任务类型,纯看确定性证据。
        let ranWithVisibleOutput = codeTaskHasVisibleRunOutput(taskRecordID: taskRecordID)
        let codeGatePassed = LingShuVerifierGate.codeDeterministicGatePasses(
            hasCodeFiles: !codeFiles.isEmpty, testsGreen: testGate.passed, ranWithVisibleOutput: ranWithVisibleOutput, runCrashed: runGateBlocks)

        // **差距2:按交付物类型 gate 贵 LLM 评审**(确定性门照跑、只省 LLM 自评)。纯代码交付——确定性门(测试/运行)
        // 已**权威定正确性**:过则直接通过、跳过冗余 LLM(省一次贵调用 + 往返延迟,差距2/7);不过则按确定性失败直接返工。
        // 主观交付物(PPT/文档)或代码+主观混合 → 仍跑 LLM(事实/版式/完整性是主观维度,下方继续)。
        switch LingShuVerifierGate.decide(codeFileCount: codeFiles.count,
                                          hasSubjectiveArtifact: LingShuVerifierGate.hasSubjectiveArtifact(realFilePaths: realFiles),
                                          codeGatePassed: codeGatePassed) {
        case .skipPassedByDeterministicGate:
            appendTrace(kind: .result, actor: "验收", title: "确定性门通过·跳过LLM评审", detail: "纯代码交付:测试全绿+运行起来+跑出可见结果,确定性门已定正确性,省一次贵 LLM 自评。")
            return (true, "确定性代码门通过(测试全绿 + 运行起来 + 跑出可见结果),跳过冗余 LLM 评审。")
        case .skipFailedByDeterministicGate:
            appendTrace(kind: .warning, actor: "验收", title: "确定性门未过·跳过LLM评审", detail: "纯代码交付确定性门失败,直接按失败反馈返工。")
            return (false, codeGateFailureReason(testGate: testGate, runGate: runGate, runGateBlocks: runGateBlocks))
        case .runLLMReview:
            break
        }

        let testGateBlock: String
        if codeFiles.isEmpty {
            testGateBlock = "代码门:本次非代码交付,跳过。"
        } else {
            let testLine = testGate.passed ? "✅ \(testGate.detail)" : "❌ \(testGate.detail)"
            let runLine = runGateBlocks ? "❌ \(runGate.detail)" : "✅ \(runGate.detail)"
            let outputLine = ranWithVisibleOutput ? "✅ 已跑出可见结果" : "❌ 还没看到真实运行结果(疑似只编译/空跑无输出)"
            testGateBlock = codeGatePassed
                ? "代码门:✅ 通过(测试全绿 + 运行不崩 + 跑出可见结果)。测试门:\(testLine) 运行门:\(runLine) 结果:\(outputLine)"
                : "代码门:❌ 未通过。测试门:\(testLine) 运行门:\(runLine) 结果:\(outputLine)。**构建≠交付**:需跑测试到全绿 + 真运行起来 + 贴出真实结果;「编译通过、无输出」不算。"
        }

        // 真实结果后置校验(verifyOutcome,方案 §6):动作型任务交付是**真实效果不是文件**。
        // 确定性事实:本回合**唯一产出是文档/指南**且**无任何真实动作工具成功执行** → "写文档冒充"高危信号。
        // 是否动作型由评审官据用户意图判(壳不写意图关键词);这里只给确定性事实。
        let artifactExts = realFiles.map { ($0 as NSString).pathExtension }
        let hadAction = taskHadActionToolSuccess(taskRecordID: taskRecordID)
        let docImpersonation = LingShuOutcomeVerification.isDocumentImpersonationSignal(artifactExtensions: artifactExts, hadActionToolSuccess: hadAction)
        let outcomeBlock = docImpersonation
            ? "真实结果信号:⚠️ 本回合**唯一交付是文档/指南、且没有任何真实动作工具成功执行**。**若用户要的是真实效果(接入设备/开关灯/操作电脑/控外设这类动作型请求),写一篇说明文档≠做到 → 判未达标、不收**(动作型任务的交付是真实效果,不是文件)。若用户要的本就是一篇文档/资料,则此信号无关、按文档正常评审。"
            : "真实结果信号:本回合\(hadAction ? "有真实动作工具成功执行" : "无'仅文档冒充'风险")。"

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

        // P1 目标认知消费:记录里有 typed GoalSpec 的成功标准则给验收官参考(完整性维度据此核对是否真达成);无则空串、不加压。
        let goalCriteria = goalSpec(for: taskRecordID)?.acceptanceCriteriaBlock ?? ""
        let goalCriteriaBlock = goalCriteria.isEmpty ? "" : "\n\(goalCriteria)\n"
        let prompt = """
        你是独立评审官,严格把关这次交付——既要真实落盘,也要**事实无错、版式不崩**。
        用户要求:\(userRequest)
        \(goalCriteriaBlock)\(acceptanceBlock)交付答复:\(reply)
        \(filesBlock)
        \(outcomeBlock)
        \(contentBlock)
        \(visualBlock)
        \(testGateBlock)
        **重要:上面【真实落盘文件】是宿主已用文件系统逐一核实存在的清单,作为权威事实——不要因"你无法独立验证"而怀疑其存在性。** 你只负责判内容与版式。
        逐条核对这五个维度(每条写达标/未达标+理由):
        1. 真实性:用户要的产出物在上面【真实落盘文件】清单里就算达标;只有"声称生成了某文件、但它不在清单里"才 ❌(假完成)。清单里有对应文件 = 真实性达标,**不要再以"无法独立验证/存疑"为由打回**。
        2. 事实准确性:用你的知识逐条审查正文里的关键数据/年份/事件/数字/人名,**发现明确错误或与公认事实不符才 ❌ 并写出正确值**;不要把"我没法 100% 确认"当作不达标。**但忽略"自指/易变"事实**——产出物描述它自己的文件体积/字节数/页数/生成时间戳这类(每次重生成都会变、且与用户关心的内容无关),以及 KB 四舍五入这种琐碎数值差(如 41KB vs 40KB),**一律不算事实错误、不得据此打回**,以免陷入自指返工死循环。
        3. 完整性:是否覆盖用户要求的主题、结构与数量;**若上面给了【成功标准】,逐条核对是否真达成**(未达成的写明缺哪条)。
        4. 版式:若有视觉评审,凡文字重叠/被截断/溢出/错位空白 → ❌ 并指出第几页;无视觉评审则此项默认达标。
        5. 代码门:以上【代码门】结论为准——标 ❌ 则本维度未达标(代码任务需有确定性成功证据:**测试全绿 或 真构建/运行起来不崩,二者择一**);标 ✅ 或"非代码交付跳过"则达标。
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
        // 代码门是**确定性硬门**:代码任务未满足「有测试且全绿」或「程序构建/运行不崩」→ 即使 LLM 评审放行也判未达标,
        // 把缺哪条 + 崩溃片段回灌给 maker,逼它修到真跑通(执行恢复力),而不是把异常当交付。
        if !codeFiles.isEmpty, !codeGatePassed {
            let reasonText = codeGateFailureReason(testGate: testGate, runGate: runGate, runGateBlocks: runGateBlocks)
            let appended = critique.isEmpty ? reasonText : critique + "\n\n" + reasonText
            return (false, appended)
        }
        return (verdict.allPassed, critique)
    }

    /// 是否真跑出**可见结果**(用户定调"我要看到结果"):任一 run_command 成功且输出**非"（无输出，退出码 N）"空跑占位**、有实质内容。
    /// 脚手架/工程编译过、退出码 0 但无输出 ≠ 看到结果——必须真把测试/程序跑出能看到的输出。
    func codeTaskHasVisibleRunOutput(taskRecordID: String?) -> Bool {
        guard let record = taskExecutionRecords.first(where: { $0.id == taskRecordID }) else { return false }
        for message in record.messages {
            if case let .toolResult(tool, success, output) = message.detail, tool == "run_command", success {
                let t = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty || t.hasPrefix("（无输出") || t.contains("无输出，退出码") { continue }   // 空跑占位,不算
                if t.count >= 4 { return true }
            }
        }
        return false
    }

    /// 代码确定性门未过时给 maker 的返工指引(用户校准:**构建≠成功**——必须跑测试到全绿 + 运行起来 + 看到真实结果)。
    func codeGateFailureReason(testGate: (passed: Bool, detail: String),
                               runGate: (attempted: Bool, clean: Bool, detail: String),
                               runGateBlocks: Bool) -> String {
        if runGateBlocks {
            return "[运行门] ❌ \(runGate.detail) 请修到程序能正常构建/运行、不再崩溃/报错。"
        }
        return "[确定性验证] ❌ **构建完成不算交付**。把全链路跑完、让我看到结果:① 写/补测试用例,用 run_command **真跑测试到全绿**;② **真把程序运行起来**(app/服务/CLI 就启动并驱动它,如起服务后 curl 一个接口);③ 交付里**贴出真实运行输出/结果**——「编译通过、无输出、退出码 0」不是结果。(\(testGate.detail))"
    }

    /// 本任务记录里是否**有真实动作工具成功执行**(自编执行器/计算机操作/外设控制… 即非产出读取元工具)。
    /// 供真实结果后置校验:动作型任务"真做到"的确定性证据(配对 toolResult 的 success)。零关键词,据 `nonActionKernelTools` 反推。
    func taskHadActionToolSuccess(taskRecordID: String?) -> Bool {
        guard let record = taskExecutionRecords.first(where: { $0.id == taskRecordID }) else { return false }
        for message in record.messages {
            if case let .toolResult(tool, success, _) = message.detail,
               success, LingShuOutcomeVerification.isActionTool(tool) {
                return true
            }
        }
        return false
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

    /// 命令是否在**构建或运行程序本身**(编译 / 直接执行),区别于跑测试框架。用于「能跑通/不崩」运行门:
    /// 复杂工程「建到能跑」却在运行期崩溃时,模型常拿报错当交付收尾——这里识别出构建/运行动作,
    /// 配合 outputLooksLikeCrash 把"最近一次运行/构建崩了"做成确定性硬门,逼它修到真跑通。
    nonisolated static func looksLikeBuildOrRunCommand(_ command: String) -> Bool {
        let needles = ["swift build", "swift run", "xcodebuild", "make ", "cmake --build",
                       "cargo build", "cargo run", "go build", "go run", "gcc ", "g++ ", "clang ", "clang++",
                       "javac", "java -jar", "mvn package", "mvn compile", "gradle build", "gradle assemble",
                       "npm run build", "npm start", "npm run start", "yarn build", "pnpm build", "tsc ",
                       "dotnet build", "dotnet run", "python ", "python3 ", "node ", "deno run",
                       "ruby ", "php ", "./"]
        return needles.contains { command.contains($0) }
    }

    /// 命令输出是否含**高置信崩溃/构建失败签名**(用于:即使退出码被包装脚本吞掉成功,看见 traceback/段错误
    /// 也判崩)。只收高置信信号,不收宽泛的 "error:"/"killed",避免在正常输出上误判。
    nonisolated static func outputLooksLikeCrash(_ output: String) -> Bool {
        let lower = output.lowercased()
        let needles = ["traceback (most recent call last)", "segmentation fault", "segfault",
                       "core dumped", "abort trap", "panic:", "fatal error:", "fatal error",
                       "uncaught exception", "unhandled exception", "exception in thread",
                       "addresssanitizer", "modulenotfounderror", "importerror", "no such module",
                       "compilation failed", "compilation terminated", "build failed", "build error",
                       "linker command failed", "undefined reference to", "cannot find module",
                       "command not found"]
        return needles.contains { lower.contains($0) }
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

    /// 「能跑通/不崩」运行门(执行恢复力核心):扫任务记录里**构建/运行程序本身**的命令(非测试运行器),
    /// 看**最近一次**构建/运行是否干净(退出码成功 **且** 输出无高置信崩溃签名)。
    /// 复杂工程「建到能跑」却运行期崩溃时,弱模型常拿报错/异常当交付收尾;此门确定性判「最近一次跑崩=未达标」,
    /// 把崩溃片段回灌给 maker 逼它修到真跑通,而不是把异常交还用户。
    /// 语义:**只有真尝试过构建/运行**才把关(attempted=true);从没跑过程序则交给测试门(attempted=false, clean=true 不单独拦)。
    func codeTaskRunEvidence(taskRecordID: String?, codeFiles: [String]) -> (attempted: Bool, clean: Bool, detail: String) {
        guard let record = taskExecutionRecords.first(where: { $0.id == taskRecordID }) else {
            return (false, true, "未找到本任务执行记录,运行门跳过。")
        }
        var attempted = false
        var lastClean = true
        var lastCmd = ""
        var lastCrashSnippet = ""
        var pendingCmd: String?
        for message in record.messages {
            switch message.detail {
            case let .toolCall(tool, summary, args):
                if tool == "run_command" { pendingCmd = (summary + " " + args).lowercased() }
            case let .toolResult(tool, success, output):
                if tool == "run_command", let cmd = pendingCmd {
                    // 构建/运行程序本身(排除测试运行器,后者归测试门)。
                    if Self.looksLikeBuildOrRunCommand(cmd), !Self.looksLikeTestCommand(cmd) {
                        attempted = true
                        let crashed = !success || Self.outputLooksLikeCrash(output)
                        lastClean = !crashed
                        lastCmd = String(cmd.prefix(80))
                        lastCrashSnippet = crashed ? Self.crashSnippet(from: output) : ""
                    }
                }
                pendingCmd = nil
            default:
                break
            }
        }
        if !attempted { return (false, true, "未单独构建/运行程序(由测试门把关)。") }
        if lastClean { return (true, true, "最近一次构建/运行程序通过(无崩溃/报错)。") }
        return (false, false, "最近一次构建/运行程序仍失败(崩溃/报错):`\(lastCmd)` → \(lastCrashSnippet)")
    }

    /// 从一段命令输出里截一段最能说明问题的崩溃片段(优先含崩溃签名的那几行,否则取尾部)。
    nonisolated static func crashSnippet(from output: String, maxChars: Int = 240) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let hit = lines.lastIndex(where: { outputLooksLikeCrash($0) }) {
            let start = max(0, hit - 1)
            let end = min(lines.count, hit + 2)
            return String(lines[start..<end].joined(separator: " ↩ ").prefix(maxChars))
        }
        let tail = lines.suffix(3).joined(separator: " ↩ ")
        return String(tail.prefix(maxChars))
    }

    /// 交付话术与返工文本解耦:验收经返工后才通过时,maker 最后一轮文本是"逐条修正"的内部 QA 记录
    /// (用户看到会觉得驴唇不对马嘴)。这里用一个**无工具**的小会话,据原始请求 + 真实产出物清单,
    /// 生成一句面向用户的干净交付说明;为空/失败则回退原文,绝不卡住交付。
    /// 收尾回复是否退化成**空/占位的工具结果**(模型最后一步是个静默 `run_command`、没写收尾总结):
    /// 如「✓ run_command:（无输出，退出码 0）」「（已发起工具调用）」。这种不该直接丢给用户当交付,应据产出物补一段。
    nonisolated static func isPlaceholderDelivery(_ text: String) -> Bool {
        let t = LingShuReasoningText.stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        // 「（无输出…）」是工具无 stdout 的专用占位串,真交付里绝不会这么写——直接命中(不靠长度)。
        if t.contains("（无输出") || t.contains("(无输出") { return true }
        if t.contains("已发起工具调用") && t.count <= 30 { return true }   // 纯"已发起工具调用"占位
        if t.hasPrefix("✓") && t.contains("run_command") && t.count <= 50 { return true }   // 裸工具回执当收尾
        return false
    }

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
        // 扩展名白名单:文档/媒体 + **源码/配置/构建产物**(根治"run_command 写的工程文件如 pom.xml/*.java/*.yml 不进产出物")。
        // 误登记由调用处 mtime 过滤兜住(只登「本次命令真创建/改动」的);`\b` 防 cpp/jsx 等被前缀(c/js)截短误匹配。
        let pattern = "[\\w\\u4e00-\\u9fff./~_-]+\\.(?:pptx|docx|xlsx|pdf|html?|md|csv|png|jpe?g|java|kt|swift|py|jsx|js|tsx|ts|go|rs|rb|cpp|cc|c|hpp|h|cs|php|scala|vue|sql|xml|yaml|yml|json|toml|ini|properties|gradle|sh|bash|env|conf|cfg|txt|jar)\\b"
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
