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
            narrate: { [weak self] verbatim, n, total, title, pace in
                guard let self else { return verbatim }
                let clean = verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return "（这一页以图为主，我看着画面讲。）" }
                let sys = "你是演示讲稿撰写者。把给定这一页的真实内容,改写成一段**口语化、可直接念出来**的讲解词(\(pace.narrationGuidance)),像真人当面讲这一页:自然、抓重点、不照本宣科逐字念。**只输出讲解词本身**,不要任何前后缀/页码/「这一页」之类开头,**绝不编造页面没有的事实**。"
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
                voice.speakPresentationNarration(text)   // 命中下一页预合成则即时起播,消翻页停顿
                self.recordSpokenLine(text)
                // **按讲稿长度给足封顶**:详细档一页可念 100s+,默认 90s 硬闸会把没念完的页切走(实测过早翻页)。
                // 保守按 ~2.5 字/秒估时长(实际更快)+富余,保证封顶恒大于真实播放时长、只在 TTS 真卡住时兜底放行。
                let cap = max(150, Double(text.count) / 2.5 + 60)
                await voice.awaitPlaybackDone(maxSeconds: cap)
            },
            prefetchNarration: { [weak self] text in self?.voiceManager?.prefetchSpeech(text) },
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
            let msg = await self.startPresentation(paths: Self.parsePresentationPaths(argsJSON))
            // **给大脑的指令只放工具结果里,不进口播**:演示已由插件接管,别再调旧路径重复演示。
            return msg + "\n(演示已由「演示与答疑」插件接管全屏播放,你这条到此停,别再调 open_preview / present_fullscreen / speak 重复演示。)"
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
        // **重演/新演前先彻底停掉在跑的老演示**(取消播放任务 + 停循环 + 清 shownDocumentPath)。
        // 否则老 play 循环会在下面 buildQueue 通读生成讲稿那十几秒里**继续推画面**,而新演示从第1页念
        // → 画面跑到前面、语音却在第1页 = 脱节(2026-06-25 用户实测 bug)。必须在 buildQueue 之前停。
        presentationPlaybackTask?.cancel()
        presentationPlaybackTask = nil
        presentationController.requestStop()
        installPresentationHooks()
        await presentationController.buildQueue(documentPaths: paths)
        let n = presentationController.queue.count
        guard n > 0 else { return "没能从这些文档生成可演示的脚本(可能都为空或读取失败)。" }
        // 后台照稿播放(每段 speak 阻塞);用户输入由 handlePresentationInputIfNeeded 拦成答疑。
        presentationPlaybackTask?.cancel()
        presentationPlaybackTask = Task { @MainActor [weak self] in await self?.presentationController.play() }
        // **口播/聊天版只说人话**——给大脑的"别再重复 open/present"指令移到 present_documents 工具结果里,不进口播。
        return "好的,我开始演示了\(n > 1 ? "(共 \(n) 篇,会一篇篇连着来)" : "")。有问题随时打断我。"
    }

    /// 取消/退出路径统一调:演示在跑就**彻底停掉**(掐音频 + 停循环 + 取消播放任务)。
    /// 供 cancelCurrentCall / abortActiveFlow / 退出演示 复用——根治"取消后音频还在播下一页"。
    func stopPresentationIfActive() {
        guard presentationController.isActive else { return }
        presentationPlaybackTask?.cancel()
        presentationPlaybackTask = nil
        presentationController.requestStop()
        voiceManager?.cancelPrefetchedSpeech()   // 清演示翻页预合成槽,别让在飞的合成空耗
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
                if c.phase == .playing { c.requestPauseForQA(); await self.waitUntilPresentationPaused() }   // 先立刻停念稿
                // **按语义让模型分类**听众这句话(暂停/继续/停止/提问),不靠硬编码关键词枚举(那覆盖不全)。
                let beat = c.queue.currentScript?.currentBeat
                let (intent, answer) = await self.classifyPresentationUtterance(trimmed, beat: beat, title: c.currentTitle)
                switch intent {
                case .resume:
                    self.appendPresentationLine("好,接着讲。"); await c.resume()
                case .stop:
                    await c.stop(); self.appendPresentationLine("好,停下了,需要再演随时叫我。")
                case .pause:
                    self.appendPresentationLine("好,先停在这一页,你说「继续」我接着讲。")   // 停住保持,等「继续」
                case .pace(let p):
                    c.setPace(p); self.appendPresentationLine("好,后面我\(p.label)讲。"); await c.resume()   // 切档→续演,后续页按新深度
                case .seek(let page):
                    self.appendPresentationLine("好,翻到第\(page)页。"); await c.resume(seekTo: page - 1)   // 定向跳页 + 从该页续演
                case .question:
                    await self.speakPresentationAnswer(answer)
                    if c.phase == .pausedForQA {
                        let seekPage = Self.parsePresentationResumePage(trimmed)   // "从第N页"→seek;否则当前位置续
                        await c.resume(seekTo: seekPage.map { $0 - 1 })
                    }
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

    /// 听众这句话的语义意图(暂停/继续/停止/换讲解档/跳页/提问)——由模型按语义判,不靠关键词枚举。
    enum PresentationUtteranceIntent { case pause, resume, stop, question, pace(LingShuPresentationPace), seek(Int) }

    /// **模型按语义分类**听众这句话 + 若提问给出回答(一次 LLM 搞定)。失败才回退关键词兜底。
    /// 这样「先暂时停一下」「稍微停会儿」「咱们接着」任何说法都能判对,而不是写死一串词。
    private func classifyPresentationUtterance(_ input: String, beat: LingShuPresentationBeat?, title: String)
        async -> (intent: PresentationUtteranceIntent, answer: String) {
        let context = beat.map { "当前在讲《\(title)》第 \($0.pageNumber) 页,这页真实内容:\n\(String($0.verbatim.prefix(700)))" }
            ?? "正在演示《\(title)》"
        let sys = """
        你在主持一场演示,听众刚说了一句话。**按语义**(别只看关键词)判断属于哪类,**只输出一行 JSON**:
        - 想让你停一下、待会再继续(如「先暂时停一下」「稍微停会儿」「等我一下」)→ {"intent":"pause"}
        - 暂停后想接着往下讲(如「继续」「咱们接着」「往下说吧」)→ {"intent":"resume"}
        - 想结束/退出/不看了(如「不演了」「停了吧」「够了」「先到这」)→ {"intent":"stop"}
        - 想**换讲解节奏/深度**(如「后面快速讲」「简要过一下就行」「概要说说剩下的」「详细讲」「恢复正常速度」)→ {"intent":"pace","pace":"detailed"或"brief"或"overview"}(快速=brief、概要=overview、详细/正常=detailed)
        - 想**跳到/翻到某一页**(如「跳到第5页」「翻到第3页」「我想看第8页」「回到第一页」)→ {"intent":"seek","page":页号数字}
        - 对内容提问、或说别的话 → {"intent":"question","answer":"结合当前这页内容、像真人当面口语简洁回答(40-140字),不复述整页、不编造页面没有的事"}
        \(context)
        """
        let session = LingShuAgentSession(id: "qa-\(UUID().uuidString.prefix(5))", system: sys, tools: [],
                                          model: controlPlaneModelAdapter(.deliveryComposer), maxTurns: 1)
        let r = await session.send("听众说:\(input)")
        guard case .completed(let raw) = r else { return Self.fallbackPresentationIntent(input) }
        let clean = LingShuReasoningText.stripThinkTags(raw)
        switch (Self.jsonField(clean, "intent") ?? "").lowercased() {
        case "pause":  return (.pause, "")
        case "resume": return (.resume, "")
        case "stop":   return (.stop, "")
        case "pace":
            let p = LingShuPresentationPace(rawValue: (Self.jsonField(clean, "pace") ?? "").lowercased()) ?? .brief
            return (.pace(p), "")
        case "seek":
            let page = (Self.jsonField(clean, "page").flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
                ?? Self.parsePresentationResumePage(input)
            if let page, page > 0 { return (.seek(page), "") }
            return (.question, "你想跳到第几页?说个页号我就翻过去。")
        case "question":
            let a = (Self.jsonField(clean, "answer") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (.question, a.isEmpty ? "这个问题我先记下,演示后细聊。" : a)
        default:
            return Self.fallbackPresentationIntent(input)   // 没解析出 intent → 关键词兜底
        }
    }

    /// **仅 LLM 不可用时的关键词兜底**(主路径是上面的语义分类)。
    nonisolated static func fallbackPresentationIntent(_ s: String) -> (intent: PresentationUtteranceIntent, answer: String) {
        if isPresentationStopIntent(s)   { return (.stop, "") }
        if isPresentationResumeIntent(s) { return (.resume, "") }
        if isPresentationPauseIntent(s)  { return (.pause, "") }
        let t = s.replacingOccurrences(of: " ", with: "")
        if (t.contains("跳") || t.contains("翻到") || t.contains("回到") || t.contains("看第")),
           let p = parsePresentationResumePage(s) { return (.seek(p), "") }   // 跳页兜底
        return (.question, "这个问题我先记下,演示后细聊。")
    }

    /// 念出答疑回答(进聊天流 + TTS 念完)。
    private func speakPresentationAnswer(_ answer: String) async {
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
