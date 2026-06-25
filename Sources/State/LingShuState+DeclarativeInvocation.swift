import Foundation

/// **声明式调插件**接进 LingShuState:可调插件注册表 + 路由(`@演示`/`用录制技能`/「+」菜单 pinned → 确定性直达)。
/// 这是对反复出现的「大脑误调用/绕开新插件」的系统性修复——用户一旦显式声明,就不再交给大脑判断。
@MainActor
extension LingShuState {

    /// 当前**可被声明式调用**的插件/能力清单(给「+」菜单展示 + 文本前缀匹配)。
    /// 按可用性实时过滤(如录制要计算机控制授权;演示总在)。
    func invocablePlugins() -> [LingShuInvocablePlugin] {
        var list: [LingShuInvocablePlugin] = []
        // **外部 agent**(可用才出现):声明式直达,跳过大脑判断要不要委托。多个 agent 组合=maker→checker 管线。
        if codexAuthStatus == "已登录" {
            list.append(.init(id: "codex", displayName: "Codex",
                              aliases: ["codex", "Codex"],
                              subtitle: "外包给 Codex 开发(仓库内自主读改跑测,擅长重型编码)", icon: "hammer.fill", kind: .agent))
        }
        if ClaudeBridge.isAvailable() {
            list.append(.init(id: "claude", displayName: "Claude",
                              aliases: ["claude", "Claude"],
                              subtitle: "外包给 Claude Code 做/独立验收(跨厂商第二视角,maker≠checker)", icon: "checkmark.seal.fill", kind: .agent))
        }
        // **插件**
        list.append(contentsOf: [
            .init(id: "present", displayName: "演示与答疑",
                  aliases: ["演示", "讲解", "present", "放映"],
                  subtitle: "把文档/网页正式演示讲解,边讲边答疑", icon: "play.rectangle.on.rectangle"),
            .init(id: "record", displayName: "录制技能",
                  aliases: ["录制", "记录技能", "学技能", "record"],
                  subtitle: "看你做一遍→学成可复用技能,以后一句话带新参数 replay", icon: "record.circle"),
        ])
        // 已学会的过程技能,每个也可直接声明调用(用 X 技能)。
        for s in LingShuProcedureSkillRouter.loadProcedures().prefix(8) {
            list.append(.init(id: "proc:\(s.id)", displayName: s.title,
                              aliases: s.triggers, subtitle: "已学会的技能" + (s.parameters.isEmpty ? "" : "(参数:\(s.parameters.map(\.name).joined(separator: "、")))"),
                              icon: "wand.and.stars"))
        }
        return list
    }

    /// 文本声明(`@Codex 开发X @Claude 验收`/`@演示 …`)或「+」菜单 pinned(可多选)→ 确定性路由。返回 true=已接管。
    func handleDeclarativeInvocationIfNeeded(_ prompt: String) -> Bool {
        let plugins = invocablePlugins()
        // ① 「+」菜单 pinned(可多选):整条输入按选中链路由(多 agent=maker→checker);用一次即清。
        if !pinnedInvocations.isEmpty {
            let ids = pinnedInvocations; pinnedInvocations = []
            chatMessages.append(.init(speaker: "你", text: prompt, isUser: true))
            runInvocationChain(buildPinnedSteps(ids: ids, input: prompt.trimmingCharacters(in: .whitespaces)), plugins: plugins)
            return true
        }
        // ② 文本 `@链式`(@Codex 开发X @Claude 验收Y)。
        let chain = LingShuDeclarativeInvocation.detectChain(prompt, plugins: plugins)
        if !chain.isEmpty {
            chatMessages.append(.init(speaker: "你", text: prompt, isUser: true))
            appendTrace(kind: .route, actor: "声明式调用", title: "用户显式指定",
                        detail: "链:\(chain.map { $0.id }.joined(separator: " → "))(跳过大脑分诊)")
            runInvocationChain(chain.map { (id: $0.id, segment: $0.segment) }, plugins: plugins)
            return true
        }
        // ③ 单个 `用X插件`/`切到X` 声明。
        if let hit = LingShuDeclarativeInvocation.detect(prompt, plugins: plugins) {
            chatMessages.append(.init(speaker: "你", text: prompt, isUser: true))
            runInvocationChain([(id: hit.id, segment: hit.rest)], plugins: plugins)
            return true
        }
        return false
    }

