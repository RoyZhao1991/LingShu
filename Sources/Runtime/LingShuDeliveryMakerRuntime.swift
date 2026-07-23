import Darwin
import Foundation

enum LingShuLoopEngine: String, CaseIterable, Identifiable, Sendable {
    /// 灵枢当前的内置原生 Loop。实现来自已内嵌、同进程常驻的 Grok 派生 Runtime。
    /// rawValue 沿用 embeddedGrok，保证已启用用户无损迁移；旧 rawValue "native"
    /// 会由 `resolvePersisted` 迁移到这里，不再作为可配置引擎出现。
    case native = "embeddedGrok"

    var id: String { rawValue }

    func displayName(language: LingShuVoiceLanguage) -> String {
        language == .english ? "LingShu Native Loop" : "灵枢原生 Loop"
    }

    static func resolvePersisted(_ rawValue: String?) -> LingShuLoopEngine {
        rawValue.flatMap(Self.init(rawValue:)) ?? .native
    }
}

enum LingShuEmbeddedRuntimeStatus: Equatable, Sendable {
    case stopped
    case starting
    case ready(version: String)
    case failed(String)

    func displayText(language: LingShuVoiceLanguage) -> String {
        switch self {
        case .stopped: return language == .english ? "Stopped" : "未启动"
        case .starting: return language == .english ? "Starting" : "启动中"
        case .ready(let version):
            return language == .english ? "Ready · v\(version)" : "已就绪 · v\(version)"
        case .failed(let reason):
            return language == .english ? "Unavailable · \(reason)" : "不可用 · \(reason)"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum LingShuEmbeddedAgentRole: String, Sendable {
    case maker
    case checker

    var actorName: String { self == .maker ? "灵枢 Maker" : "灵枢 Checker" }
    var roleName: String { self == .maker ? "Maker" : "Checker" }
}

struct LingShuEmbeddedGrokStartConfiguration: Codable, Sendable {
    var grokHome: String
    var configToml: String
    var environment: [String: String]
}

enum LingShuEmbeddedGrokRuntimeError: LocalizedError, Sendable {
    case libraryNotFound
    case symbolMissing(String)
    case startFailed(Int32)
    case sendFailed(Int32)
    case invalidRuntimeMessage
    case incompatibleKernel(String)
    case runtimeStopped
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .libraryNotFound: "找不到内嵌 Agent Runtime 动态库"
        case .symbolMissing(let name): "内嵌 Runtime 缺少符号：\(name)"
        case .startFailed(let code): "内嵌 Runtime 启动失败（\(code)）"
        case .sendFailed(let code): "向内嵌 Runtime 发送消息失败（\(code)）"
        case .invalidRuntimeMessage: "内嵌 Runtime 返回了无法解析的消息"
        case .incompatibleKernel(let reason): "内嵌 Runtime 与灵枢内核 ABI 不兼容：\(reason)"
        case .runtimeStopped: "内嵌 Runtime 尚未启动"
        case .rpc(let message): message
        }
    }
}

private typealias LingShuGrokEventCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
private typealias LingShuGrokStartFunction = @convention(c) (UnsafePointer<CChar>?, LingShuGrokEventCallback?, UnsafeMutableRawPointer?) -> Int32
private typealias LingShuGrokSendFunction = @convention(c) (UnsafePointer<CChar>?) -> Int32
private typealias LingShuGrokStopFunction = @convention(c) () -> Void
private typealias LingShuGrokRunningFunction = @convention(c) () -> Bool
private typealias LingShuGrokVersionFunction = @convention(c) () -> UnsafePointer<CChar>?
private typealias LingShuGrokKernelContractFunction = @convention(c) () -> UnsafePointer<CChar>?

fileprivate final class LingShuEmbeddedGrokDynamicBridge: @unchecked Sendable {
    private let library: UnsafeMutableRawPointer
    private let startFunction: LingShuGrokStartFunction
    private let sendFunction: LingShuGrokSendFunction
    private let stopFunction: LingShuGrokStopFunction
    private let runningFunction: LingShuGrokRunningFunction
    private let versionFunction: LingShuGrokVersionFunction
    private let kernelContractFunction: LingShuGrokKernelContractFunction

    init() throws {
        guard let loaded = Self.libraryCandidates().compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first else {
            throw LingShuEmbeddedGrokRuntimeError.libraryNotFound
        }
        library = loaded
        startFunction = try Self.load("lingshu_grok_runtime_start", from: loaded)
        sendFunction = try Self.load("lingshu_grok_runtime_send", from: loaded)
        stopFunction = try Self.load("lingshu_grok_runtime_stop", from: loaded)
        runningFunction = try Self.load("lingshu_grok_runtime_is_running", from: loaded)
        versionFunction = try Self.load("lingshu_grok_runtime_version", from: loaded)
        kernelContractFunction = try Self.load("lingshu_grok_runtime_kernel_contract", from: loaded)
        try validateKernelContract()
    }

    deinit { dlclose(library) }

    var version: String {
        versionFunction().map { String(cString: $0) } ?? "unknown"
    }

    var isRunning: Bool { runningFunction() }

    private func validateKernelContract() throws {
        guard let pointer = kernelContractFunction(),
              let data = String(cString: pointer).data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LingShuEmbeddedGrokRuntimeError.invalidRuntimeMessage
        }
        guard object["abiVersion"] as? String == LingShuKernelABI.version else {
            throw LingShuEmbeddedGrokRuntimeError.incompatibleKernel("ABI version mismatch")
        }
        let runtimeSymbols = (object["contracts"] as? [[String: Any]])?
            .compactMap { $0["symbol"] as? String } ?? []
        let appSymbols = LingShuKernelABI.contracts.map(\.symbol)
        guard runtimeSymbols == appSymbols else {
            throw LingShuEmbeddedGrokRuntimeError.incompatibleKernel("contract surface mismatch")
        }
    }

