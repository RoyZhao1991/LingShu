import Foundation

/// 「演示与答疑」**内置技能**:把文档/网页正式演示讲解、边讲边答疑、视频流式续演、多文档连播。
///
/// 这是内置技能的**样板**(见 [[presentation-engine-fixes]] 记的"内置技能可带原生代码、但归属技能模块不糊进内核"):
/// - 编排引擎是 `LingShuPresentationController`(纯逻辑、可单测,内核服务经 `Hooks` 注入);
/// - 本类是引擎接进内核的**技能外壳**:装钩子 + `present_documents` 工具 + 确定性路由 + 演示中实时答疑;
/// - 内核服务(预览/语音/聊天/控制面 LLM)经 `weak host: LingShuState?` 取——**代码不再长在 `LingShuState` 身上**。
/// - 内核(取消/暂停/续/分诊/工具/菜单)一律经 `LingShuBuiltinSkill` 协议调本类,**不直接点名"演示"**。
@MainActor
final class LingShuPresentationSkill: LingShuBuiltinSkill {

    /// 演示编排引擎(脚本/答疑/续演/多文档队列);钩子由 `installHooks()` 装配。UI(预览宿主/进度条)经 `host.presentationController` 取它渲染。
    let controller = LingShuPresentationController()
    /// 在飞的演示播放任务(后台照稿念;用户输入经 `interceptActiveInput` 拦成答疑)。
    var playbackTask: Task<Void, Never>?
    /// 当前由用户前台输入触发的演示交互记录。用于把 controller 的 opening/announce 绑定回这次输入,
    /// 让 MCP/任务窗口能追踪“演示答疑/控制”这类前台技能交互。
    private var activeInteractionRecordID: String?
    /// 内核宿主(取内核服务:预览/语音/聊天/控制面模型/口播打断)。弱引用,内核持有本技能。
    weak var host: LingShuState?

    // MARK: - LingShuBuiltinSkill 协议(内核统一调度面)

    func mount(host: LingShuState) { self.host = host }

    var id: String { "present" }
    var displayName: String { "演示与答疑" }
    var isActive: Bool { controller.isActive }

    func tools() -> [LingShuAgentTool] { [presentDocumentsTool()] }

    var invocationEntry: LingShuInvocablePlugin? {
        .init(id: "present", displayName: "演示与答疑",
              aliases: ["演示", "讲解", "present", "放映"],
              subtitle: "把文档/网页正式演示讲解,边讲边答疑", icon: "play.rectangle.on.rectangle")
    }

    func routeDeclarative(id: String, rest: String, fullPrompt: String) -> Bool {
        guard id == "present" else { return false }
        // 先看 `@演示` 后面那段;没写路径就**从整条消息兜底抽**——附件路径被折进消息时在 `@演示` 之前(attachmentContextBlock
        // 的「本机路径:…」),只看 rest 会漏掉它(2026-06-27 用户实测:@演示+附件,路径在消息里却没被认领)。
        var paths = LingShuState.extractExistingFilePaths(rest)
        if paths.isEmpty { paths = LingShuState.extractExistingFilePaths(fullPrompt) }
        guard !paths.isEmpty else {
            host?.speakAndChat("好,用演示插件——把要演示的文档路径发我(比如 /Users/.../方案.pdf),我就开讲。")
            return true
        }
        // 开场白由 startPresentation → play(opening:) → announce 串行念出并进聊天,这里**不再 append**(否则双开场白 + 抢通道)。
        Task { @MainActor [weak self] in _ = await self?.startPresentation(paths: paths) }
        return true
    }

    func interceptActiveInput(_ prompt: String) -> Bool { handlePresentationInputIfNeeded(prompt) }

    // 注:**不实现 claimRequest**(已删关键词嗅探启动路由)——演示「启动」只走显式 `@演示`(routeDeclarative)
    // 或大脑的 `present_documents` 工具。根治"句子里只是提到'演示'+带文档路径就误开演"(2026-06-27 用户定调)。

    func onCancel() { stopPresentationIfActive() }

    func onPause() { if controller.isActive { controller.requestPauseForQA() } }   // 掐音频 + 不再狂翻

