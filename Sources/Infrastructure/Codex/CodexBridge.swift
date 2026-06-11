import Foundation

struct CodexCommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

struct CodexHealthProbeReport: Equatable {
    var reply: String
    var rawLog: String
}

struct CodexHealthProbeFailure: Error, Equatable {
    var message: String
    var rawLog: String

    var diagnosticSummary: String {
        CodexDiagnosticLogFilter.diagnosticSummary(from: rawLog)
    }
}

enum CodexHealthProbeResult: Equatable {
    case success(CodexHealthProbeReport)
    case failure(CodexHealthProbeFailure)
}

enum CodexDiagnosticLogFilter {
    private static let diagnosticLevels = ["TRACE", "DEBUG", "INFO", "WARN", "ERROR"]

    static func userVisibleText(from rawText: String) -> String {
        rawText
            .components(separatedBy: .newlines)
            .filter { !isInternalDiagnosticLine($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isInternalDiagnosticLine(_ rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }

        let lowercased = line.lowercased()
        if lowercased.contains("codex_core::responses_retry")
            || lowercased.contains("stream disconnected - retrying sampling request") {
            return true
        }

        guard line.count > 28,
              line[line.startIndex...].contains("codex_") else {
            return false
        }

        let hasTimestampPrefix = line.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"#,
            options: .regularExpression
        ) != nil
        guard hasTimestampPrefix else { return false }

        return diagnosticLevels.contains { level in
            line.contains(" \(level) codex_")
        }
    }

    static func diagnosticLines(from rawText: String) -> [String] {
        rawText
            .components(separatedBy: .newlines)
            .filter(isInternalDiagnosticLine)
    }

    static func diagnosticSummary(from rawText: String) -> String {
        let diagnostics = diagnosticLines(from: rawText)
        guard !diagnostics.isEmpty else {
            return rawText
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return diagnostics
            .suffix(3)
            .joined(separator: "\n")
    }
}

private struct CodexSessionCapture {
    let knownIDs: Set<String>
    let startedAt: Date
}

private struct CodexSessionIndexEntry: Decodable {
    let id: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case updatedAt = "updated_at"
    }
}

final class CodexExecutionHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process) {
        lock.lock()
        let shouldCancel = cancelled
        if !shouldCancel {
            self.process = process
        }
        lock.unlock()

        if shouldCancel, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let processToCancel = process
        process = nil
        lock.unlock()

        if let processToCancel, processToCancel.isRunning {
            processToCancel.terminate()
        }
    }

    func detach(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }
}

final class CodexStreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var lastActivityAt = Date()
    private let progress: ((String) -> Void)?

    init(progress: ((String) -> Void)?) {
        self.progress = progress
    }

    func capture(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }

        lock.lock()
        if isError {
            stderrData.append(data)
        } else {
            stdoutData.append(data)
        }
        lastActivityAt = Date()
        lock.unlock()

        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            progress?(text)
        }
    }

    var stdout: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    var stderr: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stderrData, encoding: .utf8) ?? ""
    }

    var lastActivity: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastActivityAt
    }

    func markHeartbeat() {
        lock.lock()
        lastActivityAt = Date()
        lock.unlock()
    }
}

enum CodexReplyResult {
    case success(String)
    case failure(String)
}

struct CodexAgentTask: Codable {
    var agent: String
    var task: String
    var mode: String?
    var cadence: String?
    var rationale: String?

    enum CodingKeys: String, CodingKey {
        case agent
        case task
        case mode
        case cadence
        case rationale
    }

    init(agent: String, task: String, mode: String? = nil, cadence: String? = nil, rationale: String? = nil) {
        self.agent = agent
        self.task = task
        self.mode = mode
        self.cadence = cadence
        self.rationale = rationale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = (try? container.decode(String.self, forKey: .agent)) ?? ""
        task = (try? container.decode(String.self, forKey: .task)) ?? ""
        mode = try? container.decode(String.self, forKey: .mode)
        cadence = try? container.decode(String.self, forKey: .cadence)
        rationale = try? container.decode(String.self, forKey: .rationale)
    }
}

struct CodexRoutePayload: Codable {
    var needsAgents: Bool
    var agents: [CodexAgentTask]
    var directAnswer: String?
    var finalAnswer: String?
    var summary: String?

