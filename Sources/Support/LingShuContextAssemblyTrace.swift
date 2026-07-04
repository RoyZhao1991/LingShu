import Foundation

/// 第 5 站:上下文装配计划。
///
/// 这不是路由器,只记录"上一站给出的归属结果应该装配哪类上下文"。
/// 非 reply 的输入统一进入主脑 active turn,由主脑决定直答、调用工具或创建子任务。
struct LingShuContextAssemblyPlan: Equatable, Sendable {
    enum Strategy: String, Sendable {
        case mainActiveTurn = "main_active_turn"
        case continueExistingTask = "continue_existing_task"
        case legacyTaskTurn = "legacy_task_turn"
    }

    enum ToolScope: String, Sendable {
        case none
        case task
        case full
    }

    let strategy: Strategy
    let targetRecordID: String?
    let includeMainRecentContext: Bool
    let includeTaskMemory: Bool
    let toolScope: ToolScope
    let source: String
    let reason: String

    static func mainActiveTurn(source: String, reason: String) -> LingShuContextAssemblyPlan {
        LingShuContextAssemblyPlan(
            strategy: .mainActiveTurn,
            targetRecordID: nil,
            includeMainRecentContext: true,
            includeTaskMemory: false,
            toolScope: .full,
            source: source,
            reason: reason
        )
    }

    static func continueExistingTask(recordID: String, source: String, reason: String) -> LingShuContextAssemblyPlan {
        LingShuContextAssemblyPlan(
            strategy: .continueExistingTask,
            targetRecordID: recordID,
            includeMainRecentContext: true,
            includeTaskMemory: true,
            toolScope: .task,
            source: source,
            reason: reason
        )
    }

    static func legacyTaskTurn(recordID: String?, source: String, reason: String) -> LingShuContextAssemblyPlan {
        LingShuContextAssemblyPlan(
            strategy: .legacyTaskTurn,
            targetRecordID: recordID,
            includeMainRecentContext: true,
            includeTaskMemory: recordID != nil,
            toolScope: .full,
            source: source,
            reason: reason
        )
    }

    var traceLine: String {
        [
            "stage=5",
            "strategy=\(strategy.rawValue)",
            "record=\(targetRecordID ?? "none")",
            "mainRecent=\(includeMainRecentContext ? "on" : "off")",
            "taskMemory=\(includeTaskMemory ? "on" : "off")",
            "tools=\(toolScope.rawValue)",
            "source=\(source)",
            "reason=\(reason)"
        ].joined(separator: " ")
    }
}

/// 第 5 站:上下文装配测量账单。
///
/// 这层只观测,不改写 prompt、不筛工具、不触发 UI。它回答一个问题:
/// 每次模型调用前,我们到底把多少系统指令、历史、工具 schema、图片和动态消息塞给了主脑。
struct LingShuContextAssemblySnapshot: Equatable, Sendable {
    let id: String
    let createdAt: Date
    let provider: String
    let model: String
    let protocolName: String
    let stream: Bool
    let hasContinuationToken: Bool

    let messageCount: Int
    let systemMessageCount: Int
    let userMessageCount: Int
    let assistantMessageCount: Int
    let toolResultMessageCount: Int

    let systemChars: Int
    let userChars: Int
    let assistantChars: Int
    let toolResultChars: Int
    let toolCallArgumentChars: Int
    let imageCount: Int

    let toolCount: Int
    let toolPropertyCount: Int
    let toolSchemaChars: Int

    let estimatedTextTokens: Int
    let estimatedToolSchemaTokens: Int
    let estimatedImageTokens: Int
    let estimatedInputTokens: Int
    let maxMessageChars: Int
    let maxToolSchemaChars: Int

    var promptTokens: Int?
    var cachedTokens: Int?
    var totalTokens: Int?
    var latencyMs: Int?
    var responseKind: String?
    var errorKind: String?

    var estimatedInputChars: Int {
        systemChars + userChars + assistantChars + toolResultChars + toolCallArgumentChars + toolSchemaChars + imageCount * 4_000
    }

    var actualCacheRatePercent: Int? {
        guard let promptTokens, promptTokens > 0, let cachedTokens else { return nil }
        return Int((Double(max(0, cachedTokens)) / Double(promptTokens)) * 100)
    }

    var startLogLine: String {
        "context-assembly[\(id)] start stream=\(stream) cont=\(hasContinuationToken) msgs=\(messageCount)(sys=\(systemMessageCount),user=\(userMessageCount),assistant=\(assistantMessageCount),tool=\(toolResultMessageCount)) tools=\(toolCount)/props=\(toolPropertyCount) chars:system=\(systemChars),history=\(userChars + assistantChars + toolResultChars),toolArgs=\(toolCallArgumentChars),toolSchema=\(toolSchemaChars),images=\(imageCount) estTokens=\(estimatedInputTokens)"
    }

    var finishLogLine: String {
        var parts = [
            "context-assembly[\(id)] finish",
            "kind=\(responseKind ?? "unknown")",
            "latency=\(latencyMs.map { "\($0)ms" } ?? "nil")",
            "est=\(estimatedInputTokens)"
        ]
        if let promptTokens { parts.append("prompt=\(promptTokens)") }
        if let cachedTokens {
            parts.append("cached=\(cachedTokens)")
            if let rate = actualCacheRatePercent { parts.append("cacheRate=\(rate)%") }
        }
        if let totalTokens { parts.append("total=\(totalTokens)") }
        if let errorKind { parts.append("error=\(errorKind)") }
        return parts.joined(separator: " ")
    }

