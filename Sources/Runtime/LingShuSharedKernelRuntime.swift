import Darwin
import Foundation

enum LingShuSharedKernelRuntimeError: LocalizedError, Sendable {
    case libraryNotFound
    case symbolMissing(String)
    case startFailed(Int32)
    case sendFailed(Int32)
    case invalidMessage
    case incompatibleKernel(String)
    case runtimeStopped
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .libraryNotFound:
            "找不到灵枢共享内核动态库"
        case .symbolMissing(let name):
            "灵枢共享内核缺少符号：\(name)"
        case .startFailed(let code):
            "灵枢共享内核启动失败（\(code)）"
        case .sendFailed(let code):
            "向灵枢共享内核发送消息失败（\(code)）"
        case .invalidMessage:
            "灵枢共享内核返回了无法解析的消息"
        case .incompatibleKernel(let reason):
            "灵枢共享内核 ABI 不兼容：\(reason)"
        case .runtimeStopped:
            "灵枢共享内核尚未启动"
        case .rpc(let message):
            message
        }
    }
}

enum LingShuKernelLocale: String, Codable, Sendable {
    case zhCN = "zh_cn"
    case en
}

enum LingShuKernelProviderProtocol: String, Codable, Sendable {
    case openAIResponses = "openai_responses"
    case openAIChatCompletions = "openai_chat_completions"
    case anthropicMessages = "anthropic_messages"
}

enum LingShuKernelExecutionPermissionMode: String, Codable, Sendable {
    case sandbox
    case fullAccess = "full_access"
}

struct LingShuKernelRuntimeSettings: Codable, Sendable, Equatable {
    var locale: LingShuKernelLocale
    var providerId: String
    var providerName: String
    var `protocol`: LingShuKernelProviderProtocol
    var endpoint: String
    var model: String
    var workspace: String
    var executionPermissionMode: LingShuKernelExecutionPermissionMode
    var firstRunComplete: Bool
}

struct LingShuKernelPlatformCapabilities: Codable, Sendable, Equatable {
    var computerControl: Bool
    var realtimePerception: Bool
    var internalPreview: Bool
    var externalOpen: Bool
}

enum LingShuKernelMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

enum LingShuKernelMessageState: String, Codable, Sendable {
    case complete
    case thinking
    case failed
    case needsUserAction = "needs_user_action"
}

struct LingShuKernelChatMessage: Codable, Sendable {
    var id: UUID
    var role: LingShuKernelMessageRole
    var text: String
    var createdAt: String
    var state: LingShuKernelMessageState
    var threadId: UUID?
}

enum LingShuKernelGoalKind: String, Codable, Sendable {
    case task
    case interaction
    case question
    case unknown
}

enum LingShuKernelOutputMode: String, Codable, Sendable {
    case chatReply = "chat_reply"
    case artifact
    case visibleInteraction = "visible_interaction"
    case externalAction = "external_action"
    case unspecified
}

enum LingShuKernelReferenceScope: String, Codable, Sendable {
    case currentInput = "current_input"
    case defaultAnchor = "default_anchor"
    case candidateBackground = "candidate_background"
    case visibleContext = "visible_context"
    case taskThread = "task_thread"
    case memory
    case unknown
}

enum LingShuKernelReferenceConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
    case unknown
}

struct LingShuKernelGoalSpec: Codable, Sendable {
    var objective: String
    var kind: LingShuKernelGoalKind
    var outputMode: LingShuKernelOutputMode
    var referenceScope: LingShuKernelReferenceScope
    var referenceEvidence: [String]
    var referenceExplicit: Bool
    var referenceConfidence: LingShuKernelReferenceConfidence
    var constraints: [String]
    var boundaries: [String]
    var risks: [String]
    var successCriteria: [String]
    var openQuestions: [String]

    private enum CodingKeys: String, CodingKey {
        case objective, kind, constraints, boundaries, risks
        case outputMode = "output_mode"
        case referenceScope = "reference_scope"
        case referenceEvidence = "reference_evidence"
        case referenceExplicit = "reference_explicit"
        case referenceConfidence = "reference_confidence"
        case successCriteria = "success_criteria"
        case openQuestions = "open_questions"
    }
}

