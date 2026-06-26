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

    // MARK: 可用性(注册时探活 + 用时回写)

    /// agent 输出/报错是否表明「文件在但用不了」=不可用(登录失效 / 缺凭据 / 未认证)。返回不可用原因,否则 nil。
    /// 只认**明确的认证类信号**(不碰 "not found"/"unauthorized" 这种宽泛词,避免代码 agent 正常输出里误命中)。
    nonisolated static func outputIndicatesUnavailable(_ text: String) -> String? {
        let lower = text.lowercased()
        let en: [(String, String)] = [
            ("not logged in", "未登录"), ("please run /login", "需登录(/login)"), ("run /login", "需登录(/login)"),
            ("please login", "需登录"), ("login required", "需登录"), ("not authenticated", "未认证"),
            ("no api key", "缺 API Key"), ("missing api key", "缺 API Key"), ("invalid api key", "API Key 无效"),
            ("api key required", "缺 API Key"), ("credit balance is too low", "额度不足"), ("quota exceeded", "额度用尽"),
        ]
        for (needle, reason) in en where lower.contains(needle) { return reason }
        let zh: [(String, String)] = [
            ("未登录", "未登录"), ("请先登录", "需登录"), ("登录已过期", "登录过期"), ("登录失效", "登录失效"),
            ("认证失败", "认证失败"), ("授权已过期", "授权过期"), ("额度不足", "额度不足"), ("余额不足", "余额不足"),
        ]
        for (needle, reason) in zh where text.contains(needle) { return reason }
        return nil
    }

    /// **注册时探活**:用极短超时跑一个无害 objective——登录/认证失败会很快返回(判不可用);
    /// 真在干活会软超时(没被 auth 挡住 → 视为可用)。返回 (是否可用, 不可用原因)。
    nonisolated static func probeAvailability(_ plugin: LingShuAgentPlugin, workingDirectory: String) async -> (ok: Bool, reason: String) {
        guard plugin.executableExists else { return (false, "找不到可执行文件 \(plugin.executable)") }
        var probe = plugin
        probe.timeoutSeconds = 25   // 短超时:auth 失败秒回,在干活则超时=视为可用
        switch await run(probe, objective: "只回复 READY,不要做其它任何事。", workingDirectory: workingDirectory) {
        case .completed(let t):
            if let reason = outputIndicatesUnavailable(t) { return (false, reason) }
            return (true, "")
        case .failure(let r):
            if let reason = outputIndicatesUnavailable(r) { return (false, reason) }
            if r.contains("软超时") { return (true, "") }            // 超时=在干活,没被 auth 挡 → 可用
            if r.contains("找不到可执行文件") { return (false, "找不到可执行文件") }
            return (false, r)
        }
    }

    /// 把某 agent 标记为**不可用**(用时发现登录失效等回写;@/派活前 `isAvailableNow` 据此过滤)。
    @discardableResult
    nonisolated static func markUnavailable(id: String, reason: String, in dir: URL = directory) -> Bool {
        guard var p = plugin(id: id, from: dir) else { return false }
        p.available = false; p.unavailableReason = reason; p.lastCheckedAt = Date()
        return register(p, into: dir)
    }

    /// 恢复某 agent 为**可用**(重新登录/探活通过后)。
    @discardableResult
    nonisolated static func markAvailable(id: String, in dir: URL = directory) -> Bool {
        guard var p = plugin(id: id, from: dir) else { return false }
        p.available = true; p.unavailableReason = nil; p.lastCheckedAt = Date()
        return register(p, into: dir)
    }

    // MARK: 统一执行(跑 CLI agent)

    /// 跑一个 agent 插件:把 objective 填进参数、执行 CLI、软超时内取 stdout。任何 agent 同一套。
    /// 在工作目录 `workingDirectory` 下跑(编码类 agent 要在仓库里读改)。`env` 给定则用之(可剥会话标记)。
    /// `progress`:**流式回调**——边跑边把 stdout/stderr 的**累计尾部**喂出来(对齐 codex/claude 的"看得到它在干活"),
    /// 不再阻塞到进程结束才一次性出结果(根治派发 agent「交给 X 后干等没进度」)。在后台队列回调,调用方自行 hop 到 UI 线程。
    nonisolated static func run(_ plugin: LingShuAgentPlugin, objective: String,
                               workingDirectory: String, environment: [String: String]? = nil,
                               progress: (@Sendable (String) -> Void)? = nil,
                               producedFilesSink: (@Sendable ([String]) -> Void)? = nil) async -> AgentRunResult {
        let exe = FileManager.default.isExecutableFile(atPath: plugin.executable)
            ? plugin.executable
            : (LingShuAgentPlugin.resolveInPath(plugin.executable) ?? plugin.executable)
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            return .failure("\(plugin.displayName) 不可用:找不到可执行文件 \(plugin.executable)")
        }
        let args = plugin.resolvedArguments(objective: objective)
        let timeout = TimeInterval(plugin.timeoutSeconds)
        // stream-json 调用(claude 等):中间事件要解析成人能读的过程摘要 + 最终从 result 字段提取(不写死 agent,看 argsTemplate)。
        let isStream = LingShuAgentStreamParser.isStreamJSON(plugin.argsTemplate)
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
                let clock = ActivityClock()   // 滚动空闲计时:每次有输出就 touch;空闲(连续无输出)超 timeout 才判卡死
                let emit: @Sendable () -> Void = {
                    guard let progress else { return }
                    let combined = buf.combined()
                    // stream-json:把 NDJSON 事件提炼成"🔧 工具 / 每轮摘要"(像 codex 看得到中间过程);text:直接喂尾部。
                    let tail = isStream
                        ? LingShuAgentStreamParser.progressSummary(fromStreamJSON: combined)
                        : String(combined.suffix(800)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tail.isEmpty { progress(tail) }
                }
                outH.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty else { return }
                    buf.appendOut(d); clock.touch(); emit()
                }
                errH.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty else { return }
                    buf.appendErr(d); clock.touch(); emit()
                }
                do { try proc.run() } catch {
                    outH.readabilityHandler = nil; errH.readabilityHandler = nil
                    cont.resume(returning: .failure("启动 \(plugin.displayName) 失败:\(error.localizedDescription)")); return
                }
                let timeoutBox = TimeoutFlag()
                // **滚动空闲超时(2026-06-26,用户定调:只要还在动就不该超时)**:timeout 不是绝对墙钟上限,而是「空闲窗口」——
                // 每 15s 巡检一次,只有连续 timeout 秒(默认600=10分钟)一个字都没吐(真卡死)才 terminate;
                // agent 还在流式吐输出 → clock 持续刷新 → idle 归零 → 永不误杀正在干活的大工程。
                let idleTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                idleTimer.schedule(deadline: .now() + 15, repeating: 15)
                idleTimer.setEventHandler {
                    guard proc.isRunning else { return }
                    if clock.idleSeconds() >= timeout { timeoutBox.set(); proc.terminate(); idleTimer.cancel() }
                }
                idleTimer.resume()
                proc.waitUntilExit()
                idleTimer.cancel()
                outH.readabilityHandler = nil; errH.readabilityHandler = nil
                // 收尾把残余缓冲读干净(handler 置 nil 后可能还有最后一块)。
                let restOut = outH.readDataToEndOfFile(); if !restOut.isEmpty { buf.appendOut(restOut) }
                let restErr = errH.readDataToEndOfFile(); if !restErr.isEmpty { buf.appendErr(restErr) }
                let timedOut = timeoutBox.isSet
                let text = buf.outString(); let errText = buf.errString()
                // stream-json:把 agent 真写过的文件(tool_use)精确回调出去,供上层登记产出物(根治共享目录串台)。
                // 即便超时也回调——超时前真写出的文件也是产出。
                if isStream, let producedFilesSink {
                    producedFilesSink(LingShuAgentStreamParser.producedFiles(fromStreamJSON: text))
                }
                // **可用性回写(2026-06-26)**:输出/报错含明确的登录/认证失败信号 → 这个 agent「文件在但用不了」。
                // 把插件标记为不可用(下次 @/派活前 isAvailableNow 据此过滤),并把这次当失败返回——别把"未登录"当成功产出。
                if !timedOut, let unavail = (outputIndicatesUnavailable(text) ?? outputIndicatesUnavailable(errText)) {
                    markUnavailable(id: plugin.id, reason: unavail)
                    cont.resume(returning: .failure("\(plugin.displayName) 当前不可用:\(unavail)。已标记该插件不可用,请先恢复(如登录/补凭据)再用。"))
                    return
                }
                if timedOut { cont.resume(returning: .failure("\(plugin.displayName) 软超时(连续\(plugin.timeoutSeconds)s无输出,疑似卡死)")) }
                else if proc.terminationStatus != 0 && text.isEmpty {
                    cont.resume(returning: .failure("\(plugin.displayName) 退出码 \(proc.terminationStatus):\(errText.isEmpty ? "无输出" : String(errText.prefix(300)))"))
                } else {
                    // stream-json:最终交付从 result 字段提取(否则返回的是一坨 NDJSON);text:原样。
                    let deliverable = isStream ? LingShuAgentStreamParser.finalText(fromStreamJSON: text) : text
                    cont.resume(returning: .completed(deliverable.isEmpty ? errText : deliverable))
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

/// 线程安全的「最后活动时刻」计时器:每次子进程有输出就 `touch()`,巡检线程读 `idleSeconds()` 判空闲。
/// 滚动空闲超时用——只要 agent 还在吐输出,idle 归零,永不误杀;真卡死(连续无输出)才到顶。
private final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    func touch() { lock.lock(); last = Date(); lock.unlock() }
    func idleSeconds() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
}
