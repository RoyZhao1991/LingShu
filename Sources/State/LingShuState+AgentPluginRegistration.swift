import Foundation

/// **agent 即插件**的接入能力(取代写死的 delegate_to_codex/claude):给大脑两个**通用**工具——
/// `register_agent`(被告知本机有某 CLI agent → 注册进插件库)、`run_agent`(把活外包给某个已注册 agent)。
/// 任何 CLI agent 同一套,零硬编码;codex/claude 只是「被注册的两个 agent 插件」而已。
@MainActor
extension LingShuState {

    func agentPluginTools(recordIDProvider: @escaping @MainActor @Sendable () -> String? = { nil }) -> [LingShuAgentTool] {
        [registerAgentTool(), runAgentTool(recordIDProvider: recordIDProvider)]
    }

    private func registerAgentTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "register_agent",
            description: "把**本机一个外部 CLI agent** 注册成 agent 插件(被主人告知『本机有 X、怎么调』时用)。注册后即可 @它 声明式编排、或 run_agent 委托。入参:id(稳定标识如 codex)、name(显示名)、executable(可执行文件路径或命令名)、args(参数模板数组,用 {{objective}} 占位)、role(maker/checker/general)、aliases(可选别名)。**关键·权限:开发/产出类(maker)agent 的 args 必须带足够的写权限标志,否则它跑在只读沙箱里写不了文件、只能在对话里贴代码(无效交付)**。例:codex → [\"exec\",\"--sandbox\",\"workspace-write\",\"--skip-git-repo-check\",\"{{objective}}\"](workspace-write=可写工作目录;需要完整系统访问改 danger-full-access);claude → [\"-p\",\"{{objective}}\",\"--permission-mode\",\"bypassPermissions\",\"--output-format\",\"stream-json\",\"--verbose\"](stream-json 才能流式看到中间工具调用/过程,灵枢自动解析其 NDJSON 事件;text 则只出最终结果、无中间过程)。其它 CLI agent 按其自身的『跳过审批 / 允许写入』参数填。 ——以上 args 只解决『怎么整体跑它』。**若这个 agent 还有可枚举的子技能/插件生态(像 Codex 的插件、Claude 的 skills),要它们单独出现在「外部 agent 技能」菜单里、能被 @它·某技能 精确调用,必须额外给 `discover`**;只注册不给 discover=只能把活整体派给它、子技能不会露出(这正是『Claude 注册了却没有外部技能』的原因)。discover 三选一,**优先用①权威注册表(防伪、最可信)**:① **权威注册表源(首选)** `discover.registryFile`=该 agent 自己的『已装清单』文件 + `format`——**只认清单里真正装好的能力**,往任意目录塞假 SKILL.md 不会出现(根治『把别家技能复制进来冒充』)。**Claude 官方插件目录(用户在 Directory 里看到的全量 50 个官方+合作方插件)用 `registryFile=~/.claude/plugins/marketplaces/claude-plugins-official/.claude-plugin/marketplace.json` + `format=claude-marketplace-catalog`**(读权威市场目录全量 + 交叉 installed_plugins.json 标已装/可装);若只要它真已装那几个,改 `registryFile=~/.claude/plugins/installed_plugins.json` + `format=claude-installed-plugins`。**先 run_command 翻 ~/.claude/plugins/marketplaces 确认市场名再据实填**。② **文件源** `discover.skillsDir`=技能目录(每子目录一个 SKILL.md;Codex=`~/.codex/skills` 是它的权威技能目录,可用)+ `format=skill-md`。③ **命令源** `discover.args`=列举子能力的子命令(如 [\"plugin\",\"list\",\"--json\"])+ 对应 format。**铁律:只指向该 agent 的权威源(它自己装东西的地方),绝不自己造一个目录、更不许把别家 agent 的技能拷过来充数——那是假能力,会被验证打回**。不确定权威源在哪→先 run_command 去它的配置目录(~/.claude、~/.codex)翻清单文件。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"},\"executable\":{\"type\":\"string\"},\"args\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"role\":{\"type\":\"string\"},\"aliases\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"subtitle\":{\"type\":\"string\"},\"discover\":{\"type\":\"object\",\"description\":\"可选:怎么发现它的子技能/插件,让它们单列进「外部 agent 技能」。优先 registryFile(权威已装清单,防伪);或 skillsDir(技能目录)/args(列举命令);都要带 format(claude-installed-plugins / skill-md / codex-plugin-list)\",\"properties\":{\"registryFile\":{\"type\":\"string\"},\"skillsDir\":{\"type\":\"string\"},\"args\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"format\":{\"type\":\"string\"}}}},\"required\":[\"id\",\"name\",\"executable\",\"args\"]}"
        ) { [weak self] argsJSON in
            guard self != nil else { return "执行环境不可用" }
            guard let data = argsJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (obj["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
                  let name = (obj["name"] as? String), !name.isEmpty,
                  let exe = (obj["executable"] as? String), !exe.isEmpty,
                  let args = (obj["args"] as? [Any])?.compactMap({ $0 as? String }), !args.isEmpty
            else { return "参数不全(要 id/name/executable/args)。" }
            let role = LingShuAgentPlugin.Role(rawValue: (obj["role"] as? String) ?? "general") ?? .general
            let aliases = (obj["aliases"] as? [Any])?.compactMap { $0 as? String } ?? []
            // **子技能发现(可选)**:给了 discover 才把它的子技能/插件单列进「外部 agent 技能」;否则只能整体派活。
            var capabilities: AgentCapabilitySpec? = nil
            if let disc = obj["discover"] as? [String: Any] {
                let fmt = ((disc["format"] as? String)?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "skill-md"
                let dir = (disc["skillsDir"] as? String)?.trimmingCharacters(in: .whitespaces)
                let reg = (disc["registryFile"] as? String)?.trimmingCharacters(in: .whitespaces)
                let dargs = (disc["args"] as? [Any])?.compactMap { $0 as? String }
                let hasReg = (reg?.isEmpty == false), hasDir = (dir?.isEmpty == false), hasArgs = (dargs?.isEmpty == false)
                if hasReg || hasDir || hasArgs {
                    capabilities = AgentCapabilitySpec(discover: .init(args: hasArgs ? dargs : nil, skillsDir: hasDir ? dir : nil, registryFile: hasReg ? reg : nil, format: fmt), enable: nil, install: nil)
                }
            }
            let plugin = LingShuAgentPlugin(id: id, displayName: name, aliases: aliases, executable: exe,
                                            argsTemplate: args, role: role,
                                            subtitle: (obj["subtitle"] as? String) ?? "",
                                            icon: role == .maker ? "hammer.fill" : role == .checker ? "checkmark.seal.fill" : "cpu",
                                            capabilities: capabilities)
            guard plugin.executableExists else {
                return "没注册:找不到可执行文件「\(exe)」。确认路径对、文件可执行。"
            }
            // **注册时探活(2026-06-26 用户定调:加入前先验证真能用)**:不只看文件在,真跑一次验证——
            // 如 claude 装了但没登录,文件在但用不了。探活不过则**登记但标记为不可用**(不静默当可用),并当场告知主人。
            let wd = await MainActor.run { self?.agentWorkingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path }
            let probe = await LingShuAgentPluginStore.probeAvailability(plugin, workingDirectory: wd)
            var toRegister = plugin
            if !probe.ok {
                toRegister.available = false
                toRegister.unavailableReason = probe.reason
                toRegister.lastCheckedAt = Date()
            } else {
                toRegister.available = true
                toRegister.lastCheckedAt = Date()
            }
            _ = LingShuAgentPluginStore.register(toRegister)
            // 配了子技能发现 → 立刻强制刷新能力面(否则要等 TTL/重启才在「外部 agent 技能」里露出)。
            if capabilities != nil { await MainActor.run { self?.refreshAgentCapabilities(force: true) } }
            else { await MainActor.run { self?.invalidateInvocablePluginCatalog() } }
            let discText = capabilities != nil ? "(已配子技能发现,正在扫描其技能库,稍后即在「外部 agent 技能」单列)" : ""
            let okText = probe.ok ? "探活通过·可用\(discText)" : "探活发现不可用:\(probe.reason)"
            await MainActor.run { self?.appendTrace(kind: probe.ok ? .system : .warning, actor: "agent插件",
                title: "注册 agent(\(probe.ok ? "可用" : "不可用"))", detail: "「\(name)」(\(role.rawValue))已入库,\(okText)。") }
            if probe.ok {
                return "已把「\(name)」注册成 agent 插件(role=\(role.rawValue),**探活通过·当前可用**)\(discText)。可 `@\(name) 目标` 声明式调用,或 run_agent 委托\(capabilities != nil ? ";它的子技能会单列进「外部 agent 技能」,可 @\(name)·某技能 精确调" : "")。"
            } else {
                return "「\(name)」已登记,但**探活发现当前不可用:\(probe.reason)**——已标记为不可用,不会被 @/派活(避免用时才暴露)。请先恢复(如该 CLI 登录 / 补凭据)后,重新 `register_agent` 探活即可启用。"
            }
        }
    }

    private func runAgentTool(recordIDProvider: @escaping @MainActor @Sendable () -> String?) -> LingShuAgentTool {
        LingShuAgentTool(
            name: "run_agent",
            description: "把一段活**外包给某个已注册的 agent 插件**(如开发外包 codex、验收外包 claude)。入参:agent(已注册 agent 的 id 或名字)、objective(自足目标)。先 register_agent 注册过才可用;有哪些可用 agent 见插件库。被委托的 agent 会作为**独立命名参与方**出现在任务时间线里(maker/checker 各自一条线,你只编排+验收,别替它写)。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"agent\":{\"type\":\"string\"},\"objective\":{\"type\":\"string\"}},\"required\":[\"agent\",\"objective\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            let want = (Self.jsonField(argsJSON, "agent") ?? "").trimmingCharacters(in: .whitespaces)
            let objective = (Self.jsonField(argsJSON, "objective") ?? "").trimmingCharacters(in: .whitespaces)
            guard !want.isEmpty, !objective.isEmpty else { return "要 agent 和 objective。" }
            let all = LingShuAgentPluginStore.load()
            guard let plugin = all.first(where: { $0.id == want || $0.allAliases.contains(where: { $0.caseInsensitiveCompare(want) == .orderedSame }) }) else {
                let names = all.map(\.displayName).joined(separator: "、")
                return "没有叫「\(want)」的已注册 agent。当前已注册:\(names.isEmpty ? "(无,先 register_agent)" : names)。"
            }
            guard plugin.isCallableNow else {
                let reason = plugin.unavailableReason?.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run { self.markAgentPluginCatalogChanged(agentID: plugin.id) }
                return "\(plugin.displayName) 当前不可用\(reason?.isEmpty == false ? ":\(reason!)" : ""),我已从可调用目录隐藏它。请先恢复后在自检里重新探活。"
            }
            // **架构合规(ARCHITECTURE.md §Task Journal「被调用 agent 的发言式进度」+ §Review「只展示真实参与者」)**:
            // 被委托的 agent 必须作为**任务时间线里的独立命名参与方**(maker 一条线、checker 另一条线),不再藏在灵枢名下当工具返回串。
            // 这正是用户要的「maker session ≠ checker session」可见化——codex=工作线程、审查员=验收线程,各自一条命名角色卡。
            // **角色按本任务绑定标,不靠 agent 固定 role**(agent 就是 agent,角色是任务级装配):
            // 这个 agent 在本任务是 maker → 「开发(maker)」;否则中性「受委托执行」。checker 由框架 runAgentChecker 另标。
            let (wd, rid) = await MainActor.run { (self.agentWorkingDirectory, recordIDProvider()) }
            let isTaskMaker = await MainActor.run { rid.flatMap { self.taskReviewBindings[$0] }?.maker.id == "external:\(plugin.id)" }
            let roleLabel = isTaskMaker ? "开发(maker)" : "受委托执行"
            let verb = isTaskMaker ? "开发" : "执行"
            await MainActor.run {
                self.appendTaskRecordMessage(rid, actor: plugin.displayName, role: "\(roleLabel)·受灵枢委托", kind: .agent,
                                             text: "▶ \(plugin.displayName) 接活(\(verb)):\(objective.prefix(160))")
                self.appendTrace(kind: .tool, actor: "agent·\(plugin.displayName)", title: "\(roleLabel) 执行中", detail: String(objective.prefix(60)))
            }
            // 流式进度:把 agent 输出尾部喂进 trace(运行时可见它在干活;参与方完成态在收尾落定)。
            let result = await LingShuAgentPluginStore.run(plugin, objective: objective, workingDirectory: wd, progress: { tail in
                Task { @MainActor [weak self] in
                    self?.appendTrace(kind: .tool, actor: "agent·\(plugin.displayName)", title: "\(roleLabel) 进展", detail: String(tail.suffix(70)))
                }
            })
            switch result {
            case .completed(let t):
                await MainActor.run {
                    self.appendTaskRecordMessage(rid, actor: plugin.displayName, role: "\(roleLabel)·交付", kind: .result, text: String(t.prefix(2000)))
                    self.appendTrace(kind: .result, actor: "agent·\(plugin.displayName)", title: "\(roleLabel) 完成", detail: String(t.prefix(60)))
                }
                return "【\(plugin.displayName) 已完成】\n\(t)"
            case .failure(let r):
                await MainActor.run {
                    if LingShuAgentPluginStore.plugin(id: plugin.id)?.isCallableNow != true {
                        self.markAgentPluginCatalogChanged(agentID: plugin.id)
                    }
                    self.appendTaskRecordMessage(rid, actor: plugin.displayName, role: "\(roleLabel)·未完成", kind: .warning, text: r)
                    self.appendTrace(kind: .warning, actor: "agent·\(plugin.displayName)", title: "\(roleLabel) 未完成", detail: r)
                }
                return "【\(plugin.displayName) 未完成】\(r)"
            }
        }
    }
}