enum LingShuKernelTaskStatus: String, Codable, Sendable {
    case queued
    case understanding
    case running
    case needsUserAction = "needs_user_action"
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

enum LingShuKernelTaskRole: String, Codable, Sendable {
    case main
    case worker
    case checker
}

enum LingShuKernelTaskOrigin: String, Codable, Sendable {
    case conversation
    case subtask
    case verification
}

struct LingShuKernelTaskStep: Codable, Sendable {
    var id: UUID
    var title: String
    var detail: String
    var status: LingShuKernelTaskStatus
    var updatedAt: String
}

struct LingShuKernelArtifact: Codable, Sendable {
    var id: UUID
    var title: String
    var path: String
    var kind: String
    var sizeBytes: UInt64
    var modifiedAt: String
}

struct LingShuKernelTaskRecord: Codable, Sendable {
    var id: UUID
    var title: String
    var prompt: String
    var status: LingShuKernelTaskStatus
    var createdAt: String
    var updatedAt: String
    var goalSpec: LingShuKernelGoalSpec?
    var steps: [LingShuKernelTaskStep]
    var artifacts: [LingShuKernelArtifact]
    var summary: String
    var error: String?
    var assistantMessageId: UUID
    var attachmentPaths: [String]
    var parentTaskId: UUID?
    var rootTaskId: UUID?
    var role: LingShuKernelTaskRole
    var origin: LingShuKernelTaskOrigin
    var participantName: String
    var depth: UInt8
    var pendingQuestion: String?
}

enum LingShuKernelEventKind: String, Codable, Sendable {
    case status
    case model
    case reasoning
    case tool
    case plan
    case delegation
    case humanInteraction = "human_interaction"
    case warning
    case result
}

enum LingShuKernelEventState: String, Codable, Sendable {
    case running
    case completed
    case failed
    case blocked
}

struct LingShuKernelRuntimeEvent: Codable, Sendable {
    var id: UUID
    var sequence: UInt64
    var taskId: UUID
    var parentTaskId: UUID?
    var kind: LingShuKernelEventKind
    var state: LingShuKernelEventState
    var actor: String
    var title: String
    var detail: String
    var createdAt: String
    var updatedAt: String
}

struct LingShuKernelRuntimeSnapshot: Codable, Sendable {
    var kernelAbiVersion: String
    var settings: LingShuKernelRuntimeSettings
    var platform: String
    var capabilities: LingShuKernelPlatformCapabilities
    var messages: [LingShuKernelChatMessage]
    var tasks: [LingShuKernelTaskRecord]
    var activeTaskId: UUID?
    var queuedTaskCount: Int
    var providerConfigured: Bool
    var events: [LingShuKernelRuntimeEvent]
    var latestEventSequence: UInt64
}

struct LingShuKernelSubmitReceipt: Codable, Sendable {
    var threadId: UUID
    var userMessageId: UUID
    var assistantMessageId: UUID
    var queued: Bool
}

private typealias LingShuKernelEventCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
private typealias LingShuKernelStartFunction = @convention(c) (UnsafePointer<CChar>?, LingShuKernelEventCallback?, UnsafeMutableRawPointer?) -> Int32
private typealias LingShuKernelSendFunction = @convention(c) (UnsafePointer<CChar>?) -> Int32
private typealias LingShuKernelStopFunction = @convention(c) () -> Void
private typealias LingShuKernelRunningFunction = @convention(c) () -> Bool

private final class LingShuSharedKernelDynamicBridge: @unchecked Sendable {
    private let library: UnsafeMutableRawPointer
    private let startFunction: LingShuKernelStartFunction
    private let sendFunction: LingShuKernelSendFunction
    private let stopFunction: LingShuKernelStopFunction
    private let runningFunction: LingShuKernelRunningFunction