    func start(configuration: LingShuEmbeddedGrokStartConfiguration, callback: LingShuGrokEventCallback, context: UnsafeMutableRawPointer) throws {
        let data = try JSONEncoder().encode(configuration)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LingShuEmbeddedGrokRuntimeError.invalidRuntimeMessage
        }
        let code = json.withCString { startFunction($0, callback, context) }
        guard code == 0 else { throw LingShuEmbeddedGrokRuntimeError.startFailed(code) }
    }

    func send(_ message: String) throws {
        let code = message.withCString { sendFunction($0) }
        guard code == 0 else { throw LingShuEmbeddedGrokRuntimeError.sendFailed(code) }
    }

    func stop() { stopFunction() }

    private static func load<T>(_ symbol: String, from library: UnsafeMutableRawPointer) throws -> T {
        guard let pointer = dlsym(library, symbol) else {
            throw LingShuEmbeddedGrokRuntimeError.symbolMissing(symbol)
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static func libraryCandidates() -> [String] {
        var candidates: [String] = []
        if let frameworks = Bundle.main.privateFrameworksURL {
            candidates.append(frameworks.appendingPathComponent("liblingshu_grok_runtime.dylib").path)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Runtime/liblingshu_grok_runtime.dylib").path)
        }
        let source = URL(fileURLWithPath: #filePath)
        let repository = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repository.appendingPathComponent("Runtime/Grok/target/debug/liblingshu_grok_runtime.dylib").path)
        candidates.append(repository.appendingPathComponent("Runtime/Grok/target/release/liblingshu_grok_runtime.dylib").path)
        return candidates
    }
}

private struct LingShuGrokRPCRequest<Params: Encodable>: Encodable {
    var jsonrpc = "2.0"
    var id: Int
    var method: String
    var params: Params
}

private struct LingShuGrokRPCNotification<Params: Encodable>: Encodable {
    var jsonrpc = "2.0"
    var method: String
    var params: Params
}

actor LingShuEmbeddedGrokClient {
    private var bridge: LingShuEmbeddedGrokDynamicBridge?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var eventBuffers: [String: [Data]] = [:]
    private var eventWaiters: [String: [CheckedContinuation<Data?, Never>]] = [:]
    private var stopped = true

    fileprivate func install(_ bridge: LingShuEmbeddedGrokDynamicBridge) {
        self.bridge = bridge
        stopped = false
    }

    func receive(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let id = Self.integerID(object["id"]), object["method"] == nil, let continuation = pending.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: LingShuEmbeddedGrokRuntimeError.rpc(error["message"] as? String ?? "Runtime RPC error"))
            } else {
                continuation.resume(returning: data)
            }
            return
        }

        guard let method = object["method"] as? String,
              method == "session/update" || method == "session/request_permission" || method.hasPrefix("x.ai/") || method.hasPrefix("_x.ai/") else { return }
        let params = object["params"] as? [String: Any]
        guard let sessionID = params?["sessionId"] as? String else { return }
        if var waiters = eventWaiters[sessionID], !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            eventWaiters[sessionID] = waiters
            waiter.resume(returning: data)
        } else {
            eventBuffers[sessionID, default: []].append(data)
        }
    }

    func request<Params: Encodable & Sendable>(_ method: String, params: Params) async throws -> Data {
        guard let bridge else { throw LingShuEmbeddedGrokRuntimeError.runtimeStopped }
        let id = nextRequestID
        nextRequestID += 1
        let payload = try JSONEncoder().encode(LingShuGrokRPCRequest(id: id, method: method, params: params))
        guard let text = String(data: payload, encoding: .utf8) else {
            throw LingShuEmbeddedGrokRuntimeError.invalidRuntimeMessage
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try bridge.send(text)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    func notify<Params: Encodable & Sendable>(_ method: String, params: Params) throws {
        guard let bridge else { throw LingShuEmbeddedGrokRuntimeError.runtimeStopped }
        let payload = try JSONEncoder().encode(LingShuGrokRPCNotification(method: method, params: params))
        guard let text = String(data: payload, encoding: .utf8) else {
            throw LingShuEmbeddedGrokRuntimeError.invalidRuntimeMessage
        }
        try bridge.send(text)
    }

    func respond(id: Int, result: [String: String]) throws {
        guard let bridge else { throw LingShuEmbeddedGrokRuntimeError.runtimeStopped }
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LingShuEmbeddedGrokRuntimeError.invalidRuntimeMessage
        }
        try bridge.send(text)
    }

    func respondToPermission(request: Data, allow: Bool) throws {
        guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let id = Self.integerID(object["id"]) else {
            throw LingShuEmbeddedGrokRuntimeError.invalidRuntimeMessage
        }
        let params = object["params"] as? [String: Any]
        let options = params?["options"] as? [[String: Any]] ?? []
        let desiredKind = allow ? "allow_once" : "reject_once"
        let optionID = options.first(where: { ($0["kind"] as? String) == desiredKind })?["optionId"] as? String
            ?? options.first?["optionId"] as? String
        let outcome: [String: Any]
        if let optionID {
            outcome = ["outcome": "selected", "optionId": optionID]
        } else {
            outcome = ["outcome": "cancelled"]
        }
        guard let bridge else { throw LingShuEmbeddedGrokRuntimeError.runtimeStopped }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]]
        let data = try JSONSerialization.data(withJSONObject: response)
        guard let text = String(data: data, encoding: .utf8) else { throw LingShuEmbeddedGrokRuntimeError.invalidRuntimeMessage }
        try bridge.send(text)
    }

    func respondToQuestion(request: Data, answer: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let id = Self.integerID(object["id"]) else {
            throw LingShuEmbeddedGrokRuntimeError.invalidRuntimeMessage
        }
        let params = object["params"] as? [String: Any]
        let questions = params?["questions"] as? [[String: Any]] ?? []
        var answers: [String: [String]] = [:]
        var annotations: [String: [String: String]] = [:]
        if let firstQuestion = questions.first,
           let question = firstQuestion["question"] as? String,
           !question.isEmpty {
            // 灵枢的任务窗口目前以自由文本恢复子任务。把这段文本作为第一个问题的
            // Other/notes 回传，保持 Grok ask_user_question 的原始阻塞语义。
            answers[question] = ["Other"]
            annotations[question] = ["notes": answer]
        }
        let result: [String: Any] = [
            "outcome": "accepted",
            "answers": answers,
            "annotations": annotations,
        ]
        try sendResponse(id: id, result: result)
    }

    func respondToPlanApproval(request: Data, answer: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let id = Self.integerID(object["id"]) else {
            throw LingShuEmbeddedGrokRuntimeError.invalidRuntimeMessage
        }
        let denied = answer.localizedCaseInsensitiveContains("拒绝")
            || answer.localizedCaseInsensitiveContains("取消")
            || answer.localizedCaseInsensitiveContains("deny")
            || answer.localizedCaseInsensitiveContains("cancel")
        let result: [String: Any] = denied
            ? ["outcome": "cancelled", "feedback": answer]
            : ["outcome": "approved"]
        try sendResponse(id: id, result: result)
    }

    func cancelSession(sessionID: String) throws {
        try notify("session/cancel", params: LingShuGrokSessionReference(sessionId: sessionID))
    }

    func nextEvent(sessionID: String) async -> Data? {
        guard !stopped else { return nil }
        if var buffered = eventBuffers[sessionID], !buffered.isEmpty {
            let first = buffered.removeFirst()
            eventBuffers[sessionID] = buffered
            return first
        }
        return await withCheckedContinuation { continuation in
            eventWaiters[sessionID, default: []].append(continuation)
        }
    }

    func stop() {
        bridge?.stop()
        bridge = nil
        stopped = true
        let error = LingShuEmbeddedGrokRuntimeError.runtimeStopped
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        for waiters in eventWaiters.values {
            for continuation in waiters { continuation.resume(returning: nil) }
        }
        eventWaiters.removeAll()
        eventBuffers.removeAll()
    }

    private func sendResponse(id: Int, result: [String: Any]) throws {
        guard let bridge else { throw LingShuEmbeddedGrokRuntimeError.runtimeStopped }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        let data = try JSONSerialization.data(withJSONObject: response)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LingShuEmbeddedGrokRuntimeError.invalidRuntimeMessage
        }
        try bridge.send(text)
    }

    private static func integerID(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

@MainActor
final class LingShuEmbeddedGrokRuntime: ObservableObject {
    static let shared = LingShuEmbeddedGrokRuntime()

    @Published private(set) var status: LingShuEmbeddedRuntimeStatus = .stopped
    private let client = LingShuEmbeddedGrokClient()
    private var bridge: LingShuEmbeddedGrokDynamicBridge?

    private init() {}

    func start(configuration: LingShuEmbeddedGrokStartConfiguration) async {
        guard !status.isReady else { return }
        status = .starting
        do {
            let bridge = try LingShuEmbeddedGrokDynamicBridge()
            self.bridge = bridge
            await client.install(bridge)
            let context = Unmanaged.passUnretained(self).toOpaque()
            try bridge.start(configuration: configuration, callback: lingShuEmbeddedGrokCallback, context: context)
            _ = try await client.request("initialize", params: LingShuGrokInitializeParams())
            status = .ready(version: bridge.version)
        } catch {
            status = .failed(error.localizedDescription)
            await client.stop()
            bridge = nil
        }
    }

    func stop() async {
        await client.stop()
        bridge = nil
        status = .stopped
    }

    func reportConfigurationFailure(_ message: String) {
        status = .failed(message)
    }

    func makeSession(
        id: String,
        role: LingShuEmbeddedAgentRole,
        workingDirectory: String,
        modelID: String,
        permissionMode: LingShuExecutionPermissionMode,
        systemPrompt: String,
        initialMessages: [LingShuAgentMessage] = [],
        eventSink: @escaping @Sendable (LingShuGrokRuntimeEvent) async -> Void
    ) -> LingShuGrokAgentSession? {
        guard status.isReady else { return nil }
        return LingShuGrokAgentSession(
            id: id,
            role: role,
            workingDirectory: workingDirectory,
            modelID: modelID,
            permissionMode: permissionMode,
            systemPrompt: systemPrompt,
            initialMessages: initialMessages,
            client: client,
            eventSink: eventSink
        )
    }

    fileprivate func receive(_ text: String) {
        var runtimeFailed = false
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["kind"] as? String == "runtime",
           object["status"] as? String == "failed" {
            status = .failed(object["error"] as? String ?? "Runtime stopped")
            runtimeFailed = true
        }
        let shouldStop = runtimeFailed
        Task {
            if shouldStop { await client.stop() }
            else { await client.receive(text) }
        }
    }
}

struct LingShuGrokSessionReference: Codable, Sendable {
    var sessionId: String
}

private let lingShuEmbeddedGrokCallback: LingShuGrokEventCallback = { pointer, context in
    guard let pointer, let context else { return }
    let text = String(cString: pointer)
    let runtime = Unmanaged<LingShuEmbeddedGrokRuntime>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in runtime.receive(text) }
}

private struct LingShuGrokInitializeParams: Codable, Sendable {
    struct Capabilities: Codable, Sendable {
        struct FileSystem: Codable, Sendable {
            var readTextFile = false
            var writeTextFile = false
        }
        var fs = FileSystem()
        var terminal = false
    }
    struct Meta: Codable, Sendable {
        struct StartupHints: Codable, Sendable {
            var nonInteractive = true
            var skipGitStatus = true
            var skipProjectLayout = true
        }
        var startupHints = StartupHints()
        var clientType = "lingshu"
        var clientIdentifier = "lingshu-embedded-runtime"
    }
    var protocolVersion = 1
    var clientCapabilities = Capabilities()
    var meta = Meta()

    enum CodingKeys: String, CodingKey {
        case protocolVersion, clientCapabilities
        case meta = "_meta"
    }
}
