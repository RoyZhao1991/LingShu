import Foundation

/// **agent 插件库**:把被告知可用的外部 CLI agent 注册描述符持久化到
/// `~/Library/Application Support/LingShu/AgentPlugins/*.json`(跨重启),并提供统一执行(跑 CLI、软超时、取结果)。
/// **不为 codex/claude 写专门的桥**——任何 CLI agent 同一套注册+执行流程。
enum LingShuAgentPluginStore {

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LingShu/AgentPlugins", isDirectory: true)

    /// 加载已注册的全部 agent 插件。
    static func load(from dir: URL = directory) -> [LingShuAgentPlugin] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(LingShuAgentPlugin.self, from: data)
            }
    }

    /// 注册(写盘);id 相同则覆盖。返回是否成功。
    @discardableResult
    static func register(_ plugin: LingShuAgentPlugin, into dir: URL = directory) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(plugin.id).json")
        guard let data = try? JSONEncoder().encode(plugin) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// 注销一个 agent 插件。
    @discardableResult
    static func unregister(id: String, from dir: URL = directory) -> Bool {
        let url = dir.appendingPathComponent("\(id).json")
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// 取某个已注册 agent 插件。
    static func plugin(id: String, from dir: URL = directory) -> LingShuAgentPlugin? {
        load(from: dir).first { $0.id == id }
    }

    // MARK: 统一执行(跑 CLI agent)

    /// 跑一个 agent 插件:把 objective 填进参数、执行 CLI、软超时内取 stdout。任何 agent 同一套。
    /// 在工作目录 `workingDirectory` 下跑(编码类 agent 要在仓库里读改)。`env` 给定则用之(可剥会话标记)。
    nonisolated static func run(_ plugin: LingShuAgentPlugin, objective: String,
                               workingDirectory: String, environment: [String: String]? = nil) async -> AgentRunResult {
        let exe = FileManager.default.isExecutableFile(atPath: plugin.executable)
            ? plugin.executable
            : (LingShuAgentPlugin.resolveInPath(plugin.executable) ?? plugin.executable)
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            return .failure("\(plugin.displayName) 不可用:找不到可执行文件 \(plugin.executable)")
        }
        let args = plugin.resolvedArguments(objective: objective)
        let timeout = TimeInterval(plugin.timeoutSeconds)
        return await withCheckedContinuation { (cont: CheckedContinuation<AgentRunResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: exe)
                proc.arguments = args
                if let environment { proc.environment = environment }
                let dir = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                if !dir.isEmpty, FileManager.default.fileExists(atPath: dir) {
                    proc.currentDirectoryURL = URL(fileURLWithPath: dir)
                }
                let out = Pipe(); let err = Pipe()
                proc.standardOutput = out; proc.standardError = err
                let outH = out.fileHandleForReading; let errH = err.fileHandleForReading
                var outData = Data(); var errData = Data()
                let group = DispatchGroup()
                group.enter(); DispatchQueue.global().async { outData = outH.readDataToEndOfFile(); group.leave() }
                group.enter(); DispatchQueue.global().async { errData = errH.readDataToEndOfFile(); group.leave() }
                do { try proc.run() } catch {
                    cont.resume(returning: .failure("启动 \(plugin.displayName) 失败:\(error.localizedDescription)")); return
                }
                var timedOut = false
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if proc.isRunning { timedOut = true; proc.terminate() }
                }
                group.wait()
                proc.waitUntilExit()
                let text = String(data: outData, encoding: .utf8) ?? ""
                let errText = String(data: errData, encoding: .utf8) ?? ""
                if timedOut { cont.resume(returning: .failure("\(plugin.displayName) 软超时(\(plugin.timeoutSeconds)s)")) }
                else if proc.terminationStatus != 0 && text.isEmpty {
                    cont.resume(returning: .failure("\(plugin.displayName) 退出码 \(proc.terminationStatus):\(errText.isEmpty ? "无输出" : String(errText.prefix(300)))"))
                } else {
                    cont.resume(returning: .completed(text.isEmpty ? errText : text))
                }
            }
        }
    }

    enum AgentRunResult: Sendable {
        case completed(String)
        case failure(String)
    }
}