    init() throws {
        guard let loaded = Self.libraryCandidates().compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first else {
            throw LingShuSharedKernelRuntimeError.libraryNotFound
        }
        library = loaded
        startFunction = try Self.load("lingshu_kernel_runtime_start", from: loaded)
        sendFunction = try Self.load("lingshu_kernel_runtime_send", from: loaded)
        stopFunction = try Self.load("lingshu_kernel_runtime_stop", from: loaded)
        runningFunction = try Self.load("lingshu_kernel_runtime_is_running", from: loaded)
    }

    deinit { dlclose(library) }

    var isRunning: Bool { runningFunction() }

    func start(dataDirectory: String, callback: LingShuKernelEventCallback, context: UnsafeMutableRawPointer) throws {
        let payload = try JSONEncoder().encode(LingShuKernelStartConfiguration(dataDir: dataDirectory, platform: "macos"))
        guard let json = String(data: payload, encoding: .utf8) else {
            throw LingShuSharedKernelRuntimeError.invalidMessage
        }
        let code = json.withCString { startFunction($0, callback, context) }
        guard code == 0 else { throw LingShuSharedKernelRuntimeError.startFailed(code) }
    }

    func send(_ message: String) throws {
        let code = message.withCString { sendFunction($0) }
        guard code == 0 else { throw LingShuSharedKernelRuntimeError.sendFailed(code) }
    }

    func stop() { stopFunction() }

    private static func load<T>(_ symbol: String, from library: UnsafeMutableRawPointer) throws -> T {
        guard let pointer = dlsym(library, symbol) else {
            throw LingShuSharedKernelRuntimeError.symbolMissing(symbol)
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

private struct LingShuKernelStartConfiguration: Codable, Sendable {
    var dataDir: String
    var platform: String
}

private struct LingShuKernelRPCRequest<Params: Encodable>: Encodable {
    var jsonrpc = "2.0"
    var id: Int
    var method: String
    var params: Params
}

private struct LingShuKernelRPCResponse<Result: Decodable>: Decodable {
    var result: Result
}

private struct LingShuKernelPingResult: Decodable {
    var ok: Bool
    var kernelAbiVersion: String
}

private struct LingShuKernelConfigureParams: Encodable, Sendable {
    var settings: LingShuKernelRuntimeSettings
    var apiKey: String?
    var providerConfigured: Bool
}

private struct LingShuKernelSnapshotParams: Encodable, Sendable {
    var providerConfigured: Bool
}

private struct LingShuKernelSubmitParams: Encodable, Sendable {
    var prompt: String
    var attachmentPaths: [String]
}

private struct LingShuKernelResumeParams: Encodable, Sendable {
    var threadId: UUID
    var answer: String
}

private struct LingShuKernelThreadParams: Encodable, Sendable {
    var threadId: UUID
}

private struct LingShuKernelEmptyParams: Encodable, Sendable {}

private struct LingShuKernelAcceptedResult: Decodable {
    var accepted: Bool
}

private struct LingShuKernelCancelledResult: Decodable {
    var cancelled: Bool
}

private actor LingShuSharedKernelClient {
    private var bridge: LingShuSharedKernelDynamicBridge?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var stopped = true
    private(set) var latestRuntimeError: String?

    func install(_ bridge: LingShuSharedKernelDynamicBridge) {
        self.bridge = bridge
        stopped = false
        latestRuntimeError = nil
    }

    func receive(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = Self.integerID(object["id"]), object["method"] == nil,
           let continuation = pending.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: LingShuSharedKernelRuntimeError.rpc(error["message"] as? String ?? "Runtime RPC error"))
            } else {
                continuation.resume(returning: data)
            }
            return
        }
        if object["method"] as? String == "kernel/runtime_error",
           let params = object["params"] as? [String: Any] {
            latestRuntimeError = params["message"] as? String
        } else if object["kind"] as? String == "kernel_runtime",
                  object["status"] as? String == "failed" {
            latestRuntimeError = object["error"] as? String
        }
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params,
        as resultType: Result.Type = Result.self
    ) async throws -> Result {
        guard let bridge, !stopped else { throw LingShuSharedKernelRuntimeError.runtimeStopped }
        let id = nextRequestID
        nextRequestID += 1
        let payload = try JSONEncoder().encode(LingShuKernelRPCRequest(id: id, method: method, params: params))
        guard let text = String(data: payload, encoding: .utf8) else {
            throw LingShuSharedKernelRuntimeError.invalidMessage
        }
        let data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try bridge.send(text)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
        return try JSONDecoder().decode(LingShuKernelRPCResponse<Result>.self, from: data).result
    }

