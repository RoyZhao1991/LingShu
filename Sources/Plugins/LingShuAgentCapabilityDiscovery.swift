import Foundation

/// **能力发现器(适配器模式的核心)**:跑某个 agent 自己声明的"列能力"命令,按声明的 `format` 选对应解析器,
/// 把异构输出**归一**成 `[LingShuAgentCapability]`。内核只调 `discover(agent)`——
/// `format → parser` 的映射是**唯一 agent-specific 的地方**;新 agent/新格式只需补一个**纯函数解析器**,内核不动。
enum LingShuAgentCapabilityDiscovery {

    /// 发现 = 按声明的源(文件目录扫技能 / 跑命令列插件)拿原始数据 + 按 format 解析。无 spec / 取不到 → 空。
    static func discover(_ agent: LingShuAgentPlugin) -> [LingShuAgentCapability] {
        guard let spec = agent.capabilities?.discover else { return [] }
        // **权威注册表源(防伪,最优先)**:读 agent 的"已装清单",只认真正装好的能力——往任意目录塞假文件不再生效。
        if let registry = spec.registryFile {
            return discoverFromRegistry(agentID: agent.id, format: spec.format,
                                        registryPath: (registry as NSString).expandingTildeInPath)
        }
        // 文件源:扫技能目录(每个子目录一个 SKILL.md)。
        if let dir = spec.skillsDir {
            return scanSkillsDir(agentID: agent.id, dir: (dir as NSString).expandingTildeInPath)
        }
        // 命令源:跑发现命令。
        if let args = spec.args {
            guard let output = runDiscovery(agent: agent, args: args) else {
                lingShuControlLog("agent能力发现[\(agent.id)]: 发现命令无输出(失败/超时)")
                return []
            }
            return parse(agentID: agent.id, format: spec.format, output: output)
        }
        return []
    }

    // MARK: - 技能源:扫目录里的 SKILL.md(原生技能,如 codex 的 imagegen / real-chinese-film-imagegen)

    /// 扫 `dir` 下每个含 `SKILL.md` 的子目录(含隐藏的 `.system/`),解析成统一能力。技能一律视为**已装·已启用**(文件在即可用)。
    static func scanSkillsDir(agentID: String, dir: String) -> [LingShuAgentCapability] {
        let fm = FileManager.default
        guard let skillMDs = findSkillManifests(under: dir, fm: fm) else { return [] }
        return skillMDs.compactMap { parseSkillManifest(agentID: agentID, skillDir: ($0 as NSString).deletingLastPathComponent, manifestPath: $0) }
    }

    /// **递归找出 dir 下所有 SKILL.md(任意深度,通用)**——不同 agent 技能层级深浅不一:
    /// Codex 浅(`~/.codex/skills/.system/imagegen/SKILL.md`),Claude 深(`~/.claude/plugins/marketplaces/.../plugins/<p>/skills/<s>/SKILL.md`)。
    /// 深度封顶 + 跳过 .git/cache/node_modules 等噪声目录,任何 agent 的技能目录都能扫到。
    private static func findSkillManifests(under dir: String, fm: FileManager, maxDepth: Int = 8) -> [String]? {
        guard fm.fileExists(atPath: dir) else { return nil }
        let skip: Set<String> = [".git", "node_modules", "cache", ".cache", "DerivedData", "__pycache__", ".venv"]
        var out: [String] = []
        func walk(_ path: String, depth: Int) {
            guard depth <= maxDepth, let entries = try? fm.contentsOfDirectory(atPath: path) else { return }
            if entries.contains("SKILL.md") { out.append((path as NSString).appendingPathComponent("SKILL.md")) }
            for e in entries where !skip.contains(e) && !e.hasPrefix(".git") {
                let p = (path as NSString).appendingPathComponent(e)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { walk(p, depth: depth + 1) }
            }
        }
        walk(dir, depth: 0)
        return out
    }

    /// 解析一个技能:SKILL.md frontmatter 取 name/description;同目录 `agents/*.yaml` 的 interface 取 display_name/short_description(更友好)。
    static func parseSkillManifest(agentID: String, skillDir: String, manifestPath: String) -> LingShuAgentCapability? {
        guard let md = try? String(contentsOfFile: manifestPath, encoding: .utf8) else { return nil }
        let fmName = yamlScalar(md, key: "name") ?? (skillDir as NSString).lastPathComponent
        let fmDesc = yamlScalar(md, key: "description") ?? ""
        // 友好展示名/短描:agents/*.yaml 的 interface(如 "Image Gen")。
        var displayName: String?; var shortDesc: String?
        if let agentsDir = try? FileManager.default.contentsOfDirectory(atPath: (skillDir as NSString).appendingPathComponent("agents")) {
            for y in agentsDir where y.hasSuffix(".yaml") || y.hasSuffix(".yml") {
                if let yaml = try? String(contentsOfFile: (skillDir as NSString).appendingPathComponent("agents/" + y), encoding: .utf8) {
                    displayName = displayName ?? yamlScalar(yaml, key: "display_name")
                    shortDesc = shortDesc ?? yamlScalar(yaml, key: "short_description")
                }
            }
        }
        let id = fmName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        return LingShuAgentCapability(
            agentID: agentID, id: id,
            name: displayName ?? id,
            summary: shortDesc ?? String(fmDesc.prefix(120)),
            category: "技能", enabled: true, installed: true)
    }