    var reportLine: String {
        let actual = promptTokens.map(String.init) ?? "无"
        let cached = cachedTokens.map(String.init) ?? "无"
        let latency = latencyMs.map { "\($0)ms" } ?? "无"
        return "模型 \(provider)/\(model): 估算 \(estimatedInputTokens) tokens, 实际 prompt \(actual), 缓存 \(cached), 耗时 \(latency), 消息 \(messageCount), 工具 \(toolCount), 工具schema≈\(estimatedToolSchemaTokens) tokens"
    }

    static func make(
        provider: String,
        model: String,
        protocolName: String,
        stream: Bool,
        hasContinuationToken: Bool,
        messages: [LingShuAgentMessage],
        tools: [LingShuAgentTool]
    ) -> LingShuContextAssemblySnapshot {
        var systemChars = 0
        var userChars = 0
        var assistantChars = 0
        var toolResultChars = 0
        var toolCallArgumentChars = 0
        var imageCount = 0
        var systemCount = 0
        var userCount = 0
        var assistantCount = 0
        var toolResultCount = 0
        var maxMessageChars = 0

        for message in messages {
            maxMessageChars = max(maxMessageChars, message.content.count)
            imageCount += message.imageDataURLs?.count ?? 0
            toolCallArgumentChars += message.toolCalls.reduce(0) { $0 + $1.name.count + $1.argumentsJSON.count }
            switch message.role {
            case .system:
                systemCount += 1
                systemChars += message.content.count
            case .user:
                userCount += 1
                userChars += message.content.count
            case .assistant:
                assistantCount += 1
                assistantChars += message.content.count
            case .tool:
                toolResultCount += 1
                toolResultChars += message.content.count
            }
        }

        var toolPropertyCount = 0
        var toolSchemaChars = 0
        var maxToolSchemaChars = 0
        for tool in tools {
            let schemaChars = tool.name.count + tool.description.count + tool.parametersJSON.count
            toolSchemaChars += schemaChars
            maxToolSchemaChars = max(maxToolSchemaChars, schemaChars)
            if let data = tool.parametersJSON.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                toolPropertyCount += Self.propertyCount(in: object)
            }
        }

        let estimatedTextTokens = LingShuTokenEstimator.estimate(messages)
        let estimatedToolSchemaTokens = (toolSchemaChars + 3) / 4
        let estimatedImageTokens = imageCount * 1_300
        let estimatedInputTokens = estimatedTextTokens + estimatedToolSchemaTokens + estimatedImageTokens

        return LingShuContextAssemblySnapshot(
            id: String(UUID().uuidString.prefix(8)),
            createdAt: Date(),
            provider: provider,
            model: model,
            protocolName: protocolName,
            stream: stream,
            hasContinuationToken: hasContinuationToken,
            messageCount: messages.count,
            systemMessageCount: systemCount,
            userMessageCount: userCount,
            assistantMessageCount: assistantCount,
            toolResultMessageCount: toolResultCount,
            systemChars: systemChars,
            userChars: userChars,
            assistantChars: assistantChars,
            toolResultChars: toolResultChars,
            toolCallArgumentChars: toolCallArgumentChars,
            imageCount: imageCount,
            toolCount: tools.count,
            toolPropertyCount: toolPropertyCount,
            toolSchemaChars: toolSchemaChars,
            estimatedTextTokens: estimatedTextTokens,
            estimatedToolSchemaTokens: estimatedToolSchemaTokens,
            estimatedImageTokens: estimatedImageTokens,
            estimatedInputTokens: estimatedInputTokens,
            maxMessageChars: maxMessageChars,
            maxToolSchemaChars: maxToolSchemaChars
        )
    }

    private static func propertyCount(in object: [String: Any]) -> Int {
        if let properties = object["properties"] as? [String: Any] {
            return properties.count
        }
        if let function = object["function"] as? [String: Any],
           let parameters = function["parameters"] as? [String: Any],
           let properties = parameters["properties"] as? [String: Any] {
            return properties.count
        }
        return 0
    }
}

/// 进程级上下文测量器。最近 N 次记录保存在内存里,同时写 /tmp/lingshu-control.log。
final class LingShuContextAssemblyMeter: @unchecked Sendable {
    static let shared = LingShuContextAssemblyMeter()

    private let lock = NSLock()
    private var snapshots: [LingShuContextAssemblySnapshot] = []
    private let limit = 120

    private init() {}

    @discardableResult
    func begin(_ snapshot: LingShuContextAssemblySnapshot) -> LingShuContextAssemblySnapshot {
        lock.lock()
        snapshots.append(snapshot)
        if snapshots.count > limit {
            snapshots.removeFirst(snapshots.count - limit)
        }
        lock.unlock()
        lingShuControlLog(snapshot.startLogLine)
        return snapshot
    }

    @discardableResult
    func finish(
        id: String,
        promptTokens: Int?,
        cachedTokens: Int?,
        totalTokens: Int?,
        startedAt: Date,
        responseKind: String,
        errorKind: String? = nil
    ) -> LingShuContextAssemblySnapshot? {
        lock.lock()
        guard let index = snapshots.lastIndex(where: { $0.id == id }) else {
            lock.unlock()
            return nil
        }
        snapshots[index].promptTokens = promptTokens
        snapshots[index].cachedTokens = cachedTokens
        snapshots[index].totalTokens = totalTokens
        snapshots[index].latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        snapshots[index].responseKind = responseKind
        snapshots[index].errorKind = errorKind
        let finished = snapshots[index]
        lock.unlock()
        lingShuControlLog(finished.finishLogLine)
        return finished
    }

    func recent(limit requested: Int = 20) -> [LingShuContextAssemblySnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return Array(snapshots.suffix(max(1, requested)))
    }

    func reset() {
        lock.lock()
        snapshots.removeAll()
        lock.unlock()
    }
}
