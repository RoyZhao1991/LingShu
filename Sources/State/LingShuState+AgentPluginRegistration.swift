import Foundation

/// **agent 即插件**的接入能力(取代写死的 delegate_to_codex/claude):给大脑两个**通用**工具——
/// `register_agent`(被告知本机有某 CLI agent → 注册进插件库)、`run_agent`(把活外包给某个已注册 agent)。
/// 任何 CLI agent 同一套,零硬编码;codex/claude 只是「被注册的两个 agent 插件」而已。
@MainActor
extension LingShuState {

    func agentPluginTools() -> [LingShuAgentTool] {
        [registerAgentTool(), runAgentTool()]
    }

    private func registerAgentTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "register_agent",
            description: "把**本机一个外部 CLI agent** 注册成 agent 插件(被主人告知『本机有 X、怎么调』时用)。注册后即可 @它 声明式编排、或 run_agent 委托。入参:id(稳定标识如 codex)、name(显示名)、executable(可执行文件路径或命令名)、args(参数模板数组,用 {{objective}} 占位,如 [\"exec\",\"{{objective}}\"] 或 [\"-p\",\"{{objective}}\"])、role(maker/checker/general)、aliases(可选别名)。",
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
            guard plugin.isAvailableNow else {
                return "没注册:找不到可执行文件「\(exe)」。确认路径对、文件可执行。"
            }
            _ = LingShuAgentPluginStore.register(plugin)
            await MainActor.run { self?.appendTrace(kind: .system, actor: "agent插件", title: "注册 agent", detail: "「\(name)」(\(role.rawValue))已入插件库,可 @\(name) 调用。") }
            return "已把「\(name)」注册成 agent 插件(role=\(role.rawValue))。以后可 `@\(name) 目标` 声明式调用,或 run_agent 委托。"
        }
    }

    private func runAgentTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "run_agent",
            description: "把一段活**外包给某个已注册的 agent 插件**(如开发外包 codex、验收外包 claude)。入参:agent(已注册 agent 的 id 或名字)、objective(自足目标)。先 register_agent 注册过才可用;有哪些可用 agent 见插件库。",
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
            let wd = await MainActor.run { self.codexWorkingDirectory }
            let result = await LingShuAgentPluginStore.run(plugin, objective: objective, workingDirectory: wd)
            switch result {
            case .completed(let t): return "【\(plugin.displayName) 已完成】\n\(t)"
            case .failure(let r):   return "【\(plugin.displayName) 未完成】\(r)"
            }
        }
    }
}