    enum CodingKeys: String, CodingKey {
        case needsAgents
        case agents
        case directAnswer
        case finalAnswer
        case summary
    }

    init(needsAgents: Bool, agents: [CodexAgentTask], directAnswer: String? = nil, finalAnswer: String? = nil, summary: String? = nil) {
        self.needsAgents = needsAgents
        self.agents = agents
        self.directAnswer = directAnswer
        self.finalAnswer = finalAnswer
        self.summary = summary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        needsAgents = (try? container.decode(Bool.self, forKey: .needsAgents)) ?? false
        agents = (try? container.decode([CodexAgentTask].self, forKey: .agents)) ?? []
        directAnswer = try? container.decode(String.self, forKey: .directAnswer)
        finalAnswer = try? container.decode(String.self, forKey: .finalAnswer)
        summary = try? container.decode(String.self, forKey: .summary)
    }

    var userFacingAnswer: String {
        for candidate in [finalAnswer, directAnswer, summary] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }

        if needsAgents {
            let names = agents.map(\.agent).filter { !$0.isEmpty }.joined(separator: "、")
            return names.isEmpty ? "我判断这条消息需要能力节点参与，已进入分派流程。" : "我判断这条消息需要 \(names) 参与，已完成任务分派。"
        }

        return "收到。这一轮我可以直接处理。"
    }
}

enum CodexRouteResult {
    case success(CodexRoutePayload)
    case failure(String)
}

enum CodexPermissionMode: String, CaseIterable, Identifiable {
    case sandbox = "沙箱权限"
    case fullAccess = "完整权限"

    var id: String { rawValue }

    var sandboxArgument: String {
        switch self {
        case .sandbox: "workspace-write"
        case .fullAccess: "danger-full-access"
        }
    }

    var detail: String {
        switch self {
        case .sandbox:
            "仅允许 Codex 在目标项目内读写，适合日常开发。"
        case .fullAccess:
            "允许 Codex 访问更完整的本机文件系统，适合你明确授权的系统级操作。"
        }
    }
}

enum CodexBridge {
    static let bundledCLIPath = "/Applications/Codex.app/Contents/Resources/codex"