    /// 从 YAML/frontmatter 文本里取某个标量键的值(line-based,足够稳:`key: "值"` / `key: 值`)。
    private static func yamlScalar(_ text: String, key: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(key + ":") else { continue }
            var v = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            return v.isEmpty ? nil : v
        }
        return nil
    }

    // MARK: - 权威注册表源(防伪):只认 agent 自己"已装清单"里的能力

    /// 读 agent 的权威已装清单文件,按 format 解析成能力。**只认清单里真装的**——往任意目录塞假 SKILL.md 不会出现在这里(防伪根治)。
    static func discoverFromRegistry(agentID: String, format: String, registryPath: String) -> [LingShuAgentCapability] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: registryPath)) else {
            lingShuControlLog("agent能力发现[\(agentID)]: 权威注册表读不到(\(registryPath))")
            return []
        }
        switch format {
        case "claude-installed-plugins":  return parseClaudeInstalledPlugins(agentID: agentID, data: data)
        case "claude-marketplace-catalog": return parseClaudeMarketplaceCatalog(agentID: agentID, data: data)
        default:
            lingShuControlLog("agent能力发现[\(agentID)]: 未知注册表格式 \(format)")
            return []
        }
    }

    /// **Claude 市场目录 `.claude-plugin/marketplace.json`** → 官方插件全量目录(用户在 Directory 里看到的那些)。
    /// 结构 `{ name, plugins:[{name, description, source}] }`。交叉比对 `~/.claude/plugins/installed_plugins.json`:
    /// 已装的标 installed/enabled=true(可直接用),未装的=可装(@调用时走安装门,供应链红线需确认)。**只认目录里真有的,权威防伪**。
    static func parseClaudeMarketplaceCatalog(agentID: String, data: Data) -> [LingShuAgentCapability] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [[String: Any]] else { return [] }
        let installed = claudeInstalledPluginNames()
        let marketplace = (root["name"] as? String) ?? "claude-plugins-official"
        var out: [LingShuAgentCapability] = []
        var seen = Set<String>()
        for p in plugins {
            guard let name = (p["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  seen.insert(name.lowercased()).inserted else { continue }
            let isInstalled = installed.contains(name.lowercased())
            out.append(.init(agentID: agentID, id: name, name: name,
                             summary: (p["description"] as? String) ?? "",
                             category: marketplace, enabled: isInstalled, installed: isInstalled))
        }
        return out
    }

    /// 读 Claude 约定的已装清单 → 小写插件名集合(用于把市场目录里"已装"的标出来)。取不到=空(全当未装·可装)。
    private static func claudeInstalledPluginNames() -> Set<String> {
        let path = ("~/.claude/plugins/installed_plugins.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return [] }
        return Set(plugins.keys.map { String($0.split(separator: "@").first ?? "").lowercased() })
    }

    /// **Claude `installed_plugins.json`** → 统一能力。结构 `{ plugins: { "<name>@<marketplace>": [{ installPath, … }] } }`。
    /// 只枚举**真正已安装**的插件;每个插件再扫它自己 installPath 下的 SKILL.md(插件内的技能);无 SKILL.md(纯 MCP 插件如 github/stripe)则插件本身算一个能力。
    static func parseClaudeInstalledPlugins(agentID: String, data: Data) -> [LingShuAgentCapability] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return [] }
        let fm = FileManager.default
        var out: [LingShuAgentCapability] = []
        var seen = Set<String>()
        for (pluginKey, entriesAny) in plugins {
            guard let entries = entriesAny as? [[String: Any]],
                  let installPath = entries.first?["installPath"] as? String else { continue }
            let parts = pluginKey.split(separator: "@", maxSplits: 1)
            let pluginName = parts.first.map(String.init) ?? pluginKey
            let marketplace = parts.count > 1 ? String(parts[1]) : ""
            let skills = findSkillManifests(under: installPath, fm: fm) ?? []
            if skills.isEmpty {
                // 纯插件(无 SKILL.md,如 github/linear/slack/stripe MCP 插件)→ 插件本身算一个已装能力。
                guard seen.insert(pluginName).inserted else { continue }
                out.append(.init(agentID: agentID, id: pluginKey, name: pluginName,
                                 summary: "已安装插件", category: marketplace, enabled: true, installed: true))
            } else {
                for s in skills {
                    guard let cap = parseSkillManifest(agentID: agentID,
                                                       skillDir: (s as NSString).deletingLastPathComponent,
                                                       manifestPath: s),
                          seen.insert(cap.id).inserted else { continue }
                    var c = cap; c.category = marketplace.isEmpty ? pluginName : marketplace
                    out.append(c)
                }
            }
        }
        return out
    }

    /// 按 format 分发到解析器(适配器表)。未知 format → 空(不崩、不猜)。
    static func parse(agentID: String, format: String, output: String) -> [LingShuAgentCapability] {
        switch format {
        case "codex-plugin-list": return parseCodexPluginList(agentID: agentID, output: output)
        default:                  return []
        }
    }

    // MARK: - 解析器(纯函数,可单测,与进程执行解耦)

    /// **Codex `plugin list --json --available`** → 统一能力。形如 `{ installed:[…], available:[…] }`,
    /// 每项含 pluginId / name / marketplaceName / installed / enabled。
    static func parseCodexPluginList(agentID: String, output: String) -> [LingShuAgentCapability] {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [LingShuAgentCapability] = []
        var seen = Set<String>()
        for key in ["installed", "available"] {
            for item in (root[key] as? [[String: Any]]) ?? [] {
                guard let pid = item["pluginId"] as? String, !pid.isEmpty, seen.insert(pid).inserted else { continue }
                out.append(LingShuAgentCapability(
                    agentID: agentID,
                    id: pid,
                    name: (item["name"] as? String) ?? pid,
                    summary: (item["description"] as? String) ?? "",
                    category: (item["marketplaceName"] as? String) ?? "",
                    enabled: (item["enabled"] as? Bool) ?? false,
                    installed: (item["installed"] as? Bool) ?? (key == "installed")
                ))
            }
        }
        return out
    }

    /// **安装某个能力(供应链红线:调用方必须已取得用户明确确认)**。跑 agent 声明的 install 子命令(如 `codex plugin add <id>`)。
    /// 返回是否疑似成功 + 原始输出(真正生效由调用方随后 refresh 发现校验)。
    static func install(agent: LingShuAgentPlugin, capabilityID: String) -> (ok: Bool, output: String) {
        let args = agent.capabilities?.installArgs(for: capabilityID) ?? []
        guard !args.isEmpty else { return (false, "该 agent 未声明安装方式") }
        guard let output = runDiscovery(agent: agent, args: args, timeout: 180) else { return (false, "安装命令无输出/超时") }
        let lower = output.lowercased()
        return (!lower.contains("error") && !lower.contains("failed"), output)
    }

    // MARK: - 进程执行(发现命令是只读枚举,安全;超时保护)

    private static func runDiscovery(agent: LingShuAgentPlugin, args: [String], timeout: TimeInterval = 25) -> String? {
        let exe = agent.executableExists
            ? (FileManager.default.isExecutableFile(atPath: agent.executable) ? agent.executable : (LingShuAgentPlugin.resolveInPath(agent.executable) ?? agent.executable))
            : agent.executable
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        // app 以极简 env(env -i)启动,子 agent(codex 内部还要 shell 出 node)据此找不到工具 → 用用户登录 shell 的真实 PATH,落在 HOME(codex 读 ~/.codex)。
        var env = ProcessInfo.processInfo.environment
        if let loginPATH = LingShuAgentPluginStore.loginShellPATH { env["PATH"] = loginPATH }
        proc.environment = env
        proc.currentDirectoryURL = LingShuRuntimeEnvironment.homeDirectory
        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe; proc.standardError = errPipe
        do { try proc.run() } catch { return nil }
        // **必须边跑边排空管道**:发现输出(全市场 ~191 项 JSON)超过 64KB 管道缓冲,若等进程退出再读会写满→子进程阻塞→死锁。
        // 两根管道各起一个后台读到 EOF(进程关闭 stdout/stderr=退出/被杀时 EOF),再 join。
        let outBox = DataBox(); let errBox = DataBox()
        let readGroup = DispatchGroup()
        for (h, box) in [(outPipe.fileHandleForReading, outBox), (errPipe.fileHandleForReading, errBox)] {
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async { box.set(h.readDataToEndOfFile()); readGroup.leave() }
        }
        let exitGroup = DispatchGroup(); exitGroup.enter()
        DispatchQueue.global(qos: .utility).async { proc.waitUntilExit(); exitGroup.leave() }
        if exitGroup.wait(timeout: .now() + timeout) == .timedOut { proc.terminate() }
        _ = readGroup.wait(timeout: .now() + 5)   // 读到 EOF(进程退出/被杀后很快 EOF)
        return String(data: outBox.get(), encoding: .utf8)
    }

    /// 线程安全的数据盒(后台读管道写、主流程读;锁保护满足 Sendable)。
    private final class DataBox: @unchecked Sendable {
        private var data = Data(); private let lock = NSLock()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