    /// 「+」菜单多选 → 执行链:agent 们 = **maker→checker**(首个做 input,其余复核上一步产出);插件各自处理 input。
    private func buildPinnedSteps(ids: [String], input: String) -> [(id: String, segment: String)] {
        ids.enumerated().map { i, id in
            (id, i == 0 ? input : "复核/验收上一步的产出物,对照原始要求:\(input)")
        }
    }

    /// 顺序执行声明链:agent 步走真委托(后一个 agent 拿到前一步产出→天然 maker≠checker);插件步路由各自插件。
    private func runInvocationChain(_ steps: [(id: String, segment: String)], plugins: [LingShuInvocablePlugin]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var priorOutput = ""
            for step in steps {
                guard let inv = plugins.first(where: { $0.id == step.id }) else { continue }
                switch inv.kind {
                case .agent:
                    let obj = step.segment + (priorOutput.isEmpty ? "" : "\n\n【上一步产出,供你参考/复核】\n" + String(priorOutput.prefix(4000)))
                    self.speakAndChat("交给 \(inv.displayName):\(step.segment.prefix(50))")
                    let out = (inv.id == "codex") ? await self.runDelegatedCodex(objective: obj)
                                                  : await self.runDelegatedClaude(objective: obj)
                    self.chatMessages.append(.init(speaker: "灵枢", text: "【\(inv.displayName)】\n\(out)", isUser: false))
                    priorOutput = out
                case .plugin:
                    self.routePlugin(pluginID: inv.id, rest: step.segment)
                }
            }
        }
    }

    /// 把(已确认的)输入路由给指定**插件**(present/record/proc)。
    private func routePlugin(pluginID: String, rest: String) {
        switch pluginID {
        case "present":
            let paths = Self.extractExistingFilePaths(rest)
            guard !paths.isEmpty else {
                speakAndChat("好,用演示插件——把要演示的文档路径发我(比如 /Users/.../方案.pdf),我就开讲。")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let msg = await self.startPresentation(paths: paths)
                self.chatMessages.append(.init(speaker: "灵枢", text: msg, isUser: false))
            }
        case "record":
            startProcedureRecording(name: rest.isEmpty ? nil : rest)
        default:
            // proc:<id> —— 直接 replay 这个已学会的技能(rest 里带参数)。
            if pluginID.hasPrefix("proc:") {
                let sid = String(pluginID.dropFirst("proc:".count))
                let skills = LingShuProcedureSkillRouter.loadProcedures()
                if let skill = skills.first(where: { $0.id == sid }) {
                    if let gate = computerControlGate(requiresAccessibility: true) { speakAndChat("要跑这个技能我得能操作界面。\(gate)"); return }
                    let params = LingShuProcedureSkillRouter.extractParams(rest, for: skill)
                    let missing = skill.missingParameters(given: params)
                    if !missing.isEmpty {
                        let hints = skill.parameters.filter { missing.contains($0.name) }.map { $0.example.isEmpty ? $0.name : "\($0.name)(如\($0.example))" }.joined(separator: "、")
                        speakAndChat("用「\(skill.title)」还差参数:\(hints)。一次说全我就跑。")
                    } else {
                        replayProcedure(skill: skill, params: params)
                    }
                    return
                }
            }
            speakAndChat("我不认识这个插件:\(pluginID)。")
        }
    }

    /// 从文本里抽**真实存在的**文件路径(声明式已表意图,不再要求意图词)。
    nonisolated static func extractExistingFilePaths(_ text: String) -> [String] {
        let exts = ["pdf", "pptx", "ppt", "docx", "doc", "key", "html", "htm", "md", "txt", "xlsx"]
        let pattern = "(/[^\\s,，；;、]+\\.(?:" + exts.joined(separator: "|") + "))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var paths: [String] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m { paths.append(ns.substring(with: m.range)) }
        }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }
}