    static func resolveCLIPath(preferredPath: String) -> String? {
        let candidates = [
            preferredPath,
            bundledCLIPath,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]

        return candidates.first { path in
            !path.isEmpty && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    static func loginStatus(preferredPath: String) -> (status: String, detail: String) {
        guard let cliPath = resolveCLIPath(preferredPath: preferredPath) else {
            return ("未安装", "没有找到 Codex CLI")
        }

        let result = run(cliPath: cliPath, arguments: ["login", "status"], timeout: 8)
        let output = [result.stdout, result.stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if output.localizedCaseInsensitiveContains("Logged in using ChatGPT") {
            return ("已登录", "ChatGPT")
        }

        if output.localizedCaseInsensitiveContains("Logged in") {
            return ("已登录", output.replacingOccurrences(of: "\n", with: " "))
        }

        if result.exitCode == 0 {
            return ("未登录", output.isEmpty ? "Codex CLI 未返回登录账户" : output)
        }

        return ("检查失败", output.isEmpty ? "codex login status 退出码 \(result.exitCode)" : output)
    }

    private static func appendCodexFastArguments(to arguments: inout [String], enabled: Bool) {
        guard enabled else { return }

        arguments.append(contentsOf: ["-c", "model_reasoning_effort=\"low\""])
        arguments.append(contentsOf: ["-c", "service_tier=\"priority\""])
    }

    private static func codexExecArguments(
        outputURL: URL,
        modelName: String,
        workingDirectory: String,
        permissionMode: CodexPermissionMode,
        fastMode: Bool,
        remoteSessionID: String?
    ) -> [String] {
        let trimmedSessionID = remoteSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments: [String]

        if let trimmedSessionID, !trimmedSessionID.isEmpty {
            arguments = [
                "exec",
                "resume",
                "--ignore-user-config",
                "--ignore-rules",
                "--skip-git-repo-check",
                "-o", outputURL.path
            ]
            appendCodexFastArguments(to: &arguments, enabled: fastMode)
            let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedModel.isEmpty && !trimmedModel.contains("默认") {
                arguments.append(contentsOf: ["-m", trimmedModel])
            }
            arguments.append(trimmedSessionID)
            arguments.append("-")
            return arguments
        }

        arguments = [
            "exec",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--sandbox", permissionMode.sandboxArgument,
            "--color", "never",
            "-C", workingDirectory,
            "-o", outputURL.path
        ]

        appendCodexFastArguments(to: &arguments, enabled: fastMode)
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty && !trimmedModel.contains("默认") {
            arguments.append(contentsOf: ["-m", trimmedModel])
        }
        arguments.append("-")
        return arguments
    }

    private static func beginSessionCapture() -> CodexSessionCapture {
        .init(
            knownIDs: Set(readSessionIndex().map(\.id)),
            startedAt: Date()
        )
    }

    private static func resolvedSessionID(existingSessionID: String?, capture: CodexSessionCapture) -> String? {
        let trimmedExisting = existingSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedExisting, !trimmedExisting.isEmpty {
            return trimmedExisting
        }

        return readSessionIndex()
            .filter { !capture.knownIDs.contains($0.id) && $0.updatedAt >= capture.startedAt.addingTimeInterval(-5) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first?
            .id
    }

    private static func readSessionIndex() -> [CodexSessionIndexEntry] {
        let indexURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
        guard let raw = try? String(contentsOf: indexURL, encoding: .utf8) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(text)")
        }

        return raw
            .split(separator: "\n")
            .compactMap { line in
                try? decoder.decode(CodexSessionIndexEntry.self, from: Data(line.utf8))
            }
    }

    static func execReply(
        preferredPath: String,
        modelName: String,
        userPrompt: String,
        workingDirectory: String,
        permissionMode: CodexPermissionMode,
        timeout: TimeInterval,
        fastMode: Bool,
        remoteSessionID: String? = nil,
        cancellation: CodexExecutionHandle? = nil,
        progress: ((String) -> Void)? = nil,
        sessionRegistrar: ((String) -> Void)? = nil
    ) -> CodexReplyResult {
        guard let cliPath = resolveCLIPath(preferredPath: preferredPath) else {
            return .failure("没有找到 Codex CLI。请确认 Codex.app 已安装。")
        }

        let trimmedWorkingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedWorkingDirectory = trimmedWorkingDirectory.isEmpty ? FileManager.default.currentDirectoryPath : trimmedWorkingDirectory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedWorkingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure("目标项目目录不存在：\(resolvedWorkingDirectory)")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let sessionCapture = beginSessionCapture()
        let arguments = codexExecArguments(
            outputURL: outputURL,
            modelName: modelName,
            workingDirectory: resolvedWorkingDirectory,
            permissionMode: permissionMode,
            fastMode: fastMode,
            remoteSessionID: remoteSessionID
        )

        let bridgePrompt = """
        你是“灵枢”的通用中枢人格：冷静、可靠、克制、略有温度，像一位常驻身边的智能管家和总调度官。
        你不是演示假回复；请基于用户输入给出真实、简洁、中文的回答。
        你只能以“灵枢”的统一口吻回复用户，不要提到底层模型、Codex、CLI、Auth、JSON、路由流程等内部实现，除非用户明确询问技术接入。
        不要模拟多个 agent 的分角色对话；能力节点只在后台协作，由你统一出声。
        如果用户问“你是谁”“你是什么”“你叫什么”这类身份问题，只回答：“我是灵枢，有什么可以帮你的？”
        当前目标项目目录：\(resolvedWorkingDirectory)
        当前权限模式：\(permissionMode.rawValue)，Codex 沙箱：\(permissionMode.sandboxArgument)
        如果用户提出需要落地的复杂任务，你要以通用中枢的视角工作：先规划，再审议风险和权限，然后调度必要能力节点执行，最后只汇报真实执行结果。
        每轮回复前做一次收束判断：当前回答是否已经满足用户的显性需求，以及是否存在很自然的潜在下一步。满足度高就简洁收束；满足度不高时，只提出一个自然的继续推进问题，不要套固定模板。
        不要声称已经完成外部文件修改、网络请求、发送邮件或真实部署，除非你已经通过工具或命令得到明确结果。

        用户输入：
        \(userPrompt)
        """

        let result = run(cliPath: cliPath, arguments: arguments, stdin: bridgePrompt, timeout: timeout, cancellation: cancellation, progress: progress)
        if let sessionID = resolvedSessionID(existingSessionID: remoteSessionID, capture: sessionCapture) {
            sessionRegistrar?(sessionID)
        }
        if result.exitCode == -3 {
            return .failure("Codex CLI 调用已取消。")
        }

        let fileReply = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let fileReply, !fileReply.isEmpty {
            return .success(fileReply)
        }

        let fallback = CodexDiagnosticLogFilter.userVisibleText(from: [result.stdout, result.stderr]
            .joined(separator: "\n")
        )

        if result.exitCode == 0 && !fallback.isEmpty {
            return .success(fallback)
        }

        if result.exitCode == -2 {
            return .failure("Codex CLI 心跳失联。连续 \(Int(timeout)) 秒没有底层输出或进程心跳。")
        }

        return .failure(fallback.isEmpty ? "Codex CLI 调用失败，退出码 \(result.exitCode)。" : fallback)
    }

    static func routeReply(
        preferredPath: String,
        modelName: String,
        userPrompt: String,
        memoryContext: String,
        workingDirectory: String,
        permissionMode: CodexPermissionMode,
        timeout: TimeInterval,
        fastMode: Bool,
        remoteSessionID: String? = nil,
        cancellation: CodexExecutionHandle? = nil,
        progress: ((String) -> Void)? = nil,
        sessionRegistrar: ((String) -> Void)? = nil
    ) -> CodexRouteResult {
        guard let cliPath = resolveCLIPath(preferredPath: preferredPath) else {
            return .failure("没有找到 Codex CLI。请确认 Codex.app 已安装。")
        }

        let trimmedWorkingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedWorkingDirectory = trimmedWorkingDirectory.isEmpty ? FileManager.default.currentDirectoryPath : trimmedWorkingDirectory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedWorkingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure("目标项目目录不存在：\(resolvedWorkingDirectory)")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-route-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let sessionCapture = beginSessionCapture()
        let arguments = codexExecArguments(
            outputURL: outputURL,
            modelName: modelName,
            workingDirectory: resolvedWorkingDirectory,
            permissionMode: permissionMode,
            fastMode: fastMode,
            remoteSessionID: remoteSessionID
        )

        let routePrompt = """
        你是“灵枢”的通用中枢人格和调度模型。你必须先判断用户消息是否需要调用专家 agent 或任务运行时。
        灵枢的人格基调：冷静、可靠、克制、敏锐，像常驻身边的智能管家和总调度官；回复要自然、有存在感，但不要夸张表演。
        重要定位：灵枢不是工匠；灵枢是通用任务中枢，负责承接用户命令、判断任务类型、规划、审议、调度、权限裁决、过程监控和最终验收。真正执行由任务运行时、内部 agent 或外部 agent 完成。
        通用治理原则：复杂任务必须先规划，再审议风险、事实和权限，随后由调度节点把已批准计划分派给必要能力节点落地。
        内置知识库：
        - 灵枢的主线程负责理解意图、检索主线程记忆/冷备库、判断是否创建任务线程，以及决定是否需要外部或内部 agent。
        - 普通问答也必须基于主线程记忆、冷备库和内置知识库回答；只是无需创建任务线程，也无需展示 agent 调用链。
        - 执行线程只用于需要产出、开发、测试、读写文件、工具循环或多能力协作的任务；灵枢本人不做工匠工作，只负责分析、转发、监督和验收。
        - 执行记忆用于恢复具体任务线程的目标、约束、已完成事项和风险；主线程记忆用于判断当前消息是否续接历史讨论。
        - 后续外部 agent 可以接入灵枢，灵枢通过路由、权限、心跳、结果审核和记忆沉淀统一管理它们。

        输出要求：
        1. 只输出一个 JSON 对象，不要 Markdown，不要代码块，不要额外解释。
        2. 字段必须是：
           {
             "needsAgents": true 或 false,
             "summary": "一句话说明你的路由判断",
             "directAnswer": "如果 needsAgents=false，这里给用户的直接回答；否则可为空",
             "finalAnswer": "灵枢最终回复给用户的话，只能用灵枢统一口吻",
             "agents": [
               {
                 "agent": "\(LingShuCapabilityRole.promptChoiceList)",
                 "task": "分派给该 agent 的具体任务",
                 "mode": "规划|设计|执行|监工|纠偏|验收|待命",
                 "cadence": "本轮|实时|立即|提交后|3m|5m|7m|10m",
                 "rationale": "为什么需要这个 agent"
               }
             ]
           }
        3. 如果是闲聊、概念解释、普通问答、学习型问答，且不涉及开发产出或多专业协作，needsAgents=false，agents=[]，直接基于主线程压缩记忆和内置知识库回答。
        4. 如果用户要求写代码、脚本、函数、页面、接口、爬虫、demo 或程序，即使不修改当前项目，也属于可执行任务，needsAgents=true，必须包含“规划”“审议”“调度”，并至少选择“执行”agent。
        5. 如果用户提出需求分析、版本迭代、缺陷修复、测试、架构、设计、PPT、演示文稿、汇报材料、视觉方案、验收、Review、部署等任务，也要进入任务运行时；必须包含“规划”“审议”“调度”，再按需要选择设计、执行、监控、验证、安全、知识、记忆、路由。
        6. 如果代码任务没有明确要求读取/修改当前项目文件、运行构建或测试，仍然进入执行队列，但执行 agent 只产出代码和使用说明，不做项目文件操作。
        7. 只有当用户明确要求操作当前项目、修改文件、修复报错、运行测试、生成项目产物、推进一个能力协作任务，或任务确实需要跨多个专家协作时，才让执行器操作工作区。
        8. 不要把所有 agent 都列出来；后续可能有成百上千个 agent，本轮只返回必要 agent。
        9. 不要在回答里假装已经修改文件、运行测试、部署系统或完成外部动作，除非用户消息明确要求并且执行阶段已经完成。当前这一步只做路由判断、任务分派和灵枢口吻回复。
        10. finalAnswer 不要出现“规划 agent：”“执行 agent：”等多角色对话格式。
        11. finalAnswer 不要提到 Codex、Auth、CLI、JSON、模型通道、底层调用、路由 JSON 等内部实现，除非用户明确问这些技术细节。
        12. finalAnswer 可以简短地说“收到”“我会交给任务运行时处理”“相关执行器会介入”，但不要每轮都解释连接状态或工作原理。
        13. 如果用户问“你是谁”“你是什么”“你叫什么”“灵枢是谁”这类身份问题，needsAgents=false，agents=[]，finalAnswer 必须简洁自信，例如：“我是灵枢，有什么可以帮你的？”
        14. 如果用户的目标、对象、范围、交付物、权限边界或继续对象不明确，且无法从记忆中可靠判断，needsAgents=false，agents=[]，finalAnswer 只问必要的澄清问题；不要创建任务线程，不要盲目分派 agent。
        15. 生成 finalAnswer 前做一次需求满足度判断：显性需求是否已满足、潜在下一步是否明显。如果满足度高，就干净回答；如果只完成了第一层交付，或后续很可能需要落地、验证、细化、保存、运行、审查、生成产物，只提出一个自然的继续推进问题。不要针对某个关键词使用固定追问模板。
        16. 如果 needsAgents=true 且本轮会进入执行阶段，finalAnswer 只表达已接令和正在分派，不要提前追问用户是否继续；真正的收束判断和继续推进问题应在执行结果回传后发生。

        可用专家 agent：
        \(LingShuCapabilityRole.promptCatalog)

        当前目标项目目录：\(resolvedWorkingDirectory)
        当前权限模式：\(permissionMode.rawValue)，Codex 沙箱：\(permissionMode.sandboxArgument)

        主线程压缩记忆：
        \(memoryContext)

        记忆使用规则：
        - 这些记忆只用于判断是否续接历史线程、是否需要创建任务线程、是否应加载执行记忆。
        - 不要把记忆当成已经完成的本轮事实；如果要执行，仍需进入对应执行阶段。
        - 如果记忆提示用户在延续某个项目或主题，优先保持上下文连续性；如果没有命中，则按新任务处理。

        用户消息：
        \(userPrompt)
        """

        let result = run(cliPath: cliPath, arguments: arguments, stdin: routePrompt, timeout: timeout, cancellation: cancellation, progress: progress)
        if let sessionID = resolvedSessionID(existingSessionID: remoteSessionID, capture: sessionCapture) {
            sessionRegistrar?(sessionID)
        }
        if result.exitCode == -3 {
            return .failure("Codex CLI 路由调用已取消。")
        }

        let fileReply = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let rawReply = fileReply?.isEmpty == false
            ? fileReply!
            : CodexDiagnosticLogFilter.userVisibleText(from: [result.stdout, result.stderr].joined(separator: "\n"))

        if !rawReply.isEmpty {
            if let payload = decodeRoutePayload(from: rawReply) {
                return .success(sanitizeRoutePayload(payload))
            }

            let fallback = CodexRoutePayload(
                needsAgents: false,
                agents: [],
                directAnswer: rawReply,
                finalAnswer: rawReply,
                summary: "本轮没有形成明确分派，灵枢先直接回应。"
            )
            return .success(fallback)
        }

        if result.exitCode == -2 {
            return .failure("Codex CLI 路由心跳失联。连续 \(Int(timeout)) 秒没有底层输出或进程心跳。")
        }

        return .failure("Codex CLI 路由调用失败，退出码 \(result.exitCode)。")
    }

    static func healthProbe(
        preferredPath: String,
        modelName: String,
        workingDirectory: String,
        permissionMode: CodexPermissionMode,
        timeout: TimeInterval,
        fastMode: Bool,
        remoteSessionID: String? = nil,
        cancellation: CodexExecutionHandle? = nil,
        progress: ((String) -> Void)? = nil,
        sessionRegistrar: ((String) -> Void)? = nil
    ) -> CodexHealthProbeResult {
        guard let cliPath = resolveCLIPath(preferredPath: preferredPath) else {
            return .failure(.init(message: "没有找到 Codex CLI。请确认 Codex.app 已安装。", rawLog: ""))
        }

        let trimmedWorkingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedWorkingDirectory = trimmedWorkingDirectory.isEmpty ? FileManager.default.currentDirectoryPath : trimmedWorkingDirectory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedWorkingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.init(message: "目标项目目录不存在：\(resolvedWorkingDirectory)", rawLog: ""))
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-health-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let sessionCapture = beginSessionCapture()
        let arguments = codexExecArguments(
            outputURL: outputURL,
            modelName: modelName,
            workingDirectory: resolvedWorkingDirectory,
            permissionMode: permissionMode,
            fastMode: fastMode,
            remoteSessionID: remoteSessionID
        )

        let probePrompt = """
        你是灵枢主线程远端健康探针。
        只输出：LINGSHU_HEALTH_OK
        """

        let result = run(
            cliPath: cliPath,
            arguments: arguments,
            stdin: probePrompt,
            timeout: timeout,
            cancellation: cancellation,
            progress: progress
        )
        if let sessionID = resolvedSessionID(existingSessionID: remoteSessionID, capture: sessionCapture) {
            sessionRegistrar?(sessionID)
        }

        let fileReply = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLog = [result.stdout, result.stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleReply = fileReply?.isEmpty == false
            ? fileReply!
            : CodexDiagnosticLogFilter.userVisibleText(from: rawLog)

        if result.exitCode == 0, !visibleReply.isEmpty {
            return .success(.init(reply: visibleReply, rawLog: rawLog))
        }

        if result.exitCode == -2 {
            return .failure(.init(
                message: "主线程远端探活连续 \(Int(timeout)) 秒没有心跳。",
                rawLog: rawLog
            ))
        }

        let fallback = CodexDiagnosticLogFilter.userVisibleText(from: rawLog)
        return .failure(.init(
            message: fallback.isEmpty ? "主线程远端探活失败，退出码 \(result.exitCode)。" : fallback,
            rawLog: rawLog
        ))
    }

    private static func decodeRoutePayload(from rawReply: String) -> CodexRoutePayload? {
        guard let json = extractJSONObject(from: rawReply), let data = json.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(CodexRoutePayload.self, from: data)
    }

    private static func extractJSONObject(from rawReply: String) -> String? {
        let trimmed = rawReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end else {
            return nil
        }

        return String(trimmed[start...end])
    }

    private static func sanitizeRoutePayload(_ payload: CodexRoutePayload) -> CodexRoutePayload {
        var seenAgents = Set<String>()
        let sanitizedTasks = payload.agents.compactMap { task -> CodexAgentTask? in
            guard let agent = normalizedAgentName(task.agent), !seenAgents.contains(agent) else {
                return nil
            }

            let trimmedTask = task.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTask.isEmpty else { return nil }

            seenAgents.insert(agent)
            return CodexAgentTask(
                agent: agent,
                task: trimmedTask,
                mode: task.mode?.trimmingCharacters(in: .whitespacesAndNewlines),
                cadence: task.cadence?.trimmingCharacters(in: .whitespacesAndNewlines),
                rationale: task.rationale?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let needsAgents = payload.needsAgents && !sanitizedTasks.isEmpty
        return CodexRoutePayload(
            needsAgents: needsAgents,
            agents: needsAgents ? sanitizedTasks : [],
            directAnswer: payload.directAnswer,
            finalAnswer: payload.finalAnswer,
            summary: payload.summary
        )
    }

    private static func normalizedAgentName(_ rawName: String) -> String? {
        LingShuCapabilityRole.normalize(rawName)?.rawValue
    }

    private static func run(
        cliPath: String,
        arguments: [String],
        stdin: String? = nil,
        timeout: TimeInterval,
        cancellation: CodexExecutionHandle? = nil,
        progress: ((String) -> Void)? = nil
    ) -> CodexCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["TERM": "dumb"]) { _, new in new }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let streamCapture = CodexStreamCapture(progress: progress)

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            streamCapture.capture(handle.availableData, isError: false)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            streamCapture.capture(handle.availableData, isError: true)
        }

        let inputPipe = Pipe()
        if stdin != nil {
            process.standardInput = inputPipe
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
            cancellation?.attach(process)
            if cancellation?.isCancelled == true {
                return .init(exitCode: -3, stdout: "", stderr: "Codex CLI 调用已取消。")
            }

            if let stdin, let data = stdin.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
                inputPipe.fileHandleForWriting.closeFile()
            }
        } catch {
            return .init(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let heartbeatPolicy = LingShuHeartbeatPolicy(idleTimeout: timeout)
        var lastSyntheticHeartbeatAt = Date()

        while true {
            if semaphore.wait(timeout: .now() + 1) == .success {
                break
            }

            if cancellation?.isCancelled == true {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                process.terminate()
                let stdout = streamCapture.stdout
                let stderr = streamCapture.stderr
                return .init(exitCode: -3, stdout: stdout, stderr: stderr.isEmpty ? "Codex CLI 调用已取消。" : stderr)
            }

            let now = Date()
            if heartbeatPolicy.shouldEmitSyntheticHeartbeat(
                processIsRunning: process.isRunning,
                lastSyntheticHeartbeatAt: lastSyntheticHeartbeatAt,
                now: now
            ) {
                lastSyntheticHeartbeatAt = now
                streamCapture.markHeartbeat()
                progress?("__LINGSHU_HEARTBEAT__ Codex CLI 进程仍在运行，等待模型或工具返回。")
            }

            if !process.isRunning {
                break
            }

            if heartbeatPolicy.shouldDeclareHeartbeatLost(
                processIsRunning: process.isRunning,
                lastActivityAt: streamCapture.lastActivity,
                now: now
            ) {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                cancellation?.cancel()
                process.terminate()
                let stdout = streamCapture.stdout
                let stderr = streamCapture.stderr
                return .init(exitCode: -2, stdout: stdout, stderr: stderr.isEmpty ? "Codex CLI 心跳失联。" : stderr)
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        streamCapture.capture(outputPipe.fileHandleForReading.readDataToEndOfFile(), isError: false)
        streamCapture.capture(errorPipe.fileHandleForReading.readDataToEndOfFile(), isError: true)

        let stdout = streamCapture.stdout
        let stderr = streamCapture.stderr
        cancellation?.detach(process)

        if cancellation?.isCancelled == true {
            return .init(exitCode: -3, stdout: stdout, stderr: stderr.isEmpty ? "Codex CLI 调用已取消。" : stderr)
        }

        return .init(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
