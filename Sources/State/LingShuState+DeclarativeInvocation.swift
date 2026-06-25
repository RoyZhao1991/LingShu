import Foundation

/// **声明式调插件**接进 LingShuState:可调插件注册表 + 路由(`@演示`/`用录制技能`/「+」菜单 pinned → 确定性直达)。
/// 这是对反复出现的「大脑误调用/绕开新插件」的系统性修复——用户一旦显式声明,就不再交给大脑判断。
@MainActor
extension LingShuState {

    /// 当前**可被声明式调用**的插件/能力清单(给「+」菜单展示 + 文本前缀匹配)。
    /// 按可用性实时过滤(如录制要计算机控制授权;演示总在)。
    func invocablePlugins() -> [LingShuInvocablePlugin] {
        var list: [LingShuInvocablePlugin] = [
            .init(id: "present", displayName: "演示与答疑",
                  aliases: ["演示", "讲解", "present", "放映"],
                  subtitle: "把文档/网页正式演示讲解,边讲边答疑", icon: "play.rectangle.on.rectangle"),
            .init(id: "record", displayName: "录制技能",
                  aliases: ["录制", "记录技能", "学技能", "record"],
                  subtitle: "看你做一遍→学成可复用技能,以后一句话带新参数 replay", icon: "record.circle"),
        ]
        // 已学会的过程技能,每个也可直接声明调用(用 X 技能)。
        for s in LingShuProcedureSkillRouter.loadProcedures().prefix(8) {
            list.append(.init(id: "proc:\(s.id)", displayName: s.title,
                              aliases: s.triggers, subtitle: "已学会的技能" + (s.parameters.isEmpty ? "" : "(参数:\(s.parameters.map(\.name).joined(separator: "、")))"),
                              icon: "wand.and.stars"))
        }
        return list
    }

    /// 文本声明(`@演示 …`)或「+」菜单 pinned → 确定性路由到对应插件。返回 true=已接管。
    /// 顺序:pinned 优先(用户刚在菜单点了),否则看文本前缀。
    func handleDeclarativeInvocationIfNeeded(_ prompt: String) -> Bool {
        let plugins = invocablePlugins()
        // ① 「+」菜单 pinned:整条输入直达该插件,用一次即清。
        if let pinned = pinnedPluginInvocation {
            pinnedPluginInvocation = nil
            chatMessages.append(.init(speaker: "你", text: prompt, isUser: true))
            routeDeclarative(pluginID: pinned, rest: prompt.trimmingCharacters(in: .whitespaces))
            return true
        }
        // ② 文本前缀声明:@演示 / 用录制技能 / …
        guard let hit = LingShuDeclarativeInvocation.detect(prompt, plugins: plugins) else { return false }
        chatMessages.append(.init(speaker: "你", text: prompt, isUser: true))
        appendTrace(kind: .route, actor: "声明式调用", title: "用户显式指定插件",
                    detail: "「\(hit.id)」直达,跳过大脑分诊。")
        routeDeclarative(pluginID: hit.id, rest: hit.rest)
        return true
    }

    /// 把(已确认的)输入路由给指定插件。
    private func routeDeclarative(pluginID: String, rest: String) {
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
