import Foundation

/// 「演示与答疑」插件接进 LingShuState:装配真钩子(预览/控制面LLM/语音)+ `present_documents` 工具
/// + 演示中实时答疑路由(**主线程线性**,保真人交互感)。编排逻辑见 `LingShuPresentationController`(可单测)。
@MainActor
extension LingShuState {

    /// 装配演示控制器的真实钩子。幂等:每次 present_documents 前调。
    func installPresentationHooks() {
        presentationController.install(.init(
            loadPages: { [weak self] path in
                guard let self else { return [] }
                _ = await self.previewController.open(path: path)
                if self.previewController.isHTML {
                    let t = await self.previewController.htmlInnerText().trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? [] : [t]
                }
                let n = self.previewController.pageCount
                guard n > 0 else { return [] }
                return (0..<n).map { self.previewController.pageText($0) }
            },
            showDocument: { [weak self] path in _ = await self?.previewController.open(path: path) },
            narrate: { [weak self] verbatim, n, total, title in
                guard let self else { return verbatim }
                let clean = verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return "（这一页以图为主，我看着画面讲。）" }
                let sys = "你是演示讲稿撰写者。把给定这一页的真实内容,改写成一段**口语化、可直接念出来**的讲解词(约60-160字),像真人当面讲这一页:自然、抓重点、不照本宣科逐字念。**只输出讲解词本身**,不要任何前后缀/页码/「这一页」之类开头,**绝不编造页面没有的事实**。"
                let session = LingShuAgentSession(id: "narrate-\(UUID().uuidString.prefix(5))", system: sys, tools: [],
                                                  model: self.controlPlaneModelAdapter(.deliveryComposer), maxTurns: 1)
                let r = await session.send("文档《\(title)》第 \(n)/\(total) 页的内容:\n\(String(clean.prefix(1200)))")
                if case .completed(let text) = r {
                    let out = LingShuReasoningText.stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
                    return out.isEmpty ? clean : out
                }
                return clean
            },
            navigate: { [weak self] idx in _ = self?.previewController.goto(idx) },
            speak: { [weak self] text in
                guard let self, let voice = self.voiceManager else { return }
                voice.speak(text)
                self.recordSpokenLine(text)
                await voice.awaitPlaybackDone()
            },
            setFullscreen: { [weak self] on in _ = self?.previewController.setSlideshow(on) },
            note: { [weak self] title, detail in
                self?.appendTrace(kind: .system, actor: "演示与答疑", title: title, detail: detail)
            },
            interruptAudio: { [weak self] in self?.interruptSpeechOutput?() }   // 取消/打断 → 立刻掐 TTS
        ))
    }

    /// present_documents 工具:大脑用它正式演示一篇/多篇文档(脚本化 + 答疑 + 连播)。
    func presentDocumentsTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "present_documents",
            description: "用「演示与答疑」插件正式演示一篇或多篇文档(PPT/PDF/Word/HTML 通用,非 PPT 专属):它**先通读、逐页生成讲稿**,再进全屏照脚本逐页讲(不在演示中临时理解、不卡顿)。演示中用户随时可打断提问,我答完从打断处或指定页继续(视频流式)。多篇=连播队列,一篇演完经用户确认切下一篇。传文档绝对路径数组。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"要依次演示的文档绝对路径(1 篇或多篇)\"}},\"required\":[\"paths\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "演示不可用" }
            return await self.startPresentation(paths: Self.parsePresentationPaths(argsJSON))
        }
    }

    /// 启动一组文档的脚本化演示(@MainActor:装钩子→通读生成脚本→后台照稿播放)。
    func startPresentation(paths: [String]) async -> String {
        guard !paths.isEmpty else { return "没有给文档路径。" }
        let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
        guard missing.isEmpty else { return "这些文件不存在:\(missing.joined(separator: "、"))" }
        // **演示=自主模式交互**(本体在位、麦克风在听、语音答疑才生效)。不进自主模式→麦克风没在听→
        // 用户真实语音打断收不到(实测 bug 2026-06-25)。上岗用**空目标**:只本体在位+开麦,不给大脑任务
        // (演示由我的 presentationController 驱动,不是大脑),已在岗则幂等跳过。
        if !isStandingPersonOnDuty {
            enteringViaManagedHandoff = true   // 本体立即出现,免入场仪式盖住演示开场
            goLiveAsStandingPerson()
        }
        installPresentationHooks()
        await presentationController.buildQueue(documentPaths: paths)
        let n = presentationController.queue.count
        guard n > 0 else { return "没能从这些文档生成可演示的脚本(可能都为空或读取失败)。" }
        // 后台照稿播放(每段 speak 阻塞);用户输入由 handlePresentationInputIfNeeded 拦成答疑。
        presentationPlaybackTask?.cancel()
        presentationPlaybackTask = Task { @MainActor [weak self] in await self?.presentationController.play() }
        return "已开始演示(共 \(n) 篇,讲稿已逐页生成,正照稿进全屏讲)。演示中用户随时可打断提问,我答完接着讲;多篇会一篇篇连播,一篇演完会问要不要继续下一篇。你这条到此停,别再重复 open/present。"
    }

    /// 取消/退出路径统一调:演示在跑就**彻底停掉**(掐音频 + 停循环 + 取消播放任务)。
    /// 供 cancelCurrentCall / abortActiveFlow / 退出演示 复用——根治"取消后音频还在播下一页"。
    func stopPresentationIfActive() {
        guard presentationController.isActive else { return }
        presentationPlaybackTask?.cancel()
        presentationPlaybackTask = nil
        presentationController.requestStop()
        appendTrace(kind: .system, actor: "演示与答疑", title: "停止演示", detail: "取消/退出 → 掐音频 + 停止照稿念。")
    }

    /// **确定性路由(实测必需)**:识别「演示/讲解 + 文档路径」的请求,**直接走 present_documents 插件**,
    /// 不靠模型选工具——实测 GLM/DeepSeek 等会习惯性用旧的 open_preview+speak 手搓路径、不碰新插件(工具建了也白搭)。
    /// 返回 true=已直接路由,submitTextInput 不再走常规分诊。
    func handlePresentationStartIfNeeded(_ prompt: String) -> Bool {
        guard !presentationController.isActive else { return false }   // 已在演示 → 交给答疑路由
        guard let paths = Self.detectPresentationRequest(prompt) else { return false }
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return false }                  // 路径不存在 → 交大脑常规处理(可能要先生成)
        chatMessages.append(.init(speaker: "你", text: prompt, isUser: true))
        appendTrace(kind: .route, actor: "演示与答疑", title: "确定性路由",
                    detail: "识别为文档演示请求,直接走 present_documents 插件(\(existing.count) 篇),不靠模型选工具。")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let msg = await self.startPresentation(paths: existing)
            self.chatMessages.append(.init(speaker: "灵枢", text: msg, isUser: false))
        }
        return true
    }

    /// 识别「文档演示」请求并抽出文档路径:必须有演示意图词 + 至少一个存在的文档路径。纯逻辑,可单测。
    nonisolated static func detectPresentationRequest(_ prompt: String) -> [String]? {
        let intents = ["演示", "讲解", "放映", "讲一下这", "讲讲这", "带我看", "带人看", "过一遍这", "present", "演讲"]
        guard intents.contains(where: { prompt.contains($0) }) else { return nil }
        let exts = ["pdf", "pptx", "ppt", "docx", "doc", "key", "html", "htm", "md", "txt", "xlsx"]
        let pattern = "(/[^\\s,，；;、]+\\.(?:" + exts.joined(separator: "|") + "))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = prompt as NSString
        var paths: [String] = []
        re.enumerateMatches(in: prompt, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m { paths.append(ns.substring(with: m.range)) }
        }
        return paths.isEmpty ? nil : paths
    }

    /// 演示进行时的用户输入拦截(**实时答疑,主线程线性**):返回 true=已作为演示交互处理,submitTextInput 不再走常规分诊。
    func handlePresentationInputIfNeeded(_ prompt: String) -> Bool {
        let c = presentationController
        guard c.isActive else { return false }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        chatMessages.append(.init(speaker: "你", text: trimmed, isUser: true))   // 交互进聊天流(线性)
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch c.phase {
            case .awaitingNextDoc:
                if Self.isPresentationStopIntent(trimmed) { await c.stop(); self.appendPresentationLine("好,演示就到这里。") }
                else { self.appendPresentationLine("好,继续下一篇。"); await c.confirmAndPlayNext() }
            case .playing, .pausedForQA:
                // **命令优先,不进答疑**:暂停态下「继续」→ 续演。
                if c.phase == .pausedForQA, Self.isPresentationResumeIntent(trimmed) {
                    self.appendPresentationLine("好,接着讲。"); await c.resume(); return
                }
                if c.phase == .playing { c.requestPauseForQA(); await self.waitUntilPresentationPaused() }
                if Self.isPresentationStopIntent(trimmed) { await c.stop(); self.appendPresentationLine("好,停下了,需要再演随时叫我。"); return }
                // 「暂停/停一下」→ 停在当前页保持,等「继续」再讲(不答疑、不续)。
                if Self.isPresentationPauseIntent(trimmed) {
                    self.appendPresentationLine("好,先停在这一页,你说「继续」我接着讲。"); return
                }
                // 其余=听众提问 → 答完从打断处(或「从第N页」)续。
                await self.answerDuringPresentation(trimmed)
                if c.phase == .pausedForQA {
                    let seekPage = Self.parsePresentationResumePage(trimmed)   // "从第N页"→seek;否则当前位置续
                    await c.resume(seekTo: seekPage.map { $0 - 1 })
                }
            default:
                break
            }
        }
        return true
    }

    private func waitUntilPresentationPaused() async {
        for _ in 0..<300 {   // 最多等 ~30s(当前这段讲稿念完才会停在拍间)
            if presentationController.phase != .playing { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// 演示中答疑:据当前页内容 + 问题生成回答并念出来。
    private func answerDuringPresentation(_ question: String) async {
        let beat = presentationController.queue.currentScript?.currentBeat
        let title = presentationController.currentTitle
        let context = beat.map { "当前在讲《\(title)》第 \($0.pageNumber) 页,这页真实内容:\n\(String($0.verbatim.prefix(800)))" }
            ?? "正在演示《\(title)》"
        let sys = "你是正在做演示的灵枢,听众当面提问。**结合当前这页内容**简洁口语地回答(40-140字),像真人答疑;别复述整页、别说'继续演示'之类。只输出回答本身,不编造页面没有的事实。"
        let session = LingShuAgentSession(id: "qa-\(UUID().uuidString.prefix(5))", system: sys, tools: [],
                                          model: controlPlaneModelAdapter(.deliveryComposer), maxTurns: 1)
        let r = await session.send("\(context)\n\n听众问:\(question)")
        let answer: String
        if case .completed(let text) = r {
            let out = LingShuReasoningText.stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
            answer = out.isEmpty ? "这个问题我先记下,演示后细聊。" : out
        } else { answer = "这个问题我先记下,演示后细聊。" }
        appendPresentationLine(answer)
        if let voice = voiceManager { voice.speak(answer); recordSpokenLine(answer); await voice.awaitPlaybackDone() }
    }

    private func appendPresentationLine(_ text: String) {
        chatMessages.append(.init(speaker: "灵枢", text: text, isUser: false))
    }

    nonisolated static func isPresentationStopIntent(_ s: String) -> Bool {
        let t = s.replacingOccurrences(of: " ", with: "")
        // 注:去掉了裸「停」「停下」——它们会误命中「暂停/停一下」(那是暂停保持,不是停止)。
        return ["停止演示", "结束演示", "退出演示", "不看了", "不演了", "别演了", "够了"].contains { t.contains($0) }
    }

    /// 暂停保持(可续):说「暂停/停一下/等一下」→ 停在当前页,等「继续」再讲(不是停止、不是答疑)。
    nonisolated static func isPresentationPauseIntent(_ s: String) -> Bool {
        let t = s.replacingOccurrences(of: " ", with: "")
        return ["暂停", "停一下", "停一会", "先停", "等一下", "等等", "稍等"].contains { t.contains($0) }
    }

    /// 继续演示:暂停态下说「继续/接着讲/往下讲」→ 从当前页续。
    nonisolated static func isPresentationResumeIntent(_ s: String) -> Bool {
        let t = s.replacingOccurrences(of: " ", with: "")
        return ["继续", "接着讲", "接着演", "往下讲", "往下演", "接着说"].contains { t.contains($0) }
    }

    /// 解析"从第N页/回到第N页/第N页"里的页号(1-based);没有则 nil(从当前位置续)。
    nonisolated static func parsePresentationResumePage(_ s: String) -> Int? {
        for marker in ["第", "从"] {
            var search = s[s.startIndex...]
            while let r = search.range(of: marker) {
                let after = search[r.upperBound...]
                let digits = after.prefix(while: { $0.isNumber })
                if let n = Int(digits), n > 0 { return n }
                search = search[r.upperBound...]
            }
        }
        return nil
    }

    nonisolated static func parsePresentationPaths(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let arr = obj["paths"] as? [String] {
            return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let s = obj["paths"] as? String {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }
}