    func stop() {
        bridge?.stop()
        bridge = nil
        stopped = true
        let error = LingShuSharedKernelRuntimeError.runtimeStopped
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
    }

    private static func integerID(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

@MainActor
final class LingShuSharedKernelRuntime: ObservableObject {
    static let shared = LingShuSharedKernelRuntime()

    @Published private(set) var status: LingShuEmbeddedRuntimeStatus = .stopped
    private let client = LingShuSharedKernelClient()
    private var bridge: LingShuSharedKernelDynamicBridge?

    private init() {}

    func ensureStarted(dataDirectory: String) async throws {
        if status.isReady { return }
        status = .starting
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dataDirectory, isDirectory: true),
                withIntermediateDirectories: true
            )
            let bridge = try LingShuSharedKernelDynamicBridge()
            self.bridge = bridge
            await client.install(bridge)
            let context = Unmanaged.passUnretained(self).toOpaque()
            try bridge.start(dataDirectory: dataDirectory, callback: lingShuSharedKernelCallback, context: context)
            let ping: LingShuKernelPingResult = try await client.request(
                "kernel/ping",
                params: LingShuKernelEmptyParams()
            )
            guard ping.ok, ping.kernelAbiVersion == LingShuKernelABI.version else {
                throw LingShuSharedKernelRuntimeError.incompatibleKernel(
                    "expected \(LingShuKernelABI.version), received \(ping.kernelAbiVersion)"
                )
            }
            status = .ready(version: ping.kernelAbiVersion)
        } catch {
            status = .failed(error.localizedDescription)
            await client.stop()
            bridge = nil
            throw error
        }
    }

    func configure(
        settings: LingShuKernelRuntimeSettings,
        apiKey: String?,
        providerConfigured: Bool
    ) async throws -> LingShuKernelRuntimeSnapshot {
        try await client.request(
            "kernel/configure",
            params: LingShuKernelConfigureParams(
                settings: settings,
                apiKey: apiKey,
                providerConfigured: providerConfigured
            )
        )
    }

    func snapshot(providerConfigured: Bool) async throws -> LingShuKernelRuntimeSnapshot {
        try await client.request(
            "kernel/snapshot",
            params: LingShuKernelSnapshotParams(providerConfigured: providerConfigured)
        )
    }

    func submit(prompt: String, attachmentPaths: [String]) async throws -> LingShuKernelSubmitReceipt {
        try await client.request(
            "kernel/submit",
            params: LingShuKernelSubmitParams(prompt: prompt, attachmentPaths: attachmentPaths)
        )
    }

    @discardableResult
    func resume(threadID: UUID, answer: String) async throws -> Bool {
        let result: LingShuKernelAcceptedResult = try await client.request(
            "kernel/resume",
            params: LingShuKernelResumeParams(threadId: threadID, answer: answer)
        )
        return result.accepted
    }

    @discardableResult
    func cancel(threadID: UUID) async throws -> Bool {
        let result: LingShuKernelCancelledResult = try await client.request(
            "kernel/cancel",
            params: LingShuKernelThreadParams(threadId: threadID)
        )
        return result.cancelled
    }

    func stop() async {
        await client.stop()
        bridge = nil
        status = .stopped
    }

    fileprivate func receive(_ text: String) {
        Task { await client.receive(text) }
    }
}

private let lingShuSharedKernelCallback: LingShuKernelEventCallback = { pointer, context in
    guard let pointer, let context else { return }
    let text = String(cString: pointer)
    let runtime = Unmanaged<LingShuSharedKernelRuntime>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in runtime.receive(text) }
}