    /// 演示被暂停 → 从暂停页继续(供内核"继续"按钮调:不是去续自主循环,而是接着念)。
    func onResume() -> Bool {
        guard controller.phase == .pausedForQA else { return false }
        host?.appendTrace(kind: .runtime, actor: "演示与答疑", title: "继续演示", detail: "从暂停页接着念。")
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in await self?.controller.resume() }
        return true
    }

    // MARK: - 装配钩子(把内核服务注入引擎;幂等,每次 present_documents 前调)

    func installHooks() {
        controller.install(.init(
            loadPages: { [weak self] path in
                guard let host = self?.host else { return [] }
                _ = await host.previewController.open(path: path)
                if host.previewController.isHTML {
                    let t = await host.previewController.htmlInnerText().trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? [] : [t]
                }
                let n = host.previewController.pageCount
                guard n > 0 else { return [] }
                return (0..<n).map { host.previewController.pageText($0) }
            },
            showDocument: { [weak self] path in _ = await self?.host?.previewController.open(path: path) },
            narrate: { [weak self] verbatim, n, total, title, pace in
                guard let host = self?.host else { return verbatim }
                let clean = verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
                // **多模态:看着这一页的画面讲**(用户实测:图/表页只读抽出来的字=念字不是理解)。多模态脑就渲染本页喂图、
                // 让它真看懂图表/表格/流程再讲;非多模态脑/取不到图则回退纯文字。
                let visionOK = host.shouldAttemptNativeMultimodalForCurrentModel()
                let pageImage = visionOK ? host.previewController.pageImageDataURL(n - 1) : nil
                guard !clean.isEmpty || pageImage != nil else { return "（这一页以图为主，我看着画面讲。）" }
                // 身份锚定靠 LingShuPersona(系统提示词已是灵枢本人)+ 让大脑自己判断这页是否在讲自己——
                // **不再用 title/正文 含"灵枢" 的硬编码**(名字字符串匹配会误伤、引别的 bug;用户定调删掉)。
                let firstPerson = "这页内容若是关于你自己(你的定位/架构/能力/成果),就自然用第一人称('我'/'我的');若是别的主题,就以你的身份把那个主题给观众讲清楚,不用硬扯到自己。"
                let task = pageImage != nil
                    ? "你正在**亲自**讲这份演示。**看着这一页的画面**真正理解它(图表/表格/流程图/配图/版式)——讲它**在表达什么**:含义、关系、对比、结论、流程走向,像演讲者当面讲,**绝不是逐字念上面的文字标签**(\(pace.narrationGuidance))。\(firstPerson)**只输出讲解词本身**,不要前后缀/页码/「这一页」之类开头,**绝不编造画面里没有的东西**。"
                    : "你正在**亲自**讲这份演示。以灵枢本人的身份理解并讲解这一页:把它的真实内容改写成一段**口语化、可直接念出来**的讲解词(\(pace.narrationGuidance)),像真人当面讲:自然、抓重点、不照本宣科逐字念。\(firstPerson)**只输出讲解词本身**,不要任何前后缀/页码/「这一页」之类开头,**绝不编造页面没有的事实**。"
                // 看图生成讲稿要给多模态脑发整页图,远超分类器 8s——演示前预生成不卡用户,给足超时(90s)。
                let session = LingShuAgentSession(id: "narrate-\(UUID().uuidString.prefix(5))", system: LingShuPersona.system(task), tools: [],
                                                  model: host.controlPlaneModelAdapter(.deliveryComposer, timeoutOverride: pageImage != nil ? 90 : 20), maxTurns: 1)
                let userMsg = "文档《\(title)》第 \(n)/\(total) 页" + (clean.isEmpty ? "(以画面为主,看图讲)" : (pageImage != nil ? ",画面如下图;页面文字仅供参考:\n\(String(clean.prefix(600)))" : "的内容:\n\(String(clean.prefix(1200)))"))
                let r = pageImage != nil ? await session.send(userMsg, imageDataURLs: [pageImage!]) : await session.send(userMsg)
                if case .completed(let text) = r {
                    let out = LingShuReasoningText.stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
                    lingShuControlLog("讲稿 第\(n)页 看图=\(pageImage != nil) → \(out.replacingOccurrences(of: "\n", with: " ").prefix(150))")
                    return out.isEmpty ? clean : out
                }
                return clean
            },
            navigate: { [weak self] idx in _ = self?.host?.previewController.goto(idx) },
            speak: { [weak self] text in
                guard let host = self?.host, let voice = host.voiceManager else { return }
                voice.speakPresentationNarration(text)   // 命中下一页预合成则即时起播,消翻页停顿
                host.recordSpokenLine(text)
                // **按讲稿长度给足封顶**:详细档一页可念 100s+,默认 90s 硬闸会把没念完的页切走(实测过早翻页)。
                let cap = max(150, Double(text.count) / 2.5 + 60)
                await voice.awaitPlaybackDone(maxSeconds: cap)
            },
            prefetchNarration: { [weak self] text in self?.host?.voiceManager?.prefetchSpeech(text) },
            announce: { [weak self] text in
                guard let self, let host = self.host else { return }
                // 进聊天气泡,但**抑制气泡自动朗读**:本钩子下面已显式念这句,若再让自动朗读念一遍(同文)= 双声线互掐代次。
                let recordID = self.activeInteractionRecordID
                let bubble = ChatMessage(speaker: "灵枢", text: text, isUser: false, taskRecordID: recordID)
                host.lastSpokenMessageID = bubble.id
                host.chatMessages.append(bubble)
                if let voice = host.voiceManager {
                    voice.speakPresentationNarration(text)
                    host.recordSpokenLine(text)
                    await voice.awaitPlaybackDone(maxSeconds: 60)
                }
                self.finishPresentationInteraction(recordID, summary: text)
                if self.activeInteractionRecordID == recordID { self.activeInteractionRecordID = nil }
            },
            setFullscreen: { [weak self] on in _ = self?.host?.previewController.setSlideshow(on) },
            note: { [weak self] title, detail in
                self?.host?.appendTrace(kind: .system, actor: "演示与答疑", title: title, detail: detail)
            },
            interruptAudio: { [weak self] in self?.host?.interruptSpeechOutput?() }   // 取消/打断 → 立刻掐 TTS
        ))
        // 演示窗口文本输入框 → 答疑路由:打字提问/控制走 submitTextInput,演示进行中由 interceptActiveInput 拦成答疑。
        controller.onAsk = { [weak self] text in _ = self?.host?.submitTextInput(text) }
    }

    // MARK: - present_documents 工具

    /// present_documents 工具:大脑用它正式演示一篇/多篇文档(脚本化 + 答疑 + 连播)。
    func presentDocumentsTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "present_documents",
            description: "用「演示与答疑」插件正式演示一篇或多篇文档(PPT/PDF/Word/HTML 通用,非 PPT 专属):它**先通读、逐页生成讲稿**,再进全屏照脚本逐页讲(不在演示中临时理解、不卡顿)。演示中用户随时可打断提问,我答完从打断处或指定页继续(视频流式)。多篇=连播队列,一篇演完经用户确认切下一篇。传文档绝对路径数组。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"要依次演示的文档绝对路径(1 篇或多篇)\"}},\"required\":[\"paths\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "演示不可用" }
            let msg = await self.startPresentation(paths: Self.parsePresentationPaths(argsJSON))
            return msg + "\n(演示已由「演示与答疑」插件接管全屏播放,你这条到此停,别再调 open_preview / present_fullscreen / speak 重复演示。)"
        }
    }

    // MARK: - 启动 / 停止

    /// 启动一组文档的脚本化演示(装钩子→通读生成脚本→后台照稿播放)。
    func startPresentation(paths: [String]) async -> String {
        guard !paths.isEmpty else { return "没有给文档路径。" }
        let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
        guard missing.isEmpty else { return "这些文件不存在:\(missing.joined(separator: "、"))" }
        // 演示不抢麦(纯 TTS 念稿,不开 VPIO);交互改用演示窗口文本输入框(2026-06-27 定调)。
        // **重演/新演前先彻底停掉在跑的老演示**(取消播放任务 + 停循环);但**只有真有老演示在跑才 requestStop**——
        // requestStop 会 interruptAudio 切掉刚说的开场音频,残留(已结束)task 让 "!=nil" 误判 → 误切开场。
        playbackTask?.cancel()
        playbackTask = nil
        if controller.isActive {
            controller.requestStop()
        }
        installHooks()
        // **看不到画面就明说,别静默照本宣科(2026-06-29 用户实测:DeepSeek 演 PPT 只念字)**:
        // 非多模态脑取不到页面图,只能按抽出的文字讲(图/表/版式页讲不透)。提醒换多模态脑才能"看着画面讲"。
        if let host, !host.shouldAttemptNativeMultimodalForCurrentModel() {
            host.chatMessages.append(.init(speaker: "灵枢",
                text: "⚠️ 当前大脑「\(host.modelName)」已走图片解析降级,不能原生直看幻灯片画面——只能按抽出的**文字**讲(图/表/版式页讲不透、容易像念稿)。想让我**看着画面真正讲解**,换个支持原生多模态的脑再演示。",
                isUser: false))
        }
        await controller.buildQueue(documentPaths: paths)
        let n = controller.queue.count
        guard n > 0 else { return "没能从这些文档生成可演示的脚本(可能都为空或读取失败)。" }
        let opening = "好的,我开始演示了\(n > 1 ? "(共 \(n) 篇,会一篇篇连着来)" : "")。有问题随时打断我。"
        // **开场白交给 play(opening:)** 在首页画面就位后经 announce 串行念完再念首页讲稿——杜绝开场白被首页讲稿掐断
        // (announce 同时把开场白进聊天 + 抑制气泡自动朗读,故调用方**不要再 append 这句**)。
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in await self?.controller.play(opening: opening) }
        return opening
    }

    /// 取消/退出路径统一调:演示在跑就**彻底停掉**(掐音频 + 停循环 + 取消播放任务)。
    func stopPresentationIfActive() {
        guard controller.isActive else { return }
        playbackTask?.cancel()
        playbackTask = nil
        controller.requestStop()
        host?.voiceManager?.cancelPrefetchedSpeech()   // 清演示翻页预合成槽,别让在飞的合成空耗
        host?.appendTrace(kind: .system, actor: "演示与答疑", title: "停止演示", detail: "取消/退出 → 掐音频 + 停止照稿念。")
    }

    // MARK: - 演示中实时答疑(主线程线性)

    /// 演示进行时的用户输入拦截(**实时答疑**):返回 true=已作为演示交互处理。
    func handlePresentationInputIfNeeded(_ prompt: String) -> Bool {
        let c = controller
        guard c.isActive else { return false }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let host,
           host.previewController.isPresented,
           LingShuNestedStagePlanner.isExitPresentationCommand(trimmed) {
            // 关闭/收起前台预览是宿主级控制动作,让回 LingShuState 统一关闭窗口、取消技能和收尾记录。
            return false
        }
        let recordID = beginPresentationInteraction(trimmed)
        LingShuCueSound.playAcknowledgeChime()   // 收到输入立刻"受令"提示音
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch c.phase {
            case .awaitingNextDoc:
                if Self.isPresentationStopIntent(trimmed) { await c.stop(); await self.sayPresentationLine("好,演示就到这里。", recordID: recordID) }
                // 确认句作为 opening 交给 play:先显示下一篇首页 → 串行念这句 → 再念讲稿(不抢通道→不跳页)。
                else {
                    self.activeInteractionRecordID = recordID
                    await c.confirmAndPlayNext(opening: "好,继续下一篇。")
                    self.finishPresentationInteraction(recordID, summary: "好,继续下一篇。")
                }
            case .playing, .pausedForQA:
                if c.phase == .playing { c.requestPauseForQA(); await self.waitUntilPresentationPaused() }   // 先立刻停念稿
                let beat = c.queue.currentScript?.currentBeat
                let pulse = self.startPresentationProcessingPulse()   // 思考期"处理中"低忙音脉冲
                let (intent, answer) = await self.classifyPresentationUtterance(trimmed, beat: beat, title: c.currentTitle)
                pulse.cancel(); LingShuCueSound.busyStop()
                // **铁律**:凡是"念一句确认 + 紧接着续演"的分支,确认句必须**作为 opening 交给 play**(先翻到目标页→串行念→再念讲稿),
                // 绝不能让气泡自动朗读这句——会和续演首页讲稿抢同一发声通道(代次互掐)→ 把讲稿掐掉、play 误判念完而跳页。
                switch intent {
                case .resume:
                    self.activeInteractionRecordID = recordID
                    await c.resume(opening: "好,接着讲。")
                case .stop:
                    await c.stop(); await self.sayPresentationLine("好,停下了,需要再演随时叫我。", recordID: recordID)
                case .pause:
                    await self.sayPresentationLine("好,先停在这一页,你说「继续」我接着讲。", recordID: recordID)   // 停住保持,等「继续」
                case .pace(let p):
                    self.activeInteractionRecordID = recordID
                    c.setPace(p); await c.resume(opening: "好,后面我\(p.label)讲。")   // 切档→续演,后续页按新深度
                case .seek(let page):
                    self.activeInteractionRecordID = recordID
                    await c.resume(seekTo: page - 1, opening: "好,翻到第\(page)页。")   // 先翻到该页→念确认→从该页续演
                case .question:
                    await self.speakPresentationAnswer(answer, recordID: recordID)
                    if c.phase == .pausedForQA {
                        let seekPage = Self.parsePresentationResumePage(trimmed)   // "从第N页"→seek;否则当前位置续
                        await c.resume(seekTo: seekPage.map { $0 - 1 })
                    }
                }
            default:
                self.finishPresentationInteraction(recordID, summary: "演示当前不可接收这条输入。", status: .blocked)
                break
            }
        }
        return true
    }

    private func beginPresentationInteraction(_ text: String) -> String? {
        guard let host else { return nil }
        let recordID = host.createTaskExecutionRecord(for: text)
        host.chatMessages.append(.init(speaker: "你", text: text, isUser: true, taskRecordID: recordID))   // 交互进聊天流(线性)
        host.requestChatScrollToLatestForUserSend()
        host.appendTaskRecordMessage(recordID, actor: "你", role: "演示交互", kind: .user, text: text)
        host.appendTaskRecordMessage(recordID, actor: "演示与答疑", role: "接管输入", kind: .core, text: "当前前台演示正在运行,这条输入进入演示答疑/控制通道。")
        host.appendTrace(kind: .route, actor: "演示与答疑", title: "前台交互", detail: String(text.prefix(80)))
        return recordID
    }

    private func finishPresentationInteraction(
        _ recordID: String?,
        summary: String,
        status: LingShuTaskExecutionStatus = .answered
    ) {
        guard let host, let recordID,
              let record = host.taskExecutionRecords.first(where: { $0.id == recordID }),
              !record.status.isTerminal
        else { return }
        let clean = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            host.appendTaskRecordMessage(recordID, actor: "灵枢", role: "演示回应", kind: .result, text: clean)
        }
        host.finishTaskRecord(recordID, status: status, summary: clean.isEmpty ? "演示交互已处理。" : clean)
        if !clean.isEmpty {
            host.rememberMainThreadTurn(prompt: record.prompt, reply: clean)
        }
    }

    /// 演示文本交互的"处理中"低忙音脉冲驱动(演示不在自主模式,自带一条每 ~0.9s 驱动 busyTick 的 Task)。
    private func startPresentationProcessingPulse() -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                LingShuCueSound.busyTick()
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }

    private func waitUntilPresentationPaused() async {
        for _ in 0..<300 {   // 最多等 ~30s(当前这段讲稿念完才会停在拍间)
            if controller.phase != .playing { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// 听众这句话的语义意图(暂停/继续/停止/换讲解档/跳页/提问)。
    enum PresentationUtteranceIntent { case pause, resume, stop, question, pace(LingShuPresentationPace), seek(Int) }

    /// **模型按语义分类**听众这句话 + 若提问给出回答(一次 LLM 搞定)。失败才回退关键词兜底。
    private func classifyPresentationUtterance(_ input: String, beat: LingShuPresentationBeat?, title: String)
        async -> (intent: PresentationUtteranceIntent, answer: String) {
        guard let host else { return Self.fallbackPresentationIntent(input) }
        let context = beat.map { "当前在讲《\(title)》第 \($0.pageNumber) 页,这页真实内容:\n\(String($0.verbatim.prefix(700)))" }
            ?? "正在演示《\(title)》"
        // **注意:这是严格 JSON 分类器,不挂 LingShuPersona 身份前缀**——身份那句"不是一问一答的聊天机器人/能独立做事"
        // 会把模型推进"助手对话模式"、不再只出 JSON(2026-06-28 实测:挂了之后「从第二页开始讲解」被回成"我需要您提供文件…"
        // 的客套 markdown,jsonField 抽不到 intent→落 question)。身份只挂"出灵枢声音"的提示词(讲稿/答疑回答),不挂机器输出分类器。
        let sys = """
        你正在主持一场演示,听众刚说了一句话。**按语义**(别只看关键词)判断属于哪类,**只输出一行 JSON,别加任何解释/markdown/客套**:
        - 想让你停一下、待会再继续(如「先暂时停一下」「稍微停会儿」「等我一下」)→ {"intent":"pause"}
        - 暂停后想接着往下讲(如「继续」「咱们接着」「往下说吧」)→ {"intent":"resume"}
        - 想结束/退出/不看了(如「不演了」「停了吧」「够了」「先到这」)→ {"intent":"stop"}
        - 想**换讲解节奏/深度**(如「后面快速讲」「简要过一下就行」「概要说说剩下的」「详细讲」「恢复正常速度」)→ {"intent":"pace","pace":"detailed"或"brief"或"overview"}(快速=brief、概要=overview、详细/正常=detailed)
        - 想**跳到/翻到某页 或 从某页开始讲**(如「跳到第5页」「翻到第3页」「我想看第8页」「回到第一页」「从第一页重新开始讲」「**从第2页开始讲解**」「从第三页讲起」「第4页讲」),**或只说一个数字(如「1」「3」「第二页」)**→ {"intent":"seek","page":归一化后的阿拉伯整数页号} （**page 必须归一成阿拉伯数字整数**:「第一页」「回到第一页」「从第一页重新开始讲」→1、「跳到第四页」→4、只说「2」→2;这是你的活,别原样回中文）
        - 对内容提问、或说别的话 → {"intent":"question","answer":"结合当前这页内容、像真人当面口语简洁回答(40-140字),不复述整页、不编造页面没有的事"}
        **若提问里夹带“答完继续/说完继续/等待后续问题/继续讲下一页”等流程指令,只把它当作后续流程控制,answer 必须回答问题本身;禁止把“已完成答疑/回答完毕/等待后续问题/继续演示”当成答案。**
        **重要:若这份文档讲的就是你灵枢自己(介绍灵枢的定位/架构/能力/课题成果),回答用第一人称('我'/'我的')、结合你真实的自我认知,别把自己当外人。**
        **重要:若听众问的是“你是谁/你的价值/你和某工具相比/你能解决什么”,先点明“我是灵枢”,再基于当前文档说明你的定位、边界和差异价值;对外部工具只说明协作关系和分工,不要贬低或臆造对方能力。**
        \(context)
        """
        let session = LingShuAgentSession(id: "qa-\(UUID().uuidString.prefix(5))", system: sys, tools: [],
                                          model: host.controlPlaneModelAdapter(.deliveryComposer), maxTurns: 1)
        let r = await session.send("听众说:\(input)")
        guard case .completed(let raw) = r else { return Self.fallbackPresentationIntent(input) }
        let clean = LingShuReasoningText.stripThinkTags(raw)
        lingShuControlLog("演示意图分类 input=「\(input)」→ intent=\(LingShuState.jsonField(clean, "intent") ?? "nil") page=\(LingShuState.jsonField(clean, "page") ?? "nil") | raw=「\(clean.replacingOccurrences(of: "\n", with: " ").prefix(180))」")
        switch (LingShuState.jsonField(clean, "intent") ?? "").lowercased() {
        case "pause":  return (.pause, "")
        case "resume": return (.resume, "")
        case "stop":   return (.stop, "")
        case "pace":
            let p = LingShuPresentationPace(rawValue: (LingShuState.jsonField(clean, "pace") ?? "").lowercased()) ?? .brief
            return (.pace(p), "")
        case "seek":
            // 信大脑出的归一化整数;它没给/给歪了才用轻量兜底抽阿拉伯数字。
            let page = Int(LingShuState.jsonField(clean, "page")?.trimmingCharacters(in: .whitespaces) ?? "") ?? Self.parsePresentationResumePage(input)
            if let page, page > 0 { return (.seek(page), "") }
            return (.question, "你想跳到第几页?说个页号我就翻过去。")
        case "question":
            // 正常路径**纯大脑判定**(用户定调:大脑解析输入、判断答疑/翻页、翻页页号由大脑归一化,不在这用字典死匹配)。
            // 大脑收到了系统指令(Anthropic system 丢失已修)就会正确分类;确定性兜底只在大脑**不可用**时兜(见 fallbackPresentationIntent)。
            let a = (LingShuState.jsonField(clean, "answer") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = await presentationQuestionAnswer(input: input, candidate: a, beat: beat, title: title)
            return (.question, answer)
        default:
            return Self.fallbackPresentationIntent(input)
        }
    }

    /// 演示答疑正文闸:分类器可能把“答完继续等待”这类流程尾巴写成 answer。
    /// 这里不做领域定制,只保证“问题答案”和“后续流程状态”分离:空答案/状态话术 → 用当前演示上下文再让主脑补一版真正答疑。
    private func presentationQuestionAnswer(
        input: String,
        candidate: String,
        beat: LingShuPresentationBeat?,
        title: String
    ) async -> String {
        let cleanedCandidate = Self.cleanPresentationAnswer(candidate)
        if Self.presentationAnswerIsSubstantive(cleanedCandidate) { return cleanedCandidate }
        guard let host else {
            return cleanedCandidate.isEmpty ? Self.fallbackPresentationQuestionAnswer(input: input, beat: beat, title: title) : cleanedCandidate
        }
        let question = Self.presentationQuestionOnly(input)
        let pageContext = beat.map {
            "文档《\(title)》第 \($0.pageNumber) 页真实内容:\n\(String($0.verbatim.prefix(1_200)))"
        } ?? "正在演示《\(title)》,暂无当前页文本。"
        let sys = """
        你是演示现场的答疑者,正在基于当前材料回答听众追问。
        规则:
        1. 只输出可以直接说给听众听的答案正文,不要 JSON、markdown 表格、前后缀。
        2. 如果用户原话里夹带“答完继续/等待后续问题/继续演示/下一页”等流程指令,那只是后续状态,不要写进答案正文。
        3. 禁止只说“回答完毕、已完成答疑、等待后续问题、当前继续停在某页”。
        4. 结合当前页和材料主题回答,不知道就明确说边界,不要编造材料没有的事实。
        5. 40-180 字,口语化、清楚、有结论。
        \(pageContext)
        """
        let user = """
        听众真正的问题:
        \(question)

        上游候选答案(可能为空,也可能只是流程状态,仅供参考):
        \(cleanedCandidate)
        """
        let session = LingShuAgentSession(
            id: "qa-answer-\(UUID().uuidString.prefix(5))",
            system: LingShuPersona.system(sys),
            tools: [],
            model: host.controlPlaneModelAdapter(.deliveryComposer, timeoutOverride: 20),
            maxTurns: 1
        )
        let r = await session.send(user)
        if case .completed(let raw) = r {
            let answer = Self.cleanPresentationAnswer(LingShuReasoningText.stripThinkTags(raw))
            if Self.presentationAnswerIsSubstantive(answer) {
                lingShuControlLog("演示答疑修正 input=「\(input)」→ \(answer.replacingOccurrences(of: "\n", with: " ").prefix(160))")
                return answer
            }
        }
        if Self.presentationAnswerIsSubstantive(cleanedCandidate) { return cleanedCandidate }
        return Self.fallbackPresentationQuestionAnswer(input: input, beat: beat, title: title)
    }

    nonisolated static func presentationAnswerIsSubstantive(_ text: String) -> Bool {
        let clean = cleanPresentationAnswer(text)
        guard clean.count >= 24 else { return false }
        if LingShuInteractionFulfillment.isHollowInteractionStatus(clean) { return false }
        if LingShuInteractionFulfillment.isPageNarrationStatus(clean) { return false }
        if LingShuInteractionFulfillment.isArtifactInventoryStatus(clean) { return false }
        let compact = clean
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = ["这个问题我先记下", "演示后细聊", "回答完毕", "等待后续问题", "继续留在全屏演示状态"]
        if placeholders.contains(where: { compact.contains($0) }) { return false }
        return true
    }

    nonisolated static func presentationQuestionOnly(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["老师提问:", "老师提问：", "提问:", "提问：", "问题:", "问题："] {
            if let range = text.range(of: marker) {
                text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if let q = text.firstIndex(where: { $0 == "?" || $0 == "？" }) {
            text = String(text[...q]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for marker in ["答完", "回答完", "说完", "讲完", "等待后续", "继续等待", "继续演示"] {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    nonisolated private static func cleanPresentationAnswer(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func fallbackPresentationQuestionAnswer(
        input: String,
        beat: LingShuPresentationBeat?,
        title: String
    ) -> String {
        let question = presentationQuestionOnly(input)
        let context = beat?.verbatim.trimmingCharacters(in: .whitespacesAndNewlines) ?? title
        let compact = context
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.isEmpty {
            return "我是灵枢。这个问题我会按当前材料回答:我的价值在于把目标、任务、执行、监控、验收和记忆放进统一中枢,让工作从零散对话变成可追踪、可复盘的交付过程。"
        }
        return "我是灵枢。结合当前材料,这个问题的核心是:我不是替代某个单点工具,而是把目标理解、能力调度、执行过程、监控验收和历史记忆串成一个统一中枢。\(question.isEmpty ? "" : "你问的点,可以理解为我负责把复杂任务组织成可交付的工程闭环。")"
    }

    /// **仅 LLM 不可用时的关键词兜底**(主路径是上面的语义分类)。
    nonisolated static func fallbackPresentationIntent(_ s: String) -> (intent: PresentationUtteranceIntent, answer: String) {
        if isPresentationStopIntent(s)   { return (.stop, "") }
        if isPresentationResumeIntent(s) { return (.resume, "") }
        if isPresentationPauseIntent(s)  { return (.pause, "") }
        if let p = explicitSeekPage(s) { return (.seek(p), "") }
        return (.question, "这个问题我先记下,演示后细聊。")
    }

    /// **确定性跳页检测**(安全网,不靠大脑):仅当句子是**明确的导航**(含「从第/跳到/翻到/回到/看第/到第」或「第N页+开始/重新/讲起」
    /// 或基本就是纯页号「第N页」「N」)且**不含疑问**时,返回阿拉伯页号;否则 nil。带数字的提问(如「第2页那个引擎为啥选?」)不会误判。
    nonisolated static func explicitSeekPage(_ s: String) -> Int? {
        let t = s.replacingOccurrences(of: " ", with: "")
        if t.contains("?") || t.contains("?") || t.contains("为什么") || t.contains("怎么") || t.contains("是什么") || t.contains("吗") { return nil }
        guard let page = parsePresentationResumePage(t), page > 0 else { return nil }
        // 明确的导航动词(动词+第):稳,不会误伤"这一页讲得不错"这种评论。
        let navVerbs = ["从第", "跳到", "跳第", "翻到", "翻第", "回到", "看第", "到第", "去第"]
        if navVerbs.contains(where: { t.contains($0) }) { return page }
        if t.hasPrefix("第") && t.contains("页") { return page }   // 「第二页开始讲…」开头的页面陈述
        // 纯页号:「N」「第N页」「N页」(阿拉伯或中文,去掉第/页后基本只剩数字)。
        let bare = t.replacingOccurrences(of: "第", with: "").replacingOccurrences(of: "页", with: "")
        return (bare.count <= 3 && parsePresentationResumePage(bare) == page) ? page : nil
    }

    /// 念出答疑回答(进聊天流 + TTS 念完):答疑后常接 c.resume(seekTo:),故必须走串行通道。
    private func speakPresentationAnswer(_ answer: String, recordID: String?) async {
        await sayPresentationLine(answer, recordID: recordID)
    }

    /// **演示中串行念一句**(确认句 / 答疑回答 / 篇间播报):进聊天气泡 → **抑制气泡自动朗读** → 显式念 → await 念完。
    /// 演示里任何要出声的话都走这条串行发声通道,绝不靠气泡自动朗读——否则会和续演讲稿抢同一发声通道(代次互掐)→ 跳页。
    private func sayPresentationLine(_ text: String, recordID: String? = nil) async {
        appendPresentationLine(text, recordID: recordID)
        if let voice = host?.voiceManager {
            voice.speakPresentationNarration(text)
            host?.recordSpokenLine(text)
            await voice.awaitPlaybackDone(maxSeconds: 30)
        }
        finishPresentationInteraction(recordID, summary: text)
    }

    /// 进聊天气泡 + **抑制气泡自动朗读**(标记为已念)。纯 append 不出声。
    private func appendPresentationLine(_ text: String, recordID: String? = nil) {
        guard let host else { return }
        let bubble = ChatMessage(speaker: "灵枢", text: text, isUser: false, taskRecordID: recordID)
        host.lastSpokenMessageID = bubble.id
        host.chatMessages.append(bubble)
    }

    nonisolated static func isPresentationStopIntent(_ s: String) -> Bool {
        let t = s.replacingOccurrences(of: " ", with: "")
        return ["停止演示", "结束演示", "退出演示", "不看了", "不演了", "别演了", "够了"].contains { t.contains($0) }
    }

    /// 暂停保持(可续):说「暂停/停一下/等一下」→ 停在当前页,等「继续」再讲。
    nonisolated static func isPresentationPauseIntent(_ s: String) -> Bool {
        let t = s.replacingOccurrences(of: " ", with: "")
        return ["暂停", "停一下", "停一会", "先停", "等一下", "等等", "稍等"].contains { t.contains($0) }
    }

    /// 继续演示:暂停态下说「继续/接着讲/往下讲」→ 从当前页续。
    nonisolated static func isPresentationResumeIntent(_ s: String) -> Bool {
        let t = s.replacingOccurrences(of: " ", with: "")
        return ["继续", "接着讲", "接着演", "往下讲", "往下演", "接着说"].contains { t.contains($0) }
    }

    /// 解析"从第N页/回到第N页/第N页"里的页号(1-based);没有则 nil。
    /// 这里只做窄域页号归一(阿拉伯数字 + 常见中文数字),属于演示控制安全网,不参与通用分诊。
    nonisolated static func parsePresentationResumePage(_ s: String) -> Int? {
        if let r = s.range(of: "[0-9]+", options: .regularExpression), let n = Int(s[r]), n > 0 { return n }
        guard let r = s.range(of: "[零一二三四五六七八九十两〇]+", options: .regularExpression) else { return nil }
        return chinesePageNumber(String(s[r]))
    }

    nonisolated private static func chinesePageNumber(_ raw: String) -> Int? {
        let text = raw.replacingOccurrences(of: "两", with: "二").replacingOccurrences(of: "〇", with: "零")
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if text == "十" { return 10 }
        if text.contains("十") {
            let parts = text.split(separator: "十", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let tens = parts[0].isEmpty ? 1 : (parts[0].compactMap { digits[$0] }.first ?? -1)
            let ones = parts[1].isEmpty ? 0 : (parts[1].compactMap { digits[$0] }.first ?? -1)
            let value = tens * 10 + ones
            return value > 0 ? value : nil
        }
        let value = text.reduce(0) { acc, ch in acc * 10 + (digits[ch] ?? -1) }
        return value > 0 ? value : nil
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
