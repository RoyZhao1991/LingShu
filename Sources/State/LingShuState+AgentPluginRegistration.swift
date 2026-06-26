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
            description: "把**本机一个外部 CLI agent** 注册成 agent 插件(被主人告知『本机有 X、怎么调』时用)。注册后即可 @它 声明式编排、或 run_agent 委托。入参:id(稳定标识如 codex)、name(显示名)、executable(可执行文件路径或命令名)、args(参数模板数组,用 {{objective}} 占位)、role(maker/checker/general)、aliases(可选别名)。**关键·权限:开发/产出类(maker)agent 的 args 必须带足够的写权限标志,否则它跑在只读沙箱里写不了文件、只能在对话里贴代码(无效交付)**。例:codex → [\"exec\",\"--sandbox\",\"workspace-write\",\"--skip-git-repo-check\",\"{{objective}}\"](workspace-write=可写工作目录;需要完整系统访问改 danger-full-access);claude → [\"-p\",\"{{objective}}\",\"--permission-mode\",\"bypassPermissions\",\"--output-format\",\"text\"]。其它 CLI agent 按其自身的『跳过审批 / 允许写入』参数填。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"},\"executable\":{\"type\":\"string\"},\"args\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"role\":{\"type\":\"string\"},\"aliases\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"subtitle\":{\"type\":\"string\"}},\"required\":[\"id\",\"name\",\"executable\",\"args\"]}"
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
            let plugin = LingShuAgentPlugin(id: id, displayName: name, aliases: aliases, executable: exe,
                                            argsTemplate: args, role: role,
                                            subtitle: (obj["subtitle"] as? String) ?? "",
                                            icon: role == .maker ? "hammer.fill" : role == .checker ? "checkmark.seal.fill" : "cpu")
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
            let okText = probe.ok ? "探活通过·可用" : "探活发现不可用:\(probe.reason)"
            await MainActor.run { self?.appendTrace(kind: probe.ok ? .system : .warning, actor: "agent插件",
                title: "注册 agent(\(probe.ok ? "可用" : "不可用"))", detail: "「\(name)」(\(role.rawValue))已入库,\(okText)。") }
            if probe.ok {
                return "已把「\(name)」注册成 agent 插件(role=\(role.rawValue),**探活通过·当前可用**)。可 `@\(name) 目标` 声明式调用,或 run_agent 委托。"
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
            // **架构合规(ARCHITECTURE.md §Task Journal「被调用 agent 的发言式进度」+ §Review「只展示真实参与者」)**:
            // 被委托的 agent 必须作为**任务时间线里的独立命名参与方**(maker 一条线、checker 另一条线),不再藏在灵枢名下当工具返回串。
            // 这正是用户要的「maker session ≠ checker session」可见化——codex=工作线程、审查员=验收线程,各自一条命名角色卡。
            let roleLabel = plugin.role == .maker ? "开发(maker)" : plugin.role == .checker ? "验收(checker)" : "执行"
            let verb = plugin.role == .checker ? "复核" : "开发"
            let (wd, rid) = await MainActor.run { (self.agentWorkingDirectory, recordIDProvider()) }
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
                    self.appendTaskRecordMessage(rid, actor: plugin.displayName, role: "\(roleLabel)·未完成", kind: .warning, text: r)
                    self.appendTrace(kind: .warning, actor: "agent·\(plugin.displayName)", title: "\(roleLabel) 未完成", detail: r)
                }
                return "【\(plugin.displayName) 未完成】\(r)"
            }
        }
    }
}
