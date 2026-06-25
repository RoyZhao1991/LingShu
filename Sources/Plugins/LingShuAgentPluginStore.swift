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
    /// `progress`:**流式回调**——边跑边把 stdout/stderr 的**累计尾部**喂出来(对齐 codex/claude 的"看得到它在干活"),
    /// 不再阻塞到进程结束才一次性出结果(根治派发 agent「交给 X 后干等没进度」)。在后台队列回调,调用方自行 hop 到 UI 线程。
    nonisolated static func run(_ plugin: LingShuAgentPlugin, objective: String,
                               workingDirectory: String, environment: [String: String]? = nil,
                               progress: (@Sendable (String) -> Void)? = nil) async -> AgentRunResult {
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
                // 增量读 + 累计尾部喂进度:stdout/stderr 任一来块就把"累计输出的尾部"推给 progress(看得到在干活)。
                // 用 @unchecked Sendable 缓冲类:`readabilityHandler` 是 @Sendable 闭包,不能直接改捕获的 var,经此类锁保护。
                let buf = OutputBuffer()
                let emit: @Sendable () -> Void = {
                    guard let progress else { return }
                    let tail = String(buf.combined().suffix(800)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tail.isEmpty { progress(tail) }
                }
                outH.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty else { return }
                    buf.appendOut(d); emit()
                }
                errH.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty else { return }
                    buf.appendErr(d); emit()
                }
                do { try proc.run() } catch {
                    outH.readabilityHandler = nil; errH.readabilityHandler = nil
                    cont.resume(returning: .failure("启动 \(plugin.displayName) 失败:\(error.localizedDescription)")); return
                }
                let timeoutBox = TimeoutFlag()
                let timeoutItem = DispatchWorkItem { if proc.isRunning { timeoutBox.set(); proc.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
                proc.waitUntilExit()
                timeoutItem.cancel()
                outH.readabilityHandler = nil; errH.readabilityHandler = nil
                // 收尾把残余缓冲读干净(handler 置 nil 后可能还有最后一块)。
                let restOut = outH.readDataToEndOfFile(); if !restOut.isEmpty { buf.appendOut(restOut) }
                let restErr = errH.readDataToEndOfFile(); if !restErr.isEmpty { buf.appendErr(restErr) }
                let timedOut = timeoutBox.isSet
                let text = buf.outString(); let errText = buf.errString()
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

/// 线程安全累积子进程 stdout/stderr(供流式进度的 @Sendable readabilityHandler 用)。
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
    func combined() -> String {
        lock.lock(); defer { lock.unlock() }
        return (String(data: out, encoding: .utf8) ?? "") + (String(data: err, encoding: .utf8) ?? "")
    }
    func outString() -> String { lock.lock(); defer { lock.unlock() }; return String(data: out, encoding: .utf8) ?? "" }
    func errString() -> String { lock.lock(); defer { lock.unlock() }; return String(data: err, encoding: .utf8) ?? "" }
}

/// 线程安全的软超时标志(供超时 DispatchWorkItem 与主流程跨线程读写)。
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
